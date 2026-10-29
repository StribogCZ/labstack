#!/bin/bash
###############################################################################
# 00-cleanup-devstack.sh
#
# Deep cleanup script to completely remove an existing DevStack installation
# and restore the Ubuntu 24.04 VM to a clean state before redeploying.
#
# Must be run as root (or with sudo).
#
# Actions:
#   1. Runs DevStack unstack.sh and clean.sh (if present)
#   2. Terminates lingering OpenStack/DevStack processes
#   3. Stops, disables and removes all devstack@*.service systemd units
#   4. Destroys and cleans Nova Libvirt/KVM instances and volumes
#   5. Removes Open vSwitch (OVS) bridges (br-ex, br-int, br-tun) and veths
#   6. Flushes Neutron iptables/nftables chains and NAT rules
#   7. Drops all OpenStack databases in MySQL/MariaDB
#   8. Resets RabbitMQ state and vhosts
#   9. Disables OpenStack Apache sites (Keystone, Horizon, Placement)
#  10. Cleans up /opt/stack and Bind9/Designate zones
#
# Usage:
#   sudo ./00-cleanup-devstack.sh
#   sudo ./00-cleanup-devstack.sh --force   # Skip interactive confirmation
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
echo -e "${RED}================================================================${NC}"
echo -e "${RED}         DEEP DEVSTACK CLEANUP & PURGE SCRIPT                   ${NC}"
echo -e "${RED}================================================================${NC}"
echo ""

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This cleanup script must be run as root (use sudo)."
fi

# Confirmation prompt unless --force or -y is provided
FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-y" || "${1:-}" == "-f" ]]; then
    FORCE=true
fi

if [[ "${FORCE}" != "true" ]]; then
    echo -e "${YELLOW}WARNING: This script will terminate all OpenStack services, delete${NC}"
    echo -e "${YELLOW}all Nova instances, drop OpenStack databases, remove OVS bridges,${NC}"
    echo -e "${YELLOW}and clean /opt/stack.${NC}"
    echo ""
    read -rp "Are you sure you want to proceed with full cleanup? (type 'yes'): " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        info "Cleanup aborted by user."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# 1. Run official DevStack unstack.sh and clean.sh if available
# ---------------------------------------------------------------------------
DEVSTACK_DIR="/opt/stack/devstack"

if [[ -f "${DEVSTACK_DIR}/unstack.sh" ]]; then
    info "Running native DevStack unstack.sh as 'stack' user..."
    su - stack -c "cd ${DEVSTACK_DIR} && ./unstack.sh" || {
        warn "unstack.sh encountered errors, continuing with manual purge..."
    }
    success "unstack.sh finished."
else
    info "unstack.sh not found, proceeding with manual service termination."
fi

if [[ -f "${DEVSTACK_DIR}/clean.sh" ]]; then
    info "Running native DevStack clean.sh as 'stack' user..."
    su - stack -c "cd ${DEVSTACK_DIR} && ./clean.sh" || {
        warn "clean.sh encountered errors, continuing with manual purge..."
    }
    success "clean.sh finished."
fi

# ---------------------------------------------------------------------------
# 2. Stop and remove all devstack@*.service systemd units
# ---------------------------------------------------------------------------
info "Stopping and removing all devstack@*.service units..."

SERVICES=$(systemctl list-unit-files 'devstack@*.service' --no-legend 2>/dev/null | awk '{print $1}' || true)
if [[ -n "${SERVICES}" ]]; then
    for s in ${SERVICES}; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
    done
fi

# Remove systemd files
rm -f /etc/systemd/system/devstack@*.service
rm -f /etc/systemd/system/multi-user.target.wants/devstack@*.service
systemctl daemon-reload
success "DevStack systemd services removed."

# ---------------------------------------------------------------------------
# 3. Kill lingering processes
# ---------------------------------------------------------------------------
info "Killing lingering OpenStack/DevStack processes..."

P_NAMES="nova- neutron- glance- keystone- cinder- placement- designate- heat- dstat screen"
for p in ${P_NAMES}; do
    pkill -9 -f "${p}" 2>/dev/null || true
done
success "Processes cleaned."

# ---------------------------------------------------------------------------
# 4. Clean Nova Libvirt/KVM instances and storage
# ---------------------------------------------------------------------------
info "Cleaning Libvirt instances..."

if command -v virsh &>/dev/null; then
    RUNNING_VMS=$(virsh list --name 2>/dev/null || true)
    for vm in ${RUNNING_VMS}; do
        if [[ -n "${vm}" ]]; then
            info "  Destroying libvirt VM: ${vm}"
            virsh destroy "${vm}" 2>/dev/null || true
        fi
    done

    ALL_VMS=$(virsh list --all --name 2>/dev/null || true)
    for vm in ${ALL_VMS}; do
        if [[ -n "${vm}" ]]; then
            info "  Undefining libvirt VM: ${vm}"
            virsh undefine "${vm}" --remove-all-storage 2>/dev/null || true
        fi
    done
fi

