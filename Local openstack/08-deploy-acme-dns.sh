#!/bin/bash
###############################################################################
# 08-deploy-acme-dns.sh
# Deploys acme-dns to Kubernetes and wires up DNS delegation via Designate.
#
# This script:
#   1. Applies the acme-dns Kubernetes manifests
#   2. Patches the ConfigMap with the actual worker node IP
#   3. Creates DNS zone and records in OpenStack Designate
#   4. Registers an acme-dns account
#   5. Creates a CNAME for ACME challenge delegation
#   6. Generates and applies the cert-manager credentials secret
#
# Prerequisites:
#   - kubectl configured and pointing to the target cluster
#   - vm-ips.env file with WORKER_IP variable
#   - OpenStack RC file (openrc) sourced or available
#   - openstack CLI installed with Designate plugin
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
# Step 1: Load environment variables
# ---------------------------------------------------------------------------
info "Loading VM IP addresses..."
if [[ ! -f "${SCRIPT_DIR}/vm-ips.env" ]]; then
    error "vm-ips.env not found in ${SCRIPT_DIR}"
    error "Please run the VM provisioning scripts first."
    exit 1
fi
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/vm-ips.env"

WORKER_IP="${WORKER_IP:-${WORKER1_IP:-}}"
if [[ -z "${WORKER_IP:-}" ]]; then
    error "WORKER_IP is not set in vm-ips.env"
    exit 1
fi
info "Worker node IP: ${WORKER_IP}"

# ---------------------------------------------------------------------------
# Step 2 & 3: Deploy acme-dns manifests with actual worker IP
# ---------------------------------------------------------------------------
info "Applying acme-dns manifests (configured with worker IP ${WORKER_IP})..."
sed -e "s/WORKER_IP/${WORKER_IP}/g" \
    -e "s/auth\.acmedns\.lab\.local\. A [0-9.]\+/auth.acmedns.lab.local. A ${WORKER_IP}/g" \
    "${SCRIPT_DIR}/manifests/acme-dns.yaml" | kubectl apply -f -

# ---------------------------------------------------------------------------
# Step 4: Wait for acme-dns pod to be ready
# ---------------------------------------------------------------------------
info "Waiting for acme-dns pod to be ready..."
kubectl wait --for=condition=ready pod \
    -l app=acme-dns \
    -n acme-dns \
    --timeout=120s
info "acme-dns pod is ready."

# Forward standard DNS port 53 on worker to acme-dns NodePort 30053
SSH_KEY="${HOME}/.ssh/k8s-key.pem"
if [[ ! -f "${SSH_KEY}" && -f "/opt/stack/.ssh/k8s-key.pem" ]]; then
    SSH_KEY="/opt/stack/.ssh/k8s-key.pem"
fi
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

info "Forwarding external DNS port 53 on worker ${WORKER_IP} to NodePort 30053 via iptables..."
ssh "${SSH_OPTS[@]}" "ubuntu@${WORKER_IP}" "
sudo iptables -t nat -C PREROUTING ! -s 10.244.0.0/16 -p udp --dport 53 -j REDIRECT --to-port 30053 2>/dev/null || \
    sudo iptables -t nat -A PREROUTING ! -s 10.244.0.0/16 -p udp --dport 53 -j REDIRECT --to-port 30053
sudo iptables -t nat -C PREROUTING ! -s 10.244.0.0/16 -p tcp --dport 53 -j REDIRECT --to-port 30053 2>/dev/null || \
    sudo iptables -t nat -A PREROUTING ! -s 10.244.0.0/16 -p tcp --dport 53 -j REDIRECT --to-port 30053
sudo netfilter-persistent save 2>/dev/null || true
"



# ---------------------------------------------------------------------------
# Step 5: Create DNS zone and records in Designate
# ---------------------------------------------------------------------------
if ! command -v openstack &>/dev/null; then
    error "'openstack' CLI command not found."
    error "Please run this script from the DevStack/OpenStack host where 'openstack' CLI and 'openrc' are available,"
    error "or install python3-openstackclient (e.g. sudo apt install python3-openstackclient)."
    exit 1
fi

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
else
    set -u
    error "OpenStack RC file not found. Please provide openrc."
    exit 1
fi
set +u
set +e
trap - ERR
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

info "Ensuring lab.local DNS zone in Designate..."
if ! openstack zone show lab.local. &>/dev/null; then
    openstack zone create --email admin@lab.local lab.local. || true
    for i in $(seq 1 30); do
        STATUS=$(openstack zone show lab.local. -f value -c status 2>/dev/null || echo "PENDING")
        if [[ "${STATUS}" == "ACTIVE" ]]; then break; fi
        sleep 2
    done
