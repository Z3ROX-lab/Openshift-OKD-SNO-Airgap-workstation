# Agent-based Installer — SNO vs MNO

> Comprendre comment l'Agent-based Installer s'adapte à différentes topologies de cluster

---

## Pourquoi la MAC address est obligatoire

### Le problème que la MAC résout

Quand une VM boote sur l'ISO agent, l'agent doit répondre à une question critique :

> *"Je suis quel nœud ? Quel rôle dois-je jouer ? Quelle IP statique dois-je configurer ?"*

L'agent ne peut pas deviner. Il a besoin d'un **identifiant unique et stable** pour faire le lien entre la VM physique et sa configuration dans `agent-config.yaml`. La **MAC address** est cet identifiant.

```
VM boote sur l'ISO
        │
        ▼
Agent lit la MAC de l'interface réseau
        │
        ▼
Agent cherche dans agent-config.yaml :
"Quelle entrée hosts[] a cette MAC ?"
        │
        ├── Trouvé → applique hostname, role, IP statique de cette entrée
        └── Non trouvé → nœud non reconnu, installation bloquée
```

### Même en SNO ?

Oui — même avec un seul nœud. Sans la MAC dans `agent-config.yaml`, l'agent ne peut pas lier la VM à sa configuration réseau. Il ne saurait pas quelle IP statique configurer sur quelle interface.

```yaml
# Sans MAC → agent-config.yaml invalide
hosts:
  - hostname: sno-master
    role: master
    networkConfig: ...    # Comment savoir à quelle VM appliquer ça ?

# Avec MAC → agent-config.yaml correct
hosts:
  - hostname: sno-master
    role: master
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:xx:xx:xx"   # ← lien VM ↔ config
    networkConfig: ...
```

### Comment récupérer la MAC dans VMware Workstation

```
VM Settings → Network Adapter → Advanced → MAC Address
```

La MAC est générée automatiquement par VMware au format `00:0C:29:xx:xx:xx`. Tu peux aussi la lire depuis WSL après avoir démarré la VM une première fois :

```bash
# Si la VM a déjà booté (même sur un LiveCD) :
arp -a | grep 192.168.100.10
# ou
nmap -sn 192.168.100.0/24
```

---

## Topologie SNO

### Caractéristiques

- 1 seul nœud
- Roles fusionnés : `control-plane + master + worker`
- Le nœud se bootstrap lui-même
- Pas de tolérance aux pannes (si la VM tombe → cluster down)
- Idéal pour : lab, portfolio, démo, edge computing, développement

### install-config.yaml

```yaml
controlPlane:
  replicas: 1          # 1 seul master

compute:
  - name: worker
    replicas: 0        # pas de workers séparés
```

### agent-config.yaml

```yaml
rendezvousIP: 192.168.100.10   # IP de l'unique nœud

hosts:
  - hostname: sno-master
    role: master               # master = aussi worker en SNO
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:AA:AA:AA"
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.100.10
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.100.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33
```

### Flow bootstrap SNO

```
agent.x86_64.iso
       │
       ▼
sno-master boote
       │
       ├── Phase 1 : joue le rôle Bootstrap
       │   ├── etcd temporaire
       │   ├── API server temporaire
       │   └── génère ses propres certificats
       │
       └── Phase 2 : devient le vrai Control Plane
           ├── etcd permanent
           ├── API server permanent
           ├── Scheduler
           ├── Controller Manager
           └── Bootstrap logic → nettoyé automatiquement

→ Durée : 45-75 minutes
```

---

## Topologie MNO Compact (3 masters, sans workers)

### Caractéristiques

- 3 nœuds masters
- Masters schedulables (les pods applicatifs tournent sur les masters)
- Tolérance aux pannes : 1 master peut tomber, cluster reste opérationnel
- Idéal pour : lab avancé, environnements de dev/staging

### Ressources minimales

| Nœud | vCPU | RAM | Disk |
|------|------|-----|------|
| master-1 | 4 | 16 Go | 120 Go |
| master-2 | 4 | 16 Go | 120 Go |
| master-3 | 4 | 16 Go | 120 Go |
| **Total** | **12** | **48 Go** | **360 Go** |

### install-config.yaml

```yaml
controlPlane:
  replicas: 3          # 3 masters

compute:
  - name: worker
    replicas: 0        # masters schedulables, pas de workers séparés
```

### agent-config.yaml

