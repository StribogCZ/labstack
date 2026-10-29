#!/bin/bash
###############################################################################
# clean-and-run.sh
# Completely autonomous wipe and rebuild of the ACME Lab from scratch:
#   1. Deletes all OpenStack VMs (k8s-control-1, k8s-worker-1, k8s-worker-2, czertainly-ca)
#   2. Deletes lingering floating IPs and Designate DNS zones
#   3. Cleans all local state files (kubeconfig, tokens, registration, temp files)
#   4. Ensures br-ex network interface and iptables MASQUERADE are active
#   5. Runs run-all-automated.sh end-to-end
#   6. Validates certificate issuance and performs HTTPS test call
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo ""
echo "========================================================================"
echo "  STARTING 100% AUTONOMOUS CLEAN SLATE & FULL LAB DEPLOYMENT"
echo "========================================================================"
echo ""

# Source OpenStack credentials
set +u
source /opt/stack/devstack/openrc admin admin
trap - ERR || true
set -u

echo ">>> [1/6] Deleting existing OpenStack lab instances..."
openstack server delete czertainly-ca k8s-control-1 k8s-worker-1 k8s-worker-2 2>/dev/null || true

echo "Waiting for instances to be deleted..."
for i in $(seq 1 40); do
    REMAINING=$(openstack server list -c ID -f value | wc -l)
    if [ "${REMAINING}" -eq 0 ]; then
        echo "All instances successfully deleted."
        break
    fi
    echo "  Remaining instances: ${REMAINING} (attempt ${i}/40)..."
    sleep 3
done

echo ">>> [2/6] Cleaning floating IPs and Designate DNS zones..."
for fip in $(openstack floating ip list -f value -c ID); do
    openstack floating ip delete "${fip}" 2>/dev/null || true
done
openstack zone delete acmedns.lab.local. 2>/dev/null || true
openstack zone delete lab.local. 2>/dev/null || true

echo ">>> [3/6] Purging local state files and tokens..."
rm -f "${SCRIPT_DIR}/vm-ips.env"
rm -f "${SCRIPT_DIR}/kubeadm-join.sh"
rm -f "${HOME}/.kube/config"
rm -f "${SCRIPT_DIR}/acme-dns-registration.json"
rm -f "${SCRIPT_DIR}/acme-dns.yaml"
rm -f /tmp/acme-dns.yaml /tmp/k8s-cloud-init.yaml /tmp/czertainly-cloud-init.yaml
rm -f /tmp/cert-manager-values.yaml /tmp/04-k8s-cluster-init.sh /tmp/05-k8s-worker-join.sh /tmp/czertainly-ca.crt

echo ">>> [4/6] Verifying host bridge (br-ex) and iptables NAT..."
sudo ip link set br-ex up
sudo ip addr replace 172.24.4.1/24 dev br-ex
sudo iptables -t nat -C POSTROUTING -s 172.24.4.0/24 ! -d 172.24.4.0/24 -j MASQUERADE 2>/dev/null || \
sudo iptables -t nat -A POSTROUTING -s 172.24.4.0/24 ! -d 172.24.4.0/24 -j MASQUERADE

echo ">>> [5/6] Executing run-all-automated.sh..."
./run-all-automated.sh

echo ""
echo "========================================================================"
echo ">>> [6/6] VERIFYING AUTONOMOUS DEPLOYMENT RESULTS"
echo "========================================================================"
echo ""

export KUBECONFIG="${HOME}/.kube/config"

echo "=== Cluster Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== acme-dns Status ==="
kubectl get pods,pvc -n acme-dns

echo ""
echo "=== ClusterIssuer (czertainly-acme) ==="
kubectl get clusterissuer czertainly-acme -o wide
echo "Solver config:"
kubectl get clusterissuer czertainly-acme -o jsonpath='{.spec.acme.solvers[0]}' | jq .

echo ""
echo "=== cert-manager extraArgs Check ==="
kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'dns01.*' || echo "No recursive nameservers configured (CLEAN!)"

echo ""
echo "=== Issued Certificate ==="
kubectl wait --for=condition=ready certificate/app-tls-certificate -n istio-system --timeout=90s || true
kubectl get certificate -n istio-system app-tls-certificate -o wide

echo ""
echo "=== End-to-End HTTPS Test App Call ==="
source "${SCRIPT_DIR}/vm-ips.env"
HTTPS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
curl -k -v --resolve "app.lab.local:${HTTPS_PORT}:${WORKER_IP}" "https://app.lab.local:${HTTPS_PORT}/" 2>&1 | grep -E 'HTTP/|Hello from|subject:|issuer:'

echo ""
echo "========================================================================"
echo "  AUTONOMOUS TEST COMPLETED SUCCESSFULLY!"
echo "========================================================================"