fi

info "Ensuring acmedns.lab.local DNS zone in Designate..."
if ! openstack zone show acmedns.lab.local. &>/dev/null; then
    openstack zone create --email admin@lab.local acmedns.lab.local. || true
fi

# Wait for zone to become ACTIVE
info "Waiting for zone to become ACTIVE..."
for i in $(seq 1 30); do
    STATUS=$(openstack zone show acmedns.lab.local. -f value -c status 2>/dev/null || echo "PENDING")
    if [[ "${STATUS}" == "ACTIVE" ]]; then
        info "Zone is ACTIVE."
        break
    fi
    sleep 2
done

info "Ensuring A record: auth.acmedns.lab.local → ${WORKER_IP}"
openstack recordset create acmedns.lab.local. auth \
    --type A \
    --record "${WORKER_IP}" 2>/dev/null || {
    warn "A record may already exist, continuing..."
}

info "Ensuring NS record: auth.acmedns.lab.local → auth.acmedns.lab.local."
openstack recordset create acmedns.lab.local. auth \
    --type NS \
    --record "auth.acmedns.lab.local." 2>/dev/null || {
    warn "NS record may already exist, continuing..."
}

# Configure Bind9 forwarder for auth.acmedns.lab.local to acme-dns NodePort 30053
if [[ -f /etc/bind/named.conf.options ]]; then
    if grep -q "recursion no;" /etc/bind/named.conf.options 2>/dev/null; then
        info "Enabling recursion in BIND9 to allow forwarding to acme-dns..."
        sudo sed -i 's/recursion no;/recursion yes;\n    allow-recursion { any; };\n    allow-query { any; };/' /etc/bind/named.conf.options
    fi
fi

if [[ -f /etc/bind/named.conf.local ]]; then
    if ! grep -q "auth.acmedns.lab.local" /etc/bind/named.conf.local 2>/dev/null; then
        info "Configuring Bind9 forwarder for auth.acmedns.lab.local -> ${WORKER_IP}:30053..."
        sudo tee -a /etc/bind/named.conf.local <<EOF
zone "auth.acmedns.lab.local" {
    type forward;
    forward only;
    forwarders { ${WORKER_IP} port 30053; };
};
EOF
    else
        info "Updating Bind9 forwarder IP for auth.acmedns.lab.local -> ${WORKER_IP}:30053..."
        sudo sed -i "/zone \"auth.acmedns.lab.local\"/,/};/s/forwarders { [0-9.]\+ port 30053; };/forwarders { ${WORKER_IP} port 30053; };/" /etc/bind/named.conf.local
    fi
    sudo systemctl restart bind9 2>/dev/null || true
fi
set -e
set -u

# ---------------------------------------------------------------------------
# Step 6: Register or reuse acme-dns account
# ---------------------------------------------------------------------------
ACMEDNS_API="http://${WORKER_IP}:30080"

# Wait for the API to be reachable
for i in $(seq 1 15); do
    if curl -s -o /dev/null -w "%{http_code}" "${ACMEDNS_API}/health" 2>/dev/null | grep -q "200\|404"; then
        break
    fi
    warn "Waiting for acme-dns API to be reachable (attempt ${i}/15)..."
    sleep 5
done

if [[ -f "${SCRIPT_DIR}/acme-dns-registration.json" ]] && grep -q "subdomain" "${SCRIPT_DIR}/acme-dns-registration.json" 2>/dev/null; then
    info "Reusing existing acme-dns registration from ${SCRIPT_DIR}/acme-dns-registration.json"
    REGISTRATION=$(cat "${SCRIPT_DIR}/acme-dns-registration.json")
else
    info "Registering new acme-dns account..."
    REGISTRATION=$(curl -s -X POST "${ACMEDNS_API}/register")
    if [[ -z "${REGISTRATION}" ]]; then
        error "Failed to register with acme-dns. Is the API reachable at ${ACMEDNS_API}?"
        exit 1
    fi
    echo "${REGISTRATION}" > "${SCRIPT_DIR}/acme-dns-registration.json"
    info "Registration saved to ${SCRIPT_DIR}/acme-dns-registration.json"
fi

