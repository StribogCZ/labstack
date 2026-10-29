# ACME Lab Deployment Run 2: Kompletní příručka autonomního nasazení na cílovém prostředí (192.168.191.41)

Tento dokument představuje vyčerpávající technickou dokumentaci a návod krok za krokem z **2. ostrého nasazení** kompletní ACME certifikační infrastruktury v privátním cloudu. Celý proces proběhl na novém virtuálním stroji `192.168.191.41`.

Dokument popisuje veškeré nutné úpravy, řešení síťových a firewallových pravidel, přesměrování portů výhradně pomocí **iptables**, konfiguraci trvalých **PersistentVolumeClaims (PVC)** pro databázi a registrace `acme-dns`, a verifikaci celého řetězce.

---

## 1. Souhrn verzí všech použitých komponent

| Komponenta | Přesná verze | Poznámka / Konfigurace |
|---|---|---|
| **Hostitelský OS** | Ubuntu 24.04.5 LTS (Noble Numbat) | Kernel `6.8.0-147-generic`, 12 vCPU, 64 GB RAM |
| **OpenStack DevStack** | stable/2025.1 (Epoxy) | Podpora Pythonu 3.12, Keystone, Nova, Neutron (OVN), Glance, Heat, Designate |
| **DNS Server (OpenStack)** | BIND 9.18.39 | Backend pro Designate, rekurzivní forwarder pro ACME challenge |
| **Kubernetes (K8s)** | v1.36.0 (klient v1.36.5) | Dataplane `kube-proxy` v čistém režimu `iptables` |
| **Container Runtime** | containerd v2.2.1 | CRI na všech Kubernetes uzlech |
| **Kubernetes CNI** | Calico v3.28.2 | Enkapsulace IPIP (`ipipMode: Always`), iptables dataplane |
| **Storage Provisioner** | Rancher Local Path Provisioner v0.0.30 | Dynamický storage provisioner, `reclaimPolicy: Retain` |
| **acme-dns** | v2.0.2 (`joohoi/acme-dns:v2.0.2`) | DB ovladač `engine = "sqlite"`, perzistentní PVC `acme-dns-pvc` (1Gi) |
| **cert-manager** | v1.21.2 (Jetstack Helm Chart) | Nativní `acmeDNS` solver, `waitInsteadOfSelfCheck: 10s` (přímý bypass interního DNS self-checku) |
| **Istio Service Mesh** | v1.22.0 | Profil `default`, IngressGateway v režimu NodePort |
| **CZERTAINLY Core / ILM** | v3.9.1 (K3s uvnitř VM) | Kong API Gateway 3.9.1, PostgreSQL 15, Spring Boot Core |
| **CZERTAINLY Authority Provider**| V2 (`ca_provider.py`) | Microservice na portu 8888, REST rozhraní `AUTHORITY` v2 |
| **Helm** | v3.17.0 | Správce Kubernetes balíčků |

---

## 2. Síťová architektura a topologie portů

```
                             +-------------------------------------------------------------------------+
                             |                     Fyzický / PVE Hostitel                              |
                             |                     Cílová IP: 192.168.191.41                           |
                             +-------------------------------------------------------------------------+
                                                                  |
                         +----------------------------------------+----------------------------------------+
                         |                                                                                 |
                         v                                                                                 v
     +-----------------------------------------+                               +-----------------------------------------+
     |         DevStack & BIND9 DNS            |                               |        CZERTAINLY CA VM (Variant A)     |
     |         IP: 192.168.191.41              |                               |        Floating IP: 172.24.4.139        |
     |                                         |                               |        Interní IP:  10.10.0.171         |
     | - Horizon UI:        Port 80/443        |                               |                                         |
     | - Keystone API:      Port 5000          |                               | - Web Admin UI:     Port 8443 (NodePort)|
     | - Designate API:     Port 9001          |                               | - ACME Directory:   Port 8000 (Proxy)   |
     | - BIND9 DNS:         Port 53 (UDP/TCP)  |                               | - Core K3s API:     Port 6443           |
     |   (Zóna lab.local. & forwarder na       |                               | - Authority Microservice: Port 8888     |
     |    auth.acmedns.lab.local:30053)        |                               |   (vydává X.509 certifikáty z CSR)      |
     +-----------------------------------------+                               +-----------------------------------------+
                         |
                         +------------------------------------+
                         |                                    |
                         v                                    v
     +-----------------------------------------+  +-----------------------------------------+
     |       k8s-control-1 (Control Plane)     |  |          k8s-worker-1 & worker-2        |
     |       Floating IP: 172.24.4.158         |  |          Worker 1: 172.24.4.163         |
     |       Interní IP:  10.10.0.114          |  |          Worker 2: 172.24.4.145         |
     |                                         |  |                                         |
     | - kube-apiserver:    Port 6443          |  | - Istio HTTPS NodePort: Port 32574      |
     | - Calico CNI IPIP:   IP proto 4         |  | - Istio HTTP NodePort:  Port 30392      |
     | - Local Path Storage Controller         |  | - acme-dns DNS:         NodePort 30053  |
     |                                         |  | - acme-dns API:         NodePort 30080  |
     |                                         |  | - PVC Storage: /opt/local-path-storage  |
     +-----------------------------------------+  +-----------------------------------------+
```

