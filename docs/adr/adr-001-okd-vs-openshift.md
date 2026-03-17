# ADR-001 — Choix OKD vs Red Hat OpenShift Container Platform

## Statut

**Accepted** — Mars 2026

## Contexte

Dans le cadre du projet portfolio `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`,
il a fallu choisir entre OKD (community) et Red Hat OpenShift Container Platform (RHOCP)
comme distribution Kubernetes enterprise pour démontrer les compétences en :

- Cloud Native Security Architecture
- GitOps (ArgoCD)
- Secrets Management (HashiCorp Vault)
- Supply Chain Security (Harbor, Trivy, Cosign)
- Airgap deployment
- Observabilité (Prometheus, Grafana, Loki)

Le cluster tourne sur un GEEKOM A6 (32GB DDR5 RAM) dans un homelab WSL2/VMware Workstation.

---

## Comparaison détaillée

### 1. Origine et relation

```
OKD                                    OpenShift (RHOCP)
┌──────────────────────────┐           ┌──────────────────────────┐
│  Community upstream      │──────────►│  Enterprise downstream   │
│  Kubernetes + extensions │           │  OKD + Red Hat patches   │
│  Fedora CoreOS (FCOS)    │           │  RHCOS (FIPS, hardened)  │
│  quay.io                 │           │  registry.redhat.io      │
│  community-operators     │           │  Red Hat Certified Ops   │
└──────────────────────────┘           └──────────────────────────┘
       ↑ base de                              ↑ certifié
         tout                                  ANSSI/FedRAMP
```

### 2. Images et registries

| Aspect | OKD | OpenShift (RHOCP) |
|--------|-----|-------------------|
| Images release | `quay.io/openshift/okd` | `registry.redhat.io/openshift4` |
| Auth requise | ❌ Publique | ✅ Pull secret Red Hat |
| Operators | `quay.io/operatorhubio/catalog` | `registry.redhat.io/redhat/...` |
| Images OS | FCOS (Fedora) | RHCOS (RHEL-based) |
| Airgap | oc-mirror sans compte | oc-mirror + pull secret Red Hat |

### 3. Système d'exploitation des nœuds

```
OKD — FCOS (Fedora CoreOS)            OpenShift — RHCOS (Red Hat CoreOS)
┌───────────────────────────┐          ┌───────────────────────────┐
│  Fedora base              │          │  RHEL base                │
│  rpm-ostree               │          │  rpm-ostree               │
│  Immutable, atomic        │          │  Immutable, atomic        │
│  Updates via MachineConfig│          │  Updates via MachineConfig│
│  FIPS optionnel           │          │  FIPS certifié NSA        │
│  Pas de support Red Hat   │          │  Support Red Hat inclus   │
└───────────────────────────┘          └───────────────────────────┘
```

### 4. Operators et catalogue

```
OKD — community-operators              OpenShift — Red Hat Certified
┌───────────────────────────┐          ┌───────────────────────────┐
│  282 operators community  │          │  500+ operators certifiés │
│  Qualité variable         │          │  Testés Red Hat           │
│  Pas de SLA               │          │  CVE patchés par Red Hat  │
│  ArgoCD community         │          │  OpenShift GitOps (ArgoCD)│
│  Keycloak community       │          │  Red Hat SSO (Keycloak)   │
│  ESO community            │          │  ESO Red Hat (GA 4.20+)   │
│  Grafana community        │          │  Grafana Red Hat          │
│  Loki community           │          │  Loki Red Hat             │
└───────────────────────────┘          └───────────────────────────┘
```

### 5. Conformité et certifications

| Critère | OKD | OpenShift (RHOCP) |
|---------|-----|-------------------|
| FIPS 140-2 | ❌ | ✅ |
| FedRAMP | ❌ | ✅ (RHOCP 4.x) |
| ANSSI/SecNumCloud | ❌ | En cours (RHOCP) |
| CC EAL | ❌ | ✅ |
| CVE SLA | ❌ | ✅ 48h Critical |
| Support 24/7 | ❌ | ✅ |

### 6. Coût

| Scenario | OKD | OpenShift (RHOCP) |
|----------|-----|-------------------|
| Homelab/Dev | **Gratuit** | ~10 000€/an (Developer Sandbox gratuit) |
| Production 3 nœuds | **Gratuit** | ~30 000-50 000€/an |
| SNO production | **Gratuit** | ~15 000€/an |
| Support inclus | ❌ | ✅ |

---

## Décision

**OKD a été choisi** pour ce projet portfolio.

---

## Justifications

