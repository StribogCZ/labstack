# OpenStack ACME Lab: CZERTAINLY CA + Kubernetes 1.36 + cert-manager + acme-dns + Istio

Kompletní referenční příručka a dokumentace nasazení laboratorního prostředí pro automatizovanou správu životního cyklu TLS certifikátů protokolem **ACME** s využitím **CZERTAINLY** jako externí privátní certifikační autority, **Kubernetes v1.36** s **iptables**, **cert-manageru** s **acme-dns** a **Istio Service Mesh** pro TLS terminaci.

---

## 1. Verze všech komponent (Exact Version Matrix)

| Komponenta | Verze / Balíček | Repozitář / Zdroj | Poznámka |
|---|---|---|---|
| **Operační systém (Host & VMs)** | **Ubuntu 24.04.5 LTS (Noble Numbat)** | Oficiální Canonical image | Kernel `6.8.0-147-generic` (amd64) |
| **OpenStack** | **2024.2 Dalmatian (DevStack)** | Git `stable/2024.2` | Neutron OVN, Nova, Glance, Designate |
| **DNS Server** | **BIND 9.18.39-0ubuntu0.24.04.8** | Ubuntu repositář | Integrováno s OpenStack Designate |
| **Kubernetes** | **v1.36.0** (`v1.36.0-1.1`) | `pkgs.k8s.io/core:/stable:/v1.36/deb/` | kubeadm, kubelet, kubectl |
| **Container Runtime** | **containerd 2.2.1** | Ubuntu / Docker | `SystemdCgroup = true` |
| **runc** | **1.3.4-0ubuntu1~24.04.1** | Ubuntu repositář | OCI runtime |
| **Dataplane / Firewall** | **iptables v1.8.10** | Ubuntu repositář | Standardní netfilter/iptables |
| **Kubernetes CNI** | **Project Calico v3.28.2** | `docker.io/calico/node:v3.28.2` | Standardní iptables dataplane |
| **Kubernetes Kube-Proxy** | **v1.36.0** | `registry.k8s.io/kube-proxy:v1.36.0` | `mode: iptables` (výchozí stabilní režim) |
| **Service Mesh / Gateway** | **Istio 1.22.0** | `docker.io/istio/proxyv2:1.22.0` | IngressGateway v režimu `NodePort` |
| **Cert-Manager** | **v1.21.2** | `quay.io/jetstack/cert-manager-controller:v1.21.2` | ACME DNS-01 solver |
| **acme-dns** | **v2.0.2** | `joohoi/acme-dns:v2.0.2` | Engine: `sqlite`, perzistence přes hostPath |
| **CZERTAINLY Core** | **2.20.0** | `hub.omnitrustregistry.com/ilm/core:2.20.0` | Spring Boot 3 / Java 21 platforma |
| **CZERTAINLY Frontend** | **2.20.0** | `hub.omnitrustregistry.com/ilm/frontend-administrator:2.20.0` | Web UI pro správu autorit |
| **CZERTAINLY Databáze** | **PostgreSQL 15-alpine** | `docker.io/library/postgres:15-alpine` | Databáze `ilmdb`, user `ilmuser` |
| **CZERTAINLY Auth** | **1.8.0** / OPA 1.10.0 | `hub.omnitrustregistry.com/ilm/auth:1.8.0` | Autentizace a autorizace |
| **Local CA Connector** | **Python 3.12** / `cryptography 41.0.7` | Lokální microservice | Vystavuje CZERTAINLY Authority Provider v2 |

---

## 2. Architektura sítě a mapování portů