---

## 3. Zásadní odchylky, chyby a jejich přesná řešení

Během nasazení na čistém stroji se vyskytlo několik kritických specifik prostředí, která bylo nutné vyřešit:

### 3.1. Práva domovského adresáře `/opt/stack` a selhání mod_wsgi (Apache)
* **Problém:** V Ubuntu 24.04 má příkaz `useradd -m stack` výchozí `umask`, která vytvoří domovský adresář `/opt/stack` s oprávněním `0750` (`drwxr-x---`). Apache běžící pod uživatelem `www-data` nemohl přistupovat k virtuálnímu prostředí `/opt/stack/data/venv`, což způsobovalo chybu `(13)Permission denied: mod_wsgi` a Keystone na portu 5000 vracel HTTP 503 / timeout.
* **Řešení:**
  ```bash
  sudo chmod 755 /opt/stack
  sudo usermod -a -G stack www-data
  sudo systemctl restart apache2
  ```

### 3.2. Calico IPIP enkapsulace a OpenStack Security Group
* **Problém:** Calico používá pro cross-node pod komunikaci IPIP tunely (`ipipMode: Always`), což odpovídá IP protokolu 4 (`ipip`). Výchozí bezpečnostní skupina OpenStacku povolovala pouze TCP, UDP a ICMP. V důsledku toho byly pakety mezi worker pody a control plane (včetně CoreDNS na `10.96.0.10`) zahazovány firewallem Neutronu.
* **Řešení:**
  Povolení veškerého provozu mezi uzly v rámci stejné bezpečnostní skupiny:
  ```bash
  openstack security group rule create --remote-group k8s-sg k8s-sg
  ```

### 3.3. OpenStack Security Group blokace UDP NodePortů
* **Problém:** Rozsah NodePortů `30000:32767` byl v OpenStack bezpečnostní skupině otevřen pouze pro protokol TCP. ACME DNS-01 challenge však vyžaduje standardní UDP dotazy na port `30053`. Dotazy BIND9 na `acme-dns` končily na timeoutu.
* **Řešení:**
  Přidání UDP pravidla pro rozsah NodePortů:
  ```bash
  openstack security group rule create --proto udp --dst-port 30000:32767 --remote-ip 0.0.0.0/0 k8s-sg
  ```

### 3.4. BIND9 Authoritative vs. Recursive Resolution (SERVFAIL)
* **Problém:** DevStack konfiguruje BIND9 jako striktně autoritativní server s direktivou `recursion no;` v `/etc/bind/named.conf.options`. Přestože byla v `/etc/bind/named.conf.local` zóna `auth.acmedns.lab.local` definována jako `type forward;`, BIND9 odmítal forwardovat dotazy a vracel `SERVFAIL` s hlášením `WARNING: recursion requested but not available`.
* **Řešení:**
  Povolení rekurze a dotazů v `/etc/bind/named.conf.options`:
  ```bash
  sudo sed -i 's/recursion no;/recursion yes;\n    allow-recursion { any; };\n    allow-query { any; };/' /etc/bind/named.conf.options
  sudo systemctl restart bind9
  ```

