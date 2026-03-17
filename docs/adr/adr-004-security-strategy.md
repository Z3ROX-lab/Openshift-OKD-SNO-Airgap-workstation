# ADR-004 — Stratégie de sécurité multi-couches OpenShift/OKD

## Statut

**Accepted** — Mars 2026

## Contexte

Sécuriser un cluster OpenShift/OKD en production nécessite une approche
**défense en profondeur** — plusieurs couches de sécurité complémentaires,
chacune avec un périmètre précis. Une seule couche ne suffit jamais.

Ce document décrit la stratégie retenue pour ce projet et la compare
aux approches utilisées en contexte enterprise grands comptes.

---

## Modèle de menace

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SURFACES D'ATTAQUE KUBERNETES                    │
│                                                                     │
│  EXTERNE                                                            │
│  ├── API Server exposé               → RBAC + OAuth + NetworkPolicy │
│  ├── Ingress / Routes                → TLS + WAF                   │
│  └── Registry images                 → Harbor + Cosign + Trivy      │
│                                                                     │
│  INTERNE (lateral movement)                                         │
│  ├── Pod compromis → API Server      → RBAC minimal + SA tokens    │
│  ├── Pod compromis → autres pods     → NetworkPolicy               │
│  ├── Pod compromis → OS du nœud      → SCCs + seccompProfile       │
│  └── Pod compromis → secrets         → Vault + ESO                 │
│                                                                     │
│  SUPPLY CHAIN                                                       │
│  ├── Image malveillante déployée     → Cosign + Kyverno VERIFY     │
│  ├── CVE dans une image              → Trivy + Harbor              │
│  └── Dépendance compromise           → SBOM + Trivy                │
│                                                                     │
│  CONFIGURATION DRIFT                                                │
│  ├── Config non conforme déployée    → Kyverno VALIDATE            │
│  ├── Namespace sans NetworkPolicy    → Kyverno GENERATE            │
│  └── OS nœud modifié                → FCOS immutable + MachineConfig│
└─────────────────────────────────────────────────────────────────────┘
```

---

## Architecture défense en profondeur

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   DÉFENSE EN PROFONDEUR — 6 COUCHES                     │
└─────────────────────────────────────────────────────────────────────────┘

COUCHE 1 — Infrastructure & OS
┌─────────────────────────────────────────────────────────────────────────┐
│  FCOS (Fedora CoreOS) immutable                                         │
│  ├── Filesystem read-only → pas de modification manuelle               │
│  ├── Pas de package manager → pas d'installation non autorisée         │
│  ├── MachineConfig → seule façon déclarative de modifier l'OS          │
│  ├── FIPS optional → conformité cryptographique nationale              │
│  └── OSTree atomic updates → rollback si échec                         │
└─────────────────────────────────────────────────────────────────────────┘

COUCHE 2 — Kubernetes natif
┌─────────────────────────────────────────────────────────────────────────┐
│  RBAC (Role-Based Access Control)                                       │
│  ├── Principle of least privilege → chaque SA avec droits minimaux     │
│  ├── ClusterRole vs Role → scope cluster vs namespace                  │
│  └── Audit log → toutes les actions API tracées                        │
│                                                                         │
│  NetworkPolicy (OVN-Kubernetes)                                         │
│  ├── Default deny all → aucune communication par défaut                │
│  ├── Allow explicite → uniquement les flux nécessaires                 │
│  └── Microsegmentation → isolation par namespace/label                 │
│                                                                         │
│  ResourceQuota / LimitRange                                             │
│  ├── CPU/RAM max par namespace → pas de noisy neighbor                 │
│  └── Pas de container sans limits → denial of service impossible       │
└─────────────────────────────────────────────────────────────────────────┘

COUCHE 3 — OpenShift spécifique
┌─────────────────────────────────────────────────────────────────────────┐
│  SCCs (Security Context Constraints)                                    │
│  ├── restricted-v2 → par défaut (UID aléatoire, pas de root)          │
│  ├── anyuid → uniquement pour les apps legacy (Harbor, Vault)          │
│  ├── privileged → jamais en prod (sauf nœuds spéciaux)                │
│  └── custom SCCs → pour les cas intermédiaires                         │
│                                                                         │
│  OAuth / Keycloak (Phase 2a)                                            │
│  ├── OIDC → pas de credentials locaux                                  │
│  ├── Groups → RBAC basé sur groupes Keycloak                           │
│  └── MFA → obligatoire en prod                                         │
│                                                                         │
│  OVN-Kubernetes (SDN)                                                   │
│  ├── NetworkPolicy enforcement                                          │
│  ├── EgressNetworkPolicy → contrôle du trafic sortant                  │
│  └── AdminNetworkPolicy → policies cluster-wide (OKD 4.14+)            │
└─────────────────────────────────────────────────────────────────────────┘

COUCHE 4 — Policy Engine (Admission Control)
┌─────────────────────────────────────────────────────────────────────────┐
│  Kyverno (ce projet) / Red Hat ACS (enterprise)                         │
│                                                                         │
│  VALIDATE                                                               │
│  ├── Interdire containers privileged                                   │
│  ├── Interdire hostNetwork/hostPID/hostIPC                             │
│  ├── Exiger runAsNonRoot                                               │
│  ├── Exiger resource limits                                            │
│  ├── Interdire tag :latest                                             │
│  └── Autoriser uniquement harbor.okd.lab                               │
│                                                                         │
│  MUTATE                                                                 │
│  ├── Injecter securityContext par défaut                               │
│  └── Ajouter labels obligatoires manquants                             │
│                                                                         │
│  GENERATE                                                               │
│  ├── NetworkPolicy default-deny → chaque namespace                     │
│  ├── ResourceQuota → chaque namespace                                  │
│  └── Pull secret Harbor → chaque namespace                             │
│                                                                         │
│  VERIFY                                                                 │
│  └── Signature Cosign obligatoire → harbor.okd.lab/*                  │
└─────────────────────────────────────────────────────────────────────────┘

COUCHE 5 — Runtime Security
┌─────────────────────────────────────────────────────────────────────────┐
│  Falco (ce projet) / Red Hat ACS Runtime (enterprise)                   │
│  ├── Détection comportement anormal au runtime                         │
│  ├── Alertes : shell dans container, accès /etc/passwd, etc.           │
│  ├── Intégration Loki/Grafana → dashboard sécurité                    │
│  └── Règles custom pour l'environnement                                │
└─────────────────────────────────────────────────────────────────────────┘

COUCHE 6 — Supply Chain Security
┌─────────────────────────────────────────────────────────────────────────┐
│  Harbor + Trivy + Cosign + Kyverno VERIFY                               │
│                                                                         │
│  Dev pousse une image                                                   │
│      ↓                                                                  │
│  Harbor reçoit → Trivy scan CVE automatique                            │
│      ↓                                                                  │
│  CI/CD signe avec Cosign si scan OK                                    │
│      ↓                                                                  │
│  Kyverno VERIFY vérifie signature avant déploiement                    │
│      ↓                                                                  │
│  Pod déployé uniquement si image signée + scannée ✅                   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Comparaison des outils par couche

### Couche 4 — Policy Engine

| Critère | Kyverno | OPA/Gatekeeper | Red Hat ACS | PSA (built-in) |
|---------|---------|----------------|-------------|----------------|
| Langage | YAML/CEL | Rego | UI + YAML | Kubernetes natif |
| VALIDATE | ✅ | ✅ | ✅ | ✅ (limité) |
| MUTATE | ✅ | ✅ | ❌ | ❌ |
| GENERATE | ✅ | ❌ | ❌ | ❌ |
| VERIFY images | ✅ | ❌ | ✅ | ❌ |
| GitOps natif | ✅ | ✅ | ⚠️ | ✅ |
| Rapports audit | ✅ PolicyReport | ✅ | ✅ Dashboards | ❌ |
| Courbe apprentissage | Faible | Élevée | Faible (UI) | Très faible |
| Coût | Gratuit | Gratuit | Payant (~Red Hat) | Gratuit |
| Support enterprise | CNCF | CNCF | Red Hat 24/7 | Red Hat |
| Runtime security | ❌ | ❌ | ✅ | ❌ |
| Network visualization | ❌ | ❌ | ✅ | ❌ |

### Couche 5 — Runtime Security

| Critère | Falco | Red Hat ACS Runtime | Sysdig |
|---------|-------|---------------------|--------|
| Détection comportement | ✅ | ✅ | ✅ |
| Règles custom | ✅ | ✅ | ✅ |
| Intégration Loki/Grafana | ✅ | ⚠️ | ⚠️ |
| Alertes temps réel | ✅ | ✅ | ✅ |
| Coût | Gratuit | Payant | Payant |
| CNCF | ✅ Graduated | ❌ | ❌ |

---

## Stack retenu dans ce projet

```
Ce projet (homelab portfolio)         Enterprise grands comptes
──────────────────────────────        ──────────────────────────────
FCOS immutable          ✅            RHCOS immutable        ✅
MachineConfig           ✅            MachineConfig          ✅
RBAC minimal            ✅            RBAC + PAM             ✅
NetworkPolicy           ✅            NetworkPolicy + ACS    ✅
SCCs custom             ✅            SCCs + ACS             ✅
Keycloak SSO            ✅            Red Hat SSO / LDAP     ✅
Kyverno                 ✅            Kyverno + Red Hat ACS  ✅
Falco                   ✅ (Phase 4)  ACS Runtime            ✅
Harbor + Trivy          ✅            Quay Enterprise + ACS  ✅
Cosign + Kyverno VERIFY ✅ (Phase 4)  ACS image signing      ✅
Vault + ESO             ✅            Vault Enterprise / ACS ✅
Loki (logs)             ✅ (Phase 3)  Splunk / Elastic       ✅
Grafana (dashboards)    ✅ (Phase 3)  Grafana / Datadog      ✅
```

---

## Mapping frameworks de conformité

```
Framework      Couche principale      Outils dans ce projet
────────────   ───────────────────    ─────────────────────────────
CIS Benchmark  2 + 3 + 4             RBAC + SCCs + Kyverno
NIST 800-53    1 + 2 + 3 + 4 + 5    Toutes couches
PCI-DSS        2 + 4 + 6            NetworkPolicy + Kyverno + Trivy
ANSSI/SecNumCloud 1 + 2 + 3         FCOS FIPS + SCCs + RBAC
NIS2           4 + 5 + 6            Kyverno + Falco + Supply chain
DORA           5 + 6                Falco + Trivy + Cosign
EU AI Act      4 + 6                Kyverno + SBOM
```

---

## Décision

**Stack défense en profondeur retenu** :

```
FCOS + MachineConfig           → Couche 1 (OS)
RBAC + NetworkPolicy + Quotas  → Couche 2 (K8s natif)
SCCs + Keycloak + OVN          → Couche 3 (OpenShift)
Kyverno                        → Couche 4 (Policy engine)
Falco                          → Couche 5 (Runtime)
Harbor + Trivy + Cosign        → Couche 6 (Supply chain)
Vault + ESO                    → Secrets management transversal
Loki + Grafana + Prometheus    → Observabilité transversale
```

### Justifications

1. **Défense en profondeur** — si une couche est compromise, les autres tiennent
2. **GitOps** — toutes les policies en Git, déployées par ArgoCD
3. **Open source** — stack 100% gratuit, compétences transférables
4. **Representatif** — équivalent fonctionnel du stack enterprise Red Hat
5. **CNCF** — Kyverno + Falco + Cosign sont des projets CNCF Graduated

---

## Ce que ce stack démontre pour le portfolio

```
Niveau Junior         Niveau Senior (ce projet)
──────────────────    ──────────────────────────────────────
RBAC basique          RBAC + SCCs + Keycloak OIDC
NetworkPolicy simple  NetworkPolicy + Kyverno GENERATE auto
Pas de supply chain   Harbor + Trivy + Cosign + Kyverno VERIFY
Secrets en clair      Vault + ESO + GitOps
Pas de runtime sec    Falco + alertes Loki/Grafana
Pas d'observabilité   Prometheus + Grafana + Loki stack complet
Pas de conformité     Mapping CIS/NIST/ANSSI/NIS2
```

---

## Références

- [CNCF Security Whitepaper](https://github.com/cncf/tag-security)
- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)
- [Red Hat ACS](https://www.redhat.com/en/technologies/cloud-computing/openshift/advanced-cluster-security-kubernetes)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [NIST SP 800-190 Container Security](https://csrc.nist.gov/publications/detail/sp/800-190/final)
- [ANSSI Recommandations Kubernetes](https://www.ssi.gouv.fr/guide/recommandations-de-securite-relatives-au-deploiement-de-conteneurs-docker/)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*ADR-004 — Stratégie sécurité multi-couches — Mars 2026*
