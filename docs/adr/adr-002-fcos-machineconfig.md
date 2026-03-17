# ADR-002 — FCOS Immutable OS et MachineConfig

## Statut

**Accepted** — Mars 2026

## Contexte

Les nœuds OKD/OpenShift ne tournent pas sur un OS Linux classique (Ubuntu, RHEL, Debian)
mais sur **FCOS (Fedora CoreOS)** — un OS immutable conçu spécifiquement pour les
environnements conteneurisés. Ce choix architectural a des implications directes sur
la façon de configurer et sécuriser les nœuds du cluster.

---

## FCOS vs OS classique

```
OS classique (Ubuntu, RHEL, Debian)    FCOS / RHCOS (nœuds OKD/OpenShift)
────────────────────────────────────   ────────────────────────────────────
Tu peux modifier n'importe quoi        Filesystem en lecture seule
apt install, yum install               Pas de package manager
SSH + éditer /etc/xxx manuellement     Pas de modification manuelle directe
Config dérive avec le temps            État garanti identique sur tous nœuds
"Snowflake servers"                    "Cattle not pets"
Rollback difficile                     Rollback atomique via OSTree
```

### Filesystem FCOS en couches

```
FCOS filesystem (OSTree)
├── /     (read-only)   ← système de base — JAMAIS modifié manuellement
├── /usr  (read-only)   ← binaires système
├── /etc  (writable)    ← MachineConfig écrit ICI
├── /var  (writable)    ← données persistantes (etcd, kubelet, logs)
└── /run  (tmpfs)       ← données temporaires
```

---

## MachineConfig — définition

**MachineConfig** est la CRD OpenShift/OKD qui permet de décrire
de façon **déclarative** l'état désiré de l'OS des nœuds.
Le **MachineConfig Operator (MCO)** applique ces configurations
automatiquement sur chaque nœud via un redémarrage contrôlé.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MACHINECONFIG — FLOW                             │
│                                                                     │
│  Git (source de vérité)                                             │
│  └── MachineConfig YAML                                             │
│              │                                                      │
│              │ oc apply                                             │
│              ▼                                                      │
│  MachineConfig Operator (MCO)                                       │
│  ├── Détecte le changement                                          │
│  ├── Génère un rendered MachineConfig (fusion de tous les MC)       │
│  ├── Met à jour le MachineConfigPool                                │
│  │                                                                  │
│  │   MachineConfigPool                                              │
│  │   ├── master → nœuds control plane                              │
│  │   ├── worker → nœuds worker                                     │
│  │   └── custom → pools personnalisés (gpu, storage...)            │
│  │                                                                  │
│  └── Applique sur chaque nœud du pool concerné :                   │
│      ├── Écrit les fichiers dans /etc                               │
│      ├── Configure les units systemd                                │
│      ├── Redémarre le nœud proprement (drain → reboot → uncordon)  │
│      └── Vérifie la conformité en continu (self-healing)           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Ce que MachineConfig configure

### 1. Kernel parameters (sysctl)

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-sysctl
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/sysctl.d/99-custom.conf
          contents:
            source: data:,vm.max_map_count%3D262144%0Afs.file-max%3D65536
```

Cas d'usage : `vm.max_map_count=262144` requis pour Loki/Elasticsearch.

### 2. CA certificates (trust store OS)

```yaml
spec:
  config:
    storage:
      files:
        - path: /etc/pki/ca-trust/source/anchors/harbor-ca.crt
          contents:
            source: data:text/plain;base64,LS0tLS1CRUdJTi...
```

Cas d'usage : faire confiance à la CA Harbor sur tous les nœuds.

### 3. Container registry (ICSP)

```yaml
spec:
  config:
    storage:
      files:
        - path: /etc/containers/registries.conf.d/harbor-mirror.conf
          contents:
            source: data:,[[registry]]%0Alocation%3D...
```

Cas d'usage : rediriger `docker.io → harbor.okd.lab` — généré automatiquement
par oc-mirror via `ImageContentSourcePolicy`.

### 4. Systemd units

```yaml
spec:
  config:
    systemd:
      units:
        - name: custom-service.service
          enabled: true
          contents: |
            [Unit]
            Description=Custom Service
            [Service]
            ExecStart=/usr/local/bin/custom
            [Install]
            WantedBy=multi-user.target
```

### 5. SSH authorized keys

```yaml
spec:
  config:
    passwd:
      users:
        - name: core
          sshAuthorizedKeys:
            - ssh-rsa AAAA...
```

### 6. FIPS (sécurité nationale)

```yaml
spec:
  fips: true
  kernelArguments:
    - fips=1
