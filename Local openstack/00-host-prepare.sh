#!/bin/bash
###############################################################################
# 00-host-prepare.sh
#
# Prepares an Ubuntu host machine for DevStack deployment.
# Must be run as root (or with sudo).
#
# Actions:
#   - Validates minimum system requirements (CPU, RAM, disk)
#   - Enables nested virtualization (kvm_intel / kvm_amd)
#   - Creates the 'stack' user with passwordless sudo
#   - Installs base dependencies
#   - Configures sysctl for networking
#
# Usage:
#   sudo ./00-host-prepare.sh
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight: must be root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (or with sudo)."
fi

echo ""
info "=========================================="
info " OpenStack Lab – Host Preparation"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Check OS version (Ubuntu 24.04 LTS Noble)
# ---------------------------------------------------------------------------
info "Checking OS version …"

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "  - Detected OS: ${PRETTY_NAME:-Unknown}"
    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "This script is designed for Ubuntu 24.04 LTS (detected ${ID:-unknown})."
    fi
    if [[ "${VERSION_ID:-}" != "24.04"* ]]; then
        info "Warning: Recommended OS is Ubuntu 24.04 LTS (detected ${VERSION_ID:-unknown}). Continuing..."
    else
        success "OS is Ubuntu 24.04 LTS (Noble Numbat)."
    fi
else
    error "Cannot determine OS: /etc/os-release not found."
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Check minimum system requirements
# ---------------------------------------------------------------------------
info "Checking system requirements …"

CPU_CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( RAM_KB / 1024 / 1024 ))
DISK_GB=$(df --output=avail / | tail -1 | awk '{printf "%.0f", $1/1024/1024}')

PASS=true

if [[ "$CPU_CORES" -lt 8 ]]; then
    echo -e "  ${RED}✗ CPU cores: ${CPU_CORES} (minimum 8)${NC}"
    PASS=false
else
    echo -e "  ${GREEN}✓ CPU cores: ${CPU_CORES}${NC}"
fi

if [[ "$RAM_GB" -lt 24 ]]; then
    echo -e "  ${RED}✗ RAM: ${RAM_GB} GB (minimum 24 GB)${NC}"
    PASS=false
else
    echo -e "  ${GREEN}✓ RAM: ${RAM_GB} GB${NC}"
fi

if [[ "$DISK_GB" -lt 100 ]]; then
    echo -e "  ${RED}✗ Disk (available /): ${DISK_GB} GB (minimum 100 GB)${NC}"
    PASS=false
else
    echo -e "  ${GREEN}✓ Disk (available /): ${DISK_GB} GB${NC}"
fi

if [[ "$PASS" != "true" ]]; then
    error "System does not meet minimum requirements. Aborting."
fi

success "System requirements met."
echo ""

# ---------------------------------------------------------------------------
# 2. Enable nested virtualization
# ---------------------------------------------------------------------------
info "Enabling nested virtualization …"

KVM_MODULE=""
if grep -q vmx /proc/cpuinfo 2>/dev/null; then
    KVM_MODULE="kvm_intel"
elif grep -q svm /proc/cpuinfo 2>/dev/null; then
    KVM_MODULE="kvm_amd"
else
    error "No hardware virtualization support detected (vmx/svm)."
fi

# Persist the setting
CONF_FILE="/etc/modprobe.d/${KVM_MODULE}.conf"
echo "options ${KVM_MODULE} nested=1" > "${CONF_FILE}"

# Reload module if possible (non-fatal if VMs are running)
if lsmod | grep -q "${KVM_MODULE}"; then
    modprobe -r "${KVM_MODULE}" 2>/dev/null && modprobe "${KVM_MODULE}" 2>/dev/null || \
        info "Could not reload ${KVM_MODULE} live – a reboot may be required."
else
    modprobe "${KVM_MODULE}" 2>/dev/null || true
fi

# Verify
NESTED=$(cat /sys/module/${KVM_MODULE}/parameters/nested 2>/dev/null || echo "N")
if [[ "$NESTED" == "1" || "$NESTED" == "Y" ]]; then
    success "Nested virtualization enabled (${KVM_MODULE})."
else
    info "Nested virtualization configured but may require a reboot to activate."
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Create the 'stack' user with NOPASSWD sudo
# ---------------------------------------------------------------------------
info "Creating 'stack' user …"

if id "stack" &>/dev/null; then
    info "User 'stack' already exists – skipping creation."
else
    useradd -s /bin/bash -d /opt/stack -m stack
    chmod 0755 /opt/stack
    usermod -a -G stack www-data 2>/dev/null || true
    success "User 'stack' created (home: /opt/stack)."
fi

# Ensure passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/stack"
echo "stack ALL=(ALL) NOPASSWD: ALL" > "${SUDOERS_FILE}"
chmod 0440 "${SUDOERS_FILE}"
success "Passwordless sudo configured for 'stack'."
echo ""

# ---------------------------------------------------------------------------
# 4. Install base dependencies
# ---------------------------------------------------------------------------
info "Installing base dependencies …"

apt-get update -qq
apt-get install -y -qq \
    git \
    python3 \
    python3-pip \
    python3-venv \
    bridge-utils \
    net-tools \
    curl \
    wget \
    ca-certificates

success "Base dependencies installed."
echo ""

# ---------------------------------------------------------------------------
# 5. Set sysctl parameters for networking
# ---------------------------------------------------------------------------
info "Configuring sysctl parameters …"

SYSCTL_CONF="/etc/sysctl.d/99-devstack-lab.conf"
cat > "${SYSCTL_CONF}" <<'EOF'
# DevStack Lab – networking requirements
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Ensure br_netfilter module is loaded so bridge sysctl keys exist
modprobe br_netfilter || true
echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf

sysctl --system -q

success "sysctl parameters applied."
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "=========================================="
info " Host Preparation Complete"
info "=========================================="
echo ""
success "CPU cores .............. ${CPU_CORES}"
success "RAM .................... ${RAM_GB} GB"
success "Available disk (/) ..... ${DISK_GB} GB"
success "KVM module ............. ${KVM_MODULE} (nested)"
success "User ................... stack (NOPASSWD sudo)"
success "Packages ............... git, python3, pip, bridge-utils, net-tools"
success "Sysctl ................. ip_forward=1, bridge-nf-call-iptables=1"
echo ""
info "Next step: switch to the 'stack' user and run 01-devstack-install.sh"
info "  sudo su - stack"
echo ""
