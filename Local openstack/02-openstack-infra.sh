#!/bin/bash
###############################################################################
# 02-openstack-infra.sh
#
# Creates the OpenStack infrastructure required for the Kubernetes cluster:
#   - Ubuntu 24.04 LTS cloud image (Glance)
#   - Network, subnet, router
#   - Security group with K8s-relevant rules
#   - SSH keypair
#   - VM flavors (control / worker)
#
# Usage:
#   source /opt/stack/devstack/openrc admin admin
#   ./02-openstack-infra.sh
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
# Source credentials
# ---------------------------------------------------------------------------
info "Sourcing OpenStack credentials …"
set +u
source /opt/stack/devstack/openrc admin admin
set -u
success "Credentials loaded."
echo ""

# Detect HOST_IP for DNS nameserver
DEFAULT_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
HOST_IP=$(ip -4 addr show dev "${DEFAULT_IFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

echo ""
info "=========================================="
info " OpenStack Lab – Infrastructure Setup"
info "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Upload Ubuntu 24.04 LTS cloud image
# ---------------------------------------------------------------------------
IMAGE_NAME="ubuntu-24.04"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_FILE="/tmp/noble-server-cloudimg-amd64.img"

info "Checking for Ubuntu 24.04 cloud image …"

if openstack image show "${IMAGE_NAME}" &>/dev/null; then
    info "Image '${IMAGE_NAME}' already exists – skipping download."
else
    info "Downloading Ubuntu 24.04 cloud image …"
    wget -q --show-progress -O "${IMAGE_FILE}" "${IMAGE_URL}"

    info "Uploading image to Glance …"
    openstack image create "${IMAGE_NAME}" \
        --file "${IMAGE_FILE}" \
        --disk-format qcow2 \
        --container-format bare \
        --public

    rm -f "${IMAGE_FILE}"
    success "Image '${IMAGE_NAME}' uploaded."
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Create network and subnet
# ---------------------------------------------------------------------------
NETWORK_NAME="k8s-net"
SUBNET_NAME="k8s-subnet"
ROUTER_NAME="k8s-router"

info "Creating network '${NETWORK_NAME}' …"

if openstack network show "${NETWORK_NAME}" &>/dev/null; then
    info "Network '${NETWORK_NAME}' already exists."
else
    openstack network create "${NETWORK_NAME}"
    success "Network '${NETWORK_NAME}' created."
fi

info "Creating subnet '${SUBNET_NAME}' (10.10.0.0/24) …"

if openstack subnet show "${SUBNET_NAME}" &>/dev/null; then
    info "Subnet '${SUBNET_NAME}' already exists."
else
    openstack subnet create "${SUBNET_NAME}" \
        --network "${NETWORK_NAME}" \
        --subnet-range 10.10.0.0/24 \
        --gateway 10.10.0.1 \
        --dns-nameserver "${HOST_IP}" \
        --dns-nameserver 8.8.8.8 \
        --allocation-pool start=10.10.0.10,end=10.10.0.200
    success "Subnet '${SUBNET_NAME}' created."
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Create router
# ---------------------------------------------------------------------------
info "Creating router '${ROUTER_NAME}' …"

if openstack router show "${ROUTER_NAME}" &>/dev/null; then
    info "Router '${ROUTER_NAME}' already exists."
else
    openstack router create "${ROUTER_NAME}"
    openstack router set "${ROUTER_NAME}" --external-gateway public
    openstack router add subnet "${ROUTER_NAME}" "${SUBNET_NAME}"
    success "Router '${ROUTER_NAME}' created and attached."
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Create security group
# ---------------------------------------------------------------------------
SG_NAME="k8s-sg"

info "Creating security group '${SG_NAME}' …"

if openstack security group show "${SG_NAME}" &>/dev/null; then
    info "Security group '${SG_NAME}' already exists – recreating rules."
else
    openstack security group create "${SG_NAME}" \
        --description "Kubernetes cluster security group"
fi

# Helper to add rules idempotently (ignore duplicates)
add_rule() {
    openstack security group rule create "$@" 2>/dev/null || true
}

# All traffic between nodes in the security group (Calico IPIP protocol 4, pod-to-pod, etc.)
add_rule "${SG_NAME}" --remote-group "${SG_NAME}"
# All TCP within k8s subnet
add_rule "${SG_NAME}" --protocol tcp --dst-port 1:65535 --remote-ip 10.10.0.0/24
# All UDP within k8s subnet
add_rule "${SG_NAME}" --protocol udp --dst-port 1:65535 --remote-ip 10.10.0.0/24
# ICMP from anywhere
add_rule "${SG_NAME}" --protocol icmp --remote-ip 0.0.0.0/0
# SSH
add_rule "${SG_NAME}" --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0
# Kubernetes API server
add_rule "${SG_NAME}" --protocol tcp --dst-port 6443 --remote-ip 0.0.0.0/0
# HTTP
add_rule "${SG_NAME}" --protocol tcp --dst-port 80 --remote-ip 0.0.0.0/0
# HTTPS
add_rule "${SG_NAME}" --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0
# NodePort ranges (TCP & UDP for DNS/Istio/acme-dns)
add_rule "${SG_NAME}" --protocol tcp --dst-port 30000:32767 --remote-ip 0.0.0.0/0
add_rule "${SG_NAME}" --protocol udp --dst-port 30000:32767 --remote-ip 0.0.0.0/0
# DNS TCP & UDP
add_rule "${SG_NAME}" --protocol tcp --dst-port 53 --remote-ip 0.0.0.0/0
add_rule "${SG_NAME}" --protocol udp --dst-port 53 --remote-ip 0.0.0.0/0
# CZERTAINLY Web / ACME API
add_rule "${SG_NAME}" --protocol tcp --dst-port 8000 --remote-ip 0.0.0.0/0
add_rule "${SG_NAME}" --protocol tcp --dst-port 8443 --remote-ip 0.0.0.0/0
add_rule "${SG_NAME}" --protocol tcp --dst-port 8080 --remote-ip 0.0.0.0/0

success "Security group '${SG_NAME}' configured."
echo ""

# ---------------------------------------------------------------------------
# 5. Create SSH keypair
# ---------------------------------------------------------------------------
KEY_NAME="k8s-key"
KEY_FILE="${HOME}/.ssh/k8s-key.pem"

info "Creating SSH keypair '${KEY_NAME}' …"

mkdir -p "${HOME}/.ssh"

if openstack keypair show "${KEY_NAME}" &>/dev/null; then
    info "Keypair '${KEY_NAME}' already exists."
else
    openstack keypair create "${KEY_NAME}" > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
    success "Keypair saved to ${KEY_FILE}"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Create flavors
# ---------------------------------------------------------------------------
info "Creating VM flavors …"

if openstack flavor show k8s-control &>/dev/null; then
    info "Flavor 'k8s-control' already exists."
else
    openstack flavor create k8s-control \
        --ram 4096 --disk 40 --vcpus 2
    success "Flavor 'k8s-control' created (2 vCPU, 4 GB RAM, 40 GB disk)."
fi

if openstack flavor show k8s-worker &>/dev/null; then
    info "Flavor 'k8s-worker' already exists."
else
    openstack flavor create k8s-worker \
        --ram 8192 --disk 60 --vcpus 4
    success "Flavor 'k8s-worker' created (4 vCPU, 8 GB RAM, 60 GB disk)."
fi

if openstack flavor show czertainly &>/dev/null; then
    info "Flavor 'czertainly' already exists."
else
    openstack flavor create czertainly \
        --ram 6144 --disk 40 --vcpus 4
    success "Flavor 'czertainly' created (4 vCPU, 6 GB RAM, 40 GB disk)."
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Designate DNS zone
# ---------------------------------------------------------------------------
info "Ensuring Designate DNS zone 'lab.local.' exists …"
if openstack zone show lab.local. &>/dev/null; then
    info "DNS zone 'lab.local.' already exists."
else
    openstack zone create --email admin@lab.local lab.local. || true
    for i in $(seq 1 30); do
        STATUS=$(openstack zone show lab.local. -f value -c status 2>/dev/null || echo "PENDING")
        if [[ "${STATUS}" == "ACTIVE" ]]; then
            break
        fi
        sleep 2
    done
    success "DNS zone 'lab.local.' created and active."
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "=========================================="
info " Infrastructure Setup Complete"
info "=========================================="
echo ""
success "Image .............. ${IMAGE_NAME}"
success "Network ............ ${NETWORK_NAME} (10.10.0.0/24)"
success "Router ............. ${ROUTER_NAME} → public"
success "Security group ..... ${SG_NAME}"
success "Keypair ............ ${KEY_NAME} (${KEY_FILE})"
success "Flavor (control) ... k8s-control (2 vCPU / 4 GB / 40 GB)"
success "Flavor (worker) .... k8s-worker  (4 vCPU / 8 GB / 60 GB)"
echo ""
info "Next step: run 03-k8s-vms.sh to launch the cluster VMs."
echo ""
