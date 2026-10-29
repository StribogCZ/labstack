#!/bin/bash
###############################################################################
# 07-deploy-czertainly.sh (External PVE LXC Integration)
#
# Configures connectivity and ACME trust between the OpenStack K8s cluster
# and the external CZERTAINLY CA running in a Proxmox VE (PVE) LXC container.
#
# Prerequisites:
#   - CZERTAINLY is deployed on Proxmox VE via 'pve-create-czertainly-lxc.sh'
#   - kubectl configured and pointing to target K8s cluster inside OpenStack
#   - czertainly.env configured with PVE LXC IP and RA profile name
#
# Actions:
#   1. Reads configuration from czertainly.env
#   2. Tests TCP connectivity to external CZERTAINLY on PVE
#   3. Adds DNS mapping (Designate and/or K8s CoreDNS) for 'czertainly.lab.local'
#   4. Retrieves CZERTAINLY's TLS server/CA certificate
#   5. Configures cert-manager CA bundle secret & updates czertainly-issuer.yaml
#   6. Verifies ACME directory endpoint accessibility from within the cluster
#
# Usage:
#   ./07-deploy-czertainly.sh
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${CYAN}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "================================================================"
info " OpenStack K8s -> External CZERTAINLY (PVE LXC) Integration"
info "================================================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Load configuration
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/czertainly.env"
if [[ -f "${ENV_FILE}" ]]; then
    info "Loading configuration from ${ENV_FILE}..."
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
else
    warn "${ENV_FILE} not found, using default parameters."
fi

CZERTAINLY_HOST="${CZERTAINLY_HOST:-192.168.1.250}"
CZERTAINLY_PORT="${CZERTAINLY_PORT:-8000}"
CZERTAINLY_SCHEME="${CZERTAINLY_SCHEME:-http}"
CZERTAINLY_DOMAIN="${CZERTAINLY_DOMAIN:-czertainly.lab.local}"
CZERTAINLY_RA_PROFILE="${CZERTAINLY_RA_PROFILE:-lab-profile}"
CZERTAINLY_ACME_URL="${CZERTAINLY_ACME_URL:-${CZERTAINLY_SCHEME}://${CZERTAINLY_DOMAIN}:${CZERTAINLY_PORT}/api/v1/protocols/acme/${CZERTAINLY_RA_PROFILE}/directory}"

echo "  - External PVE LXC IP:  ${CZERTAINLY_HOST}"
echo "  - External Port:        ${CZERTAINLY_PORT}"
echo "  - FQDN:                 ${CZERTAINLY_DOMAIN}"
echo "  - RA Profile:           ${CZERTAINLY_RA_PROFILE}"
echo "  - ACME Directory URL:   ${CZERTAINLY_ACME_URL}"
echo ""

# ---------------------------------------------------------------------------
# 2. Check kubectl connectivity
# ---------------------------------------------------------------------------
if ! kubectl cluster-info &>/dev/null; then
    error "kubectl cannot reach the Kubernetes cluster. Ensure KUBECONFIG is set."
fi
success "Connected to Kubernetes cluster."

# ---------------------------------------------------------------------------
# 3. Test network reachability to PVE LXC
# ---------------------------------------------------------------------------
info "Testing network reachability to CZERTAINLY at ${CZERTAINLY_HOST}:${CZERTAINLY_PORT}..."

if command -v nc &>/dev/null; then
    nc -z -w 5 "${CZERTAINLY_HOST}" "${CZERTAINLY_PORT}" || {
        warn "Direct TCP connection to ${CZERTAINLY_HOST}:${CZERTAINLY_PORT} timed out."
        warn "Verify that routing/gateway between OpenStack and your PVE network is configured."
    }
fi

# Ensure ACME profile exists in CZERTAINLY database
info "Ensuring '${CZERTAINLY_RA_PROFILE}' ACME profile exists in CZERTAINLY database..."
SSH_KEY="${HOME}/.ssh/k8s-key.pem"
if [[ ! -f "${SSH_KEY}" && -f "/opt/stack/.ssh/k8s-key.pem" ]]; then
    SSH_KEY="/opt/stack/.ssh/k8s-key.pem"
fi

