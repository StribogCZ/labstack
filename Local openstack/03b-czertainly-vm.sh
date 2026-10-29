#!/bin/bash
###############################################################################
# 03b-czertainly-vm.sh (OpenStack In-Cloud CA Instance)
#
# Launches a dedicated OpenStack VM 'czertainly-ca' (Variant A) to act as the
# external Certificate Authority for the Kubernetes cluster.
#
# Actions:
#   1. Creates cloud-init userdata (Ubuntu 24.04 + K3s + Helm + CZERTAINLY)
#   2. Launches 'czertainly-ca' instance using 'czertainly' flavor
#   3. Assigns Floating IP from public pool
#   4. Creates DNS A-record 'czertainly.lab.local' in OpenStack Designate
#   5. Updates czertainly.env and vm-ips.env with the CZERTAINLY IP
#
# Usage:
#   source /opt/stack/devstack/openrc admin admin
#   ./03b-czertainly-vm.sh
###############################################################################
set -euo pipefail

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
USERDATA_FILE="/tmp/czertainly-cloud-init.yaml"
VM_IPS_FILE="${SCRIPT_DIR}/vm-ips.env"
CZERTAINLY_ENV_FILE="${SCRIPT_DIR}/czertainly.env"

echo ""
info "================================================================"
info " OpenStack Lab – Deploy CZERTAINLY CA Instance"
info "================================================================"
echo ""

# Source credentials if not already loaded
if [[ -z "${OS_AUTH_URL:-}" ]]; then
    set +u
    if [[ -f "/opt/stack/devstack/openrc" ]]; then
        source "/opt/stack/devstack/openrc" admin admin
    elif [[ -f "${SCRIPT_DIR}/openrc" ]]; then
        source "${SCRIPT_DIR}/openrc"
    else
        set -u
        error "OpenStack credentials not found. Source openrc first."
    fi
    trap - ERR || true
    warn()    { echo -e "${CYAN}[WARN]${NC}  $*"; }
    info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
    error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
    set -u
fi

# ---------------------------------------------------------------------------
# 1. Generate cloud-init userdata for CZERTAINLY
# ---------------------------------------------------------------------------
info "Generating CZERTAINLY cloud-init userdata …"

cat > "${USERDATA_FILE}" <<'CLOUDINIT'
#cloud-config
package_update: true

packages:
  - curl
  - wget
  - git
  - jq
  - openssl
  - ca-certificates
  - iptables
  - net-tools
  - iptables-persistent
  - netfilter-persistent

write_files:
  - path: /root/deploy-czertainly.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
      export DEBIAN_FRONTEND=noninteractive
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      echo "=== Installing K3s ==="
      if ! command -v k3s &>/dev/null; then
          curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb" sh -
      fi

      for i in $(seq 1 45); do
          if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
              break
          fi
          sleep 2
      done

      echo "=== Installing Helm ==="
      if ! command -v helm &>/dev/null; then
          curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      fi

      kubectl create namespace czertainly 2>/dev/null || true

      echo "=== Deploying PostgreSQL ==="
      cat <<'PGEOF' | kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: czertainly-postgresql
        namespace: czertainly
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: czertainly-postgresql
        template:
          metadata:
            labels:
              app: czertainly-postgresql
          spec:
            containers:
              - name: postgres
                image: postgres:15-alpine
                env:
                  - name: POSTGRES_DB
                    value: ilmdb
                  - name: POSTGRES_USER
                    value: ilmuser
                  - name: POSTGRES_PASSWORD
                    value: your-strong-password
                ports:
                  - containerPort: 5432
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: czertainly-postgresql
        namespace: czertainly
      spec:
        ports:
          - port: 5432
            targetPort: 5432
        selector:
          app: czertainly-postgresql
      PGEOF

      echo "=== Cloning Helm Charts ==="
      rm -rf /opt/helm-charts
      git clone --depth 1 https://github.com/OmniTrustILM/helm-charts.git /opt/helm-charts
      cd /opt/helm-charts/charts/ilm
      helm dependency build . || true

      cat > /tmp/czertainly-values.yaml <<'VALUES_EOF'
      global:
        hostName: czertainly.lab.local
        database:
          type: "postgresql"
          host: "czertainly-postgresql.czertainly.svc.cluster.local"
          port: 5432
          name: "ilmdb"
          username: "ilmuser"
          password: "your-strong-password"
          pgBouncer:
            enabled: false

      database:
        type: "postgresql"
        host: "czertainly-postgresql.czertainly.svc.cluster.local"
        port: 5432
        name: "ilmdb"
        username: "ilmuser"
        password: "your-strong-password"

      pgBouncer:
        enabled: false

      keycloakInternal:
        enabled: true

      feAdministrator:
        enabled: true
        service:
          type: NodePort
          nodePort: 30443

      softwareCryptographyProvider:
        enabled: true

      ingress:
        enabled: false
      VALUES_EOF

      echo "=== Deploying CZERTAINLY Helm Release ==="
      helm upgrade --install czertainly /opt/helm-charts/charts/ilm \
          --namespace czertainly \
          --values /tmp/czertainly-values.yaml \
          --timeout 15m \
          --wait 2>&1 || echo 'CZERTAINLY installation in progress...'

      # Port redirect for 8443 / 443 -> 30443
      iptables -t nat -C PREROUTING -p tcp --dport 8443 -j REDIRECT --to-port 30443 2>/dev/null || \
          iptables -t nat -A PREROUTING -p tcp --dport 8443 -j REDIRECT --to-port 30443
      iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443 2>/dev/null || \
          iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443
      netfilter-persistent save 2>/dev/null || true
      echo "=== CZERTAINLY Installation Finished ==="