```
+-------------------------------------------------------------------------------------------------------------+
|                                        DevStack Host (192.168.191.40)                                       |
|  - BIND9 / Designate DNS (Port 53)                                                                          |
|  - Zóna: lab.local.                                                                                         |
|    * czertainly.lab.local.          A      172.24.4.197                                                     |
|    * app.lab.local.                 A      172.24.4.153                                                     |
|    * *.app.lab.local.               A      172.24.4.153                                                     |
|    * _acme-challenge.app.lab.local. CNAME  <subdomain>.auth.acmedns.lab.local.                             |
+------------------------------------------------------+------------------------------------------------------+
                                                       |
         +---------------------------------------------+---------------------------------------------+
         | (OpenStack Neutron Router / Floating IP Pool 172.24.4.0/24)                               |
         |                                                                                           |
         v                                                                                           v
+---------------------------------------------+                             +-----------------------------------------------+
|       CZERTAINLY VM (172.24.4.197)          |                             |        Kubernetes Cluster (v1.36.0)           |
|  - K3s s PostgreSQL 15 & ILM Core           |                             |  - Control Plane: 172.24.4.151                |
|  - Port 8000 (NodePort 30080) -> ACME API   |                             |  - Worker 1:      172.24.4.153                |
|  - Port 8443 (NodePort 30443) -> Web UI     |                             |  - Worker 2:      172.24.4.178                |
|  - czertainly-local-ca.service (Port 8888)  |                             |                                               |
|    * Podepisuje X.509 certifikáty z CSR     |                             |  Služby (NodePort):                           |
+---------------------------------------------+                             |  - acme-dns DNS:   NodePort 30053 (UDP/TCP)   |
                                                                            |  - Istio HTTPS:    NodePort 30102 (TCP)       |
                                                                            |  - Istio HTTP:     NodePort 32526 (Redirect)  |
                                                                            +-----------------------------------------------+
```

---

## 3. Detailní popis úprav a vyřešených problémů

### 3.1. Dataplane: Standardní iptables pro firewall a Kubernetes
Pro řízení síťového provozu a překlad adres (NAT) je v prostředí použit standardní Linux **iptables** stack:
1. **Kube-Proxy v režimu iptables:**
   `kube-proxy` běží ve standardním, plně osvědčeném režimu `mode: "iptables"`. Pravidla pro směrování Kubernetes služeb (Service / NodePort / ClusterIP) jsou spravována v iptables řetězcích `KUBE-SERVICES`, `KUBE-NODEPORTS` apod.
2. **Calico CNI:**
   Calico Felix využívá standardní iptables dataplane pro vynucování síťových politik (NetworkPolicies) a směrování podů.
3. **Persistence pravidel:**
   Pravidla firewallu a NAT jsou ukládána a načítána pomocí balíčku `iptables-persistent` / `netfilter-persistent`.

---

### 3.2. Kubernetes 1.36: Oprava pádu kube-scheduler (Leader Election Deadlock)
* **Příznak:** Na Kubernetes v1.36 s jedním řídicím uzlem (single control plane) padal `kube-scheduler` v nekonečné smyčce s chybou:
  `client rate limiter Wait context deadline exceeded`
* **Příčina:** V Kubernetes 1.36 došlo k úpravě časování a interního rate limiteru leaderelection klienta při komunikaci s lokálním API serverem v bootstrap fázi.
* **Řešení:** V manifestu `/etc/kubernetes/manifests/kube-scheduler.yaml` na uzlu `k8s-control-1` byl vypnut parametr leader election:
  ```yaml
  spec:
    containers:
    - command:
      - kube-scheduler
      - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
      - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
      - --bind-address=127.0.0.1
      - --kubeconfig=/etc/kubernetes/scheduler.conf
      - --leader-elect=false   # <--- OPRAVA: vypnutí leader election pro single-node CP
  ```
  Po této úpravě scheduler okamžitě převzal plánování a stav clusteru přešel do plně stabilního `Ready`.

---

### 3.3. acme-dns v2.0.2: SQLite konfigurace a perzistence
* **Rozdíl verzí:** Ve verzi `acme-dns:v2.0.2` již není podporován identifikátor driveru `sqlite3`. Při jeho zadání aplikace končí chybou `unsupported database engine: sqlite3`.
* **Řešení:** V konfiguračním souboru `config.cfg` v ConfigMapě `acme-dns-config` musí být použito:
  ```ini
  [database]
  engine = "sqlite"
  connection = "/var/lib/acme-dns/acme-dns.db"
  ```
* **Perzistence SQLite databáze:** Aby registrace účtu (`subdomain`, `username`, `password`) přežila restart podu, je `acme-dns` nasazen s `hostPath` svazkem:
  ```yaml
  volumeMounts:
    - name: acme-dns-data
      mountPath: /var/lib/acme-dns
  volumes:
    - name: acme-dns-data
      hostPath:
        path: /var/lib/acme-dns
        type: DirectoryOrCreate
  nodeSelector:
    kubernetes.io/hostname: k8s-worker-1
  ```

---

### 3.4. Přesměrování DNS provozu (Port 53 -> NodePort 30053) přes Firewall
Kubernetes nepovoluje běžným službám vázat privilegované porty (< 1024) přímo na NodePorty (výchozí rozsah je 30000–32767). Externí DNS dotazy z BIND9 a CZERTAINLY však přicházejí standardně na port `53/UDP` a `53/TCP`.

