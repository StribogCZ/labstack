#!/bin/bash
###############################################################################
# run-all-automated.sh
#
# Master automated orchestrator for the complete ACME Lab:
#   1. DevStack Installation (2024.2 Dalmatian + Designate DNS)
#   2. OpenStack Infrastructure Setup (Image, Network, SG, Flavors)
#   3. Kubernetes VMs Provisioning (Control + 2 Workers)
#   4. CZERTAINLY CA VM Provisioning (In-Cloud Variant A)
#   5. Kubernetes Cluster Initialization (Calico CNI v3.28.2)
#   6. Worker Nodes Join
#   7. Istio 1.22 IngressGateway Deployment (NodePort)
#   8. CZERTAINLY CA Integration & Trust Bundle
#   9. acme-dns Deployment & Designate CNAME Delegation
#  10. cert-manager Deployment (Native acmeDNS Solver)
#  11. Test App Deployment & TLS Issuance Verification
#
# Must be run as user 'stack' on the OpenStack host:
#   ./run-all-automated.sh
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/stack/logs"
mkdir -p "${LOG_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step() {
    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}  [$(date -u +'%Y-%m-%d %H:%M:%SZ')] $1${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    echo ""
}

info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${CYAN}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -----------------------------------------------------------------------------
# Pre-flight check: ensure running as 'stack'
# -----------------------------------------------------------------------------
if [[ "$(whoami)" != "stack" ]]; then
    error "This script must be run as the 'stack' user. Switch with: sudo su - stack"
fi

cd "${SCRIPT_DIR}"

# -----------------------------------------------------------------------------
# STEP 1: DevStack Installation
# -----------------------------------------------------------------------------
log_step "STEP 1: DevStack Installation (2024.2 + Designate + Heat)"

if [[ ! -f "/opt/stack/devstack/openrc" ]]; then
    info "Starting DevStack installation (stack.sh) …"
    ./01-devstack-install.sh
else
    success "DevStack already installed (/opt/stack/devstack/openrc exists)."
fi

# Load OpenStack credentials
# shellcheck source=/dev/null
set +u
source "/opt/stack/devstack/openrc" admin admin
trap - ERR || true
warn()    { echo -e "${CYAN}[WARN]${NC}  $*"; }
info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
set -u
success "OpenStack credentials loaded."

# -----------------------------------------------------------------------------
# STEP 2: OpenStack Infrastructure Setup
# -----------------------------------------------------------------------------
log_step "STEP 2: OpenStack Infrastructure Setup (Image, Network, SG, Flavors)"
./02-openstack-infra.sh

# -----------------------------------------------------------------------------
# STEP 3: Kubernetes VMs Launch
# -----------------------------------------------------------------------------
log_step "STEP 3: Launching Kubernetes VMs (k8s-control-1, k8s-worker-1, k8s-worker-2)"
./03-k8s-vms.sh

# -----------------------------------------------------------------------------
# STEP 3b: CZERTAINLY CA Instance Launch
# -----------------------------------------------------------------------------
log_step "STEP 3b: Launching CZERTAINLY CA VM (Variant A)"
./03b-czertainly-vm.sh

# Load VM floating IPs
if [[ ! -f "${SCRIPT_DIR}/vm-ips.env" ]]; then
    error "vm-ips.env not found!"
fi
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/vm-ips.env"

KEY_FILE="${HOME}/.ssh/k8s-key.pem"
if [[ ! -f "${KEY_FILE}" ]]; then
    error "SSH keypair ${KEY_FILE} not found!"
fi
chmod 600 "${KEY_FILE}"

