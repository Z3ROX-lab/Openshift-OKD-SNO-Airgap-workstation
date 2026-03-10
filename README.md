# OKD Single Node OpenShift — Airgap Lab on VMware Workstation

> **Portfolio project** — Demonstrates end-to-end OpenShift/OKD expertise for on-premise, airgap, and IaC-driven enterprise deployments.

[![OKD](https://img.shields.io/badge/OKD-4.17.0--okd--scos.0-red?logo=redhat)](https://www.okd.io/)
[![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-orange?logo=argo)](https://argoproj.github.io/cd/)
[![Vault](https://img.shields.io/badge/Secrets-HashiCorp%20Vault-black?logo=vault)](https://www.vaultproject.io/)
[![Keycloak](https://img.shields.io/badge/SSO-Keycloak-blue?logo=keycloak)](https://www.keycloak.org/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 🎯 Objectives

This lab provisions a **fully airgap-capable Single Node OpenShift (SNO)** cluster on VMware Workstation using the **Agent-based Installer** (UPI, no vCenter API required).

The project covers the full stack required for **enterprise Kubernetes/OpenShift missions** (on-premise, grands comptes, défense, telecom) :

| Domain | Tools |
|--------|-------|
| Cluster provisioning | OKD 4.17, Agent-based Installer, SCOS |
| Load Balancing | HAProxy (API + Ingress) |
| Airgap | `oc-mirror`, Mirror Registry, ImageSetConfig |
| Operator lifecycle | OperatorHub (airgap mode), CatalogSource, OLM |
| Identity & SSO | Keycloak, OAuth Server OCP → Keycloak OIDC |
| GitOps | ArgoCD (OpenShift GitOps Operator), ApplicationSets |
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
│  │                  Ubuntu WSL2                       │   │
│  │                                                    │   │
│  │  /etc/hosts       HAProxy            oc-mirror     │   │
│  │  *.okd.lab   :6443 (API)        mirror registry    │   │
│  │  → .10       :22623 (MCS)       (airgap images)    │   │
│  │              :80   (HTTP)                          │   │
│  │              :443  (HTTPS)                         │   │
│  └───────────────────┬────────────────────────────────┘   │
│                      │ VMnet8 NAT (192.168.241.0/24)       │
│  ┌───────────────────▼────────────────────────────────┐   │
│  │           OKD SNO VM — 192.168.241.10              │   │
│  │         SCOS │ vCPU: 8 │ RAM: 24G │ Disk: 120G    │   │
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
1. `*.apps.sno.okd.lab` → `/etc/hosts` résout vers `192.168.241.10`
2. HAProxy WSL forward le trafic `:80`/`:443` vers la VM SNO
3. OpenShift Ingress Controller dispatche vers le bon pod via les `Route` objects
4. Chaque service = 1 `Route` OKD — aucune modif HAProxy nécessaire

**Network mode :** VMnet8 (NAT) — cluster accessible depuis l'hôte uniquement  
**Airgap simulation :** réseau VM coupé post-install, toutes les images via mirror registry local

---

## 📋 Prerequisites

### Host (Windows + WSL2 Ubuntu)
- VMware Workstation Pro 17+
- RAM : 32 Go minimum (24 Go alloués à la VM SNO)
- Disk : 120 Go disponibles sur D:\ (thin provisioning)
- `openshift-install` binary (OKD 4.17.0-okd-scos.0)
- `oc` CLI
- `oc-mirror` plugin
- HAProxy (load balancer — API + Ingress)

### ⚠️ Notes spécifiques VMware Workstation + WSL2

| Problème | Solution retenue |
|----------|-----------------|
| IP VM aléatoire à chaque boot | Réservation DHCP dans `C:\ProgramData\VMware\vmnetdhcp.conf` |
| `nmstatectl` cassé dans WSL2 | Ne pas utiliser `networkConfig` dans `agent-config.yaml` |
| DNS `*.okd.lab` non résolu | `/etc/hosts` (plus robuste que dnsmasq avec Tailscale) |
| Bug socket PostgreSQL dans le container assisted-service-db | Script wrapper Podman avec `--tmpfs /var/run/postgresql` |

### Réservation DHCP VMware (obligatoire)

Dans `C:\ProgramData\VMware\vmnetdhcp.conf`, ajouter avant le dernier `# End` :

```
host okd-sno-master {
    hardware ethernet 00:50:56:27:c8:0b;
    fixed-address 192.168.241.10;
}
```

Puis depuis PowerShell admin : `Restart-Service VMnetDHCP`

### DNS entries (`/etc/hosts` WSL2 + Windows)

```
192.168.241.10  api.sno.okd.lab api-int.sno.okd.lab
192.168.241.10  console-openshift-console.apps.sno.okd.lab
192.168.241.10  oauth-openshift.apps.sno.okd.lab
```

> Windows hosts file : `C:\Windows\System32\drivers\etc\hosts`  
> WSL2 hosts file : `/etc/hosts`

---

## 🚀 Phases du projet

### Phase 1 — SNO Bootstrap ✅ COMPLETE
> Provisionner le cluster OKD SNO via Agent-based Installer

- [x] Génération `install-config.yaml` + `agent-config.yaml`
- [x] Réservation DHCP VMware (`vmnetdhcp.conf`) — IP statique sans nmstate
- [x] Configuration DNS via `/etc/hosts`
- [x] Création de l'ISO avec `openshift-install agent create image`
- [x] Création VM VMware Workstation (UEFI, vmxnet3, 8vCPU/24GB/120GB)
- [x] Fix PostgreSQL container (assisted-service-db — socket `/var/run/postgresql`)
- [x] Boot ISO + bootstrap cluster
- [x] Validation cluster (`oc get nodes`, console web)

→ [Guide d'installation complet](docs/guide-installation-okd-sno.md)

### Phase 2 — Identity, SSO & Secrets 🔜
> Keycloak SSO unifié + HashiCorp Vault + CI/CD GitLab/Kaniko

**Phase 2a — Keycloak**
- [ ] Déploiement Keycloak via OperatorHub
- [ ] Realm `okd` + Clients (openshift, argocd, vault, gitlab, grafana)
- [ ] Groupes Keycloak → ClusterRoleBinding OCP (cluster-admins, developers, viewers)

**Phase 2b — OAuth Server OCP → Keycloak OIDC**
- [ ] Configuration OAuth CR (`config.openshift.io/v1`)
- [ ] SSO unifié : Console OCP + oc CLI via Keycloak
- [ ] Test login console avec user Keycloak

**Phase 2c — HashiCorp Vault**
- [ ] Déploiement Vault via OperatorHub
- [ ] Vault Agent Injector configuration
- [ ] Auth Kubernetes → Vault (pods s'authentifient via ServiceAccount)

**Phase 2d — CI/CD GitLab + Kaniko**
- [ ] GitLab Runner sur OKD (Kubernetes executor)
- [ ] Pipeline Kaniko (build images sans Docker daemon)
- [ ] Intégration Trivy + Grype + Syft dans la CI
- [ ] ArgoCD sync depuis GitLab

→ [Documentation Phase 2](docs/phase2-identity-sso-secrets.md)

### Phase 3 — Airgap Simulation 🔜
> Reproduire un environnement déconnecté grands comptes (défense, banque, télécom)

- [ ] Mirror registry local (Harbor)
- [ ] `oc-mirror` ImageSetConfig pour OKD + operators
- [ ] Reconfiguration OperatorHub → `disableAllDefaultSources: true`
- [ ] CatalogSource custom pointant vers le mirror registry
- [ ] Coupure réseau VM (VMnet8 NAT → VMnet1 Host-only)
- [ ] Validation cluster + OperatorHub en mode airgap
- [ ] Mise à jour cluster en mode airgap

→ [Documentation Phase 3](docs/phase3-airgap.md)

### Phase 4 — Security & Scanning 🔜
> Checkov, Kyverno, Falco, supply chain security

- [ ] Checkov dans les pipelines Terraform et manifests
- [ ] Kyverno policies (enforce mode)
- [ ] Falco runtime security rules
- [ ] SBOM generation avec Syft

→ [Documentation Phase 4](docs/phase4-security.md)

### Phase 5 — Portfolio & Demo 🔜
> Documentation, screenshots, vidéo démo

- [ ] Architecture diagrams
- [ ] Demo script
- [ ] Vidéo walkthrough (screencast sans caméra)

→ [Documentation Phase 5](docs/phase5-demo.md)

---

## 📁 Repository Structure

```
.
├── install/
│   ├── install-config.yaml         # Config cluster (originaux — ne pas supprimer)
│   └── agent-config.yaml           # Config nœud — interface ens160, MAC statique
├── scripts/
│   ├── fix-assisted-db.sh          # Fix bug PostgreSQL socket (OKD 4.17 SNO)
│   ├── setup-dns-okd.sh            # (legacy) Setup dnsmasq
│   └── restore-dns-default.sh      # (legacy) Restore DNS WSL2
├── haproxy/
│   ├── haproxy.cfg                 # HAProxy config (API :6443, Ingress :80/:443)
│   └── haproxy-setup.md
├── airgap/
│   ├── mirror-registry/            # Harbor / mirror-registry setup
│   └── imagesets/                  # oc-mirror ImageSetConfig files
├── gitops/
│   ├── argocd/                     # ArgoCD install + AppProjects
│   └── applications/               # ApplicationSets
├── vault/                          # HashiCorp Vault Helm + policies
├── ci-cd/
│   ├── gitlab/                     # GitLab Runner manifests
│   ├── kaniko/                     # Kaniko pipeline examples
│   └── scanners/                   # Trivy, Grype, Syft, Checkov configs
├── security/
│   ├── kyverno/                    # Kyverno ClusterPolicies
│   └── falco/                      # Falco custom rules
└── docs/
    ├── guide-installation-okd-sno.md   # Guide Phase 1 complet avec troubleshooting
    ├── phase2-identity-sso-secrets.md
    ├── phase3-airgap.md
    ├── phase4-security.md
    ├── phase5-demo.md
    └── screenshots/                # Captures d'écran installation
        ├── iso-generated.png
        ├── vm-cdrom-iso.png
        ├── boot-rendezvous-host.png
        ├── bootstrap-bootkube-progress.png
        ├── install-progress-console.png
        ├── install-progress-wsl.png
        └── wait-for-bootkube.png
```

---

## 🔧 Key Lessons Learned (Phase 1)

Issues encountered during real installation on VMware Workstation + WSL2 — not documented in official OKD guides :

**1. nmstate incompatible avec WSL2**  
`networkConfig` dans `agent-config.yaml` requiert `nmstatectl` + NetworkManager. NetworkManager n'est pas disponible dans WSL2 → `openshift-install agent create image` échoue. Solution : IP statique via réservation DHCP VMware.

**2. Interface réseau `ens160` pas `ens33`**  
Les VMs VMware Workstation avec adaptateur `vmxnet3` utilisent `ens160`, pas `ens33` comme dans les templates génériques. Une mauvaise interface dans `agent-config.yaml` = DHCP sur la mauvaise interface = IP aléatoire = cluster qui ne se reconnaît pas comme rendezvous host.

**3. Bug PostgreSQL dans assisted-service-db**  
Le container PostgreSQL d'assisted-service démarre avec `--user=postgres` mais le répertoire `/var/run/postgresql/` n'existe pas dans le container. `pg_ctl` ne peut pas créer le lock file → crash. Fix : `--tmpfs /var/run/postgresql:rw,mode=0777` via un script wrapper Podman. Voir `scripts/fix-assisted-db.sh`.

**4. dnsmasq vs /etc/hosts avec Tailscale**  
dnsmasq + Tailscale + WSL2 crée des conflits complexes (port 53, forwarding, `accept-dns`). La solution la plus robuste et maintenable est `/etc/hosts` — priorité absolue sur tout DNS, Tailscale ne le touche pas.

---

## 🎓 Skills Demonstrated

This project directly addresses the skill requirements of **Expert Kubernetes/OpenShift** missions (on-premise, grands comptes) :

- ✅ OpenShift UPI deployment (`platform: none`, Agent-based Installer)
- ✅ SCOS (CentOS Stream CoreOS) bare-metal provisioning via Ignition
- ✅ VMware Workstation airgap-ready lab setup
- ✅ Load balancing with HAProxy (L4 — API + Ingress)
- ✅ Airgap cluster operations (`oc-mirror`, disconnected operators)
- ✅ OperatorHub in airgap mode (CatalogSource, OLM, mirror registry)
- ✅ SSO with Keycloak — OAuth Server OCP → Keycloak OIDC (Console + oc CLI)
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