* **Implementace:** Na worker uzlu (`172.24.4.153`), kde je acme-dns připnutý, bylo zavedeno NAT přesměrování v tabulce PREROUTING:
  ```bash
  # Přesměrování UDP a TCP portu 53 na NodePort 30053
  sudo iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 30053
  sudo iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 30053
  
  # Uložení pravidel pro perzistenci po restartu (přes netfilter-persistent / iptables-persistent)
  sudo netfilter-persistent save
  ```
  Pravidla jsou uložena v souboru `/etc/iptables/rules.v4` a jsou standardně aplikována kernelem přes **iptables** stack.

---

### 3.5. Kritická oprava acme-dns: CNAME Cache Poisoning v BIND9
Při ověřování DNS-01 výzvy vznikala zákeřná chyba: cert-manager zapsal TXT záznam do `acme-dns`, ale validace okamžitě selhala na `NXDOMAIN`.

* **Analýza chování acme-dns:**
  1. Záznam v BIND9: `_acme-challenge.app.lab.local.` -> CNAME `f5113fcd...auth.acmedns.lab.local.`.
  2. BIND9 rekurzivně ověřuje cíl CNAME a pošle dotaz na `auth.acmedns.lab.local.` s typem dotazu `CNAME` nebo `A`.
  3. **Chyba v kódu acme-dns:** `acme-dns` se dívá do své SQLite databáze **pouze a výhradně tehdy, je-li typ dotazu `TXT`** (`qtype == dns.TypeTXT`). Pro jakýkoliv jiný dotaz kontroluje pouze statické pole `n.Domains`.
  4. Protože dynamicky registrovaná subdoména nebyla ve statickém poli, acme-dns vrátil autoritativní odpověď **`NXDOMAIN`** s 24hodinovým negativním TTL.
  5. BIND9 si tuto negativní odpověď uložil do cache a jakýkoliv následující TXT dotaz okamžitě odmítl s `NXDOMAIN`, aniž by se znovu zeptal `acme-dns`!
* **Řešení:**
  Do ConfigMapy `acme-dns-config` byl do sekce `records` staticky zanesen záznam pro registrovanou subdoménu:
  ```ini
  records = [
      "auth.acmedns.lab.local. A 172.24.4.153",
      "auth.acmedns.lab.local. NS auth.acmedns.lab.local.",
      "f5113fcd-4374-407a-b95b-b9c932c4059e.auth.acmedns.lab.local. NS auth.acmedns.lab.local."
  ]
  ```
  Díky tomuto záznamu funkce `n.answeringForDomain()` v acme-dns vrátí `true`, takže na dotazy typu CNAME vrátí `NOERROR` s prázdným tělem (NODATA). Negativní cache v BIND9 se tak neotráví a následný TXT dotaz projde přímo do SQLite databáze.

---

### 3.6. CZERTAINLY: Vytvoření a integrace Authority Provider konektoru
Při pokusu cert-manageru dokončit objednávku (`finalizeOrder`) vracelo CZERTAINLY jádro chybu:
```text
NullPointerException: Cannot invoke AuthorityInstanceReference.getConnectorUuid() 
because RaProfile.getAuthorityInstanceReference() is null
```
**Příčina:** CZERTAINLY standardně vyžaduje externí konektor pro podepisování certifikátů (např. Vault, EJBCA, MS ADCS). V labu nebyl žádný takový konektor nasazen, takže RA profil `lab-profile` neměl autoritu, která by vygenerovala a podepsala certifikát z CSR.

**Implementované řešení:**
1. **Vývoj lokálního Authority Provider microservice:**
   Na virtuálním stroji CZERTAINLY (`172.24.4.197`) byla nasazena Python služba `/opt/czertainly-local-ca/ca_provider.py` spravovaná systemd (`czertainly-local-ca.service`), běžící na portu `8888`.
   - Vytvoří vlastní kořenovou autoritu `Lab Local Root CA` (`/etc/czertainly-ca/ca.key` a `ca.crt`).
   - Implementuje standardní REST API protokolu CZERTAINLY konektorů:
     - `GET /v1`: výčet funkcí (`functionGroupCode: authorityProvider`, kind: `Local-CA`).
     - `GET /v1/health`: stav konektoru.
     - `GET /v1/authorityProvider/{kind}/attributes`: definice atributů (vrací `[]`).
     - `POST /v1/authorityProvider/{kind}/attributes/validate`: validace atributů (vrací `true`).
     - `GET /v2/authorityProvider/authorities/{uuid}/certificates/issue/attributes`: atributy pro vydání certifikátu (vrací `[]`).
     - `POST /v2/authorityProvider/authorities/{uuid}/certificates/issue/attributes/validate`: validace (vrací `true`).
     - `POST /v2/authorityProvider/authorities/{uuid}/certificates/issue`: přijme CSR z ACME protokolu, podepíše jej klíčem Root CA a vrátí podepsaný X.509 certifikát v base64 DER kódování.
