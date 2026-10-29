#!/bin/bash
###############################################################################
# 09-deploy-cert-manager.sh
# Installs cert-manager with the native acmeDNS solver and applies the
# CZERTAINLY ACME ClusterIssuer and test certificate.
#
# This script:
#   1. Adds the Jetstack Helm repository
#   2. Installs cert-manager with custom DNS-01 resolver settings
#   3. Waits for cert-manager pods to be ready
#   4. Verifies the acme-dns credentials secret
#   5. Applies the CZERTAINLY ACME ClusterIssuer
#   6. Applies the test certificate request and waits for issuance
#
# Prerequisites:
#   - kubectl configured and pointing to the target cluster
#   - helm v3 installed
#   - acme-dns deployed (run 08-deploy-acme-dns.sh first)
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Step 1: Add Jetstack Helm repository
# ---------------------------------------------------------------------------
info "Adding Jetstack Helm repository..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || {
    warn "Jetstack repo may already be added."
}
helm repo update

# ---------------------------------------------------------------------------
# Step 2: Install cert-manager
# ---------------------------------------------------------------------------
info "Installing cert-manager via Helm (using waitInsteadOfSelfCheck in ClusterIssuer)..."
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --values "${SCRIPT_DIR}/manifests/cert-manager-values.yaml" \
    --wait \
    --timeout 5m

# ---------------------------------------------------------------------------
# Step 3: Wait for cert-manager pods to be ready
# ---------------------------------------------------------------------------
info "Waiting for cert-manager pods to be ready..."
kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/instance=cert-manager \
    -n cert-manager \
    --timeout=180s
info "All cert-manager pods are ready."

# Verify cert-manager components
info "Verifying cert-manager components..."
kubectl get pods -n cert-manager
echo ""

# ---------------------------------------------------------------------------
# Step 4: Verify native acmeDNS solver credentials
# ---------------------------------------------------------------------------
info "Verifying acme-dns credentials secret for native cert-manager acmeDNS solver..."

if ! kubectl get secret acme-dns -n cert-manager &>/dev/null; then
    warn "Secret 'acme-dns' not found in cert-manager namespace."
    warn "Ensure 08-deploy-acme-dns.sh has completed successfully."
else
    success "Secret 'acme-dns' found in cert-manager namespace."
fi

# ---------------------------------------------------------------------------
# Step 5: Apply the CZERTAINLY ACME ClusterIssuer
# ---------------------------------------------------------------------------
info "Applying CZERTAINLY ACME ClusterIssuer..."
kubectl apply -f "${SCRIPT_DIR}/manifests/czertainly-issuer.yaml"

# Wait for the issuer to be ready
info "Waiting for ClusterIssuer to be registered..."
sleep 5
kubectl get clusterissuer czertainly-acme -o wide || {
    warn "ClusterIssuer may take a moment to become ready."
}

# ---------------------------------------------------------------------------
# Step 6: Apply the test certificate
# ---------------------------------------------------------------------------
info "Applying test certificate request..."
kubectl create namespace istio-system 2>/dev/null || true
kubectl apply -f "${SCRIPT_DIR}/manifests/test-certificate.yaml"

info "Waiting for certificate 'app-tls-certificate' to become Ready (up to 120s)..."
if kubectl wait --for=condition=ready certificate/app-tls-certificate -n istio-system --timeout=120s 2>/dev/null; then
    success "Certificate 'app-tls-certificate' issued and Ready!"
else
    warn "Certificate is still being processed. Check status with: kubectl get certificate,challenge,order -n istio-system"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "============================================"
info " cert-manager deployment complete!"
info "============================================"
info ""
info "Watch certificate issuance progress:"
info "  kubectl get certificate -n istio-system -w"
info ""
info "Check certificate request status:"
info "  kubectl get certificaterequest -n istio-system"
info ""
info "Check ACME order status:"
info "  kubectl get order -n istio-system"
info ""
info "Check DNS-01 challenge status:"
info "  kubectl get challenge -n istio-system"
info ""
info "Debug cert-manager logs:"
info "  kubectl logs -n cert-manager -l app=cert-manager --tail=100 -f"
info ""
info "Next step: Run 10-deploy-test-app.sh"
