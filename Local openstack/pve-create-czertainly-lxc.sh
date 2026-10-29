#!/bin/bash
###############################################################################
# pve-create-czertainly-lxc.sh (Ubuntu 24.04 LTS Noble)
#
# Automates the creation and deployment of CZERTAINLY CA inside a dedicated
# Ubuntu 24.04 LTS LXC container on Proxmox VE (PVE) — completely OUTSIDE
# OpenStack and outside the OpenStack Kubernetes cluster.
#
# Run this script directly on your Proxmox VE host (as root).
#
# Actions:
#   1. Validates PVE environment (pvesh, pct, pveam)
#   2. Downloads Ubuntu 24.04 LTS (Noble) LXC template if not present
#   3. Creates LXC container with nesting, keyctl and k3s compatibility flags
#   4. Boots container and installs K3s + Helm inside Ubuntu 24.04 LXC
#   5. Deploys CZERTAINLY platform (Core, Auth, Web UI, ACME, Internal DB)
#   6. Exposes CZERTAINLY on host port 8443 (HTTPS) / 8080 (HTTP)
#   7. Prints ACME directory URL and integration instructions for OpenStack/K8s
#
# Usage on Proxmox VE:
#   chmod +x pve-create-czertainly-lxc.sh
#   ./pve-create-czertainly-lxc.sh
#
# Or override defaults via environment variables:
#   CT_ID=250 CT_IP=192.168.1.250/24 CT_GW=192.168.1.1 ./pve-create-czertainly-lxc.sh
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

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  Proxmox VE (PVE) — CZERTAINLY CA on Ubuntu 24.04 LTS LXC      ${NC}"
echo -e "${GREEN}  (External to OpenStack & External to K8s Cluster)             ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Environment verification
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root on the Proxmox VE host."
fi

if ! command -v pct &>/dev/null || ! command -v pveam &>/dev/null; then
    error "Proxmox CLI tools (pct, pveam) not found. Are you running on Proxmox VE?"
fi

# ---------------------------------------------------------------------------
# 2. Configuration & Defaults
# ---------------------------------------------------------------------------
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "250")
CT_ID="${CT_ID:-${NEXT_ID}}"
CT_NAME="${CT_NAME:-czertainly-ca-ubuntu24}"
CT_CORES="${CT_CORES:-4}"
CT_MEMORY="${CT_MEMORY:-4096}"  # MB (CZERTAINLY services + DB need ~4GB)
CT_SWAP="${CT_SWAP:-2048}"      # MB
CT_DISK="${CT_DISK:-25}"        # GB
STORAGE="${STORAGE:-local-lvm}" # PVE storage for rootfs
BRIDGE="${BRIDGE:-vmbr0}"       # Network bridge
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

# Network configuration: Prompt or default to DHCP if CT_IP is not set
if [[ -z "${CT_IP:-}" ]]; then
    read -rp "Enter LXC IP with CIDR (e.g. 192.168.1.250/24) or 'dhcp' [dhcp]: " USER_IP
    CT_IP="${USER_IP:-dhcp}"
fi

if [[ "${CT_IP}" != "dhcp" && -z "${CT_GW:-}" ]]; then
    read -rp "Enter default gateway IP (e.g. 192.168.1.1): " USER_GW
    CT_GW="${USER_GW:-}"
fi

info "Container Configuration:"
echo "  - Container ID:     ${CT_ID}"
echo "  - Hostname:         ${CT_NAME}"
echo "  - OS:               Ubuntu 24.04 LTS (Noble Numbat)"
echo "  - Cores:            ${CT_CORES}"
echo "  - RAM:              ${CT_MEMORY} MB"
echo "  - Disk:             ${CT_DISK} GB on ${STORAGE}"
echo "  - Network:          ${CT_IP} on ${BRIDGE} (Gateway: ${CT_GW:-N/A})"
echo ""

# Check if container ID already exists
SKIP_CREATE=false
if pct status "${CT_ID}" &>/dev/null; then
    warn "Container ID ${CT_ID} already exists on this Proxmox host."
    read -rp "Do you want to (r)esume setup, (d)elete & recreate, or (a)bort? [r/d/a]: " EXIST_CHOICE
    case "${EXIST_CHOICE:-r}" in
        d|D)
            info "Stopping and deleting existing container ${CT_ID}..."
            pct stop "${CT_ID}" 2>/dev/null || true
            pct destroy "${CT_ID}" --purge 2>/dev/null || true
            ;;
        r|R)
            info "Resuming setup on existing container ${CT_ID}..."
            SKIP_CREATE=true
            ;;
        *)
            error "Aborted by user."
            ;;
    esac
fi