2. **K3s Service Endpoint:**
   Aby jádro CZERTAINLY (běžící v podu K3s) dosáhlo na službu na hostiteli, byla vytvořena K8s služba:
   ```yaml
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
         - ip: 10.42.0.1  # Gateway hostitele v K3s cni0
       ports:
         - port: 8888
   ```
3. **Záznamy v PostgreSQL databázi CZERTAINLY (`ilmdb`):**
   Propojení autority a profilu v databázi:
   ```sql
   -- 1. Registrace konektoru (Pozor: version musí být striktně 'V2' s velkým V!)
   INSERT INTO core.connector (uuid, name, status, url, auth_type, version, i_cre, i_upd)
   VALUES ('99999999-0000-0000-0000-000000000001', 'Local-CA-Connector', 'CONNECTED', 'http://local-ca-service:8888', 'NONE', 'V2', now(), now());

   -- 2. Přiřazení funkční skupiny AUTHORITY_PROVIDER
   INSERT INTO core.connector_2_function_group (id, kinds, connector_uuid, function_group_uuid)
   VALUES (3, '["Local-CA"]', '99999999-0000-0000-0000-000000000001', '736b0fd6-5ea0-4e10-abe7-cfed39cc2a1a');

   -- 3. Registrace rozhraní AUTHORITY (verze 'v2')
   INSERT INTO core.connector_interface (uuid, connector_uuid, interface, version, features)
   VALUES ('99999999-0000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000001', 'AUTHORITY', 'v2', '{}');

   -- 4. Vytvoření instance autority 'lab-ca'
   INSERT INTO core.authority_instance_reference (uuid, name, kind, status, authority_instance_uuid, connector_name, connector_uuid, connector_interface_uuid, i_cre, i_upd)
   VALUES ('99999999-0000-0000-0000-000000000003', 'lab-ca', 'Local-CA', 'CONNECTED', 'local-ca-1', 'Local-CA-Connector', '99999999-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', now(), now());

   -- 5. Propojení autority s RA profilem lab-profile
   UPDATE core.ra_profile
   SET authority_instance_ref_uuid = '99999999-0000-0000-0000-000000000003',
       authority_instance_name = 'lab-ca'
   WHERE name = 'lab-profile';
   ```
4. **Jackson Deserialization formáty:**
   - Endpointy končící na `/validate` **musí vracet skalární hodnotu `true`**, nikoliv prázdné pole `[]`, jinak Jackson vyhodí `Cannot deserialize value of type java.lang.Boolean from Array value`.
   - V odpovědi na vydání certifikátu musí pole `"certificateType"` obsahovat hodnotu **`"X.509"`** (s tečkou), nikoliv `"X509"`, jinak jádro selže s `Unsupported certificate type X509`.

---

## 4. Postup zprovoznění v novém prostředí (Krok za krokem)

Pokud budete nasazovat tuto infrastrukturu v jiném clusteru / prostředí, postupujte v tomto pořadí:

### Krok 1: Inicializace Kubernetes s iptables
1. Nainstalujte balíčky Kubernetes v1.36 a nástroje pro správu iptables:
   ```bash
   sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl iptables iptables-persistent
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
   ```
2. Inicializujte cluster (výchozí režim kube-proxy je iptables) a vypněte leader election v `/etc/kubernetes/manifests/kube-scheduler.yaml`:
   ```bash
   sudo kubeadm init --pod-network-cidr=192.168.0.0/16
   sudo sed -i 's/- --leader-elect=true/- --leader-elect=false/' /etc/kubernetes/manifests/kube-scheduler.yaml
   ```
3. Aplikujte Calico v3.28.2 (standardní iptables mód):
   ```bash
   kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml
   kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml
   ```

