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
| Observability built-in | Prometheus + Alertmanager + Thanos (OKD) | ✅ |
| Airgap | oc-mirror, Harbor, ICSP, CatalogSource Harbor | ✅ |
| Operators via OLM airgap | Grafana Operator v5 + Loki Operator v0.9 | ✅ |
| StorageClass | local-path-provisioner (Rancher) | ✅ |
| Observability stack | Grafana instance + Prometheus datasource + dashboard | ✅ |
| Compliance scanning | kube-bench CIS 1.8 + Prowler CIS 1.10 | ✅ |
| Policy enforcement | Kyverno (VALIDATE + MUTATE + GENERATE + VERIFY) | 🔜 |
| Runtime security | Falco | 🔜 |
| Supply chain | Cosign + Kyverno VERIFY | 🔜 |
| GitOps airgap total | GitLab in-cluster + CI/CD pipeline | 🔜 |
| Multi-cluster | HyperShift + Azure NodePools | 🔜 |

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
│  │  │  │   ├── grafana, loki, grafana-instance            │   │  │
│  │  │  │   └── tinyproxy HTTPS_PROXY → github.com         │   │  │
│  │  │  └── ESO (External Secrets Operator)                │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  │  │
│  │  │ NS: keycloak  │  │  NS: vault    │  │ NS: grafana-  │  │  │
│  │  │               │  │               │  │    operator   │  │  │
│  │  │ Keycloak 26.5 │  │ Vault (dev)   │  │               │  │  │
│  │  │ Realm: okd    │  │ KV v2         │  │ Grafana v12   │  │  │
│  │  │ OIDC → OKD    │  │ K8s auth      │  │ Datasource:   │  │  │
│  │  │               │  │ Policies/Roles│  │ Prometheus OKD│  │  │
│  │  └───────────────┘  └───────────────┘  └───────────────┘  │  │
│  │                                                             │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  NS: openshift-monitoring (built-in OKD)            │   │  │
│  │  │  ├── Prometheus     ✅                               │   │  │
│  │  │  ├── Alertmanager   ✅                               │   │  │
│  │  │  └── Thanos Querier ✅                               │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  NS: kube-bench / prowler (Jobs ponctuels)          │   │  │
│  │  │  ├── kube-bench CIS 1.8 → 36P/36F/58W ✅            │   │  │
│  │  │  └── Prowler CIS 1.10 → 91.56% PASS ✅              │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  Phase 4+ :                                         │   │  │
│  │  │  ├── Kyverno (policy enforcement)                   │   │  │
│  │  │  ├── Falco (runtime security)                       │   │  │
│  │  │  └── GitLab in-cluster (airgap Git total)           │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │              Harbor VM — 192.168.241.20                     │  │
│  │           Ubuntu 24.04 │ 4vCPU │ 8GB │ 100GB              │  │
│  │                                                             │  │
│  │  Harbor 2.11.0 (:443)     MinIO (:9000 S3)                 │  │
│  │  ├── Project: library     ├── Bucket: harbor-registry       │  │
│  │  ├── Project: okd-mirror  └── Bucket: loki-logs (réservé)  │  │
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
- [x] KV v2 : `secret/keycloak` + `secret/vault` + `secret/loki` + `secret/grafana`
- [x] `scripts/vault-bootstrap.sh` — reproductible après reboot
- [x] ClusterRoleBinding `vault-server-binding` (TokenReview)

**External Secrets Operator**
- [x] ESO via OLM Subscription GitOps (community-operators)
- [x] OperatorConfig `cluster` → pods ESO Running
- [x] SecretStore `vault-backend` → Valid ✅ (keycloak, loki-operator, grafana-operator)
- [x] ExternalSecrets → SecretSynced ✅

**Monitoring built-in OKD**
- [x] Prometheus + Alertmanager + Thanos — Running ✅
- [x] Queries validées : up, CPU, RAM, pods, cluster ratio

→ [Guide Phase 2b](docs/phase2b-argocd-vault.md) | [Monitoring validation](docs/phase2b-monitoring-validation.md)

---

### ✅ Phase 3 — Airgap — COMPLETE

> Simulation environnement déconnecté grands comptes

**Airgap progressif** — pattern enterprise réaliste :
le cluster ne voit jamais Internet, Harbor est le seul point d'entrée des images.
Le bastion WSL2 peut pousser des images dans Harbor au fur et à mesure.

