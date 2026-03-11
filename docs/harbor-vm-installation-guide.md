# Guide d'Installation — Harbor Registry sur VM Dédiée Ubuntu 24.04

> Guide pas-à-pas — VM Harbor avec Trivy + MinIO (S3) + Cosign
> Version 1.1 — Mars 2026
>
> ℹ️ **Keycloak / OIDC** : Harbor sera configuré en mode OIDC pour déléguer l'authentification à **Keycloak installé sur OKD SNO** (Phase 2b). Aucun Keycloak sur cette VM — un seul Keycloak centralisé sert OKD, Harbor, ArgoCD et Vault.

---

## Table des matières

1. [Architecture](#1-architecture)
2. [Prérequis VM VMware](#2-prérequis-vm-vmware)
3. [Réservation IP DHCP VMware](#3-réservation-ip-dhcp-vmware)
4. [Configuration Ubuntu 24.04](#4-configuration-ubuntu-2404)
5. [Installation Docker + Docker Compose](#5-installation-docker--docker-compose)
6. [Installation MinIO](#6-installation-minio)
7. [Génération des certificats TLS](#7-génération-des-certificats-tls)
8. [Installation Harbor](#8-installation-harbor)
9. [Configuration Harbor — harbor.yml](#9-configuration-harbor--harboryml)
10. [Démarrage et validation Harbor](#10-démarrage-et-validation-harbor)
11. [Configuration Trivy](#11-configuration-trivy)
12. [Installation Cosign](#12-installation-cosign)
13. [Intégration OKD SNO](#13-intégration-okd-sno)
14. [Validation complète](#14-validation-complète)

---

## 1. Architecture

```
┌─────────────────────────────────────────────────────────────┐
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
│  │  │ verify-cosign  │◄─┼───┼──┤ Harbor             │  │   │
│  │  │ policy         │  │   │  │  :443 (HTTPS)      │  │   │
│  │  └────────────────┘  │   │  │  ├── core           │  │   │
│  │                      │   │  │  ├── portal         │  │   │
│  │  ┌────────────────┐  │   │  │  ├── registry       │  │   │
│  │  │ OKD Registry   │◄─┼───┼──┤  ├── jobservice     │  │   │
│  │  │ (ICSP → Harbor)│  │   │  │  ├── db (postgres)  │  │   │
│  │  └────────────────┘  │   │  │  ├── redis          │  │   │
│  └──────────────────────┘   │  │  └── trivy-adapter  │  │   │
│                             │  └─────────┬──────────┘  │   │
│                             │            │             │   │
│                             │  ┌─────────▼──────────┐  │   │
│                             │  │ MinIO              │  │   │
│                             │  │  :9000 (S3 API)    │  │   │
│                             │  │  :9001 (Console)   │  │   │
│                             │  │  backend Harbor    │  │   │
│                             │  └────────────────────┘  │   │
│                             └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Flux d'une image

```
Developer (WSL2)
  │
  ├─ docker push harbor.okd.lab/project/image:tag
  │         │
  │         ▼
  │   Harbor registry ← stockage dans MinIO (S3)
  │         │
  │         ├─ Trivy : scan CVE automatique au push
  │         └─ Cosign : vérification signature à la pull
  │
  └─ cosign sign harbor.okd.lab/project/image@sha256:...
            │
            ▼
      OKD SNO : Kyverno policy vérifie la signature avant deploy
```

---

## 2. Prérequis VM VMware

### Specs recommandées

| Paramètre | Valeur | Note |
|-----------|--------|------|
| Guest OS | Ubuntu 64-bit | Ubuntu 24.04 LTS |
| vCPU | 4 | Harbor + MinIO + Trivy |
| RAM | **8 Go** | 4 Go minimum — 8 Go recommandé avec MinIO |
| Disk | 100 Go thin | Images Harbor + MinIO data |
| Réseau | VMnet8 NAT | Même subnet que OKD SNO |
| Firmware | UEFI | Ubuntu 24.04 standard |
| Network Adapter | vmxnet3 | Interface `ens160` dans Ubuntu |

> ⚠️ **RAM : pourquoi 8 Go et non 4 Go ?**
> Harbor (core + registry + db + redis + jobservice) ≈ 2.5 Go
> Trivy adapter ≈ 400 Mo
> MinIO ≈ 1 Go
> OS Ubuntu ≈ 500 Mo
> **Total ≈ 4.5 Go** — 8 Go donne de la marge pour les scans Trivy intensifs

### Récupérer la MAC address

```
VM Settings → Network Adapter → Advanced → MAC Address
→ Copier la valeur (ex: 00:50:56:XX:XX:XX)
```

---

## 3. Réservation IP DHCP VMware

Même approche que pour OKD SNO — IP statique via réservation DHCP VMware.

Depuis PowerShell Windows (administrateur) :

```powershell
notepad "C:\ProgramData\VMware\vmnetdhcp.conf"
```

Ajouter **avant le dernier `# End`** (adapter la MAC à ta VM) :

```
host harbor-vm {
    hardware ethernet 00:50:56:XX:XX:XX;
    fixed-address 192.168.241.20;
}
```

Le fichier doit maintenant contenir les deux réservations :

```
host okd-sno-master {
    hardware ethernet 00:50:56:27:c8:0b;
    fixed-address 192.168.241.10;
}
host harbor-vm {
    hardware ethernet 00:50:56:XX:XX:XX;
    fixed-address 192.168.241.20;
}
# End
```

Redémarrer le service DHCP :

```powershell
Restart-Service VMnetDHCP
```

---

## 4. Configuration Ubuntu 24.04

### Installation Ubuntu

Lors de l'installation Ubuntu 24.04 :
- **Profil** : username `harbor`, hostname `harbor-vm`
- **Storage** : LVM recommandé, tout le disque
- **OpenSSH** : ✅ cocher "Install OpenSSH server"
- **Snaps** : aucun à ce stade

### Post-install — Configuration de base

```bash
# Mise à jour système
sudo apt update && sudo apt upgrade -y

# Vérifier l'IP (doit être 192.168.241.20)
ip addr show ens160
```

### IP statique via Netplan (si DHCP ne suffit pas)

Si la réservation DHCP VMware ne fonctionne pas immédiatement :

```bash
sudo tee /etc/netplan/00-harbor.yaml << 'EOF'
network:
  version: 2
  ethernets:
    ens160:
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

### Hostname

```bash
sudo hostnamectl set-hostname harbor-vm
echo "192.168.241.20 harbor-vm harbor.okd.lab" | sudo tee -a /etc/hosts
```

### Accès SSH depuis WSL2

```bash
# Depuis WSL2
ssh harbor@192.168.241.20
```

Ou avec clé SSH :

```bash
ssh-copy-id -i ~/.ssh/okd-sno.pub harbor@192.168.241.20
```

---

## 5. Installation Docker + Docker Compose

```bash
# Dépendances
sudo apt install -y ca-certificates curl gnupg

# Clé GPG Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Repo Docker
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Installation
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Ajouter user au groupe docker
sudo usermod -aG docker harbor
newgrp docker

# Vérification
docker version
docker compose version
```

---

## 6. Installation MinIO

MinIO sera déployé en standalone Docker Compose, **avant Harbor**, car Harbor l'utilisera comme backend S3 au démarrage.

### Répertoires de données

```bash
sudo mkdir -p /data/minio
sudo chown -R harbor:harbor /data/minio
mkdir -p ~/minio
```

### docker-compose.yml MinIO

```bash
cat > ~/minio/docker-compose.yml << 'EOF'
version: '3.8'

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
      - "9000:9000"   # S3 API
      - "9001:9001"   # Console Web
    volumes:
      - /data/minio:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 30s
      timeout: 20s
      retries: 3
EOF
```

### Démarrage MinIO

```bash
cd ~/minio
docker compose up -d

# Vérification
docker compose ps
# NAME    STATUS    PORTS
# minio   running   0.0.0.0:9000->9000/tcp, 0.0.0.0:9001->9001/tcp
```

### Créer le bucket Harbor dans MinIO

```bash
# Installer le client mc (MinIO Client)
curl -O https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Configurer mc
mc alias set local http://localhost:9000 minioadmin minioadmin123!

# Créer le bucket pour Harbor
mc mb local/harbor-registry

# Vérifier
mc ls local
# [date]  harbor-registry  ← ✅
```

> 💡 **Console MinIO** accessible depuis Windows : `http://192.168.241.20:9001`
> Login : `minioadmin` / `minioadmin123!`

---

## 7. Génération des certificats TLS

Harbor **nécessite HTTPS**. On génère un certificat auto-signé avec une CA locale pour que OKD SNO puisse faire confiance au registry.

### Créer la CA et le certificat Harbor

```bash
mkdir -p ~/harbor/certs
cd ~/harbor/certs

# 1. Générer la clé et le certificat CA
openssl genrsa -out ca.key 4096

openssl req -x509 -new -nodes -sha512 -days 3650 \
  -subj "/C=FR/ST=IDF/L=Paris/O=Z3ROX-Lab/CN=Z3ROX Lab CA" \
  -key ca.key \
  -out ca.crt

# 2. Générer la clé Harbor
openssl genrsa -out harbor.okd.lab.key 4096

# 3. Générer la CSR Harbor
openssl req -sha512 -new \
  -subj "/C=FR/ST=IDF/L=Paris/O=Z3ROX-Lab/CN=harbor.okd.lab" \
  -key harbor.okd.lab.key \
  -out harbor.okd.lab.csr

# 4. Créer le fichier d'extensions SAN
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

# 5. Signer le certificat
openssl x509 -req -sha512 -days 3650 \
  -extfile v3.ext \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -in harbor.okd.lab.csr \
  -out harbor.okd.lab.crt

# Vérification
openssl x509 -in harbor.okd.lab.crt -text -noout | grep -E "Subject:|DNS:|IP:"
```

### Copier le certificat pour Docker

```bash
# Docker doit faire confiance au registry Harbor
sudo mkdir -p /etc/docker/certs.d/harbor.okd.lab
sudo cp ~/harbor/certs/harbor.okd.lab.crt /etc/docker/certs.d/harbor.okd.lab/ca.crt
```

---

## 8. Installation Harbor

### Téléchargement Harbor Offline Installer

```bash
# Harbor 2.11 (dernière version stable)
HARBOR_VERSION=v2.11.0
cd ~/

wget https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz

# Vérifier le checksum
wget https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz.asc

# Extraire
tar xzvf harbor-offline-installer-${HARBOR_VERSION}.tgz
ls harbor/
# common.sh  harbor.v2.11.0.tar.gz  harbor.yml.tmpl  install.sh  LICENSE  prepare
```

---

## 9. Configuration Harbor — harbor.yml

```bash
cd ~/harbor
cp harbor.yml.tmpl harbor.yml
```

Éditer `harbor.yml` :

```bash
nano harbor.yml
```

### Sections à modifier

```yaml
# 1. HOSTNAME
hostname: harbor.okd.lab

# 2. HTTPS — décommenter et configurer
https:
  port: 443
  certificate: /home/harbor/harbor/certs/harbor.okd.lab.crt
  private_key: /home/harbor/harbor/certs/harbor.okd.lab.key

# 3. MOT DE PASSE ADMIN
harbor_admin_password: Harbor12345!    # ← changer en prod

# 4. BASE DE DONNÉES
database:
  password: harbor_db_password
  max_idle_conns: 50
  max_open_conns: 1000

# 5. STORAGE — MinIO S3 backend
# Remplacer la section storage_service existante :
storage_service:
  s3:
    accesskey: minioadmin
    secretkey: minioadmin123!
    region: us-east-1
    regionendpoint: http://192.168.241.20:9000
    bucket: harbor-registry
    secure: false
    skipverify: false
    v4auth: true
    chunksize: 5242880
    rootdirectory: /

# 6. TRIVY — activer le scanner
trivy:
  ignore_unfixed: false
  skip_update: false
  offline_scan: false
  security_check: vuln
  insecure: false

# 7. DATA VOLUME — répertoire de données Harbor (hors images — dans MinIO)
data_volume: /data/harbor
```

### Créer le répertoire de données Harbor

```bash
sudo mkdir -p /data/harbor
sudo chown -R harbor:harbor /data/harbor
```

---

## 10. Démarrage et validation Harbor

### Pré-run (génère les configs)

```bash
cd ~/harbor
sudo ./prepare --with-trivy
```

Output attendu :

```
prepare base dir is set to /home/harbor/harbor
Generated configuration file: /config/portal/nginx.conf
Generated configuration file: /config/log/logrotate.conf
Generated configuration file: /config/nginx/nginx.conf
Generated configuration file: /config/core/app.conf
Generated configuration file: /config/registryctl/config.yml
Generated configuration file: /config/db/env
Generated configuration file: /config/jobservice/config.yml
Generated configuration file: /config/registry/config.yml
Generated configuration file: /config/trivy-adapter/env
Clean up the input dir
```

### Installation et démarrage

```bash
sudo ./install.sh --with-trivy
```

Output attendu :

```
[Step 1]: Loading and starting Harbor images...
[Step 2]: Preparing environment...
[Step 3]: Generating configuration files...
[Step 4]: Starting Harbor...
✔ ----Harbor has been installed and started successfully.----
```

### Vérification des containers

```bash
docker compose -f ~/harbor/docker-compose.yml ps

# SERVICE           STATUS    PORTS
# harbor-core       running
# harbor-db         running
# harbor-jobservice running
# harbor-log        running
# harbor-portal     running
# harbor-redis      running
# harbor-registryctl running
# nginx             running   0.0.0.0:80->8080/tcp, 0.0.0.0:443->8443/tcp
# registry          running
# trivy-adapter     running
```

### Accès console web Harbor

```
URL   : https://harbor.okd.lab  (ou https://192.168.241.20)
User  : admin
Pass  : Harbor12345!
```

> ⚠️ Ajouter dans `/etc/hosts` Windows et WSL2 :
> ```
> 192.168.241.20 harbor.okd.lab
> ```

---

## 11. Configuration Trivy

Trivy est activé automatiquement avec `--with-trivy`. Configurer le scan automatique :

### Via la console Harbor

```
Administration → Interrogation Services
→ Trivy : ✅ activé
→ "Scan on push" : ✅ activer
```

### Créer un projet Harbor avec scan automatique

```
Projects → New Project
→ Name: okd-platform
→ Access level: Private
→ Vulnerability scanning: ✅ Automatically scan images on push
→ OK
```

### Test scan depuis WSL2

```bash
# Ajouter la CA Harbor à Docker WSL2
sudo mkdir -p /etc/docker/certs.d/harbor.okd.lab
scp harbor@192.168.241.20:~/harbor/certs/ca.crt \
    /tmp/harbor-ca.crt
sudo cp /tmp/harbor-ca.crt /etc/docker/certs.d/harbor.okd.lab/ca.crt

# Login Harbor depuis WSL2
docker login harbor.okd.lab -u admin -p Harbor12345!

# Push une image test
docker pull alpine:3.19
docker tag alpine:3.19 harbor.okd.lab/okd-platform/alpine:3.19
docker push harbor.okd.lab/okd-platform/alpine:3.19
# → Trivy lance automatiquement un scan CVE
```

---

## 12. Installation Cosign

Cosign permet de **signer les images** et de vérifier les signatures. On l'installe sur la VM Harbor ET dans WSL2.

### Sur la VM Harbor

```bash
COSIGN_VERSION=v2.2.4
curl -L https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64 \
  -o /tmp/cosign
chmod +x /tmp/cosign
sudo mv /tmp/cosign /usr/local/bin/cosign

cosign version
```

### Dans WSL2 (pour signer depuis le poste dev)

```bash
COSIGN_VERSION=v2.2.4
curl -L https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64 \
  -o /tmp/cosign
chmod +x /tmp/cosign
sudo mv /tmp/cosign /usr/local/bin/cosign
```

### Générer une paire de clés Cosign

```bash
# Dans WSL2 — générer la keypair (stocker dans le repo GitOps)
cd ~/work/Openshift-OKD-SNO-Airgap-workstation/security/cosign/

cosign generate-key-pair
# → cosign.key  (clé privée — NE PAS committer)
# → cosign.pub  (clé publique — committer dans le repo)
```

### Signer une image

```bash
# Signer l'image poussée dans Harbor
cosign sign --key cosign.key \
  harbor.okd.lab/okd-platform/alpine:3.19

# Vérifier la signature
cosign verify --key cosign.pub \
  harbor.okd.lab/okd-platform/alpine:3.19
```

### Notation (alternative CNCF à Cosign)

```bash
NOTATION_VERSION=1.1.0
curl -L https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_amd64.tar.gz \
  | tar xz -C /tmp
sudo mv /tmp/notation /usr/local/bin/

notation version
```

> ℹ️ **Cosign vs Notation** : Harbor 2.11 supporte les deux. Cosign est plus répandu dans l'écosystème Sigstore/OKD. La Phase 4 utilisera Cosign + Kyverno pour l'enforcement.

---

## 13. Intégration OKD SNO

### Faire confiance au certificat Harbor dans OKD

```bash
export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

# Créer un ConfigMap avec la CA Harbor dans openshift-config
oc create configmap harbor-ca \
  --from-file=harbor.okd.lab=/tmp/harbor-ca.crt \
  -n openshift-config

# Ajouter la CA au cluster image registry config
oc patch image.config.openshift.io/cluster \
  --type=merge \
  --patch='{"spec":{"additionalTrustedCA":{"name":"harbor-ca"}}}'
```

### Ajouter le secret de pull Harbor dans OKD

```bash
# Créer le pull secret Harbor
oc create secret docker-registry harbor-pull-secret \
  --docker-server=harbor.okd.lab \
  --docker-username=admin \
  --docker-password=Harbor12345! \
  -n openshift-config

# Lier au global pull secret OKD
oc patch secret/pull-secret \
  -n openshift-config \
  --type=merge \
  -p '{"data":{".dockerconfigjson":"'$(
    kubectl get secret harbor-pull-secret \
      -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}'
  )'"}}'
```

### Ajouter Harbor dans /etc/hosts OKD SNO

```bash
# Ajouter harbor.okd.lab dans /etc/hosts WSL2
echo "192.168.241.20 harbor.okd.lab" | sudo tee -a /etc/hosts

# Ajouter dans /etc/hosts Windows
# C:\Windows\System32\drivers\etc\hosts
# 192.168.241.20 harbor.okd.lab
```

---

## 14. Validation complète

### Checklist

```bash
# 1. Harbor accessible
curl -k https://harbor.okd.lab/api/v2.0/health
# → {"status":"healthy"}

# 2. MinIO accessible
curl http://192.168.241.20:9000/minio/health/live
# → 200 OK

# 3. Trivy actif
curl -k https://harbor.okd.lab/api/v2.0/scanners
# → [{"name":"Trivy",...}]

# 4. Push image depuis WSL2
docker login harbor.okd.lab -u admin -p Harbor12345!
docker tag alpine:3.19 harbor.okd.lab/okd-platform/alpine:3.19
docker push harbor.okd.lab/okd-platform/alpine:3.19
# → Digest confirmé ✅

# 5. Scan Trivy automatique
# Console Harbor → okd-platform → alpine:3.19 → Scan Result
# → Vulnerabilities affichées ✅

# 6. Signature Cosign
cosign sign --key cosign.key harbor.okd.lab/okd-platform/alpine:3.19
cosign verify --key cosign.pub harbor.okd.lab/okd-platform/alpine:3.19
# → Verified OK ✅

# 7. MinIO contient les blobs
mc ls local/harbor-registry
# → blobs Harbor visibles ✅
```

---

## Récapitulatif des fichiers

```
VM Harbor (192.168.241.20) :
├── ~/harbor/
│   ├── harbor.yml              # Configuration Harbor
│   ├── certs/
│   │   ├── ca.crt              # CA auto-signée (copier dans OKD)
│   │   ├── harbor.okd.lab.crt  # Certificat Harbor
│   │   └── harbor.okd.lab.key  # Clé privée Harbor
│   └── docker-compose.yml      # Généré par ./prepare
├── ~/minio/
│   └── docker-compose.yml      # MinIO standalone
└── /data/
    ├── harbor/                 # Données Harbor (DB, logs, config)
    └── minio/                  # Blobs images (backend S3)

WSL2 :
├── /etc/docker/certs.d/harbor.okd.lab/ca.crt
├── /usr/local/bin/cosign
└── ~/work/.../security/cosign/
    ├── cosign.key              # ⚠️ NE PAS committer
    └── cosign.pub              # ✅ committer dans le repo

Repo Git :
└── security/cosign/
    ├── cosign.pub
    └── kyverno-verify-cosign-policy.yaml  # Phase 4
```

---

## Problèmes connus

| Problème | Cause | Solution |
|----------|-------|----------|
| `x509: certificate signed by unknown authority` | CA Harbor non reconnue | Copier `ca.crt` dans `/etc/docker/certs.d/harbor.okd.lab/` |
| `harbor-registry` en erreur au démarrage | Bucket MinIO non créé avant Harbor | Créer le bucket `mc mb local/harbor-registry` avant `./install.sh` |
| Trivy ne scan pas | `skip_update: false` + pas d'Internet | Passer `offline_scan: true` ou autoriser `trivy.github.io` |
| MinIO `Access Denied` sur les blobs | Mauvaises credentials dans harbor.yml | Vérifier `accesskey`/`secretkey` dans la section `s3` |
| `cosign sign` — TLS error | CA Harbor non reconnue par cosign | Utiliser `--insecure-skip-tls-verify` ou ajouter la CA au store système |

---

## Prochaine étape

→ Phase 2a — [Keycloak SSO sur OKD SNO](phase2-identity-sso-secrets.md)
→ Phase 2b — [OIDC Harbor → Keycloak OKD](phase2-identity-sso-secrets.md#harbor-oidc) (configurer Harbor auth mode OIDC après Keycloak up)
→ Phase 3 — [Airgap : ICSP OKD → Harbor](phase3-airgap.md)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*Harbor VM Installation Guide — Version 1.0 — Mars 2026*
