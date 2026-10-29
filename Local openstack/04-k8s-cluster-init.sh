#!/bin/bash
###############################################################################
# 04-k8s-cluster-init.sh
#
# Initializes the Kubernetes control plane. Run this ON the control plane VM
# (k8s-control-1) as root or with sudo.
#
# Actions:
#   - Waits for cloud-init to finish
#   - Runs kubeadm init
#   - Sets up kubectl for the 'ubuntu' user
#   - Installs Calico CNI v3.28.2
#   - Generates and saves the worker join command
#
# Usage:
#   ssh -i ~/.ssh/k8s-key.pem ubuntu@<CONTROL_IP>
#   sudo ./04-k8s-cluster-init.sh
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
# Pre-flight: must be root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "=========================================="
info " Kubernetes – Control Plane Initialization"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Wait for cloud-init to complete
# ---------------------------------------------------------------------------
info "Waiting for cloud-init to finish …"

cloud-init status --wait 2>/dev/null || true

# Extra safety: wait for kubeadm to be available
RETRIES=60
while ! command -v kubeadm &>/dev/null && [[ $RETRIES -gt 0 ]]; do
    info "  kubeadm not yet available – waiting (${RETRIES} retries left) …"
    sleep 10
    RETRIES=$((RETRIES - 1))
done

if ! command -v kubeadm &>/dev/null; then
    error "kubeadm was not installed by cloud-init. Check /var/log/cloud-init-output.log"
fi

success "cloud-init complete – kubeadm v$(kubeadm version -o short) available."
echo ""

# ---------------------------------------------------------------------------
# 2. Detect internal IP
# ---------------------------------------------------------------------------
NODE_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)10\.\d+\.\d+\.\d+' | head -1)