**oc-mirror + Harbor**
- [x] oc-mirror v4.15 — mirror 4.62 GiB (Grafana + Loki + Vault + kube-bench + Prowler)
- [x] ICSP `generic-0` appliqué — MachineConfigPool UPDATED=True ✅
- [x] CatalogSource `community-operators` → `harbor.okd.lab/okd-mirror/operatorhubio/catalog:latest`

**OLM Operators via Harbor (airgap)**
- [x] Grafana Operator v5.22.2 — channel v5 — Synced/Healthy ✅
- [x] Loki Operator v0.9.0 — channel alpha — Synced/Healthy ✅
- [x] Fix OperatorGroup AllNamespaces mode pour Loki Operator

**StorageClass**
- [x] `local-path-provisioner` v0.0.26 (Rancher) depuis Harbor
- [x] StorageClass `local-path` — default ✅

**Compliance scanning depuis Harbor**
- [x] kube-bench CIS 1.8 — Job depuis Harbor — **36 PASS / 36 FAIL / 58 WARN** ✅
- [x] Prowler CIS 1.10 — Job depuis Harbor — **2887 PASS (91.56%) / 266 FAIL** ✅
- [x] Rapports HTML/JSON sauvegardés

**Grafana + Prometheus OKD**
- [x] Grafana instance v12.4.1 depuis Harbor — Route `grafana.apps.sno.okd.lab` ✅
- [x] Token Prometheus → Vault → ESO → Secret K8s (pattern Zero Trust)
- [x] GrafanaDatasource Prometheus OKD — `status: success` ✅
- [x] Dashboard "OKD SNO — Security Compliance" — CPU/Memory/kube-bench/Prowler ✅

**ArgoCD final**
```
eso              Synced   Healthy  ✅
grafana          Synced   Healthy  ✅
grafana-instance Synced   Healthy  ✅
keycloak         Synced   Healthy  ✅
keycloak-secrets Synced   Healthy  ✅
loki             Synced   Healthy  ✅
root-app         Synced   Healthy  ✅
vault            Synced   Healthy  ✅
```

→ [Guide Phase 3](docs/phase3-airgap.md)

---

### 🔜 Phase 4 — Security & Compliance

> Kyverno, Falco, Supply Chain, GitLab in-cluster

- [ ] Kyverno — VALIDATE + MUTATE + GENERATE + VERIFY Cosign
- [ ] NetworkPolicy default-deny auto sur chaque namespace
- [ ] Falco runtime security rules
- [ ] Cosign signing pipeline + enforcement Kyverno
- [ ] GitLab in-cluster (airgap Git total)
- [ ] GitLab CI/CD pipeline (build → Harbor → OKD)
- [ ] Comparaison avant/après kube-bench (Phase 3 → Phase 4)

---

### 🔜 Phase 5 — HyperShift + Azure NodePools

> Multi-cluster management

- [ ] MCE + HyperShift installés sur SNO (management cluster)
- [ ] Hosted Control Plane déployé
- [ ] Azure NodePool (Standard_D4s_v3) connecté via Tailscale
- [ ] LokiStack sur nœuds dédiés Azure
- [ ] Observabilité multi-cluster dans Grafana

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
│       ├── eso.yaml
│       ├── grafana.yaml
│       ├── grafana-instance.yaml
│       └── loki.yaml
├── manifests/
│   ├── argocd/
│   ├── keycloak/
│   ├── vault/
│   ├── eso/
│   ├── grafana/                      # Grafana Operator (OLM)
│   ├── grafana-instance/             # Grafana CR + Datasource + Dashboard
│   ├── loki/                         # Loki Operator (OLM)
│   ├── kube-bench/                   # Job CIS benchmark
│   ├── prowler/                      # Job conformité
│   └── storage/                      # local-path-provisioner
├── scripts/
│   ├── fix-assisted-db.sh
│   ├── okd-approve-csr.sh
│   └── vault-bootstrap.sh
├── docs/
│   ├── adr/
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

# 2. Démarrer le pattern App of Apps
oc apply -f manifests/argocd/root-app.yaml

# 3. Labelliser les namespaces
oc label namespace vault argocd.argoproj.io/managed-by=openshift-operators
oc label namespace keycloak argocd.argoproj.io/managed-by=openshift-operators
oc label namespace external-secrets argocd.argoproj.io/managed-by=openshift-operators
oc label namespace grafana-operator argocd.argoproj.io/managed-by=openshift-operators
oc label namespace loki-operator argocd.argoproj.io/managed-by=openshift-operators

# 4. Appliquer les ressources cluster-level (une seule fois)
oc apply -f manifests/keycloak/04-oauth-cluster.yaml
oc apply -f manifests/vault/extras/02-auth-delegator.yaml

