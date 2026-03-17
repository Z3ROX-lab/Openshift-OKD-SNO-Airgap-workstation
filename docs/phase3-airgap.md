# Phase 3 — Airgap : oc-mirror + Harbor + Grafana + Loki

> Simulation d'un environnement déconnecté type grands comptes
> OKD 4.15 SNO — Harbor 2.11 — oc-mirror v4.15
> Mars 2026

---

## Concept airgap

Un cluster **airgap** est un cluster sans accès Internet direct. Toutes les images,
Helm charts et operators passent par des services **internes au réseau**.

C'est la configuration standard sur les environnements sensibles :
- 🏦 Banques / Finance (DORA, PCI-DSS)
- 🛡️ Défense / Gouvernement (ANSSI, SecNumCloud)
- 📡 Télécommunications (Nokia, Orange, Telefónica)

---

## Architecture complète

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PLAN AIRGAP — PHASE 3                                    │
│                                                                             │
│  OBJECTIF : OKD peut fonctionner SANS Internet                              │
│  Toutes les images → Harbor (192.168.241.20)                                │
└─────────────────────────────────────────────────────────────────────────────┘

ETAPE 1 — oc-mirror (WSL2, connecté Internet)
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  Internet                    WSL2 (948G dispo)                              │
│                                                                             │
│  quay.io ──────────────────► oc-mirror v4.15                               │
│  docker.io ────────────────► │                                             │
│  ghcr.io ──────────────────► │  ImageSetConfiguration :                    │
│                              │  airgap/imageset-config.yaml                │
│                              │  ├── operators:                             │
│                              │  │   ├── grafana-operator (v5)              │
│                              │  │   └── loki-operator (alpha)              │
│                              │  └── additionalImages:                      │
│                              │      ├── hashicorp/vault:1.16.1             │
│                              │      └── grafana/loki:3.5.5                 │
│                              │                                             │
│                              ▼                                             │
│                    Images mirrorées (~1.5 Go) :                            │
│                    ├── grafana/grafana:12.4.1                               │
│                    ├── grafana/grafana-operator:v5.22.2                    │
│                    ├── grafana/loki:3.5.5                                  │
│                    ├── grafana/loki-operator:0.9.0                         │
│                    ├── hashicorp/vault:1.16.1                              │
│                    ├── brancz/kube-rbac-proxy:v0.18.1                     │
│                    ├── observatorium/api:latest                            │
│                    └── observatorium/opa-openshift:latest                  │
└──────────────────────────────────────────────────────────────────────────┬─┘
                                                                           │
                              Push direct registry-to-registry
                              docker://harbor.okd.lab/okd-mirror
                                                                           │
ETAPE 2 — Harbor reçoit les images                                         │
┌──────────────────────────────────────────────────────────────────────────▼─┐
│                                                                             │
│  Harbor VM (192.168.241.20)                                                 │
│  harbor.okd.lab                                                             │
│                                                                             │
│  Project: okd-mirror (Private)                                              │
│  ├── okd-mirror/grafana/grafana:12.4.1          ✅                          │
│  ├── okd-mirror/grafana/grafana-operator:v5.22.2 ✅                         │
│  ├── okd-mirror/grafana/loki:3.5.5              ✅                          │
│  ├── okd-mirror/grafana/loki-operator:0.9.0     ✅                          │
│  ├── okd-mirror/hashicorp/vault:1.16.1          ✅                          │
│  ├── okd-mirror/brancz/kube-rbac-proxy:v0.18.1  ✅                         │
│  └── okd-mirror/operatorhubio/catalog:latest    ✅ (catalog index)          │
│                                                                             │
│  Trivy → scan CVE automatique à chaque push ✅                              │
└──────────────────────────────────────────────────────────────────────────┬─┘
                                                                           │
ETAPE 3 — Configurer OKD pour Harbor (ICSP + CatalogSource)               │
┌──────────────────────────────────────────────────────────────────────────▼─┐
│                                                                             │
│  oc apply -f oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml   │
│  │                                                                          │
│  │  ImageContentSourcePolicy (ICSP) = règle de redirection transparente    │
│  │  ┌────────────────────────────────────────────────────────────────┐     │
│  │  │  quay.io/operatorhubio/catalog → harbor.okd.lab/okd-mirror/.. │     │
│  │  │  docker.io/grafana/grafana     → harbor.okd.lab/okd-mirror/.. │     │
│  │  │  ghcr.io/grafana/...           → harbor.okd.lab/okd-mirror/.. │     │
│  │  │  docker.io/hashicorp/vault     → harbor.okd.lab/okd-mirror/.. │     │
│  │  └────────────────────────────────────────────────────────────────┘     │
│  │  Les pods pullent depuis quay.io/docker.io → OKD redirige vers Harbor  │
│  │  Transparence totale — aucun changement dans les manifests              │
│  │                                                                          │
│  oc apply -f oc-mirror-workspace/results-*/catalogSource-*.yaml            │
│  │                                                                          │
│  │  CatalogSource = index operators depuis Harbor                           │
│  │  OperatorHub pointe sur harbor.okd.lab/okd-mirror au lieu d'Internet   │
│  │                                                                          │
│  oc patch OperatorHub cluster --disable-all-default-sources=true           │
│  │                                                                          │
│  │  Désactive les CatalogSources Internet (community-operators, etc.)      │
└──────────────────────────────────────────────────────────────────────────┬─┘
                                                                           │