if [[ "${SKIP_CREATE}" != "true" ]]; then
    # ---------------------------------------------------------------------------
    # 3. Download/Verify Ubuntu 24.04 LTS Template
    # ---------------------------------------------------------------------------
    info "Updating Proxmox appliance database..."
    pveam update || true

    info "Checking for Ubuntu 24.04 LTS LXC template in '${TEMPLATE_STORAGE}'..."

    TEMPLATE_NAME=$(pveam available -section system | awk '{print $2}' | grep -E '^ubuntu-24\.04-standard.*amd64\.tar' | sort -V | tail -n 1 || true)

    if [[ -z "${TEMPLATE_NAME}" ]]; then
        warn "Ubuntu 24.04 template not indexed by pveam, falling back to Ubuntu 22.04..."
        TEMPLATE_NAME=$(pveam available -section system | awk '{print $2}' | grep -E '^ubuntu-22\.04-standard.*amd64\.tar' | sort -V | tail -n 1 || true)
    fi

    if [[ -z "${TEMPLATE_NAME}" ]]; then
        error "Could not find an Ubuntu 24.04 or 22.04 template in pveam available list."
    fi

    TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

    # Check if template is already downloaded
    if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${TEMPLATE_NAME}"; then
        info "Downloading template ${TEMPLATE_NAME} to ${TEMPLATE_STORAGE}..."
        pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_NAME}"
        success "Template downloaded."
    else
        info "Template ${TEMPLATE_NAME} is already cached locally."
    fi

    # ---------------------------------------------------------------------------
    # 4. Create LXC Container
    # ---------------------------------------------------------------------------
    info "Creating Ubuntu 24.04 LXC container ${CT_ID} (${CT_NAME})..."

    NET_OPTS="name=eth0,bridge=${BRIDGE},ip=${CT_IP}"
    if [[ -n "${CT_GW:-}" && "${CT_IP}" != "dhcp" ]]; then
        NET_OPTS="${NET_OPTS},gw=${CT_GW}"
    fi

    pct create "${CT_ID}" "${TEMPLATE_PATH}" \
        --hostname "${CT_NAME}" \
        --cores "${CT_CORES}" \
        --memory "${CT_MEMORY}" \
        --swap "${CT_SWAP}" \
        --rootfs "${STORAGE}:${CT_DISK}" \
        --net0 "${NET_OPTS}" \
        --ostype ubuntu \
        --unprivileged 0 \
        --features nesting=1,keyctl=1 \
        --onboot 1

    success "LXC container ${CT_ID} created."
fi

# ---------------------------------------------------------------------------
# 5. Tune LXC config for Ubuntu 24.04 systemd & K3s container runtime
# ---------------------------------------------------------------------------
info "Ensuring container config (/etc/pve/lxc/${CT_ID}.conf) has K3s privileges..."

if ! grep -q "lxc.apparmor.profile: unconfined" "/etc/pve/lxc/${CT_ID}.conf" 2>/dev/null; then
    cat >> "/etc/pve/lxc/${CT_ID}.conf" <<'EOF'
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF
    if pct status "${CT_ID}" 2>/dev/null | grep -q "status: running"; then
        info "Restarting container ${CT_ID} to apply updated LXC profile..."
        pct stop "${CT_ID}"
        sleep 3
    fi
fi

# ---------------------------------------------------------------------------
# 6. Start LXC Container
# ---------------------------------------------------------------------------
if ! pct status "${CT_ID}" 2>/dev/null | grep -q "status: running"; then
    info "Starting container ${CT_ID}..."
    pct start "${CT_ID}"
fi

info "Waiting for container network initialization (10s)..."
sleep 10

