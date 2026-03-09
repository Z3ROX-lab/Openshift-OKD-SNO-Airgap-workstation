# Guide d'Installation — OKD SNO sur VMware Workstation

> Guide pas-à-pas avec captures d'écran — Phase 1 Bootstrap

---

## Table des matières

1. [Prérequis](#1-prérequis)
2. [Configuration VMware Workstation — VMnet8](#2-configuration-vmware-workstation--vmnet8)
3. [Configuration WSL2 — MTU Fix](#3-configuration-wsl2--mtu-fix)
4. [Téléchargement des binaires OKD](#4-téléchargement-des-binaires-okd)
5. [Génération de la clé SSH](#5-génération-de-la-clé-ssh)
6. [Configuration DNS — dnsmasq](#6-configuration-dns--dnsmasq)
7. [Configuration HAProxy](#7-configuration-haproxy)
8. [Préparation des fichiers d'installation](#8-préparation-des-fichiers-dinstallation)
9. [Création de la VM VMware](#9-création-de-la-vm-vmware)
10. [Génération de l'ISO Agent-based](#10-génération-de-liso-agent-based)
11. [Boot et installation](#11-boot-et-installation)
12. [Validation du cluster](#12-validation-du-cluster)

---

## 1. Prérequis

### Hôte Windows (GEEKOM A6)
- VMware Workstation Pro 17+
- Ubuntu WSL2
- RAM disponible : 32 Go (24 Go alloués à la VM SNO)
- Espace disque D: : 528 Go disponibles

### Informations réseau

| Paramètre | Valeur |
|-----------|--------|
| Subnet VMnet8 | `192.168.241.0/24` |
| Gateway VMnet8 | `192.168.241.2` |
| IP nœud SNO | `192.168.241.10` |
| DNS | `192.168.241.2` |

---

## 2. Configuration VMware Workstation — VMnet8

VMnet8 est le réseau NAT de VMware Workstation. La VM OKD SNO sera connectée à ce réseau, qui est également accessible depuis WSL2.

### Vérification du subnet VMnet8

**VMware Workstation → Edit → Virtual Network Editor → VMnet8**

![VMnet8 Configuration](screenshots/vmnet8-config.png)

*VMnet8 configuré en mode NAT avec le subnet `192.168.241.0/24`*

### Points importants

- **Type** : NAT — la VM partage l'IP de l'hôte Windows pour accéder à Internet
- **Subnet** : `192.168.241.0/24` — toutes nos IPs statiques seront dans ce range
- **DHCP** : activé par VMware mais **on ne l'utilisera pas** — IP statique obligatoire pour OKD
- **Gateway** : `192.168.241.2` — adresse standard VMware NAT (toujours `.2`)

### Vérifier que WSL2 est sur le même subnet

```bash
# Dans WSL2
ip route show
# Doit montrer une route vers 192.168.241.0/24 via l'interface VMnet8
```

---

## 3. Configuration WSL2 — MTU Fix

### Le problème

WSL2 utilise un MTU de 1360 par défaut. Ce MTU trop élevé provoque des erreurs TLS sur les gros téléchargements :

```
error:0A000119:SSL routines::decryption failed or bad record mac
```

### La solution

```bash
# Vérifier le MTU actuel
ip link show eth0
# eth0: mtu 1360

# Réduire le MTU
sudo ip link set eth0 mtu 1280

# Vérifier
ip link show eth0 | grep mtu
```

### Rendre permanent au démarrage WSL

```bash
sudo tee /etc/profile.d/fix-mtu.sh << 'EOF'
#!/bin/bash
sudo ip link set eth0 mtu 1280 2>/dev/null
EOF
sudo chmod +x /etc/profile.d/fix-mtu.sh
```

> **Pourquoi 1280 ?** C'est la valeur MTU minimale définie par IPv6 (RFC 2460) — garantie de fonctionner sur tous les réseaux sans fragmentation problématique.

---

## 4. Téléchargement des binaires OKD

### Pourquoi ces deux binaires ?

| Binaire | Rôle | Utilisé quand |
|---------|------|---------------|
| `openshift-install` | Génère l'ISO + surveille l'installation | Pendant le bootstrap |
| `oc` | CLI pour piloter le cluster | Après installation |

### Méthode — PowerShell Windows (recommandé)

Le téléchargement via PowerShell contourne les problèmes TLS de WSL2 car il utilise directement le stack réseau Windows.

```powershell
# Dans PowerShell Windows (pas WSL)
$OKD_VERSION = "4.17.0-okd-scos.0"
$BASE = "https://github.com/okd-project/okd/releases/download/$OKD_VERSION"

Invoke-WebRequest "$BASE/openshift-client-linux-$OKD_VERSION.tar.gz" `
  -OutFile "D:\okd-lab\install\openshift-client-linux-$OKD_VERSION.tar.gz"

Invoke-WebRequest "$BASE/openshift-install-linux-$OKD_VERSION.tar.gz" `
  -OutFile "D:\okd-lab\install\openshift-install-linux-$OKD_VERSION.tar.gz"
```

### Extraction et installation depuis WSL2

```bash
cd /mnt/d/okd-lab/install
OKD_VERSION=4.17.0-okd-scos.0

tar xvf openshift-client-linux-${OKD_VERSION}.tar.gz
tar xvf openshift-install-linux-${OKD_VERSION}.tar.gz
sudo mv oc kubectl openshift-install /usr/local/bin/

# Vérification
openshift-install version
# openshift-install 4.17.0-okd-scos.0

oc version
# Client Version: 4.17.0-okd-scos.0
```

---

## 5. Génération de la clé SSH

### Pourquoi une clé SSH ?

SCOS (CentOS Stream CoreOS) est un OS **immuable** — il n'y a pas de mot de passe root, pas d'accès console avec password. La seule façon d'accéder au nœud est via SSH avec une clé publique, injectée au boot via Ignition.

```bash
# Générer la clé ed25519 dédiée OKD
ssh-keygen -t ed25519 -C "okd-sno-lab" -f ~/.ssh/okd-sno -N ""

# Afficher la clé publique
cat ~/.ssh/okd-sno.pub
# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfYWQYhU/AfkK5U+URfW5Huvg4BeZUKlnKZSlYW7VqW okd-sno-lab
```

> La clé publique (`~/.ssh/okd-sno.pub`) sera copiée dans `install-config.yaml`. La clé privée (`~/.ssh/okd-sno`) reste sur ta machine et ne se partage jamais.

---

## 6. Configuration DNS — dnsmasq

### Pourquoi dnsmasq ?

OKD génère des URLs basées sur `baseDomain` et `metadata.name` définis dans `install-config.yaml`. Ces URLs doivent être résolvables depuis l'hôte et depuis la VM.

| URL | Résolution attendue |
|-----|-------------------|
| `api.sno.okd.lab` | `192.168.241.10` |
| `api-int.sno.okd.lab` | `192.168.241.10` |
| `*.apps.sno.okd.lab` | `192.168.241.10` |
| `console-openshift-console.apps.sno.okd.lab` | `192.168.241.10` |

### Installation et configuration

```bash
# Installer dnsmasq
sudo apt update && sudo apt install -y dnsmasq

# Créer la config OKD
sudo tee /etc/dnsmasq.d/okd-sno.conf << 'EOF'
# OKD SNO — résolution DNS locale
address=/api.sno.okd.lab/192.168.241.10
address=/api-int.sno.okd.lab/192.168.241.10
address=/.apps.sno.okd.lab/192.168.241.10
address=/mirror.sno.okd.lab/192.168.241.10
EOF

# Démarrer dnsmasq
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

# Tester
dig api.sno.okd.lab @127.0.0.1
# Doit retourner 192.168.241.10
```

### Configurer WSL2 pour utiliser dnsmasq

```bash
# Désactiver la génération automatique de resolv.conf
sudo tee /etc/wsl.conf << 'EOF'
[network]
generateResolvConf = false
EOF

# Pointer sur dnsmasq local
sudo tee /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF
```

---

## 7. Configuration HAProxy

### Rôle de HAProxy

HAProxy tourne sur WSL2 et sert de **point d'entrée** pour tout le trafic vers le cluster OKD :

```
Browser / oc CLI (hôte Windows)
          │
          ▼
    HAProxy (WSL2)
    :6443  ──► sno-master:6443   (API OpenShift)
    :22623 ──► sno-master:22623  (Machine Config Server)
    :80    ──► sno-master:80     (Ingress HTTP)
    :443   ──► sno-master:443    (Ingress HTTPS)
          │
          ▼
    192.168.241.10 (VM SNO — VMnet8)
          │
          ▼
    OpenShift Ingress Controller
    ├── console.apps.sno.okd.lab
    ├── argocd.apps.sno.okd.lab
    └── vault.apps.sno.okd.lab
```

### Installation et configuration

```bash
sudo apt install -y haproxy
sudo cp haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg   # validation
sudo systemctl enable haproxy
sudo systemctl start haproxy
```

### Stats HAProxy

Accessible sur `http://localhost:9000/stats` (login: `admin` / `okdlab`)

---

## 8. Préparation des fichiers d'installation

### Structure des répertoires

```bash
mkdir -p /mnt/d/okd-lab/{install,mirror}
```

### install-config.yaml

```yaml
apiVersion: v1
baseDomain: okd.lab
metadata:
  name: sno
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 1
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 192.168.241.0/24        # VMnet8 subnet
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
  none: {}
pullSecret: '{"auths":{"fake":{"auth":"aGVsbG86d29ybGQ="}}}'
sshKey: |
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfYWQYhU/AfkK5U+URfW5Huvg4BeZUKlnKZSlYW7VqW okd-sno-lab
```

### agent-config.yaml

> ⚠️ La `macAddress` sera mise à jour après la création de la VM (étape 9)

```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: sno
rendezvousIP: 192.168.241.10
hosts:
  - hostname: sno-master
    role: master
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:xx:xx:xx"   # ← à remplacer
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.241.10
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.241.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.241.2
            next-hop-interface: ens33
```

---

## 9. Création de la VM VMware Workstation

### Specs

| Paramètre | Valeur | Raison |
|-----------|--------|--------|
| Guest OS | RHEL 9 64-bit | SCOS = CentOS Stream 9 |
| vCPU | 8 | Minimum OKD SNO |
| RAM | 24 576 MB | Confort + etcd |
| Disk | 120 Go thin | Sur D:\ |
| Réseau | VMnet8 NAT | Même subnet que WSL2 |
| Firmware | UEFI | SCOS ne supporte pas BIOS legacy |
| Secure Boot | ❌ Désactivé | Kernel OKD non signé |

### Étapes de création

1. **New Virtual Machine → Custom**
2. Guest OS : **Red Hat Enterprise Linux 9 (64-bit)**
3. Name : `okd-sno-master`
4. Location : `D:\okd-lab\vm\`
5. Processors : **8 vCPU**
6. Memory : **24 576 MB**
7. Network : **VMnet8 (NAT)**
8. Disk : **120 Go, thin provisioned**
9. **Edit VM Settings → Options → Advanced**
   - Firmware : **UEFI**
   - Disable Secure Boot

### Paramètre critique : disk.EnableUUID

```
VM Settings → Options → Advanced → Configuration Parameters
→ Add Row : disk.EnableUUID = TRUE
```

Sans ce paramètre, les CSI drivers de stockage ne fonctionnent pas correctement.

### Récupérer la MAC address

```
VM Settings → Network Adapter → Advanced → MAC Address
```

Copier la valeur (format `00:0C:29:xx:xx:xx`) et mettre à jour `agent-config.yaml` :

```bash
# Dans WSL2
sed -i 's/00:0C:29:xx:xx:xx/00:0C:29:TA:MA:C/' \
  /mnt/d/okd-lab/install/agent-config.yaml
```

---

## 10. Génération de l'ISO Agent-based

### Pourquoi Agent-based Installer ?

L'Agent-based Installer embarque tout dans une ISO bootable — aucune infrastructure externe requise (pas de bootstrap VM, pas de serveur HTTP, pas d'API vCenter). Compatible airgap.

```
openshift-install lit install-config.yaml + agent-config.yaml
          │
          ▼
Génère les manifests Kubernetes
          │
          ▼
Génère les ignition configs (bootstrap.ign, master.ign)
          │
          ▼
Assemble agent.x86_64.iso (~1 Go)
contenant : kernel SCOS + agent + ignition configs
```

> ⚠️ `openshift-install` **consomme et supprime** `install-config.yaml` et `agent-config.yaml` après génération. Toujours travailler depuis une copie.

### Commandes

```bash
# Créer le répertoire de travail (copie des configs)
mkdir -p ~/okd-sno-install
cp /mnt/d/okd-lab/install/install-config.yaml ~/okd-sno-install/
cp /mnt/d/okd-lab/install/agent-config.yaml ~/okd-sno-install/

# Générer l'ISO
openshift-install agent create image --dir ~/okd-sno-install/

# Vérifier
ls -lh ~/okd-sno-install/
# agent.x86_64.iso   (~1 Go)
# auth/              (kubeconfig + kubeadmin-password — générés après install)
```

### Monter l'ISO dans VMware

```
VM Settings → CD/DVD → Use ISO image file
→ Sélectionner ~/okd-sno-install/agent.x86_64.iso
  (accessible depuis Windows via \\wsl$\Ubuntu\home\zerotrust\okd-sno-install\)
```

---

## 11. Boot et installation

### Démarrer la VM

1. Power On la VM dans VMware Workstation
2. La VM boote sur l'ISO automatiquement
3. L'agent démarre, configure le réseau, commence le bootstrap

### Surveiller depuis WSL2

```bash
# Phase 1 — Bootstrap (API server opérationnel)
openshift-install agent wait-for bootstrap-complete \
  --dir ~/okd-sno-install/ \
  --log-level=info

# Phase 2 — Installation complète (tous les operators)
openshift-install agent wait-for install-complete \
  --dir ~/okd-sno-install/ \
  --log-level=info
```

### Timeline attendue

| Temps | Étape |
|-------|-------|
| 0-5 min | Boot SCOS, détection hardware |
| 5-15 min | Configuration réseau, pull images |
| 15-30 min | Démarrage etcd, API server, MCS |
| 30-45 min | Bootstrap Cluster Operators |
| 45-75 min | Finalisation, validation |

### Message de succès

```
INFO Install complete!
INFO To access the cluster as the system:admin user:
     export KUBECONFIG=/home/zerotrust/okd-sno-install/auth/kubeconfig
INFO Access the OpenShift web-console here:
     https://console-openshift-console.apps.sno.okd.lab
INFO Login to the console with user: "kubeadmin"
     password: xxxxx-xxxxx-xxxxx-xxxxx
```

---

## 12. Validation du cluster

```bash
# Charger le kubeconfig
export KUBECONFIG=~/okd-sno-install/auth/kubeconfig

# État du nœud
oc get nodes
# NAME         STATUS   ROLES                         AGE   VERSION
# sno-master   Ready    control-plane,master,worker   1h    v1.30.x

# Version cluster
oc get clusterversion
# AVAILABLE=True  PROGRESSING=False

# Cluster Operators (tous doivent être Available)
oc get co
# ~30 operators, tous Available=True Progressing=False Degraded=False

# Pods en erreur (doit être vide)
oc get pods -A | grep -v Running | grep -v Completed

# Accès SSH au nœud
ssh -i ~/.ssh/okd-sno core@192.168.241.10
```

### Accès console web

```
URL      : https://console-openshift-console.apps.sno.okd.lab
User     : kubeadmin
Password : cat ~/okd-sno-install/auth/kubeadmin-password
```

> ⚠️ Le compte `kubeadmin` est temporaire. Il sera supprimé en Phase 2 après configuration de Keycloak SSO.

---

## Récapitulatif des fichiers

```
D:\okd-lab\
├── install\
│   ├── install-config.yaml      # config cluster (garder une copie !)
│   └── agent-config.yaml        # config réseau nœud (garder une copie !)
│
D:\okd-lab\vm\
└── okd-sno-master\              # fichiers VMware (.vmdk, .vmx)

~/.ssh/
├── okd-sno                      # clé privée SSH
└── okd-sno.pub                  # clé publique (dans install-config.yaml)

~/okd-sno-install\               # répertoire de travail install
├── agent.x86_64.iso             # ISO à monter dans VMware
└── auth\
    ├── kubeconfig               # credentials admin
    └── kubeadmin-password       # mot de passe console
```

---

## Prochaine étape

→ [Phase 2 — Keycloak SSO + HashiCorp Vault](phase2-identity-sso-secrets.md)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