# 5. Bootstrap Vault
source .env && ./scripts/vault-bootstrap.sh

# 6. SCC pour kube-bench et Prowler
oc adm policy add-scc-to-user privileged -z kube-bench -n kube-bench
oc adm policy add-scc-to-user anyuid -z prowler -n prowler
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

| Service | URL |
|---------|-----|
| Console OKD | https://console-openshift-console.apps.sno.okd.lab |
| ArgoCD | https://argocd-server-openshift-operators.apps.sno.okd.lab |
| Vault | https://vault.apps.sno.okd.lab |
| Keycloak | https://keycloak.apps.sno.okd.lab |
| Harbor | https://harbor.okd.lab |
| Grafana | https://grafana.apps.sno.okd.lab |
| Prometheus | Console OKD → Observe → Metrics |
| Alertmanager | Console OKD → Observe → Alerting |

> ⚠️ Les credentials sont stockés dans `.env` (non commité) et dans Vault.
> Ne jamais commiter de credentials dans Git.

---

## 📐 Architecture Decision Records

| ADR | Titre | Statut |
|-----|-------|--------|
| [ADR-001](docs/adr/adr-001-okd-vs-openshift.md) | OKD vs Red Hat OpenShift | Accepted |
| [ADR-002](docs/adr/adr-002-fcos-machineconfig.md) | FCOS Immutable OS + MachineConfig | Accepted |
| [ADR-003](docs/adr/adr-003-kyverno.md) | Kyverno Policy Engine | Accepted |
| [ADR-004](docs/adr/adr-004-security-strategy.md) | Stratégie sécurité multi-couches | Accepted |
| [ADR-005](docs/adr/adr-005-kube-bench-prowler.md) | kube-bench + Prowler Compliance | Accepted |
| [ADR-006](docs/adr/adr-006-icsp-airgap.md) | ICSP Airgap Strategy | Accepted |

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
| `OwnNamespace InstallModeType not supported` | Loki Operator mode | OperatorGroup `spec: {}` (AllNamespaces) |
| `prowler executable not found` | Entrypoint = `poetry run prowler` | `command: ["poetry", "run", "prowler", ...]` |
| PVCs Pending `no storage class is set` | StorageClass créée après PVCs | Supprimer PVCs + CR, recréer avec `storageClassName` |
| `Insufficient CPU` LokiStack | SNO lab limité | LokiStack retiré — revisiter avec HyperShift Azure |

---

## 🎓 Compétences démontrées

```
Infrastructure & OS
├── OKD UPI deployment (Agent-based Installer, platform: none) ✅
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
├── Vault policies + roles par namespace ✅
└── vault-bootstrap.sh reproductible ✅

Identity & SSO
├── Keycloak OIDC — OAuth Server OKD ✅
├── Realm + clients + users + RBAC ✅
└── x509 CA fix pour self-signed certs ✅

Container Registry & Supply Chain
├── Harbor 2.11 + MinIO S3 backend ✅
├── Trivy CVE scan automatique ✅
├── Cosign image signing ✅
└── oc-mirror airgap mirroring ✅

Observabilité
├── Prometheus + Alertmanager + Thanos (built-in) ✅
├── Grafana v12 + GrafanaDatasource + GrafanaDashboard ✅
├── Token Prometheus via Vault → ESO (Zero Trust) ✅
└── Dashboard Security Compliance (kube-bench + Prowler) ✅

Compliance
├── kube-bench CIS 1.8 — 36P/36F/58W ✅
├── Prowler CIS 1.10 — 91.56% PASS ✅
└── Rapports HTML/JSON sauvegardés ✅

Airgap
├── oc-mirror ImageSetConfiguration ✅
├── Harbor okd-mirror project (4.62 GiB) ✅
├── ICSP + CatalogSource Harbor ✅
├── Airgap progressif (bastion → Harbor → cluster) ✅
└── local-path-provisioner StorageClass ✅

Sécurité
├── Défense en profondeur 6 couches (ADR-004) ✅
├── SCCs OpenShift (privileged, anyuid) ✅
├── Kyverno policy engine 🔜
└── Falco runtime security 🔜
```

---

## 👤 Auteur

**Z3ROX (Stéphane Seloi)** — Cloud Native Security Architect
CCSP | AWS Solutions Architect | ISO 27001 Lead Implementer | CompTIA Security+
[GitHub](https://github.com/Z3ROX-lab)

---

## 📄 License

MIT — see [LICENSE](LICENSE)
