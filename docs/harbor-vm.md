# Harbor Registry — VM Dédiée Ubuntu 24.04

> Harbor 2.11 + MinIO (S3) + Trivy + Cosign sur VM VMware
> Version 2.0 — Mars 2026

---

## Architecture

```
                    Z3ROX Lab CA (ca.crt)
                    ┌─────────────────┐
                    │  ca.key         │  ← secret, reste sur harbor-vm
                    │  ca.crt         │  ← distribué à tout le monde
                    └────────┬────────┘
                             │ signe
                    ┌────────▼────────┐
                    │ harbor.okd.lab  │
                    │  .crt + .key    │
                    └────────┬────────┘
                             │ utilisé par
┌────────────────────────────▼────────────────────────────────┐
│                  Windows Host (GEEKOM A6)                    │
│                                                             │
│         VMnet8 NAT — 192.168.241.0/24                       │
│                                                             │
│  ┌──────────────────────┐   ┌──────────────────────────┐   │
│  │  OKD SNO             │   │  Harbor VM               │   │
│  │  192.168.241.10      │   │  192.168.241.20          │   │
│  │  FCOS / 8vCPU / 24G  │   │  Ubuntu 24.04            │   │
│  │                      │   │  4 vCPU / 8G / 100G      │   │
│  │  ┌────────────────┐  │   │                          │   │
│  │  │ Kyverno        │  │   │  ┌────────────────────┐  │   │
│  │  │ verify-cosign  │◄─┼───┼──┤ Harbor :443        │  │   │
│  │  │ policy         │  │   │  │  ├── core           │  │   │
│  │  └────────────────┘  │   │  │  ├── portal         │  │   │
│  │                      │   │  │  ├── registry       │  │   │
│  │  OKD Image Config    │   │  │  ├── jobservice     │  │   │
│  │  additionalTrustedCA │   │  │  ├── db (postgres)  │  │   │
│  │  → harbor-ca CM      │   │  │  ├── redis          │  │   │
│  └──────────────────────┘   │  │  └── trivy-adapter  │  │   │
│                             │  └─────────┬──────────┘  │   │
│  WSL2 / Docker Desktop      │            │             │   │
│  /etc/docker/certs.d/       │  ┌─────────▼──────────┐  │   │
│  harbor.okd.lab/ca.crt      │  │ MinIO :9000 (S3)   │  │   │
│                             │  │ Console :9001       │  │   │
│  Windows Browser            │  │ Bucket: harbor-reg  │  │   │
│  CA importée → Trust Root   │  └────────────────────┘  │   │
└─────────────────────────────┴──────────────────────────┘   │
```

### Flux d'une image signée

```
Dev / GitLab CI
  │
  ├─ docker push harbor.okd.lab/project/image:tag
  │       └─► Harbor reçoit → stocke dans MinIO → Trivy scanne auto
  │
  ├─ cosign sign --key cosign.key harbor.okd.lab/project/image:tag
  │       └─► signature OCI attachée à l'image dans Harbor
  │           colonne "Signed" = ✅
  │
  └─ OKD deploy image
          └─► Kyverno policy vérifie cosign.pub avant deploy ✅
```

---

## Table des matières