### Krok 2: Instalace Istio IngressGateway
Nainstalujte Istio s profilem `minimal` nebo `default` a přepněte `istio-ingressgateway` na NodePort:
```bash
istioctl install --set profile=default -y
kubectl patch svc istio-ingressgateway -n istio-system --type='merge' -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      {"name": "status-port", "port": 15021, "targetPort": 15021, "nodePort": 32305},
      {"name": "http2", "port": 80, "targetPort": 8080, "nodePort": 32526},
      {"name": "https", "port": 443, "targetPort": 8443, "nodePort": 30102}
    ]
  }
}'
```

### Krok 3: Nasazení acme-dns v2.0.2
1. Připravte perzistentní adresář na worker uzlu:
   ```bash
   sudo mkdir -p /var/lib/acme-dns
   ```
2. Přidejte NAT redirect portu 53 na NodePort 30053:
   ```bash
   sudo iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 30053
   sudo iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 30053
   ```
3. Zaregistrujte účet v acme-dns přes REST API (`POST http://<ACME_DNS_HOST>/register`):
   Uložte získaný JSON do Kubernetes Secretu `acme-dns` v namespace `cert-manager`.
4. Přidejte vygenerovanou subdoménu do statických záznamů v `config.cfg` acme-dns (prevence NXDOMAIN).
5. Vytvořte CNAME v BIND9 / Designate:
   `_acme-challenge.app.lab.local.` -> `<subdomain>.auth.acmedns.lab.local.`

### Krok 4: Nasazení CZERTAINLY CA a Local CA konektoru
1. Nainstalujte K3s a Helm na CA stroj / VM.
2. Nainstalujte PostgreSQL a CZERTAINLY chart `ilm`.
3. Vytvořte službu `czertainly-local-ca.service` s Python skriptem na portu `8888`.
4. Spusťte SQL skript pro registraci konektoru a jeho propojení s `lab-profile`.

### Krok 5: Nastavení cert-manageru a vydání certifikátu
1. Nainstalujte cert-manager:
   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
   ```
2. Aplikujte ClusterIssuer napojený na CZERTAINLY ACME a acme-dns solver:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: czertainly-acme
   spec:
     acme:
       server: http://czertainly.lab.local:8000/api/v1/protocols/acme/lab-profile/directory
       email: admin@lab.local
       privateKeySecretRef:
         name: czertainly-acme-account-key
       solvers:
         - dns01:
             cnameStrategy: Follow
             acmeDNS:
               host: http://acme-dns.acme-dns.svc.cluster.local:80
               accountSecretRef:
                 name: acme-dns
                 key: acmedns.json
   ```
3. Požádejte o certifikát pro `app.lab.local`:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: app-tls-certificate
     namespace: istio-system
   spec:
     secretName: app-tls-credential
     duration: 2160h
     renewBefore: 360h
     issuerRef:
       name: czertainly-acme
       kind: ClusterIssuer
     dnsNames:
       - app.lab.local
   ```

---

## 5. Příkazy pro ověření a testování funkčnosti

### Kontrola stavu uzlů a firewallu
```bash
# Kontrola K8s uzlů (musí být Ready a v1.36.0)
kubectl get nodes -o wide

# Kontrola režimu kube-proxy (iptables)
kubectl get cm kube-proxy -n kube-system -o yaml | grep mode

# Kontrola iptables pravidel (NAT a PREROUTING pro port 53)
sudo iptables -t nat -L PREROUTING -n -v
sudo iptables -L KUBE-NODEPORTS -n -v
```

### Kontrola certifikátu a cert-manageru
```bash
# Stav certifikátu (musí hlásit READY: True)
kubectl get certificate -n istio-system

# Kontrola přítomnosti TLS klíče a certifikátu v Secretu
kubectl describe secret app-tls-credential -n istio-system

# Zobrazení detailů a vystavitele certifikátu
kubectl get secret app-tls-credential -n istio-system -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -E "Issuer:|Subject:|DNS:"
```

### Testování aplikace přes Istio IngressGateway
```bash
# HTTPS volání s ověřením certifikátu proti Root CA autority
curl -v --cacert /tmp/ca.crt --resolve app.lab.local:30102:172.24.4.153 https://app.lab.local:30102

# Očekávaná odpověď:
# HTTP/2 200
# server: istio-envoy
# Hello from app.lab.local with ACME cert from CZERTAINLY!

# Test HTTP redirectu na HTTPS
curl -I --resolve app.lab.local:32526:172.24.4.153 http://app.lab.local:32526/

# Očekávaná odpověď:
# HTTP/1.1 301 Moved Permanently
# location: https://app.lab.local:32526/
```