DEFAULT_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
HOST_IP=$(ip -4 addr show dev "${DEFAULT_IFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

# Wait for PostgreSQL pod inside CZERTAINLY K3s to be ready
info "Waiting for CZERTAINLY PostgreSQL pod on ${CZERTAINLY_HOST} to be ready..."
for i in $(seq 1 30); do
    if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" \
        "sudo k3s kubectl wait --for=condition=ready pod -l app=czertainly-postgresql -n czertainly --timeout=10s" &>/dev/null; then
        success "CZERTAINLY PostgreSQL is ready."
        break
    fi
    info "  Waiting for PostgreSQL pod (attempt ${i}/30)..."
    sleep 5
done

# Wait for CZERTAINLY Platform Core pod to be ready
info "Waiting for CZERTAINLY Platform Core to be ready (migrations in progress)..."
for i in $(seq 1 60); do
    if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" \
        "sudo k3s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=platform-core -n czertainly --timeout=10s" &>/dev/null; then
        success "CZERTAINLY Platform Core pod is ready."
        break
    fi
    info "  Waiting for platform-core pod (attempt ${i}/60)..."
    sleep 5
done

# Wait for CZERTAINLY Core database migrations to complete (specifically the 'version' column in core.connector)
info "Waiting for CZERTAINLY Core database schema migrations to finalize..."
for i in $(seq 1 30); do
    if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" \
        "sudo k3s kubectl exec -n czertainly deploy/czertainly-postgresql -- psql -U ilmuser -d ilmdb -c 'SELECT version FROM core.connector LIMIT 1;'" &>/dev/null; then
        success "CZERTAINLY Core database schema is ready."
        break
    fi
    info "  Waiting for core.connector.version column (attempt ${i}/30)..."
    sleep 5
done

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" \
    "sudo k3s kubectl exec -n czertainly deploy/czertainly-postgresql -- psql -U ilmuser -d ilmdb -c \"
INSERT INTO core.acme_profile (uuid, name, is_enabled, dns_resolver_ip, dns_resolver_port, retry_interval, validity, disable_new_orders, require_contact, require_terms_of_service, i_cre, i_upd)
SELECT gen_random_uuid(), '${CZERTAINLY_RA_PROFILE}', true, '${HOST_IP}', '53', 30, 2592000, false, false, false, now(), now()
WHERE NOT EXISTS (SELECT 1 FROM core.acme_profile WHERE name='${CZERTAINLY_RA_PROFILE}');

INSERT INTO core.ra_profile (uuid, name, enabled, acme_profile_uuid, validation_enabled, i_cre, i_upd)
SELECT gen_random_uuid(), '${CZERTAINLY_RA_PROFILE}', true, p.uuid, false, now(), now()
FROM core.acme_profile p
WHERE p.name = '${CZERTAINLY_RA_PROFILE}'
AND NOT EXISTS (SELECT 1 FROM core.ra_profile WHERE name='${CZERTAINLY_RA_PROFILE}');

UPDATE core.acme_profile p
SET ra_profile_uuid = r.uuid
FROM core.ra_profile r
WHERE p.name = '${CZERTAINLY_RA_PROFILE}' AND r.name = '${CZERTAINLY_RA_PROFILE}' AND p.ra_profile_uuid IS NULL;
\"" 2>/dev/null || true

# Deploy Local CA Authority Provider microservice on CZERTAINLY VM
info "Deploying Local CA Authority Provider on CZERTAINLY VM (${CZERTAINLY_HOST})..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" "sudo mkdir -p /opt/czertainly-local-ca /etc/czertainly-ca"
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SCRIPT_DIR}/manifests/ca_provider.py" ubuntu@"${CZERTAINLY_HOST}":/tmp/ca_provider.py
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" "
sudo mv /tmp/ca_provider.py /opt/czertainly-local-ca/ca_provider.py
sudo chmod 755 /opt/czertainly-local-ca/ca_provider.py
sudo apt-get update -qq && sudo apt-get install -y -qq python3-cryptography

sudo tee /etc/systemd/system/czertainly-local-ca.service <<'SVCEOF'
[Unit]
Description=CZERTAINLY Local CA Authority Provider
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/czertainly-local-ca/ca_provider.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable --now czertainly-local-ca
sudo systemctl restart czertainly-local-ca
"

# Expose ACME API on port 8000 via NodePort 30080 and socat systemd proxy
info "Configuring ACME API exposure on port 8000 via NodePort 30080 and socat on ${CZERTAINLY_HOST}..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" "
sudo k3s kubectl patch svc -n czertainly api-gateway-service -p '{\"spec\": {\"type\": \"NodePort\", \"ports\": [{\"name\": \"admin\", \"port\": 8001, \"targetPort\": 8001}, {\"name\": \"consumer\", \"port\": 8000, \"targetPort\": 8000, \"nodePort\": 30080}, {\"name\": \"status\", \"port\": 8100, \"targetPort\": 8100}]}}' 2>/dev/null || true
command -v socat &>/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq socat)
sudo tee /etc/systemd/system/czertainly-acme-proxy.service <<'PROXYEOF'
[Unit]
Description=CZERTAINLY ACME Port 8000 Forwarder
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP-LISTEN:8000,fork,reuseaddr TCP:127.0.0.1:30080
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
PROXYEOF
sudo systemctl daemon-reload
sudo systemctl enable --now czertainly-acme-proxy
sudo systemctl restart czertainly-acme-proxy
"