### 3.5. ClusterRoleBinding apiGroup v Local Path Provisioneru
* **Problém:** V manifestu pro Rancher Local Path Provisioner byla v objektu `ClusterRoleBinding` hodnota `roleRef.apiGroup: rbac.authorization.k8s.io/v1`. Kubernetes 1.36 striktně vyžaduje `rbac.authorization.k8s.io` (bez verze `/v1`). Vazba se nevytvořila a provisioner nemohl vytvářet helper pody (`pods is forbidden`).
* **Řešení:**
  Oprava `manifests/local-path-storage.yaml`:
  ```yaml
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: local-path-provisioner-role
  ```
  A rozšíření oprávnění ClusterRole o slovesa `create`, `delete`, `patch`, `update` pro zdroj `pods`.

### 3.6. PersistentVolumeClaim (PVC) pro databázi acme-dns
* **Požadavek:** SQLite databáze a registrace cert-manager účtů musí přežít restart, smazání i přeplánování podu `acme-dns`.
* **Řešení:**
  Vytvořen dedikovaný PVC navázaný na StorageClass `local-path` s politikou `reclaimPolicy: Retain`:
  ```yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: acme-dns-pvc
    namespace: acme-dns
  spec:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 1Gi
  ```
  V Deploymentu je svazek připojen do `/var/lib/acme-dns`. Při smazání podu se nový pod připojí na identický existující svazek a zachová soubor `acme-dns.db` (28 KB).

### 3.7. Expozice CZERTAINLY ACME API na portu 8000
* **Problém:** Kong API Gateway uvnitř K3s na instanci CZERTAINLY byl nasazen jako `ClusterIP`. Port 8000 nebyl na vnější IP adrese instance dostupný. Jednoduchý `iptables REDIRECT` selhával, protože K3s NodePorty nesledují loopback `127.0.0.1`.
* **Řešení:**
  1. Patch služby `api-gateway-service` v K3s na `NodePort 30080`:
     ```bash
     sudo k3s kubectl patch svc -n czertainly api-gateway-service -p '{"spec": {"type": "NodePort", "ports": [{"name": "admin", "port": 8001, "targetPort": 8001}, {"name": "consumer", "port": 8000, "targetPort": 8000, "nodePort": 30080}, {"name": "status", "port": 8100, "targetPort": 8100}]}}'
     ```
  2. Zřízení transparentní systemd služby `czertainly-acme-proxy.service` s nástrojem `socat`:
     ```ini
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
     ```
  3. Otevření portu 8000 v OpenStack Security Group:
     ```bash
     openstack security group rule create --proto tcp --dst-port 8000 --remote-ip 0.0.0.0/0 k8s-sg
     ```

### 3.8. Přesměrování portu 53 na NodePort 30053 přes iptables (žádné nftables)
* **Požadavek:** Dodržet pravidlo: *"nftables jsou nesmysl. Jsou tam iptables :facepalm:"*, přičemž pravidlo nesmí zachytávat interní DNS dotazy samotných Kubernetes podů (`10.244.0.0/16`).
* **Řešení:**
  Na worker uzlu (`172.24.4.163`), kde běží Ingress a acme-dns, je přesměrování standardního DNS portu 53 na NodePort 30053 (pro UDP i TCP) realizováno čistým `iptables` s vyloučením podové sítě:
  ```bash
  sudo iptables -t nat -C PREROUTING ! -s 10.244.0.0/16 -p udp --dport 53 -j REDIRECT --to-port 30053 2>/dev/null || \
      sudo iptables -t nat -A PREROUTING ! -s 10.244.0.0/16 -p udp --dport 53 -j REDIRECT --to-port 30053
  sudo iptables -t nat -C PREROUTING ! -s 10.244.0.0/16 -p tcp --dport 53 -j REDIRECT --to-port 30053 2>/dev/null || \
      sudo iptables -t nat -A PREROUTING ! -s 10.244.0.0/16 -p tcp --dport 53 -j REDIRECT --to-port 30053
  sudo netfilter-persistent save
  ```