ETAPE 4 — Installer Grafana + Loki via ArgoCD (airgap)                    │
┌──────────────────────────────────────────────────────────────────────────▼─┐
│                                                                             │
│  GitHub ──► ArgoCD (via tinyproxy) ──► OKD                                 │
│                                                                             │
│  argocd/applications/grafana.yaml   → installe grafana-operator via OLM   │
│  argocd/applications/loki.yaml      → installe loki-operator via OLM      │
│                                                                             │
│  OLM pull catalog depuis harbor.okd.lab/okd-mirror (ICSP) ✅               │
│  Pods pull images depuis harbor.okd.lab/okd-mirror (ICSP) ✅               │
│  Zéro accès Internet requis ✅                                              │
└──────────────────────────────────────────────────────────────────────────┬─┘
                                                                           │
RESULTAT FINAL                                                             │
┌──────────────────────────────────────────────────────────────────────────▼─┐
│                                                                             │
│  AVANT airgap                    APRES airgap                               │
│                                                                             │
│  quay.io ──► OKD                 Harbor ──► OKD (ICSP)                    │
│  docker.io ──► OKD               Harbor ──► OKD (ICSP)                    │
│  OperatorHub ──► Internet        OperatorHub ──► Harbor (CatalogSource)   │
│  ArgoCD ──► github.com           ArgoCD ──► github.com (tinyproxy)        │
│                                                                             │
│  Stack observabilité complète en airgap :                                  │
│  ├── Prometheus    ✅ built-in OKD                                          │
│  ├── Alertmanager  ✅ built-in OKD                                          │
│  ├── Thanos        ✅ built-in OKD                                          │
│  ├── Grafana       ✅ installé depuis Harbor en airgap                     │
│  └── Loki          ✅ installé depuis Harbor en airgap                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Prérequis accomplis

```
✅ oc-mirror v4.15 installé
✅ imageset-config.yaml créé et commité (airgap/imageset-config.yaml)
✅ CA Harbor ajoutée au store système WSL2
✅ Projet okd-mirror créé dans Harbor
✅ docker login harbor.okd.lab effectué
✅ Dry-run validé — 1.543 GiB à mirror
```

---

## ImageSetConfiguration

```yaml
# airgap/imageset-config.yaml
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
storageConfig:
  local:
    path: /home/zerotrust/work/oc-mirror/workspace
mirror:
  operators:
    - catalog: quay.io/operatorhubio/catalog:latest
      packages:
        - name: grafana-operator
          channels:
            - name: v5
        - name: loki-operator
          channels:
            - name: alpha
  additionalImages:
    - name: docker.io/hashicorp/vault:1.16.1
    - name: docker.io/grafana/loki:3.5.5
```

### Images détectées automatiquement par oc-mirror

| Image | Source | Version | Via |
|-------|--------|---------|-----|
| grafana | docker.io/grafana | 12.4.1 | operator bundle |
| grafana-operator | ghcr.io/grafana | v5.22.2 | operator bundle |
| loki | docker.io/grafana | 3.5.5 | bundle + additionalImages |
| loki-operator | docker.io/grafana | 0.9.0 | operator bundle |
| vault | docker.io/hashicorp | 1.16.1 | additionalImages |
| kube-rbac-proxy | quay.io/brancz | v0.18.1 | operator bundle |
| observatorium/api | quay.io/observatorium | latest | operator bundle |
| opa-openshift | quay.io/observatorium | latest | operator bundle |

**Total : ~1.543 GiB**

---

## Commandes oc-mirror

### Installation oc-mirror

```bash
# Télécharger oc-mirror v4.15
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.15.0/oc-mirror.tar.gz
tar xvf oc-mirror.tar.gz
sudo mv oc-mirror /usr/local/bin/
chmod +x /usr/local/bin/oc-mirror

# Dépendance libgpgme
sudo apt install -y libgpgme11

# Vérification
oc-mirror version
```

### Ajouter la CA Harbor au store système

