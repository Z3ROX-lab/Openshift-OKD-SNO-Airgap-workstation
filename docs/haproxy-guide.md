# Guide HAProxy — Load Balancer Externe OKD SNO

> HAProxy tourne dans WSL2 et sert de pont entre Windows et la VM OKD SNO

---

## Table des matières

1. [Rôle de HAProxy dans l'architecture](#1-rôle-de-haproxy-dans-larchitecture)
2. [HAProxy vs Ingress Controller — deux niveaux distincts](#2-haproxy-vs-ingress-controller--deux-niveaux-distincts)
3. [Les 4 ports OKD obligatoires](#3-les-4-ports-okd-obligatoires)
4. [Architecture complète](#4-architecture-complète)
5. [Installation](#5-installation)
6. [Configuration](#6-configuration)
7. [Démarrage et validation](#7-démarrage-et-validation)
8. [Scripts setup/restore](#8-scripts-setuprestore)

---

## 1. Rôle de HAProxy dans l'architecture

Sans HAProxy, le browser Windows ne peut pas atteindre les ports de la VM directement. WSL2 et la VM sont sur le même subnet VMnet8 (`192.168.241.0/24`), mais Windows ne route pas automatiquement vers ce subnet.

HAProxy tourne dans WSL2 et sert de **pont réseau** :

```
Windows (hôte)
      │
      │ :6443 / :443 / :80 / :22623
      ▼
WSL2 (accessible depuis Windows)
      │
      │ HAProxy forward vers VMnet8
      ▼
VM okd-sno-master (192.168.241.10)
```

---

## 2. HAProxy vs Ingress Controller — deux niveaux distincts

C'est un point important à bien comprendre — il y a **deux niveaux de routage** dans l'architecture OKD SNO, et les **deux utilisent HAProxy** :

```
Browser (Windows)
      │
      │ https://console-openshift-console.apps.sno.okd.lab
      ▼
┌─────────────────────────────────────────────────┐
│  NIVEAU 1 — HAProxy (WSL2)                      │
│  → TON HAProxy, que tu installes et configures  │
│                                                 │
│  Mode : TCP layer 4                             │
│  Rôle : forward les ports TCP vers la VM        │
│  Ne lit PAS les headers HTTP                    │
│  Ne connaît PAS les applications                │
│                                                 │
│  :443 → 192.168.241.10:443  (et c'est tout)    │
└──────────────────────┬──────────────────────────┘
                       │
                       │ TCP forward
                       ▼
┌─────────────────────────────────────────────────┐
│  NIVEAU 2 — HAProxy OKD (Ingress Controller)    │
│  → HAProxy INTERNE, géré automatiquement par OKD│
│  → pod "router-default" dans la VM              │
│                                                 │
│  Mode : HTTP layer 7                            │
│  Rôle : dispatch selon le header Host           │
│  Config : via Routes OKD (oc get route)         │
│                                                 │
│  Lit : Host: console-openshift-console.apps...  │
│  ├── console-openshift-console.apps → pod       │
│  ├── argocd-server.apps → pod ArgoCD            │
│  ├── vault.apps → pod Vault                     │
│  └── keycloak.apps → pod Keycloak               │
└─────────────────────────────────────────────────┘
```

> **Pourquoi OKD utilise HAProxy pour son Ingress Controller ?**
> Red Hat a choisi HAProxy comme implémentation par défaut du Router OKD. C'est historique — HAProxy était déjà mature et performant pour le routage HTTP quand OpenShift a été conçu. Dans OpenShift on parle du **"Router"** plutôt que de l'"Ingress Controller" pour éviter justement la confusion avec un HAProxy externe.

| | Ton HAProxy (WSL2) | HAProxy OKD (Router) |
|---|---|---|
| **Où** | WSL2 | Pod `router-default` dans la VM |
| **Qui le gère** | Toi | OKD automatiquement |
| **Mode** | TCP layer 4 | HTTP layer 7 |
| **Config** | `haproxy.cfg` | Routes OKD (`oc get route -A`) |
| **Rôle** | Forward ports | Dispatch par hostname |
| **Connaît les apps** | ❌ Non | ✅ Oui |
| **Lit les headers HTTP** | ❌ Non | ✅ Oui |
| **Remplaçable par** | iptables, socat | Nginx Ingress, Traefik |

---

## 3. Les 4 ports OKD obligatoires

OKD SNO nécessite exactement 4 ports exposés :

```
┌────────┬──────────────────────────┬─────────────────────────────────────┐
│  Port  │  Composant               │  Utilisé par                        │
├────────┼──────────────────────────┼─────────────────────────────────────┤
│  6443  │  API Server              │  oc login, kubectl, CI/CD, ArgoCD   │
│        │                          │  Toujours actif après installation  │
├────────┼──────────────────────────┼─────────────────────────────────────┤
│  22623 │  Machine Config Server   │  Nodes pendant le bootstrap         │
│        │                          │  Inactif après installation         │
├────────┼──────────────────────────┼─────────────────────────────────────┤
│  443   │  Ingress Controller HTTPS│  Toutes les apps (console, vault...) │
│        │                          │  Toujours actif                     │
├────────┼──────────────────────────┼─────────────────────────────────────┤
│  80    │  Ingress Controller HTTP │  Redirect vers 443                  │
│        │                          │  Toujours actif                     │
└────────┴──────────────────────────┴─────────────────────────────────────┘
```

> **Port 22623 — Machine Config Server** : utilisé uniquement pendant l'installation pour distribuer les configs aux nodes. Il reste ouvert dans HAProxy mais devient inactif une fois le cluster installé. En production, il serait fermé au firewall après bootstrap.

---

## 4. Architecture complète

```
                    WINDOWS (hôte)
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │   Browser         oc CLI / kubectl                   │
    │      │                  │                            │
    │      │ :443/:80         │ :6443                      │
    │      └────────┬─────────┘                            │
    │               │                                      │
    └───────────────┼──────────────────────────────────────┘
                    │
                    │ (WSL2 accessible depuis Windows)
                    ▼
    ┌──────────────────────────────────────────────────────┐
    │                   WSL2 (Ubuntu)                      │
    │                                                      │
    │   ┌──────────────────────────────────────────────┐   │
    │   │  HAProxy                                     │   │
    │   │                                              │   │
    │   │  frontend :6443  ──► backend 192.168.241.10:6443  │
    │   │  frontend :22623 ──► backend 192.168.241.10:22623 │
    │   │  frontend :443   ──► backend 192.168.241.10:443   │
    │   │  frontend :80    ──► backend 192.168.241.10:80    │
    │   │                                              │   │
    │   │  Stats : http://localhost:9000/stats         │   │
    │   └──────────────────────┬───────────────────────┘   │
    │                          │                           │
    └──────────────────────────┼───────────────────────────┘
                               │
                               │ VMnet8 (192.168.241.0/24)
                               ▼
    ┌──────────────────────────────────────────────────────┐
    │              VM okd-sno-master                       │
    │              192.168.241.10                          │
    │                                                      │
    │  :6443   API Server                                  │
    │  :22623  Machine Config Server                       │
    │  :443    Ingress Controller → dispatch par hostname  │
    │  :80     Ingress Controller → redirect HTTPS         │
    │                                                      │
    └──────────────────────────────────────────────────────┘
```

---

## 5. Installation

```bash
# Fix MTU si pas déjà fait
sudo ip link set eth0 mtu 1280

sudo apt install -y haproxy

# Vérifier la version
haproxy -v
# HAProxy version 2.8.x
```

---

## 6. Configuration

Le fichier de config HAProxy est `/etc/haproxy/haproxy.cfg` :

```bash
sudo tee /etc/haproxy/haproxy.cfg << 'EOF'
#---------------------------------------------------------------------
# HAProxy — OKD SNO Lab
# Load Balancer externe WSL2 → VM okd-sno-master
#---------------------------------------------------------------------

global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 2000
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  1m
    timeout server  1m

#---------------------------------------------------------------------
# Stats — http://localhost:9000/stats
#---------------------------------------------------------------------
frontend stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:okdlab
    stats show-legends
    stats show-node

#---------------------------------------------------------------------
# API Server — oc login, kubectl, ArgoCD
# Port 6443 → masters
#---------------------------------------------------------------------
frontend okd-api
    bind *:6443
    default_backend okd-api-backend

backend okd-api-backend
    balance roundrobin
    option ssl-hello-chk
    server sno-master 192.168.241.10:6443 check

#---------------------------------------------------------------------
# Machine Config Server — bootstrap uniquement
# Port 22623 → masters
#---------------------------------------------------------------------
frontend okd-mcs
    bind *:22623
    default_backend okd-mcs-backend

backend okd-mcs-backend
    balance roundrobin
    server sno-master 192.168.241.10:22623 check

#---------------------------------------------------------------------
# Ingress HTTPS — toutes les apps OKD
# Port 443 → workers (Ingress Controller)
#---------------------------------------------------------------------
frontend okd-https
    bind *:443
    default_backend okd-https-backend

backend okd-https-backend
    balance roundrobin
    option ssl-hello-chk
    server sno-master 192.168.241.10:443 check

#---------------------------------------------------------------------
# Ingress HTTP — redirect vers HTTPS
# Port 80 → workers (Ingress Controller)
#---------------------------------------------------------------------
frontend okd-http
    bind *:80
    default_backend okd-http-backend

backend okd-http-backend
    balance roundrobin
    server sno-master 192.168.241.10:80 check

EOF
```

> **Pourquoi `mode tcp` et pas `mode http` ?**
> HAProxy est configuré en mode TCP (layer 4) — il forward les paquets sans les inspecter. Le TLS est terminé directement par OKD, pas par HAProxy. C'est le bon pattern pour OKD car les certificats sont gérés par le cluster lui-même (cert-manager, Let's Encrypt ou CA interne).

---

## 7. Démarrage et validation

### Valider la config

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
# Configuration file is valid
```

### Démarrer HAProxy

```bash
sudo systemctl enable haproxy
sudo systemctl start haproxy
sudo systemctl status haproxy
# → Active: active (running)
```

### Vérifier les ports en écoute

```bash
sudo ss -tulnp | grep haproxy
# tcp LISTEN 0 128 *:6443   haproxy
# tcp LISTEN 0 128 *:22623  haproxy
# tcp LISTEN 0 128 *:443    haproxy
# tcp LISTEN 0 128 *:80     haproxy
# tcp LISTEN 0 128 *:9000   haproxy
```

### Page de stats

```
http://localhost:9000/stats
Login : admin / okdlab
```

Les backends apparaîtront en rouge (DOWN) jusqu'au démarrage de la VM OKD — c'est normal.

---

## 8. Scripts setup/restore

Comme pour le DNS, deux scripts dans `scripts/` :

```bash
# Activer HAProxy OKD
./scripts/setup-haproxy-okd.sh

# Arrêter HAProxy
./scripts/restore-haproxy-default.sh
```

---

## Récapitulatif

| Composant | Rôle | Port |
|---|---|---|
| HAProxy frontend `okd-api` | Expose l'API Kubernetes | 6443 |
| HAProxy frontend `okd-mcs` | Machine Config Server (bootstrap) | 22623 |
| HAProxy frontend `okd-https` | Toutes les apps OKD (HTTPS) | 443 |
| HAProxy frontend `okd-http` | Redirect HTTP → HTTPS | 80 |
| HAProxy stats | Dashboard monitoring HAProxy | 9000 |

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
