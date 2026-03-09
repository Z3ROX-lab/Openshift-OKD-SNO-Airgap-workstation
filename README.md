# OKD Single Node OpenShift — Airgap Lab on VMware Workstation

> **Portfolio project** — Demonstrates end-to-end OpenShift/OKD expertise for on-premise, airgap, and IaC-driven enterprise deployments.

[![OKD](https://img.shields.io/badge/OKD-4.17-red?logo=redhat)](https://www.okd.io/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-purple?logo=terraform)](https://www.terraform.io/)
[![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-orange?logo=argo)](https://argoproj.github.io/cd/)
[![Vault](https://img.shields.io/badge/Secrets-HashiCorp%20Vault-black?logo=vault)](https://www.vaultproject.io/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 🎯 Objectives

This lab provisions a **fully airgap-capable Single Node OpenShift (SNO)** cluster on VMware Workstation using the **Agent-based Installer** (UPI, no vCenter API required).

The project covers the full stack required for **enterprise Kubernetes/OpenShift missions** (on-premise, grands comptes, défense, telecom) :

| Domain | Tools |
|--------|-------|
| Cluster provisioning | OKD 4.17, Agent-based Installer, FCOS |
| Load Balancing | HAProxy (API + Ingress) |
| IaC | Terraform (`platform: none`) |
| Airgap | `oc-mirror`, Mirror Registry, ImageSetConfig |
| GitOps | ArgoCD, ApplicationSets |
| Secrets management | HashiCorp Vault, Vault Agent Injector |
| CI/CD | GitLab CI, Kaniko, GitLab Runners |
| Container security | Trivy, Grype, Syft, Checkov, Falco |
| Policy enforcement | Kyverno |
| Storage | MinIO (S3-compatible CSI) |
| Observability | Prometheus, Grafana, Loki |

---

## 🏗️ Architecture

```
  Browser / oc CLI
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│                  Windows Host (GEEKOM A6)                  │
│                                                           │
│  ┌────────────────────────────────────────────────────┐   │
│  │                  Ubuntu WSL                        │   │
│  │                                                    │   │
│  │  dnsmasq          HAProxy            oc-mirror     │   │
│  │  *.okd.lab   :6443 (API)        mirror registry    │   │
│  │  → SNO IP    :22623 (MCS)       (airgap images)    │   │
│  │              :80   (HTTP)                          │   │
│  │              :443  (HTTPS)                         │   │
│  └───────────────────┬────────────────────────────────┘   │
│                      │ VMnet8 NAT (192.168.100.0/24)       │
│  ┌───────────────────▼────────────────────────────────┐   │
│  │           OKD SNO VM — 192.168.100.10              │   │
│  │           FCOS │ vCPU: 8 │ RAM: 24G │ Disk: 120G  │   │
│  │                                                    │   │
│  │   ┌──────────────────────────────────────────┐    │   │
│  │   │       OpenShift Ingress Controller        │    │   │
│  │   │  (HAProxy interne — Router OKD natif)     │    │   │
│  │   └──┬──────────┬──────────┬──────────┬───────┘    │   │
│  │      │          │          │          │            │   │
│  │      ▼          ▼          ▼          ▼            │   │
│  │  console    argocd      vault      gitlab          │   │
│  │  .apps.*    .apps.*    .apps.*    .apps.*          │   │
│  │                                                    │   │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────────────┐    │   │
│  │  │  Kyverno │ │  Falco  │ │ Mirror Registry   │    │   │
│  │  │  Trivy   │ │  Grype  │ │ (airgap — Harbor) │    │   │
│  │  │  Checkov │ │  Syft   │ └──────────────────┘    │   │
│  │  └──────────┘ └─────────┘                         │   │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────────────┐    │   │
│  │  │  MinIO   │ │  Loki   │ │    Prometheus     │    │   │
│  │  │  (S3)    │ │         │ │    + Grafana       │    │   │
│  │  └──────────┘ └─────────┘ └──────────────────┘    │   │
│  └────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────┘
```

**Flux réseau :**
1. `*.apps.sno.okd.lab` → dnsmasq résout vers `192.168.100.10`
2. HAProxy WSL forward le trafic `:80`/`:443` vers la VM SNO
3. OpenShift Ingress Controller dispatche vers le bon pod via les `Route` objects
4. Chaque service = 1 `Route` OKD — aucune modif HAProxy nécessaire

**Network mode :** VMnet8 (NAT) — cluster accessible depuis l'hôte uniquement  
**Airgap simulation :** réseau VM coupé post-install, toutes les images via mirror registry local

---

## 📋 Prerequisites

### Host (Windows/Linux with VMware Workstation Pro)
- VMware Workstation Pro 17+
- RAM : 32 Go minimum (24 Go alloués à la VM)
- Disk : 135 Go disponibles (thin provisioning)
- `openshift-install` binary (OKD 4.17)
- `oc` CLI
- `oc-mirror` plugin
- Terraform >= 1.6
- HAProxy (load balancer — API + Ingress)
- dnsmasq (résolution DNS locale)

### DNS entries à ajouter (`/etc/hosts` ou dnsmasq)
```
192.168.x.x  api.sno.okd.lab
192.168.x.x  api-int.sno.okd.lab
192.168.x.x  *.apps.sno.okd.lab
192.168.x.x  mirror.sno.okd.lab
```

---

## 🚀 Phases du projet

### Phase 1 — SNO Bootstrap ✅
> Provisionner le cluster OKD SNO via Agent-based Installer

- [ ] Génération `install-config.yaml` + `agent-config.yaml`
- [ ] Configuration HAProxy sur l'hôte WSL
- [ ] Configuration dnsmasq sur l'hôte WSL
- [ ] Création de l'ISO avec `openshift-install`
- [ ] Création VM VMware Workstation + boot ISO
- [ ] Validation cluster (`oc get nodes`, console web)

→ [Documentation Phase 1](docs/phase1-bootstrap.md)

### Phase 2 — HashiCorp Vault + CI/CD
> Secrets management enterprise + pipeline GitLab/Kaniko

- [ ] Déploiement Vault (dev mode → prod mode)
- [ ] Vault Agent Injector configuration
- [ ] GitLab Runner sur OKD
- [ ] Pipeline Kaniko (build images sans Docker daemon)
- [ ] Intégration Trivy + Grype + Syft dans la CI

→ [Documentation Phase 2](docs/phase2-vault-cicd.md)

### Phase 3 — Airgap Simulation
> Reproduire un environnement déconnecté grands comptes

- [ ] Mirror registry local (Harbor ou `mirror-registry`)
- [ ] `oc-mirror` ImageSetConfig pour OKD + operators
- [ ] Coupure réseau VM + validation cluster airgap
- [ ] Mise à jour cluster en mode airgap

→ [Documentation Phase 3](docs/phase3-airgap.md)

### Phase 4 — Security & Scanning
> Checkov, Kyverno, Falco, supply chain security

- [ ] Checkov dans les pipelines Terraform et manifests
- [ ] Kyverno policies (enforce mode)
- [ ] Falco runtime security rules
- [ ] SBOM generation avec Syft

→ [Documentation Phase 4](docs/phase4-security.md)

### Phase 5 — Portfolio & Demo
> Documentation, screenshots, vidéo démo

- [ ] Architecture diagrams
- [ ] Demo script
- [ ] Vidéo walkthrough

→ [Documentation Phase 5](docs/phase5-demo.md)

---

## 📁 Repository Structure

```
.
├── install/                    # install-config.yaml + agent-config.yaml
├── haproxy/
│   ├── haproxy.cfg             # HAProxy config (API :6443, Ingress :80/:443)
│   └── haproxy-setup.md        # Installation + test guide
├── terraform/
│   ├── ignition/               # Ignition configs generation
│   ├── dns/                    # dnsmasq configuration
│   └── mirror/                 # Mirror registry Terraform module
├── airgap/
│   ├── mirror-registry/        # Harbor / mirror-registry setup
│   └── imagesets/              # oc-mirror ImageSetConfig files
├── gitops/
│   ├── argocd/                 # ArgoCD install + AppProjects
│   └── applications/           # ApplicationSets
├── vault/                      # HashiCorp Vault Helm + policies
├── ci-cd/
│   ├── gitlab/                 # GitLab Runner manifests
│   ├── kaniko/                 # Kaniko pipeline examples
│   └── scanners/               # Trivy, Grype, Syft, Checkov configs
├── security/
│   ├── kyverno/                # Kyverno ClusterPolicies
│   └── falco/                  # Falco custom rules
└── docs/                       # Documentation par phase
```

---

## 🎓 Skills Demonstrated

This project directly addresses the skill requirements of **Expert Kubernetes/OpenShift** missions (on-premise, grands comptes) :

- ✅ OpenShift UPI deployment (`platform: none`, Agent-based)
- ✅ Load balancing with HAProxy (L4 — API + Ingress)
- ✅ Airgap cluster operations (`oc-mirror`, disconnected operators)
- ✅ GitOps with ArgoCD
- ✅ Secrets management with HashiCorp Vault
- ✅ Container image build with Kaniko (daemonless)
- ✅ Supply chain security (Trivy, Grype, Syft, SBOM)
- ✅ IaC scanning with Checkov
- ✅ Runtime security with Falco
- ✅ Policy enforcement with Kyverno
- ✅ CSI storage with MinIO

---

## 👤 Author

**Z3ROX** — Lead SecOps / Cloud Security Architect  
CCSP | AWS Solutions Architect | ISO 27001 Lead Implementer  
[GitHub](https://github.com/Z3ROX-lab) | [LinkedIn](#)

---

## 📄 License

MIT — see [LICENSE](LICENSE)