rm -rf /var/lib/nova/instances/* 2>/dev/null || true
rm -rf /opt/stack/data/nova/* 2>/dev/null || true
success "Libvirt instances and Nova storage cleaned."

# ---------------------------------------------------------------------------
# 5. Clean Open vSwitch (OVS) bridges and network interfaces
# ---------------------------------------------------------------------------
info "Cleaning Open vSwitch (OVS) bridges and interfaces..."

if command -v ovs-vsctl &>/dev/null; then
    for br in br-ex br-int br-tun br-mgmt; do
        if ovs-vsctl br-exists "${br}" 2>/dev/null; then
            info "  Deleting OVS bridge: ${br}"
            ovs-vsctl del-br "${br}" 2>/dev/null || true
        fi
    done
fi

# Delete leftover network namespaces (qrouter, qdhcp, etc.)
for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
    info "  Deleting network namespace: ${ns}"
    ip netns delete "${ns}" 2>/dev/null || true
done

# Delete leftover dummy/veth/tap interfaces
for iface in $(ip link show 2>/dev/null | grep -oP '(?<=\d:\s)(tap|qbr|qvb|qvo|qr-|qg-|fg-)[^:@]+' || true); do
    ip link delete "${iface}" 2>/dev/null || true
done
success "Network bridges and namespaces purged."

# ---------------------------------------------------------------------------
# 6. Flush iptables and restore networking
# ---------------------------------------------------------------------------
info "Flushing Neutron iptables rules..."

# Flush filter and nat tables
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

# Set default ACCEPT policies
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true

# IPv6 rules flush
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

success "Iptables chains flushed."

# ---------------------------------------------------------------------------
# 7. Drop OpenStack databases in MySQL/MariaDB
# ---------------------------------------------------------------------------
info "Cleaning OpenStack databases in MySQL/MariaDB..."

OS_DBS=(
    "keystone"
    "glance"
    "nova"
    "nova_api"
    "nova_cell0"
    "placement"
    "neutron"
    "cinder"
    "heat"
    "designate"
    "designate_pool_manager"
    "ovs_neutron"
)

if command -v mysql &>/dev/null; then
    for db in "${OS_DBS[@]}"; do
        mysql -e "DROP DATABASE IF EXISTS ${db};" 2>/dev/null || true
    done
    success "OpenStack databases dropped."
else
    info "MySQL client not found, skipping DB purge."
fi

# ---------------------------------------------------------------------------
# 8. Reset RabbitMQ
# ---------------------------------------------------------------------------
info "Resetting RabbitMQ..."

if command -v rabbitmqctl &>/dev/null; then
    systemctl stop rabbitmq-server 2>/dev/null || true
    rm -rf /var/lib/rabbitmq/mnesia/* 2>/dev/null || true
    systemctl start rabbitmq-server 2>/dev/null || true
    success "RabbitMQ reset."
else
    info "RabbitMQ not found, skipping."
fi

# ---------------------------------------------------------------------------
# 9. Clean Apache OpenStack sites
# ---------------------------------------------------------------------------
info "Cleaning Apache OpenStack site configurations..."

if command -v a2dissite &>/dev/null; then
    for site in keystone placement horizon designate-api cinder; do
        a2dissite "${site}" 2>/dev/null || true
        rm -f "/etc/apache2/sites-available/${site}.conf"
        rm -f "/etc/apache2/sites-enabled/${site}.conf"
    done
    systemctl restart apache2 2>/dev/null || true
    success "Apache sites cleaned."
fi

# ---------------------------------------------------------------------------
# 10. Clean Bind9 / Designate configuration
# ---------------------------------------------------------------------------
info "Cleaning Bind9 Designate zones and options..."

rm -rf /etc/bind/zones/* 2>/dev/null || true
rm -f /etc/bind/named.conf.designate 2>/dev/null || true
if [[ -f /etc/bind/named.conf.local ]]; then
    sed -i '/zone "auth.acmedns.lab.local"/,/};/d' /etc/bind/named.conf.local 2>/dev/null || true
fi
systemctl restart bind9 2>/dev/null || systemctl restart named 2>/dev/null || true
success "Bind9 cleaned."

# ---------------------------------------------------------------------------
# 11. Clean /opt/stack data & configuration
# ---------------------------------------------------------------------------
info "Cleaning /opt/stack data and configuration..."

rm -rf /opt/stack/data/* 2>/dev/null || true
rm -rf /opt/stack/status/* 2>/dev/null || true
rm -f /opt/stack/devstack/local.conf 2>/dev/null || true
rm -f /opt/stack/devstack/.stackvms 2>/dev/null || true

# Clean /etc/openstack, /etc/nova, /etc/neutron, etc.
for conf_dir in nova neutron glance keystone placement designate cinder heat; do
    rm -rf "/etc/${conf_dir}" 2>/dev/null || true
done

success "/opt/stack data and configs wiped."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  DevStack Cleanup Completed Successfully!                      ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo "The system is now clean and ready for a fresh deployment:"
echo "  1. (Optional but recommended) Reboot the VM to clear network namespaces cleanly:"
echo "     sudo reboot"
echo ""
echo "  2. Run host preparation:"
echo "     sudo ./00-host-prepare.sh"
echo ""
echo "  3. Deploy DevStack freshly with Designate:"
echo "     sudo su - stack"
echo "     ./01-devstack-install.sh"
echo ""
echo -e "${GREEN}================================================================${NC}"

