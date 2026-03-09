# Phase 1 — Guide Complet : Bootstrap OKD SNO sur VMware Workstation

> Document pédagogique — Comprendre chaque étape avant de l'exécuter

---

## Table des matières

1. [Architecture globale](#1-architecture-globale)
2. [Pourquoi ces deux binaires ?](#2-pourquoi-ces-deux-binaires-)
3. [Le problème MTU sur WSL2](#3-le-problème-mtu-sur-wsl2)
4. [Pourquoi une clé SSH ?](#4-pourquoi-une-clé-ssh-)
5. [install-config.yaml — Anatomie complète](#5-install-configyaml--anatomie-complète)
6. [agent-config.yaml — Anatomie complète](#6-agent-configyaml--anatomie-complète)
7. [Génération de l'ISO Agent-based](#7-génération-de-liso-agent-based)
8. [Création de la VM VMware Workstation](#8-création-de-la-vm-vmware-workstation)
9. [Surveillance de l'installation](#9-surveillance-de-linstallation)
10. [Validation du cluster](#10-validation-du-cluster)

---

## 1. Architecture globale

Avant de toucher au moindre fichier, il faut comprendre ce qu'on construit et pourquoi.

### Ce qu'est OKD SNO

**OKD** (Origin Kubernetes Distribution) est la version communautaire open-source d'OpenShift. C'est l'upstream de Red Hat OpenShift Container Platform (OCP) — même codebase, sans licence commerciale.

**SNO** (Single Node OpenShift) est une topologie où les rôles `control-plane`, `master` et `worker` sont tous fusionnés sur **un seul nœud**. En production, un cluster OpenShift normal a minimum 3 masters + 2 workers. En SNO, tout tourne sur une seule VM.

```
Cluster OpenShift normal          OKD SNO (notre cas)
─────────────────────────         ──────────────────
master-1 (control plane)
master-2 (control plane)    →     sno-master (control plane + worker)
master-3 (control plane)
worker-1
worker-2
```

### L'OS du nœud : SCOS

Depuis OKD 4.17, l'OS des nœuds est **SCOS** (CentOS Stream CoreOS). C'est un OS :

- **Immuable** : le filesystem système est en lecture seule. On ne peut pas installer de paquets manuellement
- **Géré par Ignition** : toute la configuration initiale (users, fichiers, services) est injectée au premier boot via un fichier JSON appelé *ignition config*
- **Auto-mis à jour** : le MCO (Machine Config Operator) gère les mises à jour OS via GitOps

C'est exactement l'OS utilisé en production chez les grands comptes — Nokia, Orange, Telefónica utilisent tous des nœuds CoreOS/SCOS sur leurs clusters OpenShift.

### Le flux complet de l'installation

```
WSL2 Ubuntu
    │
    ├── 1. install-config.yaml     ← configuration du cluster
    ├── 2. agent-config.yaml       ← configuration réseau du nœud
    │
    ▼
openshift-install agent create image
    │
    ▼
agent.x86_64.iso                  ← ISO bootable (~1 Go)
    │
    ▼
VMware Workstation                ← on monte l'ISO dans la VM
    │
    ▼
VM boot → Assisted Installer      ← agent embarqué dans l'ISO
    │    détecte le hardware
    │    configure le réseau
    │    applique les ignition configs
    │
    ▼
OKD SNO opérationnel              ← ~45-75 minutes
    │
    ▼
openshift-install agent wait-for install-complete
    │
    ▼
Console : https://console-openshift-console.apps.sno.okd.lab
```

---

## 2. Pourquoi ces deux binaires ?

### openshift-install

C'est le **cerveau de l'installation**. Il fait deux choses :

**Avant l'installation :**
- Lit `install-config.yaml` et `agent-config.yaml`
- Génère les *manifests* Kubernetes (objets YAML de configuration du cluster)
- Génère les *ignition configs* (fichiers JSON qui configurent l'OS SCOS au boot)
- Assemble tout dans une **ISO bootable** (~1 Go) contenant l'agent d'installation

**Pendant l'installation :**
- Se connecte à l'agent qui tourne dans la VM
- Surveille la progression en temps réel
- Valide que chaque composant démarre correctement

Sans `openshift-install` → impossible de créer l'ISO, impossible de surveiller l'install.

### oc (OpenShift CLI)

C'est le **couteau suisse** pour piloter le cluster une fois installé. C'est une extension de `kubectl` avec des commandes spécifiques OpenShift.

```bash
# Commandes kubectl standard (fonctionnent avec oc)
oc get pods -A
oc get nodes
oc apply -f manifest.yaml

# Commandes spécifiques OpenShift
oc get routes -A                    # Routes OpenShift (pas d'équivalent kubectl)
oc get clusterversion               # Version et état du cluster
oc get co                           # Cluster Operators (composants internes OCP)
oc adm top nodes                    # Consommation ressources
oc login https://api.sno.okd.lab:6443 --token=...
```

Sans `oc` → tu peux utiliser `kubectl`, mais tu perds toutes les commandes spécifiques OpenShift (routes, builds, imagestreams, operators...).

### Pourquoi deux fichiers séparés ?

Historiquement, Red Hat distribue les deux outils séparément car :
- `oc` est utilisé par les **développeurs** et **ops** au quotidien (léger, ~70 Mo)
- `openshift-install` est utilisé **une seule fois** lors du bootstrap (lourd, ~400 Mo car il embarque toutes les images de référence)

En production, seul `oc` est installé sur les postes des équipes. `openshift-install` ne sert qu'à l'équipe infra lors du déploiement initial.

### Pourquoi OKD 4.17.0-okd-scos.0 spécifiquement ?

C'est la **première release stable SCOS** d'OKD 4.17 (le `.0` indique la première release officielle du channel stable). Les versions `4.17.0-0.okd-scos-YYYY-MM-DD` sont des builds nightlies — fonctionnels mais sans garantie de stabilité ni de chemin de mise à jour.

```
4.17.0-okd-scos.0   ← version stable (notre choix ✅)
4.17.0-okd-scos.1   ← patch stable
4.17.0-0.okd-scos-2025-02-23-210454  ← nightly (instable ❌ pour un lab)
```

---

## 3. Le problème MTU sur WSL2

### Qu'est-ce que le MTU ?

**MTU** (Maximum Transmission Unit) = la taille maximale d'un paquet réseau en octets.

```
Paquet réseau
┌─────────────────────────────────────────┐
│ Header IP │ Header TCP │    Data        │
│  20 bytes │  20 bytes  │  1460 bytes    │
└─────────────────────────────────────────┘
◄────────────────── MTU = 1500 ──────────►
```

Si un paquet est plus grand que le MTU du réseau, il est **fragmenté** (découpé en morceaux). Sur TLS (HTTPS), cette fragmentation peut corrompre les enregistrements cryptographiques → erreur `bad record mac`.

### Pourquoi WSL2 est affecté ?

WSL2 utilise une interface réseau virtuelle (`eth0`) avec un MTU de **1500 par défaut**. Mais le réseau Windows sous-jacent (Hyper-V virtual switch) a ses propres en-têtes, réduisant l'espace disponible pour les données. Résultat : les gros fichiers (>100 Mo) via TLS échouent aléatoirement.

```
WSL2 eth0 (MTU 1500)
    │
    ▼
Hyper-V vSwitch (overhead ~40 bytes)
    │
    ▼
Réseau physique Windows
```

### La solution

Réduire le MTU de WSL2 à **1280** (valeur minimale IPv6, sûre pour tous les réseaux) :

```bash
sudo ip link set eth0 mtu 1280
```

Cela force des paquets plus petits → moins de fragmentation → plus d'erreurs TLS.

Pour rendre permanent (sinon perdu au redémarrage WSL) :

```bash
sudo tee /etc/profile.d/fix-mtu.sh << 'EOF'
#!/bin/bash
sudo ip link set eth0 mtu 1280 2>/dev/null
EOF
sudo chmod +x /etc/profile.d/fix-mtu.sh
```

### Pourquoi PowerShell contourne le problème

PowerShell télécharge directement via le stack réseau Windows, sans passer par la couche Hyper-V de WSL2. Pas de double encapsulation → pas de fragmentation → pas d'erreur TLS. C'est la méthode **la plus propre** pour les gros téléchargements depuis WSL2.

---

## 4. Pourquoi une clé SSH ?

### SCOS est immuable, pas de mot de passe

Sur un OS standard (Ubuntu, CentOS), tu peux te connecter avec un mot de passe root via la console. SCOS interdit ça :

- Pas de root password configuré
- Pas d'accès console avec mot de passe
- Filesystem système en lecture seule (impossible de modifier `/etc/shadow` après boot)

La **seule façon d'accéder** au nœud SCOS est SSH avec une clé publique.

### Comment la clé est injectée

```
install-config.yaml
└── sshKey: "ssh-ed25519 AAAA..."    ← clé publique
          │
          ▼
openshift-install génère master.ign   ← fichier Ignition JSON
          │
          contient :
          {
            "passwd": {
              "users": [{
                "name": "core",
                "sshAuthorizedKeys": ["ssh-ed25519 AAAA..."]
              }]
            }
          }
          │
          ▼
SCOS boot → Ignition s'exécute au premier démarrage
          │
          ▼
~/.ssh/authorized_keys configuré pour l'user "core"
          │
          ▼
ssh -i ~/.ssh/okd-sno core@192.168.100.10  ✅
```

### Pourquoi ed25519 et pas RSA ?

| Algorithme | Sécurité | Taille clé | Performance | Recommandation |
|-----------|---------|-----------|------------|---------------|
| RSA 2048 | ⚠️ Déprécié | 2048 bits | Lent | ❌ Éviter |
| RSA 4096 | ✅ | 4096 bits | Très lent | ⚠️ Acceptable |
| ECDSA | ✅ | 256 bits | Rapide | ✅ Bien |
| **ed25519** | ✅ Meilleur | 256 bits | Très rapide | ✅ **Standard actuel** |

`ed25519` utilise les courbes de Twisted Edwards — résistant aux attaques par canal auxiliaire, clé courte, signature rapide. C'est le standard recommandé par ANSSI, NIST, et tous les cloud providers (AWS, Azure, GCP).

### Usage en pratique

```bash
# Générer la clé
ssh-keygen -t ed25519 -C "okd-sno-lab" -f ~/.ssh/okd-sno -N ""
#           │           │               │                  │
#           │           │               │                  └── pas de passphrase
#           │           │               └── fichier de sortie
#           │           └── commentaire (dans la clé publique)
#           └── algorithme

# Résultat
~/.ssh/okd-sno      ← clé PRIVÉE (ne jamais partager !)
~/.ssh/okd-sno.pub  ← clé PUBLIQUE (va dans install-config.yaml)

# Se connecter au nœud après install
ssh -i ~/.ssh/okd-sno core@192.168.100.10
```

---

## 5. install-config.yaml — Anatomie complète

C'est le **fichier de configuration principal** du cluster. Il décrit ce qu'on veut construire.

```yaml
apiVersion: v1
baseDomain: okd.lab
# ↑ Domaine de base. Toutes les URLs du cluster seront sous ce domaine :
#   API    : api.sno.okd.lab
#   Console: console-openshift-console.apps.sno.okd.lab
#   Apps   : *.apps.sno.okd.lab

metadata:
  name: sno
# ↑ Nom du cluster. Forme le sous-domaine :
#   api.SNO.okd.lab
#   *.apps.SNO.okd.lab

compute:
  - name: worker
    replicas: 0
# ↑ En SNO, 0 workers séparés. Le master est aussi schedulable (MastersSchedulable: true)

controlPlane:
  name: master
  replicas: 1
# ↑ 1 seul master = SNO. Pour un compact cluster : replicas: 3

networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  # ↑ Réseau interne des pods. Chaque nœud reçoit un /23 (512 IPs pour ses pods)
  #   Ce réseau est interne au cluster, invisible depuis l'extérieur

  machineNetwork:
    - cidr: 192.168.100.0/24
  # ↑ Réseau physique de tes VMs (VMnet8 NAT)
  #   L'IP du nœud SNO DOIT être dans ce CIDR

  networkType: OVNKubernetes
  # ↑ CNI (Container Network Interface) plugin
  #   OVNKubernetes = Open Virtual Network, le CNI standard OpenShift 4.12+
  #   Remplace l'ancien OpenShiftSDN

  serviceNetwork:
    - 172.30.0.0/16
  # ↑ Réseau des Services Kubernetes (ClusterIP)
  #   Virtuel, géré par kube-proxy/OVN, invisible depuis l'extérieur

platform:
  none: {}
# ↑ Pas de cloud provider, pas d'API hyperviseur
#   = UPI pur, tu gères l'infra toi-même
#   C'est le mode utilisé sur baremetal en prod

pullSecret: '{"auths":{"fake":{"auth":"aGVsbG86d29ybGQ="}}}'
# ↑ OKD (OSS) ne nécessite pas de vrai pull secret Red Hat
#   Ce JSON fakr est le standard pour OKD — il bypass la vérification

sshKey: |
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfYWQYhU/AfkK5U+URfW5Huvg4BeZUKlnKZSlYW7VqW okd-sno-lab
# ↑ Ta clé publique (cat ~/.ssh/okd-sno.pub)
#   Injectée dans SCOS via Ignition pour accès SSH
```

### Champs critiques vs optionnels

| Champ | Critique | Impact si mal configuré |
|-------|---------|------------------------|
| `baseDomain` | ✅ | Toutes les URLs cassées |
| `metadata.name` | ✅ | Sous-domaine incorrect |
| `machineNetwork.cidr` | ✅ | IP du nœud rejetée |
| `networkType` | ✅ | Pas de réseau pods |
| `platform` | ✅ | Installer cherche une API cloud |
| `sshKey` | ✅ | Nœud inaccessible post-install |
| `pullSecret` | ✅ | Impossible de pull les images |
| `replicas` worker/master | ✅ | Mauvaise topologie |

---

## 6. agent-config.yaml — Anatomie complète

Alors que `install-config.yaml` décrit le cluster, `agent-config.yaml` décrit la **configuration réseau physique** des nœuds.

```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: sno

rendezvousIP: 192.168.100.10
# ↑ IP du nœud "rendez-vous" — en SNO, c'est l'unique nœud
#   C'est l'IP que l'agent bootstrap utilisera pour se contacter
#   DOIT correspondre à l'IP statique configurée ci-dessous

hosts:
  - hostname: sno-master
    role: master
    # ↑ Rôle du nœud. En SNO : master (qui est aussi worker)

    interfaces:
      - name: ens33
        macAddress: "00:0C:29:xx:xx:xx"
      # ↑ Liaison interface → adresse MAC
      #   VMware nomme toujours la première interface "ens33"
      #   La MAC est visible dans VM Settings → Network Adapter → Advanced

    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            # ↑ IP STATIQUE obligatoire pour OKD
            #   DHCP = IP changeante = DNS cassé = cluster cassé
            address:
              - ip: 192.168.100.10
                prefix-length: 24
                # ↑ /24 = 255.255.255.0 = subnet VMnet8

      dns-resolver:
        config:
          server:
            - 192.168.100.2
            # ↑ Gateway VMnet8 (par défaut x.x.x.2 sur VMware)
            #   Ou l'IP WSL si tu fais tourner dnsmasq dessus

      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33
            # ↑ Route par défaut = tout le trafic sortant passe par la gateway VMnet8
```

### Pourquoi une IP statique ?

OpenShift génère des certificats TLS et des entrées DNS basés sur l'IP du nœud lors de l'installation. Si l'IP change (DHCP), les certificats deviennent invalides, les routes DNS cassent, et le cluster devient inutilisable.

En production, les nœuds OpenShift sont **toujours** en IP statique, que ce soit en baremetal, VMware vSphere, ou cloud privé.

---

## 7. Génération de l'ISO Agent-based

### Qu'est-ce que l'Agent-based Installer ?

C'est une méthode d'installation introduite dans OpenShift 4.12. Au lieu de nécessiter une infrastructure de bootstrap externe (bootstrap VM, S3 bucket, Route53...), l'installer embarque tout dans une **ISO bootable**.

L'ISO contient :
- Un kernel Linux minimal
- L'agent d'installation (Assisted Installer en mode local)
- Tes configurations `install-config.yaml` et `agent-config.yaml`
- Les ignition configs générés

Au boot de la VM, l'agent :
1. Détecte le hardware (CPU, RAM, disks)
2. Configure le réseau selon `agent-config.yaml`
3. Démarre les composants OpenShift
4. S'auto-bootstrap sans infrastructure externe

### Pourquoi c'est parfait pour VMware Workstation

Les méthodes d'installation traditionnelles OKD/OCP nécessitent :
- Une VM bootstrap séparée
- Un serveur DHCP/PXE
- Un serveur HTTP pour les ignition configs
- Une API cloud (vCenter, AWS, Azure...)

L'Agent-based Installer **élimine tout ça**. Tu génères une ISO, tu la montes dans VMware, et c'est parti. C'est exactement le mode utilisé pour les installations **baremetal** en production — très valorisé sur les missions grands comptes.

### La commande

```bash
# ⚠️ IMPORTANT : openshift-install CONSUME et SUPPRIME install-config.yaml
# Toujours travailler depuis une COPIE

mkdir -p ~/okd-sno-install
cp /mnt/d/okd-lab/install/install-config.yaml ~/okd-sno-install/
cp /mnt/d/okd-lab/install/agent-config.yaml ~/okd-sno-install/

# Générer l'ISO
openshift-install agent create image --dir ~/okd-sno-install/

# Résultat : ~/okd-sno-install/agent.x86_64.iso (~1 Go)
```

Après cette commande, `install-config.yaml` et `agent-config.yaml` **disparaissent** du répertoire — ils sont consommés pour générer l'ISO. C'est normal, garde tes originaux dans le repo Git.

---

## 8. Création de la VM VMware Workstation

### Specs de la VM

| Paramètre | Valeur | Raison |
|-----------|--------|--------|
| OS Guest | RHEL 9 64-bit | SCOS est basé sur CentOS Stream 9 |
| vCPU | 8 | Minimum OKD SNO : 8 vCPUs |
| RAM | 24 576 MB | Minimum OKD SNO : 16 Go, 24 Go pour confort |
| Disk | 120 Go thin | `/var` OpenShift peut grossir significativement |
| Réseau | VMnet8 NAT | Même subnet que WSL2 pour accès HAProxy |
| Firmware | UEFI | SCOS ne supporte pas le BIOS legacy |
| Secure Boot | Désactivé | SCOS kernel OKD non signé Microsoft |

### Pourquoi thin provisioning ?

**Thick provisioning** : VMware alloue immédiatement 120 Go sur ton disque D:
**Thin provisioning** : VMware alloue uniquement l'espace réellement écrit (commence à ~5 Go, grandit selon besoin)

Avec 528 Go disponibles, thin provisioning te permet de créer la VM sans sacrifier 120 Go immédiatement. La VM ne prendra que l'espace dont elle a besoin.

### L'option disk.EnableUUID

Cette option VMware est **critique pour OKD** :

```
VM Settings → Options → Advanced → Configuration Parameters
→ Ajouter : disk.EnableUUID = TRUE
```

Sans cette option, SCOS ne peut pas identifier de façon unique les disques (nécessaire pour les CSI drivers de stockage comme le vSphere CSI ou Longhorn). L'installation peut compléter mais le stockage persistant ne fonctionnera pas.

---

## 9. Surveillance de l'installation

### Deux phases à surveiller

**Phase Bootstrap** : le nœud SNO se bootstrap lui-même

```bash
openshift-install agent wait-for bootstrap-complete \
  --dir ~/okd-sno-install/ \
  --log-level=info
```

Cette commande surveille jusqu'à ce que :
- L'API server soit disponible sur `https://api.sno.okd.lab:6443`
- etcd soit opérationnel
- Le control plane soit stable

**Phase Install Complete** : tous les operators démarrent

```bash
openshift-install agent wait-for install-complete \
  --dir ~/okd-sno-install/ \
  --log-level=info
```

Cette commande surveille jusqu'à ce que :
- Tous les Cluster Operators soient `Available=True`
- La console web soit accessible
- L'installation soit déclarée complète

### Ce qui se passe sous le capot

```
Minute 0-5   : Boot SCOS, détection hardware
Minute 5-15  : Configuration réseau, pull images depuis quay.io
Minute 15-30 : Démarrage etcd, API server, MCS
Minute 30-45 : Bootstrap des Cluster Operators (console, monitoring, ingress...)
Minute 45-75 : Finalisation, validation, nettoyage bootstrap
```

---

## 10. Validation du cluster

### Commandes de vérification

```bash
# Charger le kubeconfig admin
export KUBECONFIG=~/okd-sno-install/auth/kubeconfig

# 1. État du nœud
oc get nodes
# NAME         STATUS   ROLES                         AGE   VERSION
# sno-master   Ready    control-plane,master,worker   1h    v1.30.x
# ↑ ROLES = control-plane,master,worker → confirmation SNO correct

# 2. Version du cluster
oc get clusterversion
# AVAILABLE=True, PROGRESSING=False → cluster stable

# 3. Cluster Operators (composants internes)
oc get co
# Tous doivent être : AVAILABLE=True, PROGRESSING=False, DEGRADED=False
# ~30 operators au total

# 4. Pods système
oc get pods -A | grep -v Running | grep -v Completed
# Ne doit rien afficher → tous les pods tournent

# 5. URL console
oc whoami --show-console
```

### Accès à la console web

```
URL      : https://console-openshift-console.apps.sno.okd.lab
User     : kubeadmin
Password : cat ~/okd-sno-install/auth/kubeadmin-password
```

Le `kubeadmin` est un **compte temporaire** créé uniquement pour le bootstrap initial. En production, on le supprime après avoir configuré un Identity Provider (dans notre cas, Keycloak en Phase 2).

---

## Récapitulatif des dépendances

```
D:\okd-lab\
├── install\
│   ├── openshift-install          → génère l'ISO + surveille l'install
│   ├── oc                         → pilote le cluster post-install
│   ├── install-config.yaml        → config cluster (conserve une copie !)
│   └── agent-config.yaml          → config réseau nœud (conserve une copie !)
│
~/.ssh/
├── okd-sno                        → clé privée (accès SSH nœud)
└── okd-sno.pub                    → clé publique (dans install-config.yaml)
│
~/okd-sno-install/                 → répertoire de travail install
├── agent.x86_64.iso               → ISO à monter dans VMware
└── auth/
    ├── kubeconfig                 → credentials admin cluster
    └── kubeadmin-password         → mot de passe console web
```

---

*Document généré dans le cadre du projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*Phase 1 — Bootstrap OKD SNO sur VMware Workstation*