```yaml
rendezvousIP: 192.168.100.10   # master-1 = point de rendez-vous

hosts:
  - hostname: master-1
    role: master
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:AA:AA:AA"
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.100.10
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.100.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33

  - hostname: master-2
    role: master
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:BB:BB:BB"   # MAC différente
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.100.11         # IP différente
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.100.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33

  - hostname: master-3
    role: master
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:CC:CC:CC"
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.100.12
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.100.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33
```

### Flow bootstrap MNO Compact

```
Même ISO bootée sur 3 VMs simultanément
          │
          ▼
master-1 (rendezvousIP)         master-2              master-3
    │                               │                     │
    │◄──────── "je suis là" ────────┤                     │
    │◄──────── "je suis là" ─────────────────────────────┘
    │
    ▼
Quorum atteint (3/3 nœuds détectés)
    │
    ▼
Bootstrap collectif
├── etcd distribué sur 3 nœuds
├── API server HA
└── Certificates distribués

→ Durée : 60-90 minutes
```

---

## Topologie MNO Full (3 masters + workers)

### Caractéristiques

- 3 nœuds masters dédiés control plane
- N nœuds workers pour les workloads applicatifs
- Séparation stricte control plane / workloads
- Tolérance aux pannes maximale
- Idéal pour : production, staging prod-like

### Ressources minimales (3M + 2W)

| Nœud | Count | vCPU | RAM | Disk |
|------|-------|------|-----|------|
| master | 3 | 4 | 16 Go | 120 Go |
| worker | 2 | 2 | 8 Go | 100 Go |
| **Total** | **5** | **20** | **64 Go** | **560 Go** |

### install-config.yaml

```yaml
controlPlane:
  replicas: 3

compute:
  - name: worker
    replicas: 2        # workers séparés
```

### agent-config.yaml — ajout des workers

```yaml
# ... masters identiques au MNO Compact ...

  - hostname: worker-1
    role: worker                             # ← role: worker
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:DD:DD:DD"
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.100.20
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.100.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33

  - hostname: worker-2
    role: worker
    interfaces:
      - name: ens33
        macAddress: "00:0C:29:EE:EE:EE"
    networkConfig:
      interfaces:
        - name: ens33
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: 192.168.100.21
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 192.168.100.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 192.168.100.2
            next-hop-interface: ens33
```

---

## Comparaison des trois topologies

| | SNO | MNO Compact | MNO Full |
|--|-----|-------------|---------|
| **Nœuds** | 1 | 3 | 3 + N |
| **Masters schedulables** | ✅ | ✅ | ❌ |
| **HA Control Plane** | ❌ | ✅ | ✅ |
| **Tolérance pannes** | ❌ | 1 master | 1 master + workers |
| **RAM minimum hôte** | 32 Go | 64 Go | 96 Go+ |
| **ISOs différentes** | Non | Non | Non |
| **MACs dans agent-config** | 1 | 3 | 3 + N |
| **Usage** | Lab / Edge | Dev / Staging | Production |

---

## Agent-based vs UPI Classique (méthode bootstrap VM)

L'Agent-based Installer remplace la méthode UPI classique qui nécessitait une infrastructure externe :

| Composant | UPI Classique | Agent-based |
|-----------|--------------|-------------|
| Bootstrap VM | ✅ Rocky Linux / RHCOS séparé | ❌ Embarqué dans l'ISO |
| Serveur HTTP ignition | ✅ Apache/Nginx | ❌ Embarqué dans l'ISO |
| Fichiers ignition séparés | ✅ bootstrap.ign, master.ign, worker.ign | ❌ Tout dans l'ISO |
| HAProxy | ✅ Serveur dédié | ✅ Sur l'hôte (simplifié) |
| DNS | ✅ Bind/dnsmasq dédié | ✅ dnsmasq hôte |
| API externe requise | ✅ (vCenter, AWS...) pour IPI | ❌ Aucune |
| Compatible airgap | ⚠️ Complexe | ✅ Natif |

En UPI classique, chaque nœud recevait son fichier ignition via HTTP au boot :

```
master-1 → GET http://bastion:8080/master.ign
master-2 → GET http://bastion:8080/master.ign
worker-1 → GET http://bastion:8080/worker.ign
bootstrap → GET http://bastion:8080/bootstrap.ign
```

Avec l'Agent-based Installer, tout est embarqué dans l'ISO — aucun serveur externe nécessaire.

---

*Document de référence — projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
