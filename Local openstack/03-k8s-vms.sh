#!/bin/bash
###############################################################################
# 03-k8s-vms.sh
#
# Launches 3 OpenStack VMs for the Kubernetes cluster:
#   - k8s-control-1  (k8s-control flavor)
#   - k8s-worker-1   (k8s-worker flavor)
#   - k8s-worker-2   (k8s-worker flavor)
#
# Each VM is provisioned via cloud-init with containerd, kubeadm, kubelet,
# and kubectl v1.30 pre-installed. Floating IPs are assigned to all VMs.
#
# Usage:
#   source /opt/stack/devstack/openrc admin admin
#   ./03-k8s-vms.sh
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Source credentials
# ---------------------------------------------------------------------------
info "Sourcing OpenStack credentials …"
set +u
source /opt/stack/devstack/openrc admin admin
set -u
success "Credentials loaded."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERDATA_FILE="/tmp/k8s-cloud-init.yaml"
VM_IPS_FILE="${SCRIPT_DIR}/vm-ips.env"
KEY_FILE="${HOME}/.ssh/k8s-key.pem"

echo ""
info "=========================================="
info " OpenStack Lab – Launch Kubernetes VMs"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Generate cloud-init userdata
# ---------------------------------------------------------------------------
info "Generating cloud-init userdata …"

cat > "${USERDATA_FILE}" <<'CLOUDINIT'
#cloud-config
package_update: true

write_files:
  # Kernel modules for containerd / Kubernetes
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter

  # Sysctl parameters for Kubernetes networking
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1

  # containerd configuration with SystemdCgroup enabled
  - path: /etc/containerd/config.toml
    content: |
      version = 2
      [plugins]
        [plugins."io.containerd.grpc.v1.cri"]
          [plugins."io.containerd.grpc.v1.cri".containerd]
            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
              [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
                runtime_type = "io.containerd.runc.v2"
                [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
                  SystemdCgroup = true

runcmd:
  # Load required kernel modules
  - modprobe overlay
  - modprobe br_netfilter
  - sysctl --system

  # Disable swap
  - swapoff -a
  - sed -i '/\sswap\s/d' /etc/fstab

  # Install containerd and networking tools
  - DEBIAN_FRONTEND=noninteractive apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg iptables iptables-persistent

  # Create containerd config directory and restart
  - mkdir -p /etc/containerd
  # Config already written via write_files above; just restart
  - systemctl restart containerd
  - systemctl enable containerd

  # Add Kubernetes apt repository (v1.36)
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

  # Install kubeadm, kubelet, kubectl
  - DEBIAN_FRONTEND=noninteractive apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl

  # Enable kubelet (it will wait for kubeadm init/join)
  - systemctl enable kubelet
CLOUDINIT

success "Cloud-init userdata written to ${USERDATA_FILE}"
echo ""

# ---------------------------------------------------------------------------
# 2. Launch VMs
# ---------------------------------------------------------------------------
declare -A VM_FLAVORS=(
    ["k8s-control-1"]="k8s-control"
    ["k8s-worker-1"]="k8s-worker"
    ["k8s-worker-2"]="k8s-worker"
)

for VM_NAME in k8s-control-1 k8s-worker-1 k8s-worker-2; do
    FLAVOR="${VM_FLAVORS[$VM_NAME]}"
    info "Launching '${VM_NAME}' (flavor: ${FLAVOR}) …"

    if openstack server show "${VM_NAME}" &>/dev/null; then
        info "VM '${VM_NAME}' already exists – skipping."
    else
        openstack server create "${VM_NAME}" \
            --image ubuntu-24.04 \
            --flavor "${FLAVOR}" \
            --network k8s-net \
            --security-group k8s-sg \
            --key-name k8s-key \
            --user-data "${USERDATA_FILE}" \
            --wait
        success "VM '${VM_NAME}' launched."
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 3. Wait for all VMs to be ACTIVE
# ---------------------------------------------------------------------------
info "Waiting for all VMs to reach ACTIVE state …"

for VM_NAME in k8s-control-1 k8s-worker-1 k8s-worker-2; do
    RETRIES=30
    while [[ $RETRIES -gt 0 ]]; do
        STATUS=$(openstack server show "${VM_NAME}" -f value -c status)
        if [[ "${STATUS}" == "ACTIVE" ]]; then
            success "${VM_NAME} is ACTIVE."
            break
        elif [[ "${STATUS}" == "ERROR" ]]; then
            error "${VM_NAME} entered ERROR state."
        fi
        info "  ${VM_NAME}: ${STATUS} – waiting …"
        sleep 10
        RETRIES=$((RETRIES - 1))
    done

    if [[ $RETRIES -eq 0 ]]; then
        error "${VM_NAME} did not become ACTIVE within timeout."
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 4. Assign floating IPs
# ---------------------------------------------------------------------------
info "Assigning floating IPs …"

declare -A FLOATING_IPS

for VM_NAME in k8s-control-1 k8s-worker-1 k8s-worker-2; do
    # Check if a floating IP is already assigned (handles dict, list, and string formats)
    EXISTING_FIP=$(openstack server show "${VM_NAME}" -f json | \
        python3 -c "import sys,json,re; d=json.load(sys.stdin); s=json.dumps(d.get('addresses','')); m=re.findall(r'172\.24\.4\.\d+', s); print(m[0] if m else '')" 2>/dev/null || echo "")

    if [[ -n "${EXISTING_FIP}" ]]; then
        info "${VM_NAME} already has floating IP: ${EXISTING_FIP}"
        FLOATING_IPS["${VM_NAME}"]="${EXISTING_FIP}"
    else
        FIP=$(openstack floating ip create public -f value -c floating_ip_address)
        openstack server add floating ip "${VM_NAME}" "${FIP}"
        FLOATING_IPS["${VM_NAME}"]="${FIP}"
        success "${VM_NAME} → ${FIP}"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 5. Save vm-ips.env mapping file
# ---------------------------------------------------------------------------
info "Saving VM IP mapping to ${VM_IPS_FILE} …"

DEFAULT_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
HOST_IP=$(ip -4 addr show dev "${DEFAULT_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")

cat > "${VM_IPS_FILE}" <<EOF
# VM floating IP mapping – generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONTROL_IP=${FLOATING_IPS["k8s-control-1"]}
WORKER_IP=${FLOATING_IPS["k8s-worker-1"]}
WORKER1_IP=${FLOATING_IPS["k8s-worker-1"]}
WORKER2_IP=${FLOATING_IPS["k8s-worker-2"]}
DESIGNATE_IP=${HOST_IP}
EOF

success "Mapping saved."
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "=========================================="
info " Kubernetes VMs Launched"
info "=========================================="
echo ""
success "k8s-control-1 ...... ${FLOATING_IPS["k8s-control-1"]}"
success "k8s-worker-1 ....... ${FLOATING_IPS["k8s-worker-1"]}"
success "k8s-worker-2 ....... ${FLOATING_IPS["k8s-worker-2"]}"
echo ""
info "SSH access (wait ~3 min for cloud-init):"
echo ""
echo "  ssh -i ${KEY_FILE} ubuntu@${FLOATING_IPS["k8s-control-1"]}   # control plane"
echo "  ssh -i ${KEY_FILE} ubuntu@${FLOATING_IPS["k8s-worker-1"]}   # worker 1"
echo "  ssh -i ${KEY_FILE} ubuntu@${FLOATING_IPS["k8s-worker-2"]}   # worker 2"
echo ""
info "IP mapping file: ${VM_IPS_FILE}"
info "Next step: SSH to the control plane and run 04-k8s-cluster-init.sh"
echo ""