runcmd:
  - /root/deploy-czertainly.sh > /var/log/czertainly-deploy.log 2>&1
CLOUDINIT

success "Cloud-init userdata written to ${USERDATA_FILE}"

# ---------------------------------------------------------------------------
# 2. Launch czertainly-ca VM
# ---------------------------------------------------------------------------
VM_NAME="czertainly-ca"
info "Launching '${VM_NAME}' (flavor: czertainly) …"

if openstack server show "${VM_NAME}" &>/dev/null; then
    info "VM '${VM_NAME}' already exists – skipping launch."
else
    openstack server create "${VM_NAME}" \
        --image ubuntu-24.04 \
        --flavor czertainly \
        --network k8s-net \
        --security-group k8s-sg \
        --key-name k8s-key \
        --user-data "${USERDATA_FILE}" \
        --wait
    success "VM '${VM_NAME}' launched."
fi

# ---------------------------------------------------------------------------
# 3. Wait for VM to be ACTIVE
# ---------------------------------------------------------------------------
info "Waiting for ${VM_NAME} to become ACTIVE …"
RETRIES=30
while [[ $RETRIES -gt 0 ]]; do
    STATUS=$(openstack server show "${VM_NAME}" -f value -c status)
    if [[ "${STATUS}" == "ACTIVE" ]]; then
        success "${VM_NAME} is ACTIVE."
        break
    elif [[ "${STATUS}" == "ERROR" ]]; then
        error "${VM_NAME} entered ERROR state."
    fi
    sleep 5
    RETRIES=$((RETRIES - 1))
done

# ---------------------------------------------------------------------------
# 4. Assign Floating IP
# ---------------------------------------------------------------------------
info "Assigning floating IP to ${VM_NAME} …"
EXISTING_FIP=$(openstack server show "${VM_NAME}" -f json | \
    python3 -c "import sys,json,re; d=json.load(sys.stdin); s=json.dumps(d.get('addresses','')); m=re.findall(r'172\.24\.4\.\d+', s); print(m[0] if m else '')" 2>/dev/null || echo "")

if [[ -n "${EXISTING_FIP}" ]]; then
    CZERTAINLY_FIP="${EXISTING_FIP}"
    info "${VM_NAME} already has floating IP: ${CZERTAINLY_FIP}"
else
    CZERTAINLY_FIP=$(openstack floating ip create public -f value -c floating_ip_address)
    openstack server add floating ip "${VM_NAME}" "${CZERTAINLY_FIP}"
    success "${VM_NAME} → ${CZERTAINLY_FIP}"
fi

# ---------------------------------------------------------------------------
# 5. Register in OpenStack Designate DNS
# ---------------------------------------------------------------------------
info "Creating DNS record in Designate: czertainly.lab.local → ${CZERTAINLY_FIP} …"
openstack recordset create lab.local. czertainly \
    --type A \
    --record "${CZERTAINLY_FIP}" 2>/dev/null || {
    warn "Record for czertainly.lab.local may already exist."
}

# ---------------------------------------------------------------------------
# 6. Update czertainly.env and vm-ips.env
# ---------------------------------------------------------------------------
info "Updating czertainly.env …"

cat > "${CZERTAINLY_ENV_FILE}" <<EOF
# Configuration for CZERTAINLY CA (running as OpenStack VM czertainly-ca)
CZERTAINLY_HOST="${CZERTAINLY_FIP}"
CZERTAINLY_PORT="8000"
CZERTAINLY_TLS_PORT="8443"
CZERTAINLY_SCHEME="http"
CZERTAINLY_DOMAIN="czertainly.lab.local"
CZERTAINLY_RA_PROFILE="lab-profile"
CZERTAINLY_ACME_URL="\${CZERTAINLY_SCHEME}://\${CZERTAINLY_DOMAIN}:\${CZERTAINLY_PORT}/api/v1/protocols/acme/\${CZERTAINLY_RA_PROFILE}/directory"
EOF

# Append CZERTAINLY_IP to vm-ips.env if not present
if [[ -f "${VM_IPS_FILE}" ]] && ! grep -q "CZERTAINLY_IP=" "${VM_IPS_FILE}"; then
    echo "CZERTAINLY_IP=${CZERTAINLY_FIP}" >> "${VM_IPS_FILE}"
fi

success "CZERTAINLY CA instance deployed successfully!"
echo ""
echo "  VM Name:        ${VM_NAME}"
echo "  Floating IP:    ${CZERTAINLY_FIP}"
echo "  Web UI URL:     https://${CZERTAINLY_FIP}:8443"
echo "  DNS FQDN:       https://czertainly.lab.local:8443"
echo "  Next step:      Wait ~3-5 min for cloud-init and CZERTAINLY pods to start."
echo ""

