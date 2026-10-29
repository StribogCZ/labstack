#!/bin/bash
###############################################################################
# 10-deploy-test-app.sh
# Deploys the test application and Istio Gateway, then configures DNS
# so that app.lab.local resolves to the Istio IngressGateway.
#
# This script:
#   1. Deploys the test application (http-echo)
#   2. Applies the Istio Gateway + VirtualService
#   3. Discovers the IngressGateway NodePort
#   4. Creates a DNS A record for app.lab.local in Designate
#   5. Prints curl commands for verification
#
# Prerequisites:
#   - kubectl configured and pointing to the target cluster
#   - Istio installed with IngressGateway
#   - cert-manager deployed with certificate issued (run 09 first)
#   - OpenStack RC file available
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Step 1: Deploy the test application
# ---------------------------------------------------------------------------
info "Deploying test application..."
kubectl apply -f "${SCRIPT_DIR}/manifests/test-app.yaml"

info "Waiting for test app pods to be ready..."
kubectl rollout status deployment/my-app -n default --timeout=120s
info "Test application is ready."

# ---------------------------------------------------------------------------
# Step 2: Apply the Istio Gateway and VirtualService
# ---------------------------------------------------------------------------
info "Applying Istio Gateway and VirtualService..."
kubectl apply -f "${SCRIPT_DIR}/manifests/istio-gateway.yaml"

# ---------------------------------------------------------------------------
# Step 3: Get IngressGateway NodePort
# ---------------------------------------------------------------------------
info "Discovering Istio IngressGateway HTTPS NodePort..."
HTTPS_NODEPORT=$(kubectl get svc istio-ingressgateway \
    -n istio-system \
    -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

HTTP_NODEPORT=$(kubectl get svc istio-ingressgateway \
    -n istio-system \
    -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')

info "HTTPS NodePort: ${HTTPS_NODEPORT}"
info "HTTP NodePort:  ${HTTP_NODEPORT}"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Step 4: Load worker IP and create DNS record
# ---------------------------------------------------------------------------
info "Loading VM IP addresses..."
if [[ -f "${SCRIPT_DIR}/vm-ips.env" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/vm-ips.env"
else
    error "vm-ips.env not found. Please provide WORKER_IP."
    exit 1
fi

WORKER_IP="${WORKER_IP:-${WORKER1_IP:-}}"
if [[ -z "${WORKER_IP:-}" ]]; then
    error "WORKER_IP (or WORKER1_IP) is not set in vm-ips.env"
    exit 1
fi
info "Target worker node IP: ${WORKER_IP}"

if ! command -v openstack &>/dev/null; then
    warn "'openstack' CLI command not found on this machine."
    warn "If running inside K8s VM, either run this script from the DevStack host,"
    warn "or manually add DNS records in Designate: app.lab.local -> ${WORKER_IP}"
else
    info "Sourcing OpenStack credentials..."
    set +u
    if [[ -f "${SCRIPT_DIR}/openrc" ]]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/openrc"
    elif [[ -f "${HOME}/openrc" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/openrc"
    elif [[ -f "/opt/stack/devstack/openrc" ]]; then
        # shellcheck source=/dev/null
        source "/opt/stack/devstack/openrc" admin admin
    fi
    trap - ERR || true
    warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
    info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
    error()   { echo -e "${RED}[ERROR]${NC} $*"; }
    set -u

    info "Creating A record: app.lab.local → ${WORKER_IP}"
    openstack recordset create lab.local. app \
        --type A \
        --record "${WORKER_IP}" 2>/dev/null || {
        warn "A record may already exist, continuing..."
    }

    # Also create a wildcard record for *.app.lab.local
    info "Creating A record: *.app.lab.local → ${WORKER_IP}"
    openstack recordset create lab.local. "*.app" \
        --type A \
        --record "${WORKER_IP}" 2>/dev/null || {
        warn "Wildcard A record may already exist, continuing..."
    }
fi

# ---------------------------------------------------------------------------
# Step 5: Verify certificate status
# ---------------------------------------------------------------------------
info "Checking certificate status..."
kubectl get certificate -n istio-system app-tls-certificate -o wide || {
    warn "Certificate may not be issued yet."
}
echo ""

# ---------------------------------------------------------------------------
# Summary and verification
# ---------------------------------------------------------------------------
echo ""
info "============================================"
info " Test application deployment complete!"
info "============================================"
echo ""
info "Test with curl (from a machine that can resolve lab.local):"
echo ""
echo -e "  ${YELLOW}# HTTPS (verify certificate)${NC}"
echo -e "  curl -v --resolve app.lab.local:${HTTPS_NODEPORT}:${WORKER_IP} https://app.lab.local:${HTTPS_NODEPORT}"
echo ""
echo -e "  ${YELLOW}# HTTPS (skip verification for self-signed CA)${NC}"
echo -e "  curl -k --resolve app.lab.local:${HTTPS_NODEPORT}:${WORKER_IP} https://app.lab.local:${HTTPS_NODEPORT}"
echo ""
echo -e "  ${YELLOW}# HTTP (should redirect to HTTPS)${NC}"
echo -e "  curl -v --resolve app.lab.local:${HTTP_NODEPORT}:${WORKER_IP} http://app.lab.local:${HTTP_NODEPORT}"
echo ""
info "============================================"
info " Verification Checklist"
info "============================================"
echo ""
echo -e "  ${GREEN}[  ]${NC} Certificate is in 'Ready' state:"
echo -e "       kubectl get certificate -n istio-system"
echo ""
echo -e "  ${GREEN}[  ]${NC} TLS secret exists:"
echo -e "       kubectl get secret app-tls-credential -n istio-system"
echo ""
echo -e "  ${GREEN}[  ]${NC} Gateway is configured:"
echo -e "       kubectl get gateway app-gateway"
echo ""
echo -e "  ${GREEN}[  ]${NC} App pods are running:"
echo -e "       kubectl get pods -l app=my-app"
echo ""
echo -e "  ${GREEN}[  ]${NC} HTTPS curl returns 'Hello from app.lab.local with ACME cert from CZERTAINLY!'"
echo ""
echo -e "  ${GREEN}[  ]${NC} Certificate chain shows CZERTAINLY CA"
echo ""
echo -e "  ${GREEN}[  ]${NC} DNS resolves correctly:"
echo -e "       dig app.lab.local @${WORKER_IP}"
echo ""