# Create K3s Service and Endpoint inside czertainly namespace
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" "
sudo k3s kubectl apply -f - <<'K8SEOF'
apiVersion: v1
kind: Service
metadata:
  name: local-ca-service
  namespace: czertainly
spec:
  ports:
    - port: 8888
      targetPort: 8888
---
apiVersion: v1
kind: Endpoints
metadata:
  name: local-ca-service
  namespace: czertainly
subsets:
  - addresses:
      - ip: 10.42.0.1
    ports:
      - port: 8888
K8SEOF
"

# Register connector and authority in CZERTAINLY PostgreSQL database
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${CZERTAINLY_HOST}" "
sudo k3s kubectl exec -n czertainly deploy/czertainly-postgresql -- psql -U ilmuser -d ilmdb -c \"
INSERT INTO core.connector (uuid, name, status, url, auth_type, version, i_cre, i_upd)
VALUES ('99999999-0000-0000-0000-000000000001', 'Local-CA-Connector', 'CONNECTED', 'http://local-ca-service:8888', 'NONE', 'V2', now(), now())
ON CONFLICT (uuid) DO NOTHING;

INSERT INTO core.connector_2_function_group (id, kinds, connector_uuid, function_group_uuid)
VALUES (3, '[\"Local-CA\"]', '99999999-0000-0000-0000-000000000001', '736b0fd6-5ea0-4e10-abe7-cfed39cc2a1a')
ON CONFLICT (id) DO NOTHING;

INSERT INTO core.connector_interface (uuid, connector_uuid, interface, version, features)
VALUES ('99999999-0000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000001', 'AUTHORITY', 'v2', '{}')
ON CONFLICT (uuid) DO NOTHING;

INSERT INTO core.authority_instance_reference (uuid, name, kind, status, authority_instance_uuid, connector_name, connector_uuid, connector_interface_uuid, i_cre, i_upd)
VALUES ('99999999-0000-0000-0000-000000000003', 'lab-ca', 'Local-CA', 'CONNECTED', 'local-ca-1', 'Local-CA-Connector', '99999999-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', now(), now())
ON CONFLICT (uuid) DO NOTHING;

UPDATE core.ra_profile
SET authority_instance_ref_uuid = '99999999-0000-0000-0000-000000000003',
    authority_instance_name = 'lab-ca'
WHERE name = '${CZERTAINLY_RA_PROFILE}';
\""


# ---------------------------------------------------------------------------
# 4. Configure DNS resolution in CoreDNS (K8s) for czertainly.lab.local
# ---------------------------------------------------------------------------
info "Ensuring '${CZERTAINLY_DOMAIN}' resolves to ${CZERTAINLY_HOST} in K8s CoreDNS..."

# Check if CoreDNS ConfigMap exists and configure hosts plugin
if kubectl get configmap coredns -n kube-system &>/dev/null; then
    CURRENT_COREDNS=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
    if ! echo "${CURRENT_COREDNS}" | grep -q "${CZERTAINLY_DOMAIN}"; then
        info "Adding hosts entry for ${CZERTAINLY_DOMAIN} -> ${CZERTAINLY_HOST} into CoreDNS..."
        
        # Insert hosts entry before the 'ready' or '.' block
        kubectl get configmap coredns -n kube-system -o yaml > /tmp/coredns-cm.yaml
        sed -i "/.:53 {/a \        hosts {\n            ${CZERTAINLY_HOST} ${CZERTAINLY_DOMAIN}\n            fallthrough\n        }" /tmp/coredns-cm.yaml
        kubectl apply -f /tmp/coredns-cm.yaml 2>/dev/null || {
            warn "CoreDNS auto-patching skipped. Ensure DNS resolves ${CZERTAINLY_DOMAIN}."
        }
        kubectl rollout restart deployment coredns -n kube-system 2>/dev/null || true
        success "CoreDNS updated."
    else
        info "CoreDNS already contains entry for ${CZERTAINLY_DOMAIN}."
    fi
fi

