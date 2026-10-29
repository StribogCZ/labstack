#!/bin/bash
###############################################################################
# 01-devstack-install.sh
#
# Installs DevStack (stable/2024.2) with Designate DNS service.
# Must be run as the 'stack' user.
#
# Actions:
#   - Clones DevStack repository
#   - Generates local.conf with Designate, Heat, Bind9 backend
#   - Runs stack.sh to deploy OpenStack
#   - Creates initial DNS zone (lab.local.)
#
# Usage:
#   sudo su - stack
#   ./01-devstack-install.sh
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
# Pre-flight: must be 'stack' user
# ---------------------------------------------------------------------------
if [[ "$(whoami)" != "stack" ]]; then
    error "This script must be run as the 'stack' user."
fi

echo ""
info "=========================================="
info " OpenStack Lab – DevStack Installation"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Detect HOST_IP from default route interface
# ---------------------------------------------------------------------------
info "Detecting host IP address …"

DEFAULT_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
HOST_IP=$(ip -4 addr show dev "${DEFAULT_IFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

if [[ -z "${HOST_IP}" ]]; then
    error "Could not determine HOST_IP. Check network configuration."
fi

success "HOST_IP = ${HOST_IP} (interface: ${DEFAULT_IFACE})"
echo ""

# ---------------------------------------------------------------------------
# 2. Clone DevStack
# ---------------------------------------------------------------------------
DEVSTACK_DIR="/opt/stack/devstack"

DEVSTACK_BRANCH="${DEVSTACK_BRANCH:-stable/2025.1}"

info "Cloning DevStack (${DEVSTACK_BRANCH}) …"

if [[ -d "${DEVSTACK_DIR}" ]]; then
    info "DevStack directory already exists – pulling latest."
    cd "${DEVSTACK_DIR}"
    git checkout "${DEVSTACK_BRANCH}" 2>/dev/null || git checkout -b "${DEVSTACK_BRANCH}" "origin/${DEVSTACK_BRANCH}"
    git pull
else
    git clone https://opendev.org/openstack/devstack.git "${DEVSTACK_DIR}" -b "${DEVSTACK_BRANCH}"
fi

success "DevStack cloned to ${DEVSTACK_DIR}."
echo ""

# ---------------------------------------------------------------------------
# 3. Generate local.conf
# ---------------------------------------------------------------------------
info "Generating local.conf …"

cat > "${DEVSTACK_DIR}/local.conf" <<EOF
[[local|localrc]]
# ---- Host -------------------------------------------------------------------
HOST_IP=${HOST_IP}
SERVICE_HOST=${HOST_IP}

# ---- Passwords (lab only – NOT for production) ------------------------------
ADMIN_PASSWORD=labpassword
DATABASE_PASSWORD=labpassword
RABBIT_PASSWORD=labpassword
SERVICE_PASSWORD=labpassword
SERVICE_TOKEN=labpassword

# ---- Networking -------------------------------------------------------------
FLOATING_RANGE=172.24.4.0/24
Q_FLOATING_ALLOCATION_POOL=start=172.24.4.100,end=172.24.4.200
FIXED_RANGE=10.0.0.0/24
NETWORK_GATEWAY=10.0.0.1

# ---- Designate (DNS-as-a-Service) -------------------------------------------
enable_plugin designate https://opendev.org/openstack/designate.git ${DEVSTACK_BRANCH}
DESIGNATE_BACKEND_DRIVER=bind9
enable_service designate
enable_service designate-central
enable_service designate-api
enable_service designate-worker
enable_service designate-producer
enable_service designate-mdns

# ---- Heat (Orchestration) ---------------------------------------------------
enable_plugin heat https://opendev.org/openstack/heat.git ${DEVSTACK_BRANCH}

# ---- Disable unnecessary services to save resources -------------------------
disable_service tempest
disable_service c-api c-vol c-sch c-bak

# ---- Logging ----------------------------------------------------------------
LOGFILE=\$DEST/logs/stack.sh.log
LOGDAYS=2
LOG_COLOR=True
EOF

success "local.conf written to ${DEVSTACK_DIR}/local.conf"
echo ""

# ---------------------------------------------------------------------------
# 4. Run stack.sh
# ---------------------------------------------------------------------------
info "Running stack.sh – this will take 20-40 minutes …"
info "Tail the log:  tail -f /opt/stack/logs/stack.sh.log"
echo ""

cd "${DEVSTACK_DIR}"
./stack.sh

success "stack.sh completed successfully!"
echo ""

# ---------------------------------------------------------------------------
# 5. Create initial DNS zone
# ---------------------------------------------------------------------------
info "Creating initial DNS zone (lab.local.) …"

source "${DEVSTACK_DIR}/openrc" admin admin

# Create the zone (ignore error if it already exists)
openstack zone create --email admin@lab.local lab.local. || \
    info "Zone lab.local. may already exist."

# Wait a moment for the zone to become ACTIVE
sleep 5
openstack zone show lab.local. || true

success "DNS zone lab.local. created."
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
DASHBOARD_URL="http://${HOST_IP}/dashboard"

echo ""
info "=========================================="
info " DevStack Installation Complete"
info "=========================================="
echo ""
success "Dashboard URL .......... ${DASHBOARD_URL}"
success "Admin user ............. admin"
success "Admin password ......... labpassword"
success "Keystone endpoint ...... http://${HOST_IP}/identity"
success "Designate API .......... http://${HOST_IP}:9001"
success "DNS zone ............... lab.local."
echo ""
info "Source credentials:  source ${DEVSTACK_DIR}/openrc admin admin"
info "Next step: run 02-openstack-infra.sh"
echo ""
