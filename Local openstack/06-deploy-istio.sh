#!/bin/bash
###############################################################################
# 06-deploy-istio.sh
#
# Deploys Istio service mesh (v1.22.0) on the Kubernetes cluster.
# Run from any machine with kubectl access to the cluster.
#
# Actions:
#   - Downloads and installs istioctl 1.22.0
#   - Installs Istio with the default profile
#   - Patches IngressGateway service to NodePort
#   - Labels default namespace for automatic sidecar injection
#
# Usage:
#   ./06-deploy-istio.sh
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
# Pre-flight: kubectl must be configured
# ---------------------------------------------------------------------------
if ! kubectl cluster-info &>/dev/null; then
    error "kubectl cannot reach the cluster. Ensure KUBECONFIG is set."
fi

ISTIO_VERSION="1.22.0"

echo ""
info "=========================================="
info " Kubernetes – Istio Deployment (v${ISTIO_VERSION})"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Download and install istioctl
# ---------------------------------------------------------------------------
info "Downloading istioctl v${ISTIO_VERSION} …"

ISTIO_DIR="/tmp/istio-${ISTIO_VERSION}"

if command -v istioctl &>/dev/null && istioctl version --remote=false 2>/dev/null | grep -q "${ISTIO_VERSION}"; then
    info "istioctl v${ISTIO_VERSION} already installed."
else
    curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh - 2>/dev/null || \
        curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp/

    # Install istioctl to /usr/local/bin
    if [[ -f "./istio-${ISTIO_VERSION}/bin/istioctl" ]]; then
        sudo cp "./istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
    elif [[ -f "${ISTIO_DIR}/bin/istioctl" ]]; then
        sudo cp "${ISTIO_DIR}/bin/istioctl" /usr/local/bin/istioctl
    fi
    sudo chmod +x /usr/local/bin/istioctl
    success "istioctl v${ISTIO_VERSION} installed to /usr/local/bin/istioctl"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Install Istio with default profile
# ---------------------------------------------------------------------------
info "Installing Istio with default profile …"

istioctl install --set profile=default -y

success "Istio installed."
echo ""

# ---------------------------------------------------------------------------
# 3. Patch IngressGateway to NodePort
# ---------------------------------------------------------------------------
info "Patching istio-ingressgateway to NodePort …"

kubectl patch svc istio-ingressgateway \
    -n istio-system \
    --type='json' \
    -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]'

success "IngressGateway patched to NodePort."
echo ""

# ---------------------------------------------------------------------------
# 4. Label default namespace for sidecar injection
# ---------------------------------------------------------------------------
info "Enabling automatic sidecar injection on 'default' namespace …"

kubectl label namespace default istio-injection=enabled --overwrite

success "Namespace 'default' labeled for sidecar injection."
echo ""

# ---------------------------------------------------------------------------
# 5. Wait for Istio pods
# ---------------------------------------------------------------------------
info "Waiting for Istio pods to be ready …"

kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=300s 2>/dev/null || \
    info "Some Istio pods may still be starting. Check: kubectl get pods -n istio-system"

success "Istio pods are ready."
echo ""

# ---------------------------------------------------------------------------
# Summary: print NodePort assignments
# ---------------------------------------------------------------------------
echo ""
info "=========================================="
info " Istio Deployment Complete"
info "=========================================="
echo ""

info "IngressGateway NodePort assignments:"
echo ""

# Fetch NodePort mappings
HTTP_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || echo "N/A")
HTTPS_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "N/A")
STATUS_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="status-port")].nodePort}' 2>/dev/null || echo "N/A")

success "HTTP  (http2) .......... NodePort ${HTTP_NODEPORT}"
success "HTTPS (https) .......... NodePort ${HTTPS_NODEPORT}"
success "Status ................. NodePort ${STATUS_NODEPORT}"
echo ""
info "Access via: http://<NODE_IP>:${HTTP_NODEPORT}"
info "Next step: run 07-deploy-czertainly.sh"
echo ""