### 3.9. Prevence CNAME Cache Poisoning v BIND9 (`NXDOMAIN` na non-TXT dotazy)
* **Problém:** `acme-dns` se dívá do SQLite databáze výhradně při dotazu typu `TXT`. Pokud rekurzivní resolver BIND9 před dotazem na `TXT` pošle dotaz na `A` nebo `CNAME` cílové subdomény `<UUID>.auth.acmedns.lab.local.`, `acme-dns` kontroluje pouze statickou mapu `d.Domains` z `config.cfg` a vrátí `NXDOMAIN`, což otráví negativní cache v BIND9.
* **Řešení:** Skript `08-deploy-acme-dns.sh` po registraci účtu automaticky zapíše registrovanou `<FULLDOMAIN>. NS auth.acmedns.lab.local.` do sekce `records = [...]` v ConfigMapě `acme-dns-config`. Díky tomu `acme-dns` na dotazy typu `A`/`CNAME` vrátí `NOERROR` (`NODATA`) a následný `TXT` dotaz projde do SQLite databáze.

### 3.10. Prevence Hairpin NAT a řešení Self-Checku přes `waitInsteadOfSelfCheck`
* **Problém:** Pokud by cert-manager zevnitř podu volal `acme-dns` REST API nebo prováděl DNS-01 Self-Check přes vnější Floating IP vlastního clusteru, narazil by na Hairpin NAT (paket zevnitř na vnější IP nodu je zahozen).
* **Řešení:**
  1. **Interní REST API komunikace:** V `manifests/czertainly-issuer.yaml` je nastavena interní Kubernetes Service `host: http://acme-dns.acme-dns.svc.cluster.local`.
  2. **Úplné vypnutí Self-Checku (`waitInsteadOfSelfCheck: 10s`):** V definici solveru v `ClusterIssuer` je nastaven parametr `waitInsteadOfSelfCheck: 10s`. cert-manager tím pádem zevnitř podu neprovádí žádné DNS dotazy a nevyžaduje konfiguraci `--dns01-recursive-nameservers`. Po zapsání TXT tokenu do `acme-dns` pouze počká 10 vteřin na usazení záznamu a okamžitě vyzve CZERTAINLY CA k validaci.

---

## 4. Postup nasazení v novém prostředí (Krok za krokem)

Pokud nasazujete tuto infrastrukturu na novém serveru, postupujte přesně podle těchto kroků:

### Krok 0: Příprava hostitelského OS
1. Nainstalujte Ubuntu 24.04 LTS s minimálně 8 vCPU, 32 GB RAM a 100 GB disku.
2. Ověřte podporu hardwarové virtualizace (KVM):
   ```bash
   egrep -c '(vmx|svm)' /proc/cpuinfo
   ```
3. Povolte směrování paketů a načtěte `br_netfilter`:
   ```bash
   sudo modprobe br_netfilter
   echo "br_netfilter" | sudo tee -a /etc/modules
   sudo sysctl -w net.ipv4.ip_forward=1
   sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
   ```
4. Vytvořte uživatele `stack` s heslem a sudo bez hesla:
   ```bash
   sudo useradd -s /bin/bash -d /opt/stack -m stack
   echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack
   sudo chmod 755 /opt/stack
   ```

### Krok 1: Instalace DevStack (2025.1 + Designate)
1. Přihlaste se jako uživatel `stack`:
   ```bash
   sudo su - stack
   git clone https://opendev.org/openstack/devstack.git -b stable/2025.1
   cd devstack
   ```
2. Vytvořte `local.conf` s povoleným Designate a BIND9 backendem (viz `01-devstack-install.sh`).
3. Spusťte instalaci:
   ```bash
   ./stack.sh
   ```
4. Upravte práva `/opt/stack` pro Apache:
   ```bash
   sudo chmod 755 /opt/stack
   sudo usermod -a -G stack www-data
   sudo systemctl restart apache2
   ```

### Krok 2: Příprava OpenStack infrastruktury
1. Stáhněte Ubuntu 24.04 Cloud Image a vytvořte síť, router, security group a flavors:
   ```bash
   cd /opt/stack/lab
   ./02-openstack-infra.sh
   ```
2. Skript automaticky vytvoří síť `k8s-net` (10.10.0.0/24), klíč `k8s-key`, a security group `k8s-sg` se všemi potřebnými TCP/UDP pravidly.

### Krok 3: Spuštění virtuálních strojů
1. Spusťte uzly Kubernetes:
   ```bash
   ./03-k8s-vms.sh
   ```
2. Spusťte instanci CZERTAINLY CA:
   ```bash
   ./03b-czertainly-vm.sh
   ```
3. Vyčkejte ~3 minuty na dokončení `cloud-init` na všech virtuálních strojích.