```bash
scp harbor@192.168.241.20:~/harbor/certs/ca.crt /tmp/harbor-ca.crt
sudo cp /tmp/harbor-ca.crt /usr/local/share/ca-certificates/harbor-ca.crt
sudo update-ca-certificates

# Vérification
curl -v https://harbor.okd.lab/v2/ 2>&1 | grep "SSL certificate verify"
# → SSL certificate verify ok ✅
```

### Dry-run (validation sans téléchargement)

```bash
oc-mirror --config airgap/imageset-config.yaml \
  --dry-run \
  docker://harbor.okd.lab/okd-mirror
```

### Mirror réel

```bash
cd ~/work/oc-mirror

oc-mirror --config ~/work/Openshift-OKD-SNO-Airgap-workstation/airgap/imageset-config.yaml \
  docker://harbor.okd.lab/okd-mirror 2>&1 | tee /tmp/oc-mirror-run.txt
```

### Appliquer ICSP et CatalogSource

```bash
# Résultats générés dans oc-mirror-workspace/results-*/
ls oc-mirror-workspace/results-*/

# Appliquer la politique de redirection d'images
oc apply -f oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml

# Appliquer le catalogue d'operators depuis Harbor
oc apply -f oc-mirror-workspace/results-*/catalogSource-*.yaml

# Désactiver les sources Internet
oc patch OperatorHub cluster --type json \
  -p '[{"op":"add","path":"/spec/disableAllDefaultSources","value":true}]'
```

### Vérification post-ICSP

```bash
# Vérifier que le nœud redémarre bien (MachineConfig update)
oc get nodes
oc get mcp

# Vérifier les CatalogSources
oc get catalogsource -n openshift-marketplace

# Vérifier OperatorHub depuis la console
# → Operators → OperatorHub → filtrer par "grafana" ou "loki"
# → Doit apparaître depuis harbor.okd.lab
```

---

## Installation Grafana + Loki via ArgoCD (airgap)

Une fois ICSP appliqué, on déploie via ArgoCD depuis Git :

```bash
# manifests/grafana/00-subscription.yaml
# manifests/loki/00-subscription.yaml
# argocd/applications/grafana.yaml
# argocd/applications/loki.yaml
```

ArgoCD sync depuis GitHub (via tinyproxy) → OLM pull depuis Harbor (ICSP) → pods déployés.

---

## Validation airgap complète

```bash
# 1. Cluster opérationnel sans Internet
oc get nodes   # → Ready
oc get co      # → tous Available

# 2. OperatorHub depuis Harbor
oc get catalogsource -n openshift-marketplace
# → harbor.okd.lab comme source

# 3. Grafana accessible
oc get route -n grafana
# → grafana.apps.sno.okd.lab

# 4. Loki collecte les logs
oc get pods -n loki
# → Running

# 5. Vault pod redémarre depuis Harbor
oc delete pod vault-0 -n vault
oc get pods -n vault
# → image pullée depuis harbor.okd.lab via ICSP ✅
```

---

## Note sur ArgoCD en airgap partiel

Dans ce lab, ArgoCD continue d'accéder à GitHub via **tinyproxy** (10.128.0.2:8888).
Ce n'est pas un airgap total — c'est un airgap **images uniquement**.

Le vrai airgap Git complet nécessiterait GitLab installé dans le cluster
(prévu en Phase 4), ce qui rendrait le cluster totalement autonome :

```
Airgap partiel (Phase 3) :
  Images → Harbor ✅
  Git    → GitHub via tinyproxy ⚠️

Airgap total (Phase 4) :
  Images → Harbor ✅
  Git    → GitLab in-cluster ✅
  CI/CD  → GitLab Runner in-cluster ✅
```

---

## Problèmes rencontrés et solutions

| Problème | Cause | Solution |
|----------|-------|----------|
| `x509: certificate signed by unknown authority` | CA Harbor non reconnue par oc-mirror | `sudo update-ca-certificates` avec ca.crt Harbor |
| `BAD_REQUEST: invalid repository name` | Projet Harbor inexistant | Créer projet `okd-mirror` dans Harbor UI |
| `channel does not exist: lokistack-1.0` | Mauvais channel loki-operator | Utiliser channel `alpha` |
| `401 UNAUTHORIZED quay.io/grafana` | Version inexistante | Supprimer de additionalImages (inclus via bundle) |
| `fatal: not a git repository` | Mauvais dossier courant | `cd ~/work/Openshift-OKD-SNO-Airgap-workstation` |

---

## Prochaine étape — Phase 4

→ GitLab in-cluster (airgap Git complet)
→ GitLab CI/CD pipeline (build → Harbor → OKD)
→ Cosign + Kyverno enforcement
→ Airgap total validé

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*Phase 3 Airgap — Mars 2026*