```

Cas d'usage : conformité ANSSI, NSA, FedRAMP — appliqué sur tous les nœuds.

---

## MachineConfig vs NetworkPolicy

Une confusion fréquente :

```
MachineConfig                    NetworkPolicy
────────────────────────────     ────────────────────────────
Configure l'OS du NŒUD           Configure le réseau des PODS
Niveau : système d'exploitation  Niveau : Kubernetes
Fichiers, kernel, systemd        Ingress/Egress entre pods
Appliqué via MCO + reboot        Appliqué via CNI (OVN-Kubernetes)
CRD : MachineConfig              CRD : NetworkPolicy
Scope : cluster-wide par pool    Scope : namespace
```

Pour appliquer des NetworkPolicies sur tous les namespaces automatiquement,
on utilise **Kyverno ClusterPolicy** (prévu Phase 4) :

```yaml
# Kyverno génère automatiquement une NetworkPolicy
# sur chaque nouveau namespace créé
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-networkpolicy
spec:
  rules:
    - name: default-deny-ingress
      match:
        resources:
          kinds: [Namespace]
      generate:
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{request.object.metadata.name}}"
        data:
          spec:
            podSelector: {}
            policyTypes: [Ingress]
```

---

## MachineConfigPool — vérification

```bash
# Voir l'état des pools
oc get mcp

# Output attendu :
# NAME     CONFIG                     UPDATED   UPDATING   DEGRADED
# master   rendered-master-xxxxx      True      False      False
# worker   rendered-worker-xxxxx      True      False      False

# Voir les MachineConfigs appliqués
oc get mc

# Voir le détail d'un pool
oc describe mcp master
```

**Quand `UPDATING=True`** — un nœud est en train de redémarrer
pour appliquer un nouveau MachineConfig. C'est normal et attendu
lors d'un changement de config (ICSP, kernel params, etc.).

---

## Impact sur ce projet

### ICSP généré par oc-mirror

Quand on applique l'`ImageContentSourcePolicy` après oc-mirror,
OpenShift génère **automatiquement** un MachineConfig qui :

```
ICSP appliqué
      ↓
MCO génère un nouveau rendered MachineConfig
      ↓
Écrit /etc/containers/registries.conf.d/harbor-mirror.conf
sur TOUS les nœuds
      ↓
Nœuds redémarrent un par un (rolling restart)
      ↓
Tous les nœuds redirigent docker.io → harbor.okd.lab
```

En SNO (1 seul nœud), le cluster sera **indisponible ~5 minutes**
pendant le redémarrage. C'est normal.

### CA Harbor dans le trust store OS

Pour que les nœuds fassent confiance à Harbor sans `--insecure`,
il faut ajouter la CA Harbor via MachineConfig (ou via
`image.config.openshift.io/cluster` qui génère un MachineConfig) :

```bash
# Méthode recommandée OpenShift
oc create configmap harbor-ca \
  --from-file=harbor.okd.lab=/tmp/harbor-ca.crt \
  -n openshift-config

oc patch image.config.openshift.io/cluster \
  --type=merge \
  --patch='{"spec":{"additionalTrustedCA":{"name":"harbor-ca"}}}'
# → OpenShift génère automatiquement un MachineConfig ✅
```

---

## Pourquoi FCOS + MachineConfig est un avantage sécurité

```
FCOS immutable = surface d'attaque réduite
├── Pas de SSH par défaut en prod
│   → Pas d'accès interactif = pas de modification non tracée
│
├── Pas de package manager
│   → Impossible d'installer des binaires non autorisés
│
├── OS identique sur tous les nœuds
│   → Pas de dérive de configuration
│   → Audit : tu peux prouver que tous les nœuds sont conformes
│
├── Mise à jour atomique via OSTree
│   → Si une mise à jour échoue → rollback automatique
│   → Pas de nœud dans un état intermédiaire incohérent
│
└── MachineConfig = seule façon officielle de modifier l'OS
    → Tout changement passe par Git (GitOps) ✅
    → Audit trail complet ✅
    → Cohérence garantie sur 1 ou 500 nœuds ✅
```

C'est l'une des raisons pour lesquelles OpenShift/OKD est privilégié
dans les contextes ANSSI/SecNumCloud — la configuration OS est
**déclarative, versionnée, et auto-réparatrice**.

---

## Références

- [MachineConfig Operator](https://docs.okd.io/latest/post_installation_configuration/machine-configuration-tasks.html)
- [FCOS Documentation](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [OSTree — Atomic Updates](https://ostreedev.github.io/ostree/)
- [ICSP — ImageContentSourcePolicy](https://docs.okd.io/latest/openshift_images/image-configuration.html)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*ADR-002 — FCOS Immutable OS et MachineConfig — Mars 2026*