1. [VM VMware — Specs](#1-vm-vmware--specs)
2. [Ubuntu 24.04 — Post-install](#2-ubuntu-2404--post-install)
3. [LVM — Étendre le disque](#3-lvm--étendre-le-disque)
4. [Docker + Docker Compose](#4-docker--docker-compose)
5. [MinIO — Backend S3](#5-minio--backend-s3)
6. [Certificats TLS](#6-certificats-tls)
7. [Harbor — Installation](#7-harbor--installation)
8. [Harbor — Configuration harbor.yml](#8-harbor--configuration-harboryml)
9. [Harbor — Démarrage et validation](#9-harbor--démarrage-et-validation)
10. [Trivy — Scan CVE automatique](#10-trivy--scan-cve-automatique)
11. [Cosign — Signature d'images](#11-cosign--signature-dimages)
12. [Intégration OKD SNO](#12-intégration-okd-sno)
13. [Distribution de la CA](#13-distribution-de-la-ca)

---

## 1. VM VMware — Specs

| Paramètre | Valeur |
|-----------|--------|
| Guest OS | Ubuntu 64-bit |
| VM Name | `harbor-vm` |
| Location | `D:\okd-lab\vm\harbor-vm\` |
| vCPU | 4 |
| RAM | 8 192 MB |
| Disk | 100 Go thin — NVMe |
| Réseau | VMnet8 NAT |
| Adaptateur | e1000 (ens33) |
| Firmware | UEFI |
| MAC | `00:50:56:34:a0:cb` |
| IP | `192.168.241.20` (statique via Netplan) |

> ⚠️ **RAM : pourquoi 8 Go ?**
> Harbor (core + registry + db + redis + jobservice) ≈ 2.5 Go
> Trivy adapter ≈ 400 Mo | MinIO ≈ 1 Go | OS Ubuntu ≈ 500 Mo
> **Total ≈ 4.5 Go** — 8 Go donne de la marge pour les scans Trivy intensifs

### Réservation DHCP VMware

`C:\ProgramData\VMware\vmnetdhcp.conf` :

```
host harbor-vm {
    hardware ethernet 00:50:56:34:a0:cb;
    fixed-address 192.168.241.20;
}
```

```powershell
# Redémarrer le service DHCP VMware
Restart-Service VMnetDHCP
```

---

## 2. Ubuntu 24.04 — Post-install

![Harbor VM Post-Install](screenshots/harbor-vm-post-install.png)

```
OS      : Ubuntu 24.04.4 LTS (Noble Numbat)
Kernel  : 6.8.0-101-generic x86_64
IP      : 192.168.241.20/24 sur ens33
RAM     : 7.7 Gi total, 7.2 Gi disponible
Swap    : 4 Gi
```

### Configuration de base

```bash
# Mise à jour système
sudo apt update && sudo apt upgrade -y

# Hostname
sudo hostnamectl set-hostname harbor-vm
echo "192.168.241.20 harbor-vm harbor.okd.lab" | sudo tee -a /etc/hosts
```

### IP statique via Netplan (si DHCP ne suffit pas)

```bash
sudo tee /etc/netplan/00-harbor.yaml << 'EOF'
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses:
        - 192.168.241.20/24
      routes:
        - to: default
          via: 192.168.241.2
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

sudo netplan apply
```

---

## 3. LVM — Étendre le disque

Ubuntu 24.04 LVM alloue ~50% du disque par défaut. Étendre à 100% :

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h /
# → 96G disponibles ✅
```

---

## 4. Docker + Docker Compose

![Docker Install](screenshots/harbor-vm-docker-install.png)

```bash
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker harbor
newgrp docker
```

**Versions installées :**
- Docker Engine : `29.3.0`
- Docker Compose : `v5.1.0`

---

## 5. MinIO — Backend S3

![MinIO Up](screenshots/harbor-vm-minio-up.png)

Harbor stocke les blobs d'images dans MinIO (compatible S3). MinIO doit être démarré **avant** Harbor.

```bash
sudo mkdir -p /data/minio
sudo chown -R harbor:harbor /data/minio
mkdir -p ~/minio

cat > ~/minio/docker-compose.yml << 'EOF'
services:
  minio:
    image: quay.io/minio/minio:latest
    container_name: minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin123!
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - /data/minio:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 30s
      timeout: 20s
      retries: 3
EOF

cd ~/minio && docker compose up -d
```

### Créer le bucket Harbor

![MinIO Bucket](screenshots/harbor-vm-minio-bucket.png)

```bash
curl -O https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc && sudo mv mc /usr/local/bin/

mc alias set local http://localhost:9000 minioadmin minioadmin123!
mc mb local/harbor-registry
mc ls local
# → [date]   0B harbor-registry/ ✅
```

> 💡 Console MinIO : `http://192.168.241.20:9001` — `minioadmin` / `minioadmin123!`

---

## 6. Certificats TLS

Harbor expose son registry en **HTTPS obligatoire**. On génère une CA privée Z3ROX Lab
et on la distribue à tous les clients (OKD, Docker, WSL2, Windows).

### Pourquoi une CA privée ?

On ne peut pas utiliser Let's Encrypt sur un réseau local → CA privée auto-signée
distribuée à tous les clients qui doivent faire confiance à Harbor.

### Fichiers générés

| Fichier | Rôle | À distribuer ? |
|---------|------|----------------|
| `ca.key` | Clé privée CA | ❌ Jamais — reste sur harbor-vm |
| `ca.crt` | Certificat CA | ✅ À tous les clients |
| `harbor.okd.lab.key` | Clé privée Harbor | ❌ Reste sur harbor-vm |
| `harbor.okd.lab.crt` | Certificat Harbor signé | Utilisé par Harbor |

### Génération

![Certificats Générés](screenshots/harbor-vm-certs-generated.png)

```bash
mkdir -p ~/harbor/certs && cd ~/harbor/certs

# CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
  -subj "/C=FR/ST=IDF/L=Paris/O=Z3ROX-Lab/CN=Z3ROX Lab CA" \
  -key ca.key -out ca.crt

# Clé Harbor
openssl genrsa -out harbor.okd.lab.key 4096

# CSR
openssl req -sha512 -new \
  -subj "/C=FR/ST=IDF/L=Paris/O=Z3ROX-Lab/CN=harbor.okd.lab" \
  -key harbor.okd.lab.key \
  -out harbor.okd.lab.csr

# SAN (Subject Alternative Names)
cat > v3.ext << 'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = harbor.okd.lab
DNS.2 = harbor-vm
IP.1 = 192.168.241.20
EOF

# Signer
openssl x509 -req -sha512 -days 3650 \
  -extfile v3.ext \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -in harbor.okd.lab.csr \
  -out harbor.okd.lab.crt

# Vérification
openssl x509 -in harbor.okd.lab.crt -text -noout | grep -E "Subject:|DNS:|IP:"
# Subject: CN=harbor.okd.lab, O=Z3ROX-Lab, L=Paris, ST=IDF, C=FR
# DNS: harbor.okd.lab, DNS: harbor-vm, IP: 192.168.241.20 ✅
```

### Copier le cert pour Docker sur harbor-vm

```bash
sudo mkdir -p /etc/docker/certs.d/harbor.okd.lab
sudo cp ~/harbor/certs/harbor.okd.lab.crt \
        /etc/docker/certs.d/harbor.okd.lab/ca.crt
```

---

## 7. Harbor — Installation

![Harbor Download](screenshots/harbor-vm-harbor-download.png)

```bash
HARBOR_VERSION=v2.11.0
cd ~
wget https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz
tar xzvf harbor-offline-installer-${HARBOR_VERSION}.tgz
```

**Harbor 2.11.0** — 629 Mo ✅

---

## 8. Harbor — Configuration harbor.yml

```bash
cd ~/harbor
cp harbor.yml.tmpl harbor.yml
```

Sections modifiées :

```yaml
hostname: harbor.okd.lab

https:
  port: 443
  certificate: /home/harbor/harbor/certs/harbor.okd.lab.crt
  private_key: /home/harbor/harbor/certs/harbor.okd.lab.key

harbor_admin_password: Harbor12345!

data_volume: /data/harbor

storage_service:
  s3:
    accesskey: minioadmin
    secretkey: minioadmin123!
    region: us-east-1
    regionendpoint: http://192.168.241.20:9000
    bucket: harbor-registry
    secure: false
    v4auth: true
    chunksize: 5242880
    rootdirectory: /
  redirect:
    disable: true

trivy:
  ignore_unfixed: false
  skip_update: false
  offline_scan: false
  security_check: vuln
  insecure: false
```

```bash
sudo mkdir -p /data/harbor
sudo chown -R harbor:harbor /data/harbor
```

---

## 9. Harbor — Démarrage et validation

```bash
cd ~/harbor
sudo ./prepare --with-trivy
sudo ./install.sh --with-trivy
```

![Harbor Up](screenshots/harbor-vm-harbor-up.png)

```
[+] up 11/11
✔ Container harbor-log        Started
✔ Container registry          Started
✔ Container redis             Started
✔ Container harbor-db         Started
✔ Container registryctl       Started
✔ Container harbor-portal     Started
✔ Container trivy-adapter     Started
✔ Container harbor-core       Started
✔ Container nginx             Started
✔ Container harbor-jobservice Started
✔ ----Harbor has been installed and started successfully.----
```

### Health check

![Harbor Health](screenshots/harbor-vm-harbor-health.png)

```bash
curl -k https://harbor.okd.lab/api/v2.0/health
# → {"status":"healthy"} — tous composants healthy ✅

docker compose -f ~/harbor/docker-compose.yml ps
# → 11/11 containers Up (healthy) ✅
```

### Console Web

![Console Login](screenshots/harbor-vm-console-login.png)

```
URL   : https://harbor.okd.lab
User  : admin
Pass  : Harbor12345!
```

![Console Dashboard](screenshots/harbor-vm-console-dashboard.png)

### Push image test

**Prérequis Docker Desktop Windows :**

```
Docker Desktop → Settings → Docker Engine
→ Ajouter : "insecure-registries": ["harbor.okd.lab"]
→ Apply & Restart
```

> ⚠️ Known limitation lab : Docker Desktop ignore `/etc/docker/certs.d/` WSL2.
> `insecure-registries` est le workaround. En production : certificat signé par une CA reconnue.

```powershell
Add-Content "C:\Windows\System32\drivers\etc\hosts" "192.168.241.20 harbor.okd.lab"
docker login harbor.okd.lab -u admin -p Harbor12345!
docker pull alpine:3.19
docker tag alpine:3.19 harbor.okd.lab/library/alpine:3.19
docker push harbor.okd.lab/library/alpine:3.19
```

![Library Alpine](screenshots/harbor-vm-library-alpine.png)

---

## 10. Trivy — Scan CVE automatique

### Configuration

```
Administration → Interrogation Services
→ Vulnerability → Enable auto-scan on push ✅
→ Schedule : Hourly
```

### Résultats

![Trivy Not Scanned](screenshots/harbor-vm-trivy-not-scanned.png)

Au push, l'image apparaît d'abord **Not Scanned**. Le scan se déclenche automatiquement.

![Trivy Results](screenshots/harbor-vm-trivy-results.png)

Résultats sur `alpine:3.19` : **6 CVEs** (3x Medium busybox, 3x Low), tous fixables.
Reporté par `Trivy v0.51.2`.

### Scan manuel depuis WSL2

```bash
# Ajouter la CA Harbor à Docker WSL2
sudo mkdir -p /etc/docker/certs.d/harbor.okd.lab
scp harbor@192.168.241.20:~/harbor/certs/ca.crt \
    /tmp/harbor-ca.crt
sudo cp /tmp/harbor-ca.crt /etc/docker/certs.d/harbor.okd.lab/ca.crt

docker login harbor.okd.lab -u admin -p Harbor12345!
docker push harbor.okd.lab/okd-platform/alpine:3.19
# → Trivy lance automatiquement un scan CVE
```

---

## 11. Cosign — Signature d'images

### Concept

```
Harbor (serveur)          Cosign CLI (client)
├── Affiche "Signed" ✅   └── Signe les images → installer sur
├── Stocke signatures OCI    harbor-vm et WSL2 (lab)
└── Vérifie au pull          ou image Docker dans GitLab CI
```

### Installation

![Cosign Install](screenshots/harbor-vm-cosign-install.png)

```bash
# Sur harbor-vm ET WSL2
COSIGN_VERSION=v2.2.4
curl -L https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64 \
  -o /tmp/cosign
chmod +x /tmp/cosign
sudo mv /tmp/cosign /usr/local/bin/cosign
cosign version
# → v2.2.4 ✅
```

### Générer la paire de clés

```bash
cd ~/harbor
cosign generate-key-pair
# → cosign.key  (privée — protégée par mot de passe COSIGN_PASSWORD)
# → cosign.pub  (publique — distribuer à Kyverno OKD)
```

### Signer une image

```bash
docker login harbor.okd.lab -u admin -p Harbor12345!

cosign sign --key ~/harbor/cosign.key \
  --allow-insecure-registry \
  harbor.okd.lab/library/alpine:3.19
```

![Cosign Sign](screenshots/harbor-vm-cosign-sign.png)

```
tlog entry created with index: 1091751131
Pushing signature to: harbor.okd.lab/library/alpine ✅
```

### Vérifier la signature

```bash
cosign verify --key ~/harbor/cosign.pub \
  --allow-insecure-registry \
  harbor.okd.lab/library/alpine:3.19 | jq .
```

### Résultat dans Harbor

![Harbor Signed + Trivy](screenshots/harbor-vm-signed-trivy.png)

```
Signed         : ✅ (cercle vert)
Vulnerabilities: M — 6 Total, 6 Fixable
```

### Intégration GitLab CI (Phase 4)

```yaml
sign-image:
  stage: sign
  image:
    name: gcr.io/projectsigstore/cosign:v2.2.4
    entrypoint: [""]
  script:
    - cosign sign --key $COSIGN_PRIVATE_KEY
        harbor.okd.lab/myproject/myapp:$CI_COMMIT_SHA
  variables:
    COSIGN_PASSWORD: $COSIGN_PASSWORD
```

Secrets GitLab CI/CD Variables :
- `COSIGN_PRIVATE_KEY` → contenu de `cosign.key` (masked, protected)
- `COSIGN_PASSWORD` → mot de passe clé privée (masked, protected)

---

## 12. Intégration OKD SNO

### Faire confiance au certificat Harbor dans OKD

```bash
export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

# Copier la CA depuis la VM Harbor
scp harbor@192.168.241.20:~/harbor/certs/ca.crt /tmp/harbor-ca.crt

# Créer un ConfigMap avec la CA Harbor dans openshift-config
oc create configmap harbor-ca \
  --from-file=harbor.okd.lab=/tmp/harbor-ca.crt \
  -n openshift-config

# Ajouter la CA au cluster image registry config
oc patch image.config.openshift.io/cluster \
  --type=merge \
  --patch='{"spec":{"additionalTrustedCA":{"name":"harbor-ca"}}}'
```

### Ajouter le pull secret Harbor dans OKD

```bash
oc create secret docker-registry harbor-pull-secret \
  --docker-server=harbor.okd.lab \
  --docker-username=admin \
  --docker-password=Harbor12345! \
  -n openshift-config

oc patch secret/pull-secret \
  -n openshift-config \
  --type=merge \
  -p '{"data":{".dockerconfigjson":"'$(
    kubectl get secret harbor-pull-secret \
      -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}'
  )'"}}'
```

### Kyverno — Vérification signature Cosign (Phase 4)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        resources:
          kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.okd.lab/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ... contenu de cosign.pub ...
                      -----END PUBLIC KEY-----
```

---

## 13. Distribution de la CA

### harbor-vm → Docker local

```bash
sudo mkdir -p /etc/docker/certs.d/harbor.okd.lab
sudo cp ~/harbor/certs/harbor.okd.lab.crt \
        /etc/docker/certs.d/harbor.okd.lab/ca.crt
```

### Windows — Store certificats

```powershell
scp harbor@192.168.241.20:~/harbor/certs/ca.crt "$env:TEMP\harbor-ca.crt"
Import-Certificate -FilePath "$env:TEMP\harbor-ca.crt" `
  -CertStoreLocation Cert:\LocalMachine\Root
# → CN=Z3ROX Lab CA, O=Z3ROX-Lab ✅
```

### WSL2

```bash
sudo mkdir -p /etc/docker/certs.d/harbor.okd.lab
scp harbor@192.168.241.20:~/harbor/certs/ca.crt \
    /tmp/harbor-ca.crt
sudo cp /tmp/harbor-ca.crt /etc/docker/certs.d/harbor.okd.lab/ca.crt
```

---

## Récapitulatif des fichiers

```
VM Harbor (192.168.241.20) :
├── ~/harbor/
│   ├── harbor.yml              # Configuration Harbor
│   ├── certs/
│   │   ├── ca.crt              # CA auto-signée (copier dans OKD, WSL2, Windows)
│   │   ├── harbor.okd.lab.crt  # Certificat Harbor
│   │   └── harbor.okd.lab.key  # Clé privée Harbor
│   ├── cosign.key              # ⚠️ NE PAS committer
│   ├── cosign.pub              # ✅ committer dans le repo
│   └── docker-compose.yml      # Généré par ./prepare
├── ~/minio/
│   └── docker-compose.yml      # MinIO standalone
└── /data/
    ├── harbor/                 # Données Harbor (DB, logs, config)
    └── minio/                  # Blobs images (backend S3)

WSL2 :
├── /etc/docker/certs.d/harbor.okd.lab/ca.crt
└── /usr/local/bin/cosign

Repo Git :
└── security/cosign/
    ├── cosign.pub                          # ✅ committer
    └── kyverno-verify-cosign-policy.yaml   # Phase 4
```

---

## Validation complète

```bash
# 1. Harbor API health
curl -k https://harbor.okd.lab/api/v2.0/health
# → {"status":"healthy"} ✅

# 2. MinIO health
curl http://192.168.241.20:9000/minio/health/live
# → 200 OK ✅

# 3. Push image test
docker login harbor.okd.lab -u admin -p Harbor12345!
docker tag alpine:3.19 harbor.okd.lab/library/alpine:3.19
docker push harbor.okd.lab/library/alpine:3.19
# → Digest confirmé ✅

# 4. Scan Trivy automatique
# Console Harbor → library → alpine:3.19 → Vulnerabilities ✅

# 5. Signature Cosign
cosign sign --key ~/harbor/cosign.key \
  harbor.okd.lab/library/alpine:3.19
cosign verify --key ~/harbor/cosign.pub \
  harbor.okd.lab/library/alpine:3.19
# → Verified OK ✅

# 6. MinIO contient les blobs
mc ls local/harbor-registry
# → blobs Harbor visibles ✅
```

---

## Problèmes connus

| Problème | Cause | Solution |
|----------|-------|----------|
| `x509: certificate signed by unknown authority` (Docker Desktop) | Docker Desktop ignore `/etc/docker/certs.d/` WSL2 | Ajouter `insecure-registries` dans Docker Engine settings |
| `Could not resolve host: harbor.okd.lab` | `/etc/hosts` manquant | `echo "192.168.241.20 harbor.okd.lab" >> /etc/hosts` |
| Harbor storage error au démarrage | Bucket MinIO non créé avant | `mc mb local/harbor-registry` avant `./install.sh` |
| `UNAUTHORIZED` Cosign sign | Pas de `docker login` avant | `docker login harbor.okd.lab` puis resigneer |
| Trivy ne scan pas | `skip_update: false` + pas d'Internet | Passer `offline_scan: true` ou autoriser `trivy.github.io` |
| MinIO `Access Denied` sur les blobs | Mauvaises credentials dans harbor.yml | Vérifier `accesskey`/`secretkey` dans la section `s3` |
| WSL2 ne ping plus VMnet8 après crash VMware | Routes réseau perdues | Redémarrer Windows complètement |

---

## Screenshots — Index

| Fichier | Contenu |
|---------|---------|
| `harbor-vm-post-install.png` | SSH post-install — IP + OS + RAM + disk |
| `harbor-vm-docker-install.png` | Docker 29.3.0 + Compose v5.1.0 |
| `harbor-vm-minio-up.png` | MinIO container up — ports 9000/9001 |
| `harbor-vm-minio-bucket.png` | Bucket `harbor-registry` créé |
| `harbor-vm-certs-generated.png` | Certificats TLS générés + vérification SAN |
| `harbor-vm-harbor-download.png` | Harbor 2.11.0 téléchargé — 629 Mo |
| `harbor-vm-harbor-up.png` | Harbor 11/11 containers started successfully |
| `harbor-vm-harbor-health.png` | API health + docker compose ps — tous healthy |
| `harbor-vm-console-login.png` | Page login Harbor console |
| `harbor-vm-console-dashboard.png` | Dashboard — projet library, quota 3.26 MiB |
| `harbor-vm-trivy-not-scanned.png` | alpine:3.19 avant scan — Not Scanned |
| `harbor-vm-trivy-results.png` | Trivy — 6 CVEs alpine:3.19 (Medium+Low) |
| `harbor-vm-cosign-install.png` | Cosign v2.2.4 installé |
| `harbor-vm-cosign-sign.png` | Cosign sign — tlog + pushing signature |
| `harbor-vm-signed-trivy.png` | Harbor — Signed ✅ + 6 CVEs Trivy |
| `harbor-vm-library-alpine.png` | Repository library/alpine — 1 artifact |

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*Harbor VM — Version 2.0 — Mars 2026*
