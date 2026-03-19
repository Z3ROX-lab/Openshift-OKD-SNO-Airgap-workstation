# OKD Single Node OpenShift — Airgap Lab on VMware Workstation

> **Portfolio project** — Demonstrates end-to-end OpenShift/OKD expertise for on-premise, airgap, and IaC-driven enterprise deployments.

[![OKD](https://img.shields.io/badge/OKD-4.15%20FCOS-red?logo=redhat)](https://www.okd.io/)
[![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-orange?logo=argo)](https://argoproj.github.io/cd/)
[![Vault](https://img.shields.io/badge/Secrets-HashiCorp%20Vault-black?logo=vault)](https://www.vaultproject.io/)
[![Harbor](https://img.shields.io/badge/Registry-Harbor-blue?logo=harbor)](https://goharbor.io/)
[![Keycloak](https://img.shields.io/badge/SSO-Keycloak-blue?logo=keycloak)](https://www.keycloak.org/)
[![Kyverno](https://img.shields.io/badge/Policy-Kyverno-blue)](https://kyverno.io/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 🎯 Objectives

This lab provisions a **fully airgap-capable Single Node OpenShift (SNO)** cluster on VMware Workstation using the **Agent-based Installer** (UPI, no vCenter API required).

The project covers the full stack required for **enterprise Kubernetes/OpenShift missions** (on-premise, grands comptes, défense, telecom) :

| Domain | Tools | Status |
|--------|-------|--------|
| Cluster provisioning | OKD 4.15, Agent-based Installer, FCOS | ✅ |
| Container registry | Harbor 2.11 + MinIO S3 + Trivy + Cosign | ✅ |
| Identity & SSO | Keycloak 26.5.5, OAuth OKD → Keycloak OIDC | ✅ |
| GitOps | ArgoCD Community Operator v0.17 — App of Apps pattern | ✅ |
| Secrets management | HashiCorp Vault + External Secrets Operator | ✅ |
| Observability | Prometheus + Alertmanager + Thanos (built-in OKD) | ✅ |
| Airgap | oc-mirror, Harbor, ImageContentSourcePolicy | 🔄 |
| Observability stack | Grafana + Loki (airgap install) | 🔜 |
| Compliance scanning | kube-bench (CIS) + Prowler (NIS2/ISO27001) | 🔜 |
| Policy enforcement | Kyverno (VALIDATE + MUTATE + GENERATE + VERIFY) | 🔜 |
| Runtime security | Falco | 🔜 |
| Supply chain | Cosign + Kyverno VERIFY | 🔜 |

---

## 🏗️ Architecture

```
  Browser / oc CLI
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│                    Windows Host (GEEKOM A6 — 32GB DDR5)           │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │                      Ubuntu WSL2                            │  │
│  │  /etc/hosts         tinyproxy :8888      oc-mirror          │  │
│  │  *.okd.lab          (proxy ArgoCD        (airgap mirror)    │  │
│  │  → .10              → github.com)                           │  │
│  └──────────────────────────┬──────────────────────────────────┘  │
│                             │ VMnet8 NAT (192.168.241.0/24)       │
│  ┌──────────────────────────▼──────────────────────────────────┐  │
│  │              OKD SNO VM — 192.168.241.10                    │  │
│  │            FCOS │ 8vCPU │ 24GB RAM │ 120GB NVMe            │  │
│  │                                                             │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  NS: openshift-operators                            │   │  │
│  │  │  ├── ArgoCD (App of Apps)                           │   │  │
│  │  │  │   ├── root-app → keycloak, vault, eso            │   │  │
│  │  │  │   └── tinyproxy HTTPS_PROXY → github.com         │   │  │
│  │  │  └── ESO (External Secrets Operator)                │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  │  │
│  │  │ NS: keycloak  │  │  NS: vault    │  │ NS: external- │  │  │
│  │  │               │  │               │  │    secrets    │  │  │
│  │  │ Keycloak 26.5 │  │ Vault (dev)   │  │               │  │  │
│  │  │ Realm: okd    │  │ KV v2         │  │ SecretStore   │  │  │
│  │  │ Client:       │  │ K8s auth      │  │ ExternalSecret│  │  │
│  │  │  openshift    │  │ Policies      │  │ → K8s Secrets │  │  │
│  │  │  argocd       │  │ Route OKD     │  │               │  │  │
│  │  │  vault        │  │               │  └───────────────┘  │  │
│  │  └───────────────┘  └───────────────┘                     │  │
│  │                                                             │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  NS: openshift-monitoring (built-in OKD)            │   │  │
│  │  │  ├── Prometheus     ✅                               │   │  │
│  │  │  ├── Alertmanager   ✅                               │   │  │
│  │  │  └── Thanos Querier ✅                               │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  Phase 3+ (airgap) :                                │   │  │
│  │  │  ├── Grafana (depuis Harbor via ICSP)               │   │  │
│  │  │  ├── Loki (depuis Harbor via ICSP)                  │   │  │
│  │  │  ├── kube-bench (CIS scan)                          │   │  │
│  │  │  ├── Prowler (compliance NIS2/ISO27001)              │   │  │
│  │  │  ├── Kyverno (policy enforcement)                   │   │  │
│  │  │  └── Falco (runtime security)                       │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │              Harbor VM — 192.168.241.20                     │  │
│  │           Ubuntu 24.04 │ 4vCPU │ 8GB │ 100GB              │  │
│  │                                                             │  │
│  │  Harbor 2.11.0 (:443)     MinIO (:9000 S3)                 │  │
│  │  ├── Project: library     ├── Bucket: harbor-registry       │  │
│  │  ├── Project: okd-mirror  └── Backend stockage images       │  │
│  │  ├── Trivy ← scan CVE auto au push                         │  │
│  │  └── Cosign ← signatures OCI                               │  │
│  └─────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Phases du projet

### ✅ Phase 1 — SNO Bootstrap — COMPLETE

> Provisionner le cluster OKD SNO via Agent-based Installer

- [x] `install-config.yaml` + `agent-config.yaml` générés
- [x] Réservation DHCP VMware — IP statique `192.168.241.10`
- [x] ISO créée avec `openshift-install agent create image`
- [x] VM VMware (UEFI, 8vCPU/24GB/120GB NVMe)
- [x] Fix PostgreSQL container (`--tmpfs /var/run/postgresql`)
- [x] Bootstrap cluster + validation 30/30 Cluster Operators
- [x] HAProxy (API :6443 + Ingress :80/:443)

→ [Guide d'installation](docs/phase1-bootstrap.md) | [Validation console](docs/phase1-validation-console.md)

---

### ✅ Phase Harbor — Registry VM — COMPLETE

> Harbor 2.11.0 sur VM dédiée avec MinIO S3 backend

- [x] VM Ubuntu 24.04 — IP statique `192.168.241.20`
- [x] Docker 29.3.0 + Docker Compose v5.1.0
- [x] MinIO standalone — bucket `harbor-registry`
- [x] CA privée Z3ROX Lab + certificat TLS `harbor.okd.lab`
- [x] Harbor 2.11.0 — 11/11 containers healthy
- [x] Trivy scan CVE automatique ✅
- [x] Cosign v2.2.4 — signature + vérification ✅

→ [Guide Harbor VM](docs/harbor-vm.md)

---

### ✅ Phase 2a — Keycloak OIDC SSO — COMPLETE

> SSO unifié OKD via Keycloak 26.5.5

- [x] Keycloak Operator v26.5.5 via OperatorHub (channel fast)
- [x] Instance Keycloak avec wildcard cert `*.apps.sno.okd.lab`
- [x] Realm `okd` — client `openshift` configuré
- [x] OAuth CR OKD → Keycloak OIDC (fix CA x509 via ConfigMap)
- [x] Utilisateur `admin-okd` + droits `cluster-admin`
- [x] SSO validé — login console OKD via Keycloak ✅

→ [Guide Phase 2a](docs/phase2a-keycloak-oidc.md)

---

### ✅ Phase 2b — ArgoCD + Vault + ESO — COMPLETE

> GitOps App of Apps + Secrets Management + External Secrets

**ArgoCD — App of Apps pattern**
- [x] ArgoCD Community Operator v0.17 via OperatorHub
- [x] `root-app.yaml` — pattern App of Apps
- [x] HTTPS_PROXY persistant dans la CR ArgoCD (tinyproxy → GitHub)
- [x] Applications : keycloak, vault, eso, keycloak-secrets
- [x] OLM Subscriptions tracées dans Git (00-subscription.yaml)
- [x] Namespaces labellisés `argocd.argoproj.io/managed-by`

**HashiCorp Vault**
- [x] Helm chart v0.28.0 via ArgoCD Multiple Sources
- [x] Route OKD `vault.apps.sno.okd.lab`
- [x] Kubernetes auth + CA cert + policies + roles
- [x] KV v2 : `secret/keycloak/*` + `secret/argocd/*`
- [x] `scripts/vault-bootstrap.sh` — reproductible après reboot
- [x] ClusterRoleBinding `vault-server-binding` (TokenReview)

**External Secrets Operator**
- [x] ESO via OLM Subscription GitOps (community-operators)
- [x] OperatorConfig `cluster` → pods ESO Running
- [x] SecretStore `vault-backend` → Valid ✅
- [x] ExternalSecret `keycloak-secrets` → SecretSynced ✅
- [x] K8s Secret `keycloak-vault-secrets` créé automatiquement

**Monitoring built-in OKD**
- [x] Prometheus + Alertmanager + Thanos — Running ✅
- [x] Queries validées : up, CPU, RAM, pods, cluster ratio
- [x] Dashboards API Performance + etcd validés

→ [Guide Phase 2b](docs/phase2b-argocd-vault.md) | [Monitoring validation](docs/phase2b-monitoring-validation.md)

---

### 🔄 Phase 3 — Airgap — IN PROGRESS

> Simulation environnement déconnecté grands comptes

- [x] oc-mirror v4.15 installé + CA Harbor ajoutée au store WSL2
- [x] `airgap/imageset-config.yaml` créé et commité
- [x] Projet `okd-mirror` créé dans Harbor
- [x] Dry-run validé — 1.543 GiB à mirror
- [x] Mirror réel lancé — Grafana + Loki + Vault + kube-bench + Prowler
- [ ] ICSP + CatalogSource appliqués sur OKD
- [ ] Grafana installé depuis Harbor (airgap)
- [ ] Loki installé depuis Harbor (airgap)
- [ ] kube-bench — rapport CIS Kubernetes Benchmark
- [ ] Prowler — rapport conformité NIS2/ISO27001
- [ ] Validation cluster sans Internet

→ [Guide Phase 3](docs/phase3-airgap.md)

---

### 🔜 Phase 4 — Security & Compliance

> Kyverno, Falco, Supply Chain, Conformité

- [ ] Kyverno — VALIDATE + MUTATE + GENERATE + VERIFY Cosign
- [ ] NetworkPolicy default-deny auto sur chaque namespace
- [ ] Falco runtime security rules
- [ ] Cosign signing pipeline + enforcement Kyverno
- [ ] Comparaison avant/après kube-bench (Phase 3 → Phase 4)

→ [Documentation Phase 4](docs/phase4-security.md)

---

## 📁 Structure du repository

```
.
├── airgap/
│   └── imageset-config.yaml          # oc-mirror ImageSetConfiguration
├── argocd/
│   └── applications/                 # ArgoCD Applications (App of Apps)
│       ├── keycloak.yaml
│       ├── keycloak-secrets.yaml
│       ├── vault.yaml
│       └── eso.yaml
├── manifests/
│   ├── argocd/
│   │   ├── 00-subscription.yaml      # OLM Subscription ArgoCD
│   │   ├── 01-argocd-instance.yaml
│   │   └── root-app.yaml             # Bootstrap App of Apps
│   ├── keycloak/
│   │   ├── 00-namespace.yaml
│   │   ├── 00-subscription.yaml      # OLM Subscription Keycloak
│   │   ├── 01-tls-secret.sh
│   │   ├── 02-keycloak-instance.yaml
│   │   ├── 03-client-secret.yaml
│   │   └── 04-oauth-cluster.yaml     # Manuel (cluster-level)
│   ├── vault/
│   │   ├── 00-namespace.yaml
│   │   ├── values.yaml               # Helm values Vault
│   │   └── extras/
│   │       ├── 01-route.yaml         # Route OKD Vault
│   │       └── 02-auth-delegator.yaml # Manuel (cluster-level)
│   └── eso/
│       ├── 00-namespace.yaml
│       ├── 00-subscription.yaml      # OLM Subscription ESO
│       ├── 01-operatorconfig.yaml
│       ├── 01-secret-store.yaml
│       └── 02-external-secret.yaml
├── scripts/
│   ├── fix-assisted-db.sh            # Fix PostgreSQL socket OKD 4.15
│   ├── okd-approve-csr.sh            # Approbation CSR kubelet
│   └── vault-bootstrap.sh            # Bootstrap Vault après reboot
├── docs/
│   ├── adr/
│   │   ├── adr-001-okd-vs-openshift.md
│   │   ├── adr-002-fcos-machineconfig.md
│   │   ├── adr-003-kyverno.md
│   │   └── adr-004-security-strategy.md
│   ├── phase1-bootstrap.md
│   ├── phase1-validation-console.md
│   ├── harbor-vm.md
│   ├── phase2a-keycloak-oidc.md
│   ├── phase2b-argocd-vault.md
│   ├── phase2b-monitoring-validation.md
│   ├── phase3-airgap.md
│   └── screenshots/
└── haproxy/
    └── haproxy.cfg
```

---

## ⚙️ GitOps — Bootstrap from scratch

```bash
# 1. Installer ArgoCD via OLM
oc apply -f manifests/argocd/00-subscription.yaml
# Attendre que l'opérateur soit Running (~2 min)

# 2. Démarrer le pattern App of Apps
oc apply -f manifests/argocd/root-app.yaml
# ArgoCD déploie automatiquement keycloak, vault, eso

# 3. Labelliser les namespaces
oc label namespace vault argocd.argoproj.io/managed-by=openshift-operators
oc label namespace keycloak argocd.argoproj.io/managed-by=openshift-operators
oc label namespace external-secrets argocd.argoproj.io/managed-by=openshift-operators

# 4. Appliquer les ressources cluster-level (une seule fois)
oc apply -f manifests/keycloak/04-oauth-cluster.yaml
oc apply -f manifests/vault/extras/02-auth-delegator.yaml

# 5. Bootstrap Vault
source .env && ./scripts/vault-bootstrap.sh

# 6. TLS Keycloak (après chaque reboot)
./manifests/keycloak/01-tls-secret.sh
```

---

## ⚠️ Post-reboot checklist

```bash
export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

# 1. Approuver les CSR kubelet
./scripts/okd-approve-csr.sh

# 2. Vérifier le cluster
oc get nodes
oc get co | grep -v "True.*False.*False"

# 3. Bootstrap Vault (mode dev — données perdues au reboot)
source .env && ./scripts/vault-bootstrap.sh

# 4. TLS Keycloak si nécessaire
./manifests/keycloak/01-tls-secret.sh
```

---

## 🔐 Accès aux UIs

| Service | URL | Credentials |
|---------|-----|-------------|
| Console OKD | https://console-openshift-console.apps.sno.okd.lab | admin-okd / Keycloak |
| ArgoCD | https://argocd-server-openshift-operators.apps.sno.okd.lab | admin |
| Vault | https://vault.apps.sno.okd.lab | Token: root |
| Keycloak | https://keycloak.apps.sno.okd.lab | admin |
| Harbor | https://harbor.okd.lab | admin / Harbor12345! |
| Prometheus | Console OKD → Observe → Metrics | - |
| Alertmanager | Console OKD → Observe → Alerting | - |

---

## 📐 Architecture Decision Records

| ADR | Titre | Statut |
|-----|-------|--------|
| [ADR-001](docs/adr/adr-001-okd-vs-openshift.md) | OKD vs Red Hat OpenShift | Accepted |
| [ADR-002](docs/adr/adr-002-fcos-machineconfig.md) | FCOS Immutable OS + MachineConfig | Accepted |
| [ADR-003](docs/adr/adr-003-kyverno.md) | Kyverno Policy Engine | Accepted |
| [ADR-004](docs/adr/adr-004-security-strategy.md) | Stratégie sécurité multi-couches | Accepted |

---

## 🔧 Problèmes connus et solutions

| Problème | Cause | Solution |
|----------|-------|----------|
| `AttributeError: 'NoneType' ...SettingBond` | nmstatectl absent dans WSL2 | Supprimer `networkConfig` de agent-config.yaml |
| IP VM aléatoire | Pas de réservation DHCP VMware | Ajouter entrée dans `vmnetdhcp.conf` |
| `assisted-service-db` crash | Bug socket `/var/run/postgresql` | `--tmpfs /var/run/postgresql:rw,mode=0777` |
| OKD 4.17 SCOS bloqué sur VMware | `release-image-pivot` remount `/sysroot` | **Utiliser OKD 4.15 FCOS** |
| Certificats kubelet expirés après reboot | Cluster éteint > 24h | `scripts/okd-approve-csr.sh` |
| OAuth CO Degraded : x509 unknown authority | Keycloak self-signed cert | ConfigMap `keycloak-ca` dans `openshift-config` |
| ArgoCD perd HTTPS_PROXY | Opérateur reconcilie le Deployment | Configurer dans la CR ArgoCD `spec.repo.env` |
| ESO `OperatorConfig` erreur spec | `spec: {}` requis | Ajouter `spec: {}` explicitement |
| Vault 403 Kubernetes auth | `authDelegator` désactivé + CA cert manquant | ClusterRoleBinding + CA cert dans bootstrap script |
| oc-mirror `401 UNAUTHORIZED` | Image inexistante dans additionalImages | Utiliser versions détectées automatiquement par bundle |

---

## 🎓 Compétences démontrées

```
Infrastructure & OS
├── OKD UPI deployment (platform: none, Agent-based Installer) ✅
├── FCOS bare-metal provisioning via Ignition ✅
└── MachineConfig — configuration OS déclarative ✅

GitOps
├── ArgoCD App of Apps pattern ✅
├── OLM Subscriptions as Code ✅
├── ArgoCD Multiple Sources (Helm + Git) ✅
└── Namespace management (labels, managed-by) ✅

Secrets Management
├── HashiCorp Vault Kubernetes auth ✅
├── External Secrets Operator ✅
├── SecretStore + ExternalSecret GitOps ✅
└── vault-bootstrap.sh reproductible ✅

Identity & SSO
├── Keycloak OIDC — OAuth Server OKD ✅
├── Realm + clients + users + RBAC ✅
└── x509 CA fix pour self-signed certs ✅

Container Registry & Supply Chain
├── Harbor 2.11 + MinIO S3 backend ✅
├── Trivy CVE scan automatique ✅
├── Cosign image signing ✅
└── oc-mirror airgap mirroring 🔄

Observabilité
├── Prometheus + Alertmanager + Thanos (built-in) ✅
├── PromQL queries cluster health ✅
├── Grafana + Loki (airgap install) 🔜
└── kube-bench + Prowler compliance 🔜

Sécurité
├── Défense en profondeur 6 couches (ADR-004) ✅
├── SCCs OpenShift ✅
├── Kyverno policy engine 🔜
└── Falco runtime security 🔜

Airgap
├── oc-mirror ImageSetConfiguration ✅
├── Harbor okd-mirror project ✅
├── ICSP + CatalogSource 🔜
└── Validation cluster sans Internet 🔜
```

---

## 👤 Auteur

**Z3ROX (Stéphane Seloi)** — Cloud Native Security Architect  
CCSP | AWS Solutions Architect | ISO 27001 Lead Implementer | CompTIA Security+  
[GitHub](https://github.com/Z3ROX-lab)

---

## 📄 License

MIT — see [LICENSE](LICENSE)