### Krok 4: Inicializace Kubernetes Control Plane
1. Spusťte inicializaci clusteru na `k8s-control-1`:
   ```bash
   ./04-k8s-cluster-init.sh
   ```
2. Skript:
   - Nastaví `mode: "iptables"` v `kube-proxy`.
   - Nainstaluje Calico CNI v3.28.2.
   - Deaktivuje leader election v `kube-scheduler.yaml` (prevence deadlocku na K8s 1.36).
   - Nasadí Rancher Local Path Storage provisioner s opravným RBAC a politikou `Retain`.
   - Vygeneruje soubor `/tmp/kubeadm-join.sh`.

### Krok 5: Připojení worker uzlů
1. Na obou workerech spusťte join skript:
   ```bash
   cat /opt/stack/lab/kubeadm-join.sh | ssh ubuntu@<WORKER_IP> 'sudo bash'
   ```
2. Ověřte, že všechny uzly jsou ve stavu `Ready`:
   ```bash
   kubectl get nodes -o wide
   ```

### Krok 6: Nasazení Istio IngressGateway
1. Nainstalujte Istio v1.22.0:
   ```bash
   ./06-deploy-istio.sh
   ```
2. Skript stáhne `istioctl`, nainstaluje profil `default`, označí jmenný prostor `default` pro sidecar injection (`istio-injection=enabled`) a přepne `istio-ingressgateway` na NodePort (HTTPS `32574`, HTTP `30392`).

### Krok 7: Integrace CZERTAINLY CA (Authority Provider v2)
1. Spusťte integrační skript:
   ```bash
   ./07-deploy-czertainly.sh
   ```
2. Skript:
   - Zaregistruje ACME profil `lab-profile` a RA profil v PostgreSQL (`ilmdb`).
   - Nasadí Python microservice `ca_provider.py` (`czertainly-local-ca.service`) na portu 8888.
   - Nakonfiguruje K3s Service a Endpoints `local-ca-service` na IP `10.42.0.1:8888`.
   - Zaregistruje konektor `Local-CA-Connector` s verzí `'V2'` a instanci autority `lab-ca`.
   - Zpřístupní ACME API přes `socat` na portu 8000 (`NodePort 30080`).

### Krok 8: Nasazení acme-dns a konfigurace DNS delegace
1. Spusťte skript:
   ```bash
   ./08-deploy-acme-dns.sh
   ```
2. Skript:
   - Aplikuje manifesty s trvalým úložištěm PVC `acme-dns-pvc` (1Gi, `local-path`).
   - Nastaví v BIND9 rekurzi (`recursion yes;`) a forwarder pro `auth.acmedns.lab.local` na NodePort `30053`.
   - Zaregistruje nový účet v `acme-dns` a uloží jej do `acme-dns-registration.json`.
   - Vytvoří CNAME záznam `_acme-challenge.app.lab.local.` -> `<subdomain>.auth.acmedns.lab.local.`.
   - Uloží přihlašovací údaje do Kubernetes Secretu `acme-dns` v namespace `cert-manager`.

### Krok 9: Nasazení cert-manager a ClusterIssueru
1. Spusťte skript:
   ```bash
   ./09-deploy-cert-manager.sh
   ```
2. Skript:
   - Nainstaluje cert-manager v1.21.2 přes Helm s využitím parametru `waitInsteadOfSelfCheck: 10s` v ClusterIssueru (bez nutnosti rekurzivního nameserveru).
   - Aplikuje ClusterIssuer `czertainly-acme` s nativním `acmeDNS` solverem.
   - Požádá o testovací certifikát pro `app.lab.local`.

### Krok 10: Nasazení testovací aplikace a ověření
1. Spusťte skript:
   ```bash
   ./10-deploy-test-app.sh
   ```
2. Skript:
   - Nasadí aplikaci `my-app` (`http-echo`).
   - Vytvoří Istio `Gateway` a `VirtualService` navázané na tajný klíč `app-tls-credential`.
   - Vytvoří DNS A záznam `app.lab.local` směřující na Floating IP worker uzlu.

---

## 5. Kontrolní seznam (Pre-flight / Health-check příkazy)

Před i po nasazení použijte následující příkazy pro ověření správné konfigurace všech komponent:

### 5.1. Kontrola DNS zón a rekurze v Designate / BIND9
```bash
# 1. Kontrola stavu zón v Designate
openstack zone list

# 2. Ověření záznamu CNAME pro DNS challenge
openstack recordset list lab.local.

# 3. Kontrola BIND9 rekurze (musí vrátit 'ra' flag a CNAME + TXT bez SERVFAIL)
dig @192.168.191.41 _acme-challenge.app.lab.local TXT

# 4. Přímý dotaz na acme-dns NodePort na workeru
dig @172.24.4.163 -p 30053 <subdomain>.auth.acmedns.lab.local TXT
```

### 5.2. Kontrola CZERTAINLY ACME a Authority Provider endpointu
```bash
# 1. Dostupnost ACME Directory endpointu (musí vrátit HTTP 200 a JSON s endpointy)
curl -s http://czertainly.lab.local:8000/api/v1/protocols/acme/lab-profile/directory | jq .

# 2. Kontrola běhu authority mikroservisu na CZERTAINLY VM
ssh -i /opt/stack/.ssh/k8s-key.pem ubuntu@172.24.4.139 "sudo systemctl status czertainly-local-ca"

# 3. Test zdraví authority provideru uvnitř CZERTAINLY
ssh -i /opt/stack/.ssh/k8s-key.pem ubuntu@172.24.4.139 "curl -s http://127.0.0.1:8888/v1/health"

# 4. Kontrola stavu konektoru v PostgreSQL
ssh -i /opt/stack/.ssh/k8s-key.pem ubuntu@172.24.4.139 \
  "sudo k3s kubectl exec -n czertainly deploy/czertainly-postgresql -- psql -U ilmuser -d ilmdb -c 'SELECT uuid, name, status, version FROM core.connector;'"
```

### 5.3. Kontrola Kubernetes clusteru a PersistentVolumeClaim
```bash
# 1. Stav všech uzlů (všechny musí být Ready)
kubectl get nodes -o wide

# 2. Stav úložiště acme-dns (musí být Bound na StorageClass local-path)
kubectl get pvc,pv -n acme-dns

# 3. Ověření souboru databáze uvnitř běžícího podu
kubectl exec -n acme-dns deploy/acme-dns -- ls -la /var/lib/acme-dns
```

### 5.4. Kontrola vydání certifikátu a cert-manageru
```bash
# 1. Stav ClusterIssueru (musí být Ready: True)
kubectl get clusterissuer czertainly-acme -o wide

# 2. Stav certifikátu (musí být Ready: True)
kubectl get certificate -n istio-system

# 3. Inspekce vydaného certifikátu v Secretu
kubectl get secret app-tls-credential -n istio-system -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -E '(Issuer|Subject|Not After)'
```

### 5.5. Test funkčnosti aplikace a TLS terminace
```bash
# 1. Test HTTPS s ověřením certifikátu proti lokální CA (NodePort 30646 na Worker 1 172.24.4.180)
curl -k -v --resolve app.lab.local:30646:172.24.4.180 https://app.lab.local:30646/

# 2. Test HTTP -> HTTPS přesměrování (musí vrátit HTTP 301 Moved Permanently na NodePortu 30531)
curl -s -i --resolve app.lab.local:30531:172.24.4.180 http://app.lab.local:30531/
```

---

## 6. Autonomní testování a znovunasazení celého prostředí (`clean-and-run.sh`)

Pro ověření, že je celá infrastruktura reprodukovatelná z čistého stolu bez jakéhokoliv manuálního zásahu, slouží orchestrátor `clean-and-run.sh`:

```bash
cd /opt/stack/lab
./clean-and-run.sh
```

Tento skript:
1. Smaže všechny běžící virtuální servery v OpenStacku a počká na uvolnění všech prostředků.
2. Odstraní floating IP adresy a vyčistí zóny v Designate.
3. Smaže veškeré dočasné soubory, tokeny a staré stavové soubory.
4. Ověří integritu sítě `br-ex` a odchozího NAT (iptables `MASQUERADE`).
5. Spustí orchestraci `run-all-automated.sh` (Kroky 1 až 10).
6. Automaticky ověří uzly, perzistenci acme-dns PVC, cert-manager bez rekurzivních DNS resolverů, stav vystaveného certifikátu (`Ready: True`) a provede živé HTTPS volání testovací aplikace přes HTTP/2.