# Extract fields from registration
FULLDOMAIN=$(echo "${REGISTRATION}" | python3 -c "import sys,json; print(json.load(sys.stdin)['fulldomain'])")
SUBDOMAIN=$(echo "${REGISTRATION}" | python3 -c "import sys,json; print(json.load(sys.stdin)['subdomain'])")
USERNAME=$(echo "${REGISTRATION}" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
PASSWORD=$(echo "${REGISTRATION}" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

info "acme-dns fulldomain: ${FULLDOMAIN}"

# ---------------------------------------------------------------------------
# Step 6b: Add registered fulldomain to acme-dns static records
#          (prevents BIND9 negative cache poisoning / NXDOMAIN on A/CNAME queries)
# ---------------------------------------------------------------------------
CURRENT_CFG=$(kubectl get configmap acme-dns-config -n acme-dns -o jsonpath='{.data.config\.cfg}' 2>/dev/null || echo "")
if [[ -n "${CURRENT_CFG}" ]] && ! echo "${CURRENT_CFG}" | grep -q "${FULLDOMAIN}"; then
    info "Registering ${FULLDOMAIN} in acme-dns static records to prevent NXDOMAIN negative caching..."
    sed -e "s/WORKER_IP/${WORKER_IP}/g" \
        -e "s|\"auth.acmedns.lab.local. NS auth.acmedns.lab.local.\"|\"auth.acmedns.lab.local. NS auth.acmedns.lab.local.\",\n        \"${FULLDOMAIN}. NS auth.acmedns.lab.local.\"|" \
        "${SCRIPT_DIR}/manifests/acme-dns.yaml" | kubectl apply -f -
    kubectl rollout restart deployment/acme-dns -n acme-dns
    kubectl rollout status deployment/acme-dns -n acme-dns --timeout=60s
fi

# ---------------------------------------------------------------------------
# Step 7: Create CNAME record in Designate for challenge delegation
# ---------------------------------------------------------------------------
set +e
set +u
trap - ERR
info "Creating CNAME: _acme-challenge.app.lab.local → ${FULLDOMAIN}."

# Create or update the CNAME recordset in Designate
openstack recordset create lab.local. _acme-challenge.app \
    --type CNAME \
    --record "${FULLDOMAIN}." \
    --ttl 300 2>/dev/null || \
openstack recordset set lab.local. _acme-challenge.app.lab.local. \
    --record "${FULLDOMAIN}." \
    --ttl 300 2>/dev/null || {
    warn "CNAME record already exists, continuing..."
}
set -e
set -u

# ---------------------------------------------------------------------------
# Step 8: Generate and apply acme-dns credentials secret
# ---------------------------------------------------------------------------
info "Generating acme-dns credentials secret..."

# Ensure cert-manager namespace exists
kubectl create namespace cert-manager 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: acme-dns
  namespace: cert-manager
  labels:
    app.kubernetes.io/name: acme-dns
    app.kubernetes.io/part-of: acme-lab
type: Opaque
stringData:
  acmedns.json: |
    {
      "app.lab.local": {
        "username": "${USERNAME}",
        "password": "${PASSWORD}",
        "fulldomain": "${FULLDOMAIN}",
        "subdomain": "${SUBDOMAIN}",
        "allowfrom": ["0.0.0.0/0"]
      },
      "*.app.lab.local": {
        "username": "${USERNAME}",
        "password": "${PASSWORD}",
        "fulldomain": "${FULLDOMAIN}",
        "subdomain": "${SUBDOMAIN}",
        "allowfrom": ["0.0.0.0/0"]
      }
    }
EOF

info "acme-dns credentials secret applied to cert-manager namespace."

# Ensure static NS record exists in acme-dns ConfigMap to prevent BIND9 NXDOMAIN cache poisoning
info "Ensuring static NS record for ${FULLDOMAIN} in acme-dns ConfigMap..."
kubectl get cm acme-dns-config -n acme-dns -o json | python3 -c "
import sys, json
cm = json.load(sys.stdin)
cfg = cm['data']['config.cfg']
rec = '\"' + '${FULLDOMAIN}' + ' NS auth.acmedns.lab.local.\"'
if '${FULLDOMAIN}' not in cfg:
    cfg = cfg.replace('records = [', 'records = [\n        ' + rec + ',')
    cm['data']['config.cfg'] = cfg
    print(json.dumps(cm))
else:
    sys.exit(0)
" | kubectl apply -f - 2>/dev/null || true

kubectl rollout restart deployment/acme-dns -n acme-dns 2>/dev/null || true
kubectl rollout status deployment/acme-dns -n acme-dns --timeout=60s 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "============================================"
info " acme-dns deployment complete!"
info "============================================"
info ""
info "  acme-dns API:     ${ACMEDNS_API}"
info "  DNS (NodePort):   ${WORKER_IP}:30053"
info "  Fulldomain:       ${FULLDOMAIN}"
info "  Registration:     ${SCRIPT_DIR}/acme-dns-registration.json"
info ""
info "Verify DNS resolution:"
info "  dig @${WORKER_IP} -p 30053 ${FULLDOMAIN} TXT"
info ""
info "Next step: Run 09-deploy-cert-manager.sh"