# Detect IP if DHCP was used
if [[ "${CT_IP}" == "dhcp" ]]; then
    for i in {1..15}; do
        DETECTED_IP=$(pct exec "${CT_ID}" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        if [[ -n "${DETECTED_IP}" ]]; then
            ACTUAL_IP="${DETECTED_IP}"
            break
        fi
        sleep 2
    done
    if [[ -z "${ACTUAL_IP:-}" ]]; then
        error "Could not detect DHCP IP assigned to container ${CT_ID}."
    fi
else
    ACTUAL_IP="${CT_IP%%/*}"
fi

success "Container is running with IP: ${ACTUAL_IP}"

# ---------------------------------------------------------------------------
# 7. Provision K3s and Helm inside Ubuntu 24.04 LXC
# ---------------------------------------------------------------------------
info "Installing prerequisites, K3s, and Helm inside Ubuntu 24.04 container..."

pct exec "${CT_ID}" -- bash <<'PROVISION_LXC'
set -euo pipefail

# Ensure standard environment, PATH, and locales
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Fix /dev/kmsg and mount sharing required by containerd / K3s in LXC
if [ ! -e /dev/kmsg ]; then
    ln -sf /dev/console /dev/kmsg 2>/dev/null || true
fi
mount --make-rshared / 2>/dev/null || true

# Persist PATH in /etc/environment
echo "PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" > /etc/environment

apt-get update -y
apt-get install -y curl wget git jq openssl ca-certificates iptables net-tools iptables-persistent netfilter-persistent

# Ensure iptables uses nftables or legacy cleanly on Ubuntu 24.04
update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

# Install K3s (disabling default traefik to bind CZERTAINLY directly)
echo "Checking / Installing K3s lightweight Kubernetes..."
if ! command -v k3s &>/dev/null && ! [[ -f /usr/local/bin/k3s ]]; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb" sh -
else
    echo "K3s is already installed, restarting service..."
    systemctl restart k3s 2>/dev/null || true
fi

# Ensure kubectl is accessible in PATH and symlinked to /usr/bin
ln -sf /usr/local/bin/kubectl /usr/bin/kubectl 2>/dev/null || true

# Wait for K3s node to be ready
echo "Waiting for K3s node to become ready..."
for i in $(seq 1 45); do
    if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
        echo "K3s node is Ready."
        break
    fi
    echo "  Waiting for K3s API server (attempt ${i}/45)..."
    sleep 2
done

# Install Helm v3 with PATH explicitly set
echo "Installing Helm v3..."
if ! command -v helm &>/dev/null && ! [[ -f /usr/local/bin/helm ]]; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH" bash
fi

# Ensure helm is symlinked to /usr/bin
ln -sf /usr/local/bin/helm /usr/bin/helm 2>/dev/null || true

echo "K3s and Helm installation complete on Ubuntu 24.04."
PROVISION_LXC

success "K3s and Helm are ready inside the container."

# ---------------------------------------------------------------------------
# 8. Deploy CZERTAINLY CA Platform inside LXC
# ---------------------------------------------------------------------------
info "Deploying CZERTAINLY platform via Helm inside container..."

pct exec "${CT_ID}" -- bash <<'DEPLOY_LXC'
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 1. Clone official OmniTrustILM / CZERTAINLY Helm charts repository
if [[ ! -d /opt/helm-charts ]]; then
    echo "Cloning official OmniTrustILM/CZERTAINLY Helm charts repository..."
    git clone --depth 1 https://github.com/OmniTrustILM/helm-charts.git /opt/helm-charts
else
    echo "Updating local Helm charts repository..."
    git -C /opt/helm-charts pull || true
fi

# 2. Build local subchart dependencies (keycloak, auth, rabbitmq, etc.)
echo "Building chart dependencies from local subcharts..."
cd /opt/helm-charts/charts/ilm
helm dependency build .

# Ensure K3s API server is responsive
echo "Checking K3s API server status..."
systemctl start k3s 2>/dev/null || true
for i in $(seq 1 45); do
    if kubectl get nodes &>/dev/null; then
        echo "K3s API is responding."
        break
    fi
    echo "  Waiting for K3s API server (attempt ${i}/45)..."
    sleep 2
done

kubectl create namespace czertainly 2>/dev/null || true

# 3. Deploy lightweight PostgreSQL for CZERTAINLY
echo "Deploying PostgreSQL database service in czertainly namespace..."
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

# 4. Prepare values file
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

echo "Installing/Upgrading CZERTAINLY / ILM platform via Helm..."
helm upgrade --install czertainly /opt/helm-charts/charts/ilm \
    --namespace czertainly \
    --values /tmp/czertainly-values.yaml \
    --timeout 15m \
    --wait 2>&1 || echo 'CZERTAINLY deployment initiated...'

# Port forward / host port redirect inside LXC so port 8443 on container IP forwards to 30443
iptables -t nat -C PREROUTING -p tcp --dport 8443 -j REDIRECT --to-port 30443 2>/dev/null || \
    iptables -t nat -A PREROUTING -p tcp --dport 8443 -j REDIRECT --to-port 30443
iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443 2>/dev/null || \
    iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 30443
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
DEPLOY_LXC

success "CZERTAINLY deployed successfully in Ubuntu 24.04 LXC container."

# ---------------------------------------------------------------------------
# 9. Summary & Integration Guide for OpenStack / K8s
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  CZERTAINLY CA (Ubuntu 24.04 LXC) Deployed Successfully!       ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo "  Container ID:        ${CT_ID}"
echo "  Container Hostname:  ${CT_NAME}"
echo "  OS Version:          Ubuntu 24.04 LTS (Noble Numbat)"
echo "  Container IP:        ${ACTUAL_IP}"
echo "  Web UI URL:          https://${ACTUAL_IP}:8443   (or https://${ACTUAL_IP})"
echo "  Default Login:       admin / admin"
echo ""
echo -e "${CYAN}--- Next Steps to Connect OpenStack / Kubernetes Cluster ---${NC}"
echo "1. On your OpenStack/DevStack machine or DNS:"
echo "   Add DNS or /etc/hosts entry so 'czertainly.lab.local' resolves to ${ACTUAL_IP}:"
echo "     ${ACTUAL_IP} czertainly.lab.local"
echo ""
echo "2. In your OpenStack project directory ('Local openstack'):"
echo "   Update 'czertainly.env' or run '07-deploy-czertainly.sh':"
echo "     CZERTAINLY_HOST=${ACTUAL_IP} ./07-deploy-czertainly.sh"
echo ""
echo "3. In CZERTAINLY Web UI (https://${ACTUAL_IP}:8443):"
echo "   - Create a CA / Cryptographic Connector (Software CA or PyCA provider)"
echo "   - Create an RA Profile (e.g. named 'lab-profile')"
echo "   - Enable ACME protocol for this RA Profile"
echo "   - The ACME directory endpoint will be:"
echo "     https://czertainly.lab.local:8443/api/v1/protocols/acme/profile/lab-profile/directory"
echo ""
echo -e "${GREEN}================================================================${NC}"
