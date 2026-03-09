# Guide DNS — OKD SNO Lab

> Comprendre et configurer la résolution DNS pour OKD SNO sur VMware Workstation

---

## Table des matières

1. [Pourquoi le DNS est critique pour OKD](#1-pourquoi-le-dns-est-critique-pour-okd)
2. [Les 3 entrées DNS obligatoires](#2-les-3-entrées-dns-obligatoires)
3. [Architecture complète](#3-architecture-complète)
4. [Le problème WSL2 — MTU](#4-le-problème-wsl2--mtu)
5. [Installation et configuration dnsmasq](#5-installation-et-configuration-dnsmasq)
6. [Validation](#6-validation)
7. [Scripts setup/restore](#7-scripts-setuprestore)

---

## 1. Pourquoi le DNS est critique pour OKD

OKD génère automatiquement des URLs basées sur deux paramètres de `install-config.yaml` :

```yaml
baseDomain: okd.lab       # domaine de base
metadata:
  name: sno               # nom du cluster
```

Ces deux valeurs combinées donnent :
- Toutes les URLs API : `*.sno.okd.lab`
- Toutes les URLs apps : `*.apps.sno.okd.lab`

Ces domaines **n'existent pas sur Internet** — ils sont locaux au lab. Sans un serveur DNS local qui les résout, rien ne fonctionne :
- `oc login` échoue
- La console web est inaccessible
- L'installation elle-même peut échouer si `api-int` n'est pas résolvable depuis la VM

---

## 2. Les 3 entrées DNS obligatoires

OKD SNO nécessite exactement **3 entrées DNS**, chacune avec un rôle distinct :

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   api.sno.okd.lab          → 192.168.241.10:6443                   │
│   ─────────────────                                                 │
│   Utilisé par :                                                     │
│   - toi (oc login, kubectl)                                         │
│   - les outils externes (CI/CD, Terraform...)                       │
│   Accessible depuis : DEHORS du cluster                             │
│                                                                     │
│                                                                     │
│   api-int.sno.okd.lab      → 192.168.241.10:6443                   │
│   ───────────────────                                               │
│   Utilisé par :                                                     │
│   - les nodes du cluster entre eux                                  │
│   - les pods qui appellent l'API Kubernetes                         │
│   Accessible depuis : DEDANS du cluster                             │
│   (même IP que api, mais résolution interne obligatoire)            │
│                                                                     │
│                                                                     │
│   *.apps.sno.okd.lab       → 192.168.241.10:443/80                 │
│   ──────────────────                                                │
│   Utilisé par :                                                     │
│   - toutes les applications déployées sur OKD                       │
│   - console, vault, argocd, keycloak, grafana...                    │
│   Le wildcard (*) = UN seul enregistrement DNS                      │
│   qui couvre TOUTES les routes OKD automatiquement                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Pourquoi `api` et `api-int` sont deux entrées séparées ?

En production multi-node avec un vrai Load Balancer :

```
Depuis l'extérieur :
  oc login → api.sno.okd.lab → Load Balancer EXTERNE → masters

Depuis l'intérieur (pods) :
  appel API → api-int.sno.okd.lab → Load Balancer INTERNE → masters

Les pods utilisent api-int pour ne pas sortir par le LB externe
inutilement — c'est plus court, plus rapide, et évite un aller-retour
réseau inutile.
```

En SNO c'est la **même IP** pour les deux (`192.168.241.10`) — mais OKD **exige** que les deux noms soient résolvables. Si `api-int` n'est pas résolvable depuis la VM pendant l'installation → **échec garanti**.

### Ce qui se passe sans chaque entrée

| Entrée manquante | Conséquence |
|---|---|
| `api` | `oc login` échoue, kubectl inaccessible |
| `api-int` | Installation OKD échoue, nodes ne peuvent pas joindre l'API |
| `*.apps` | Console web inaccessible, toutes les routes OKD cassées |

---

## 3. Architecture complète

```
                    WSL2 (Ubuntu)
    ┌───────────────────────────────────────────────────┐
    │                                                   │
    │   Browser / oc CLI / kubectl                      │
    │        │                                          │
    │        │ "api.sno.okd.lab ?"                      │
    │        ▼                                          │
    │   /etc/resolv.conf                                │
    │   nameserver 127.0.0.1  ───────────────────────┐  │
    │   nameserver 8.8.8.8                           │  │
    │                                                │  │
    │                          ┌─────────────────────┘  │
    │                          ▼                        │
    │              dnsmasq (127.0.0.1:53)               │
    │   ┌───────────────────────────────────────────┐   │
    │   │                                           │   │
    │   │  api.sno.okd.lab      → 192.168.241.10   │   │
    │   │  api-int.sno.okd.lab  → 192.168.241.10   │   │
    │   │  *.apps.sno.okd.lab   → 192.168.241.10   │   │
    │   │                                           │   │
    │   │  github.com → ? (inconnu)                │   │
    │   │  google.com → ? (inconnu)                │   │
    │   │                                           │   │
    │   └──────────────┬──────────────┘             │   │
    │                  │                            │   │
    │         connu ───┘    inconnu ───► 8.8.8.8    │   │
    │                  │                (Internet)  │   │
    │                  ▼                            │   │
    └──────────────────┼────────────────────────────┘
                       │
                       │ 192.168.241.10 (VMnet8 NAT)
                       │
                       ▼
    ┌──────────────────────────────────────────────────┐
    │             VM okd-sno-master                    │
    │             192.168.241.10                       │
    │                                                  │
    │  :6443   → API Server                            │
    │            oc login, kubectl, pods internes      │
    │                                                  │
    │  :22623  → Machine Config Server                 │
    │            (bootstrap uniquement)                │
    │                                                  │
    │  :443    → Ingress Controller (wildcard)         │
    │            ├── console-openshift-console.apps.   │
    │            ├── vault.apps.sno.okd.lab            │
    │            ├── argocd.apps.sno.okd.lab           │
    │            ├── keycloak.apps.sno.okd.lab         │
    │            └── grafana.apps.sno.okd.lab          │
    │                                                  │
    │  :80     → Ingress Controller (HTTP)             │
    │            (redirect vers :443)                  │
    │                                                  │
    └──────────────────────────────────────────────────┘
```

### Rôle de l'Ingress Controller

Une seule IP (`192.168.241.10`) répond à **toutes** les URLs `*.apps`. C'est l'**Ingress Controller** à l'intérieur du cluster qui fait le dispatch :

```
Requête : https://vault.apps.sno.okd.lab
          │
          ▼
192.168.241.10:443 (Ingress Controller)
          │
          │ lit le header Host: vault.apps.sno.okd.lab
          ▼
Service vault dans namespace vault-system
          │
          ▼
Pod Vault
```

C'est pourquoi le wildcard DNS `*.apps` est suffisant — un seul enregistrement, l'Ingress Controller fait le reste.

---

## 4. Le problème WSL2 — MTU

### Symptôme

```
E: Failed to fetch ... Hash Sum mismatch
SSL error: bad record mac
```

### Cause

Le trafic WSL2 passe par plusieurs couches avant d'atteindre Internet :

```
WSL2 eth0 (MTU 1360)
      ↓ overhead Hyper-V
Windows Hyper-V
      ↓ overhead réseau virtuel
Carte réseau physique (MTU 1500)
      ↓
Internet
```

Si un paquet TLS est trop grand → fragmenté en route → le checksum cryptographique ne correspond plus → connexion coupée.

### Solution

```bash
# Fix temporaire (session courante)
sudo ip link set eth0 mtu 1280

# Fix permanent (au démarrage WSL2)
sudo tee /etc/profile.d/fix-mtu.sh << 'EOF'
#!/bin/bash
sudo ip link set eth0 mtu 1280 2>/dev/null
EOF
sudo chmod +x /etc/profile.d/fix-mtu.sh
```

> MTU 1280 = valeur minimale IPv6 (RFC 2460) — garantie de passer partout sans fragmentation.

---

## 5. Installation et configuration dnsmasq

### Pourquoi dnsmasq et pas /etc/hosts ?

| Solution | Avantages | Inconvénients |
|---|---|---|
| `/etc/hosts` | Simple | Pas de wildcard — il faudrait lister chaque app manuellement |
| **dnsmasq** | Wildcard `*.apps`, léger, configurable | Nécessite installation |
| bind9 | Complet | Trop lourd pour un lab |

dnsmasq est le bon compromis — il supporte le wildcard `*.apps` avec une seule ligne de config.

### Étape 1 — Fix MTU

```bash
sudo ip link set eth0 mtu 1280
```

### Étape 2 — Installation

```bash
sudo apt update && sudo apt install -y dnsmasq
```

### Étape 3 — Désactivation de systemd-resolved

`systemd-resolved` est le résolveur DNS par défaut d'Ubuntu. Il occupe le port 53 — on doit le désactiver :

```bash
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
```

### Étape 4 — Config OKD

```bash
sudo tee /etc/dnsmasq.d/okd-sno.conf << 'EOF'
# OKD SNO Lab — résolution DNS locale
address=/api.sno.okd.lab/192.168.241.10
address=/api-int.sno.okd.lab/192.168.241.10
address=/.apps.sno.okd.lab/192.168.241.10

# Écouter uniquement sur loopback
# WSL2 a son propre DNS sur 10.255.255.254:53 — évite le conflit
listen-address=127.0.0.1
bind-interfaces

# Upstream DNS — forward tout ce qui n'est pas *.okd.lab
# Tailscale DNS en priorité, Google en fallback
server=100.100.100.100
server=8.8.8.8
EOF
```

> **Pourquoi `server=100.100.100.100` ?** Tailscale utilise son propre DNS (`100.100.100.100`) et peut écraser `/etc/resolv.conf` au démarrage. En ajoutant le DNS Tailscale comme upstream dans dnsmasq, les deux coexistent : dnsmasq résout `*.okd.lab` localement et forward tout le reste vers Tailscale → Internet.

### Étape 5 — Démarrage

```bash
sudo systemctl enable dnsmasq
sudo systemctl start dnsmasq
```

### Étape 6 — Configuration resolv.conf

```bash
# Empêcher WSL2 de régénérer resolv.conf au démarrage
sudo tee /etc/wsl.conf << 'EOF'
[network]
generateResolvConf = false
EOF

# Pointer sur dnsmasq + fallbacks
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 100.100.100.100
nameserver 8.8.8.8
EOF
```

> **Ordre des nameservers** : Linux essaie d'abord `127.0.0.1` (dnsmasq). dnsmasq résout `*.okd.lab` localement et forward le reste vers `100.100.100.100` (Tailscale) puis `8.8.8.8` en dernier recours.
>
> **Problème Tailscale** : Tailscale peut écraser `/etc/resolv.conf` au démarrage. La solution est de configurer dnsmasq avec `server=100.100.100.100` comme upstream — ainsi même si Tailscale réécrit resolv.conf, relancer `setup-dns-okd.sh` remet tout en ordre.

---

## 6. Validation

```bash
# API externe
dig api.sno.okd.lab @127.0.0.1 +short
# → 192.168.241.10 ✅

# API interne (critique pour l'installation)
dig api-int.sno.okd.lab @127.0.0.1 +short
# → 192.168.241.10 ✅

# Wildcard apps
dig console-openshift-console.apps.sno.okd.lab @127.0.0.1 +short
# → 192.168.241.10 ✅

# Une app fictive (teste le wildcard)
dig nimportequoi.apps.sno.okd.lab @127.0.0.1 +short
# → 192.168.241.10 ✅

# Internet (ne doit pas être cassé)
dig github.com +short
# → une IP publique ✅
```

---

## 7. Scripts setup/restore

Pour ne pas avoir à se souvenir de toutes ces étapes, deux scripts sont disponibles dans `scripts/` :

### Activer la config OKD

```bash
chmod +x scripts/setup-dns-okd.sh
./scripts/setup-dns-okd.sh
```

Ce script fait tout automatiquement : MTU fix, installation dnsmasq, config, resolv.conf, validation.

### Revenir à la config WSL2 par défaut

```bash
chmod +x scripts/restore-dns-default.sh
./scripts/restore-dns-default.sh
```

Utile si tu dois utiliser un VPN ou un DNS d'entreprise depuis WSL2.

---

## Récapitulatif

| Composant | Rôle | Fichier de config |
|---|---|---|
| `dnsmasq` | Résoudre `*.okd.lab` localement | `/etc/dnsmasq.d/okd-sno.conf` |
| `resolv.conf` | Pointer WSL2 sur dnsmasq | `/etc/resolv.conf` |
| `wsl.conf` | Empêcher WSL2 de régénérer resolv.conf | `/etc/wsl.conf` |
| MTU fix | Éviter les erreurs TLS sur apt/download | `/etc/profile.d/fix-mtu.sh` |

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