### 1. Coût — facteur déterminant pour un homelab

Un projet portfolio nécessite un environnement réaliste mais sans budget enterprise.
OKD offre **100% des fonctionnalités** nécessaires pour démontrer les compétences
visées (GitOps, secrets, supply chain, airgap, observabilité) sans coût de licence.

### 2. Équivalence technique pour le portfolio

Les patterns démontrés sont identiques en OKD et OpenShift :

```
OKD lab                          OpenShift prod
─────────────────────────────    ─────────────────────────────
ArgoCD community operator    ≡   Red Hat OpenShift GitOps
Keycloak community           ≡   Red Hat SSO
ESO community                ≡   Red Hat ESO (GA 4.20+)
FCOS immutable nodes         ≡   RHCOS immutable nodes
MachineConfig operator       ≡   MachineConfig operator (identique)
oc CLI                       ≡   oc CLI (identique)
CRDs, RBAC, SCCs             ≡   CRDs, RBAC, SCCs (identiques)
```

Un recruteur ou client qui voit `oc adm`, `MachineConfig`, `SCC`,
`ClusterOperator` dans un portfolio OKD reconnaît immédiatement
les compétences OpenShift enterprise.

### 3. Airgap — OKD plus simple sans compte Red Hat

En environnement airgap, OpenShift nécessite :
- Un pull secret Red Hat (compte payant)
- `registry.redhat.io` pour les images de base
- Un abonnement actif pour oc-mirror

OKD utilise `quay.io` avec des images **publiques** — le mirror
airgap fonctionne sans aucun compte, ce qui simplifie la démonstration
du pattern airgap dans ce projet.

### 4. Upstream = connaissance de la roadmap

OKD est l'upstream d'OpenShift. Les fonctionnalités apparaissent
dans OKD 3-6 mois avant OpenShift. Travailler sur OKD donne une
vision anticipée de la roadmap OpenShift enterprise.

### 5. Community operators — plus de liberté

Les operators community (ArgoCD v0.17, Keycloak v26, ESO) sont
parfois **plus récents** que les versions Red Hat certifiées.
Pour un projet portfolio démontrant les dernières pratiques,
c'est un avantage.

---

## Conséquences

### Positives
- Aucun coût de licence
- Déploiement immédiat sans compte Red Hat
- Airgap simplifié (images publiques quay.io)
- Operators community souvent plus récents
- Démontre la compréhension de l'écosystème OpenShift

### Négatives et mitigations

| Conséquence | Mitigation |
|-------------|------------|
| Pas de FIPS certifié | Démontré via config explicite dans values.yaml |
| Pas de support Red Hat | Environnement lab — acceptable |
| CVE non patchés par Red Hat | Trivy + Kyverno pour démontrer la détection |
| ESO Red Hat GA seulement OCP 4.20+ | ESO community v0.11 utilisé — même API |
| ANSSI/SecNumCloud non certifié | Pattern SecNumCloud documenté dans ADR |

### En contexte enterprise réel

Dans une mission grands comptes, le choix serait OpenShift RHOCP pour :
- La certification FIPS/FedRAMP/ANSSI
- Le support Red Hat 24/7
- Les CVE patchés avec SLA
- L'intégration Red Hat ACM, ACS, Quay Enterprise

**Les compétences démontrées dans ce projet sont directement transférables.**
La différence opérationnelle est mineure — principalement le pull secret
et le catalogue d'operators certifiés.

---

## Alternatives considérées

| Alternative | Raison du rejet |
|-------------|-----------------|
| OpenShift RHOCP | Coût prohibitif pour homelab (~30k€/an) |
| Rancher/RKE2 | Moins représentatif du contexte clients télécoms/défense |
| Vanilla Kubernetes (K3s, K8s) | Manque les APIs OpenShift (Route, SCC, MachineConfig) |
| OpenShift Developer Sandbox | Environnement partagé, pas de contrôle total, pas d'airgap |
| MicroShift | Trop limité — conçu pour edge, pas pour démo enterprise |

---

## Références

- [OKD Documentation](https://docs.okd.io)
- [OpenShift vs OKD FAQ](https://www.okd.io/faq/)
- [Red Hat OpenShift Pricing](https://www.redhat.com/en/technologies/cloud-computing/openshift/pricing)
- [FCOS vs RHCOS](https://docs.fedoraproject.org/en-US/fedora-coreos/faq/)
- [ESO Red Hat GA Announcement](https://developers.redhat.com/articles/2025/11/11/introducing-external-secrets-operator-openshift)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*ADR-001 — OKD vs OpenShift — Mars 2026*
