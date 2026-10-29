#!/bin/bash
###############################################################################
# 05-k8s-worker-join.sh
#
# Joins a worker node to the Kubernetes cluster. Run this ON each worker VM
# as root or with sudo.
#
# The kubeadm join command can be provided as:
#   1. A positional argument:   sudo ./05-k8s-worker-join.sh "kubeadm join ..."
#   2. Via stdin (pipe):        cat /tmp/kubeadm-join.sh | sudo ./05-k8s-worker-join.sh
#
# Usage:
#   ssh -i ~/.ssh/k8s-key.pem ubuntu@<WORKER_IP>
#   sudo ./05-k8s-worker-join.sh "kubeadm join 10.10.0.x:6443 --token ... --discovery-token-ca-cert-hash ..."
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

echo ""
info "=========================================="
info " Kubernetes – Worker Node Join"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Read join command
# ---------------------------------------------------------------------------
JOIN_CMD=""

if [[ $# -ge 1 ]]; then
    # Join command passed as argument
    JOIN_CMD="$1"
    info "Join command received via argument."
elif [[ ! -t 0 ]]; then
    # Join command piped via stdin
    JOIN_CMD=$(cat)
    info "Join command received via stdin."
else
    error "No join command provided. Pass it as an argument or pipe it via stdin."
fi

# Strip any shebang or comments if the whole script was piped
JOIN_CMD=$(echo "${JOIN_CMD}" | grep -v '^#' | grep -v '^set ' | grep -v '^$' | head -1)

if [[ -z "${JOIN_CMD}" || ! "${JOIN_CMD}" =~ ^kubeadm\ join ]]; then
    error "Invalid join command. Expected: kubeadm join <api-server>:6443 --token ... --discovery-token-ca-cert-hash ..."
fi

info "Join command: ${JOIN_CMD}"
echo ""

# ---------------------------------------------------------------------------
# 2. Wait for cloud-init to complete
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

success "cloud-init complete – kubeadm available."
echo ""

# ---------------------------------------------------------------------------
# 3. Execute the join command
# ---------------------------------------------------------------------------
# Ensure containerd is active and responsive before join
info "Ensuring containerd runtime is active..."
systemctl restart containerd
sleep 3

info "Joining the Kubernetes cluster …"

if ! eval "${JOIN_CMD}"; then
    warn "Join failed, resetting kubeadm, restarting containerd and retrying..."
    kubeadm reset -f || true
    systemctl restart containerd
    sleep 5
    eval "${JOIN_CMD}"
fi

success "Worker node joined the cluster successfully!"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "=========================================="
info " Worker Node Joined"
info "=========================================="
echo ""
success "Hostname ............... $(hostname)"
success "Node IP ................ $(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)"
echo ""
info "On the control plane, verify with:  kubectl get nodes"
echo ""