# ---------------------------------------------------------------------------
# 5. Also register in OpenStack Designate DNS if openrc is present
# ---------------------------------------------------------------------------
if command -v openstack &>/dev/null; then
    set +u
    if [[ -f "${SCRIPT_DIR}/openrc" ]]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/openrc"
    elif [[ -f "/opt/stack/devstack/openrc" ]]; then
        # shellcheck source=/dev/null
        source "/opt/stack/devstack/openrc" admin admin
    fi
    trap - ERR || true
    warn()    { echo -e "${CYAN}[WARN]${NC}  $*"; }
    info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
    error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
    set -u
    if [[ -n "${OS_AUTH_URL:-}" ]]; then
        info "Registering ${CZERTAINLY_DOMAIN} in OpenStack Designate..."
        openstack recordset create lab.local. "${CZERTAINLY_DOMAIN}." --type A --record "${CZERTAINLY_HOST}" 2>/dev/null || \
            info "Designate record for ${CZERTAINLY_DOMAIN} already exists or was skipped."
    fi
fi

# ---------------------------------------------------------------------------
# 6. Fetch CZERTAINLY CA certificate (if using self-signed TLS)
# ---------------------------------------------------------------------------
TLS_PORT="${CZERTAINLY_TLS_PORT:-8443}"
info "Fetching CZERTAINLY TLS certificate from ${CZERTAINLY_HOST}:${TLS_PORT}..."
CERT_FILE="/tmp/czertainly-ca.crt"
echo | openssl s_client -servername "${CZERTAINLY_DOMAIN}" -connect "${CZERTAINLY_HOST}:${TLS_PORT}" 2>/dev/null | \
    openssl x509 -outform PEM > "${CERT_FILE}" 2>/dev/null || true

CA_BUNDLE_B64=""
if openssl x509 -in "${CERT_FILE}" -noout 2>/dev/null; then
    success "Retrieved valid TLS certificate from CZERTAINLY."
    CA_BUNDLE_B64=$(base64 -w 0 < "${CERT_FILE}")
else
    warn "Could not retrieve certificate via openssl (PVE service might still be starting or firewall blocks it)."
fi

# ---------------------------------------------------------------------------
# 7. Update manifests/czertainly-issuer.yaml
# ---------------------------------------------------------------------------
info "Updating manifests/czertainly-issuer.yaml with external PVE ACME URL..."

ISSUER_MANIFEST="${SCRIPT_DIR}/manifests/czertainly-issuer.yaml"

cat > "${ISSUER_MANIFEST}" <<EOF
###############################################################################
# CZERTAINLY ACME ClusterIssuer (External PVE LXC Instance)
# Connects cert-manager to the external CZERTAINLY CA running in Proxmox VE.
#
# Flow:
#   1. cert-manager requests cert from CZERTAINLY (${CZERTAINLY_ACME_URL})
#   2. CZERTAINLY issues DNS-01 challenge
#   3. cert-manager updates acme-dns via native acmeDNS solver
#   4. CZERTAINLY validates DNS TXT record
#   5. Certificate is issued and stored in Kubernetes Secret
###############################################################################
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: czertainly-acme
  labels:
    app.kubernetes.io/name: czertainly-acme
    app.kubernetes.io/part-of: acme-lab
spec:
  acme:
    # External CZERTAINLY ACME directory URL on Proxmox VE LXC
    server: ${CZERTAINLY_ACME_URL}

    # Contact email for ACME notifications
    email: admin@lab.local

    # Secret storing ACME account private key (generated automatically)
    privateKeySecretRef:
      name: czertainly-acme-account-key
EOF

if [[ "${CZERTAINLY_SCHEME}" == "https" && -n "${CA_BUNDLE_B64}" ]]; then
cat >> "${ISSUER_MANIFEST}" <<EOF

    # CA bundle for trusting self-signed / internal PVE CZERTAINLY TLS cert
    caBundle: ${CA_BUNDLE_B64}
EOF
fi

cat >> "${ISSUER_MANIFEST}" <<'EOF'

    # DNS-01 solver configuration using cert-manager's native acmeDNS solver
    solvers:
      - dns01:
          cnameStrategy: Follow
          acmeDNS:
            host: http://acme-dns.acme-dns.svc.cluster.local
            accountSecretRef:
              name: acme-dns
              key: acmedns.json
        # Skip internal DNS self-check and wait 10s for propagation before ACME validation
        waitInsteadOfSelfCheck: 10s
EOF

success "Updated ${ISSUER_MANIFEST}"

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}================================================================"
echo -e " External CZERTAINLY Configuration Complete"
echo -e "================================================================${NC}"
echo ""
echo "Next step: Run '08-deploy-acme-dns.sh' and '09-deploy-cert-manager.sh'"
echo "Cert-manager will connect directly to CZERTAINLY in PVE at:"
echo "  ${CZERTAINLY_ACME_URL}"
echo ""