SSH_OPTS=(-i "${KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

# -----------------------------------------------------------------------------
# STEP 4: K8s Control Plane Initialization
# -----------------------------------------------------------------------------
log_step "STEP 4: Initializing K8s Control Plane on k8s-control-1 (${CONTROL_IP})"

if [[ -f "${SCRIPT_DIR}/kubeadm-join.sh" && -f "${HOME}/.kube/config" ]] && kubectl --kubeconfig "${HOME}/.kube/config" get nodes &>/dev/null; then
    success "Control plane already initialized and kubectl responsive."
    export KUBECONFIG="${HOME}/.kube/config"
else
    info "Waiting for cloud-init on k8s-control-1 (${CONTROL_IP}) …"
    for i in $(seq 1 60); do
        if ssh "${SSH_OPTS[@]}" "ubuntu@${CONTROL_IP}" "cloud-init status --wait" 2>/dev/null; then
            success "cloud-init finished on k8s-control-1."
            break
        fi
        info "  Waiting for k8s-control-1 SSH / cloud-init (attempt ${i}/60) …"
        sleep 5
    done

    info "Copying 04-k8s-cluster-init.sh and manifests to k8s-control-1 …"
    scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/04-k8s-cluster-init.sh" "${SCRIPT_DIR}/vm-ips.env" "ubuntu@${CONTROL_IP}:/tmp/"
    scp "${SSH_OPTS[@]}" -r "${SCRIPT_DIR}/manifests" "ubuntu@${CONTROL_IP}:/tmp/"

    info "Executing 04-k8s-cluster-init.sh on k8s-control-1 …"
    ssh "${SSH_OPTS[@]}" "ubuntu@${CONTROL_IP}" "sudo chmod +x /tmp/04-k8s-cluster-init.sh && sudo /tmp/04-k8s-cluster-init.sh"

    info "Retrieving worker join command and kubeconfig …"
    scp "${SSH_OPTS[@]}" "ubuntu@${CONTROL_IP}:/tmp/kubeadm-join.sh" "${SCRIPT_DIR}/kubeadm-join.sh"
    chmod +x "${SCRIPT_DIR}/kubeadm-join.sh"

    mkdir -p "${HOME}/.kube"
    scp "${SSH_OPTS[@]}" "ubuntu@${CONTROL_IP}:/home/ubuntu/.kube/config" "${HOME}/.kube/config"
    chmod 600 "${HOME}/.kube/config"

    # Patch kubeconfig to use the public floating IP so host can run kubectl directly
    sed -i "s|https://10.10.0.*:6443|https://${CONTROL_IP}:6443|g" "${HOME}/.kube/config"
    export KUBECONFIG="${HOME}/.kube/config"
    success "kubectl configured on host pointing to https://${CONTROL_IP}:6443"
fi

# Verify kubectl on host
export KUBECONFIG="${HOME}/.kube/config"
kubectl cluster-info

# -----------------------------------------------------------------------------
# STEP 5: Join Worker Nodes
# -----------------------------------------------------------------------------
log_step "STEP 5: Joining Worker Nodes to Kubernetes Cluster"

for WORKER_IP_ADDR in "${WORKER1_IP}" "${WORKER2_IP}"; do
    if [[ -n "${WORKER_IP_ADDR:-}" ]]; then
        info "Preparing worker ${WORKER_IP_ADDR} …"
        if ssh "${SSH_OPTS[@]}" "ubuntu@${WORKER_IP_ADDR}" "test -f /etc/kubernetes/kubelet.conf && systemctl is-active --quiet kubelet" 2>/dev/null; then
            success "Worker ${WORKER_IP_ADDR} is already joined to cluster."
            continue
        fi
        for i in $(seq 1 60); do
            if ssh "${SSH_OPTS[@]}" "ubuntu@${WORKER_IP_ADDR}" "cloud-init status --wait" 2>/dev/null; then
                success "cloud-init finished on worker ${WORKER_IP_ADDR}."
                break
            fi
            info "  Waiting for worker ${WORKER_IP_ADDR} SSH (attempt ${i}/60) …"
            sleep 5
        done

        scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kubeadm-join.sh" "${SCRIPT_DIR}/05-k8s-worker-join.sh" "ubuntu@${WORKER_IP_ADDR}:/tmp/"
        ssh "${SSH_OPTS[@]}" "ubuntu@${WORKER_IP_ADDR}" "sudo chmod +x /tmp/05-k8s-worker-join.sh /tmp/kubeadm-join.sh && cat /tmp/kubeadm-join.sh | sudo /tmp/05-k8s-worker-join.sh"
        success "Worker ${WORKER_IP_ADDR} joined cluster."
    fi
done

info "Waiting for all cluster nodes to reach Ready state …"
for i in $(seq 1 45); do
    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "${READY_NODES}" -ge 2 && "${READY_NODES}" -eq "${TOTAL_NODES}" ]]; then
        success "All ${READY_NODES} Kubernetes nodes are Ready."
        break
    fi
    info "  Ready nodes: ${READY_NODES}/${TOTAL_NODES} (attempt ${i}/45) …"
    sleep 5
done
kubectl get nodes -o wide

# -----------------------------------------------------------------------------
# STEP 6: Deploy Istio IngressGateway
# -----------------------------------------------------------------------------
log_step "STEP 6: Deploying Istio 1.22 IngressGateway"
./06-deploy-istio.sh

# -----------------------------------------------------------------------------
# STEP 7: Integrate CZERTAINLY CA
# -----------------------------------------------------------------------------
log_step "STEP 7: Integrating CZERTAINLY CA"
# Wait briefly for CZERTAINLY cloud-init to start up services
info "Verifying CZERTAINLY CA connectivity …"
./07-deploy-czertainly.sh

# -----------------------------------------------------------------------------
# STEP 8: Deploy acme-dns & DNS Delegation
# -----------------------------------------------------------------------------
log_step "STEP 8: Deploying acme-dns and Configuring Designate DNS Delegation"
./08-deploy-acme-dns.sh

# -----------------------------------------------------------------------------
# STEP 9: Deploy cert-manager with Native acmeDNS Solver
# -----------------------------------------------------------------------------
log_step "STEP 9: Deploying cert-manager & ClusterIssuer"
./09-deploy-cert-manager.sh

# -----------------------------------------------------------------------------
# STEP 10: Deploy Test Application & Verify Certificate Issuance
# -----------------------------------------------------------------------------
log_step "STEP 10: Deploying Test Application & Validating TLS Issuance"
./10-deploy-test-app.sh

log_step "DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "Summary of deployed services:"
echo "  - OpenStack Horizon:      http://$(ip -4 route show default | awk '{print $5}' | xargs ip -4 addr show dev | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)/dashboard"
echo "  - CZERTAINLY Web UI:      https://${CZERTAINLY_IP:-${CONTROL_IP}}:8443"
echo "  - Istio IngressGateway:   NodePort on Worker IP ${WORKER1_IP}"
echo "  - Test Application:       https://app.lab.local"
echo ""