if [[ -z "${NODE_IP}" ]]; then
    # Fallback: use the default route interface
    DEFAULT_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
    NODE_IP=$(ip -4 addr show dev "${DEFAULT_IFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
fi

info "Node IP: ${NODE_IP}"
echo ""

# ---------------------------------------------------------------------------
# 3. Prepare kubeadm v1beta4 config with iptables mode
# ---------------------------------------------------------------------------
info "Detecting external IP / extra SANs for API server certificate …"

EXTRA_SANS_LIST=()
EXTRA_SANS_LIST+=("${NODE_IP}")

METADATA_IP=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
if [[ -n "${METADATA_IP}" && "${METADATA_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    EXTRA_SANS_LIST+=("${METADATA_IP}")
fi

# Also check for vm-ips.env if copied locally or on shared storage
if [[ -f "/tmp/vm-ips.env" ]]; then
    # shellcheck source=/dev/null
    source "/tmp/vm-ips.env"
    if [[ -n "${CONTROL_IP:-}" && "${CONTROL_IP}" != "${METADATA_IP:-}" ]]; then
        EXTRA_SANS_LIST+=("${CONTROL_IP}")
    fi
fi

info "Writing kubeadm v1beta4 configuration with mode: iptables …"
KUBEADM_CONFIG="/tmp/kubeadm-config.yaml"

cat > "${KUBEADM_CONFIG}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  name: $(hostname)
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.0
clusterName: kubernetes
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
apiServer:
  certSANs:
$(for san in "${EXTRA_SANS_LIST[@]}"; do echo "    - \"${san}\""; done)
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "iptables"
EOF

# Ensure containerd is active and responsive
info "Ensuring containerd runtime is active and responsive..."
systemctl restart containerd
sleep 5
for i in $(seq 1 15); do
    if ctr -a /run/containerd/containerd.sock version &>/dev/null; then
        success "containerd runtime is responsive."
        break
    fi
    info "  Waiting for containerd socket (attempt ${i}/15)..."
    sleep 2
done

info "Running kubeadm init with kubeadm-config.yaml …"

if ! kubeadm init --config="${KUBEADM_CONFIG}" --upload-certs 2>&1 | tee /tmp/kubeadm-init.log; then
    warn "kubeadm init encountered an issue, restarting containerd and retrying with preflight check..."
    systemctl restart containerd
    sleep 5
    kubeadm reset -f || true
    kubeadm init --config="${KUBEADM_CONFIG}" --upload-certs 2>&1 | tee /tmp/kubeadm-init.log
fi

# Patch kube-scheduler for Kubernetes 1.36 single control-plane deadlock fix
info "Patching kube-scheduler: disabling leader election for single control-plane (K8s 1.36 fix)..."
sed -i 's/- --leader-elect=true/- --leader-elect=false/' /etc/kubernetes/manifests/kube-scheduler.yaml 2>/dev/null || true

success "kubeadm init completed."
echo ""

# ---------------------------------------------------------------------------
# 4. Set up kubectl for the 'ubuntu' user
# ---------------------------------------------------------------------------
info "Configuring kubectl for the 'ubuntu' user …"

UBUNTU_HOME="/home/ubuntu"
mkdir -p "${UBUNTU_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${UBUNTU_HOME}/.kube/config"
chown -R ubuntu:ubuntu "${UBUNTU_HOME}/.kube"

# Also set up for root
export KUBECONFIG=/etc/kubernetes/admin.conf

success "kubectl configured."
echo ""

# ---------------------------------------------------------------------------
# 5. Install Calico CNI v3.28.2 (Ubuntu 24.04 / Linux 6.8+ compatible)
# ---------------------------------------------------------------------------
info "Installing Calico CNI v3.28.2 …"

CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml"
kubectl apply -f "${CALICO_URL}"

# Wait for Calico pods to start
info "Waiting for Calico pods to become ready …"

RETRIES=30
while [[ $RETRIES -gt 0 ]]; do
    READY=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [[ "$READY" -ge 1 ]]; then
        success "Calico is running (${READY} node(s))."
        break
    fi
    info "  Calico pods not ready yet – waiting (${RETRIES} retries left) …"
    sleep 10
    RETRIES=$((RETRIES - 1))
done

if [[ $RETRIES -eq 0 ]]; then
    info "Calico pods may still be starting. Check: kubectl get pods -n kube-system"
fi

# ---------------------------------------------------------------------------
# 5b. Deploy Local Path Storage Provisioner for PersistentVolumeClaims (PVC)
# ---------------------------------------------------------------------------
info "Deploying Local Path Provisioner to support standard PersistentVolumeClaims …"
if [[ -f "/tmp/manifests/local-path-storage.yaml" ]]; then
    kubectl apply -f "/tmp/manifests/local-path-storage.yaml" 2>/dev/null || true
elif [[ -f "${SCRIPT_DIR}/manifests/local-path-storage.yaml" ]]; then
    kubectl apply -f "${SCRIPT_DIR}/manifests/local-path-storage.yaml" 2>/dev/null || true
elif [[ -f "/opt/stack/lab/manifests/local-path-storage.yaml" ]]; then
    kubectl apply -f "/opt/stack/lab/manifests/local-path-storage.yaml" 2>/dev/null || true
else
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml 2>/dev/null || true
fi
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true


echo ""

# ---------------------------------------------------------------------------
# 6. Generate join command
# ---------------------------------------------------------------------------
info "Generating worker join command …"

JOIN_CMD=$(kubeadm token create --print-join-command)

cat > /tmp/kubeadm-join.sh <<EOF
#!/bin/bash
# Kubernetes worker join command – generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Run this on each worker node as root.
set -euo pipefail
${JOIN_CMD}
EOF

chmod +x /tmp/kubeadm-join.sh

success "Join command saved to /tmp/kubeadm-join.sh"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "=========================================="
info " Control Plane Initialization Complete"
info "=========================================="
echo ""
success "Node name .............. $(hostname)"
success "Node IP ................ ${NODE_IP}"
success "Pod CIDR ............... 10.244.0.0/16"
success "Service CIDR ........... 10.96.0.0/12"
success "CNI .................... Calico v3.28.2"
echo ""
info "Join command for workers:"
echo ""
echo "  ${JOIN_CMD}"
echo ""
info "Or copy /tmp/kubeadm-join.sh to each worker and execute it."
info "Next step: run 05-k8s-worker-join.sh on each worker node."
echo ""
