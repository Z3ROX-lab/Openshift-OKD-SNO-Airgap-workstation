# Phase 4 — Security & Compliance : Kyverno

> Policy Engine — Supply Chain Security — Cosign Image Verification
> OKD 4.15 SNO — Kyverno v1.12.0
> Mars 2026

---

## Objectifs Phase 4

```
✅ Kyverno v1.12.0 installé via Helm (airgap Harbor)
✅ ClusterPolicy Cosign image signature verification
✅ Background scanning actif
❌ Webhook admission (limitation OKD SNO — voir ci-dessous)
❌ Falco runtime security
❌ GitLab in-cluster
```

---

## Architecture Kyverno

```
╔══════════════════════════════════════════════════════════════════════╗
║              KYVERNO — ARCHITECTURE DÉPLOYÉE                         ║
╚══════════════════════════════════════════════════════════════════════╝

                    Git (manifests/kyverno-policies/)
                           │
                           │ scripts/apply-kyverno-policies.sh
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Namespace: kyverno                                                  │
│                                                                      │
│  ┌─────────────────────┐   ┌──────────────────────────────────────┐ │
│  │ admission-controller│   │  ClusterPolicy                       │ │
│  │ 1/1 Running ✅      │   │  verify-image-signature              │ │
│  │                     │   │  ├── imageReferences:                │ │
│  │ Webhook :9443       │   │  │   harbor.okd.lab/okd-mirror/*     │ │
│  │ → valide à chaque   │   │  ├── mutateDigest: false             │ │
│  │   déploiement Pod   │   │  ├── ignoreTlog: true (airgap)       │ │
│  └─────────────────────┘   │  ├── ignoreSCT: true (airgap)        │ │
│                             │  └── validationFailureAction: Audit  │ │
│  ┌─────────────────────┐   └──────────────────────────────────────┘ │
│  │background-controller│                                            │
│  │ 1/1 Running ✅      │   ┌──────────────────────────────────────┐ │
│  │                     │   │  ConfigMap cosign-public-key         │ │
│  │ Scanne les          │   │  -----BEGIN PUBLIC KEY-----          │ │
│  │ ressources          │   │  MFkwEwYHKoZIzj0CAQY...             │ │
│  │ existantes          │   │  -----END PUBLIC KEY-----            │ │
│  └─────────────────────┘   └──────────────────────────────────────┘ │
│                                                                      │
│  ┌─────────────────────┐   ┌─────────────────────┐                 │
│  │ reports-controller  │   │  cleanup-controller  │                 │
│  │ 1/1 Running ✅      │   │  1/1 Running ✅      │                 │
│  └─────────────────────┘   └─────────────────────┘                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Installation Kyverno via Helm (airgap)

### Pourquoi Helm et non OLM ?

Kyverno n'est pas disponible dans notre catalog Harbor mirrored.
De plus, Kyverno crée des ressources **cluster-level** (ClusterRole, CRD)
incompatibles avec ArgoCD en mode namespaced.

```
Helm direct → installe tout en une commande ✅
OLM         → pas dans le catalog Harbor ❌
ArgoCD      → incompatible namespaced mode pour ClusterRole/CRD ❌
```

### Images mirrorées dans Harbor

```bash
# 7 images pushées dans harbor.okd.lab/okd-mirror/
kyverno/kyverno:v1.12.0
kyverno/kyvernopre:v1.12.0
kyverno/background-controller:v1.12.0
kyverno/cleanup-controller:v1.12.0
kyverno/reports-controller:v1.12.0
kyverno/kyverno-cli:v1.12.0
bitnami/kubectl:1.28.5     ← requis pour cleanup CronJobs
```

### Installation

```bash
# Lancer l'installation
./scripts/install-kyverno.sh

# Équivalent :
helm upgrade --install kyverno kyverno/kyverno \
  --version 3.2.0 \
  --namespace kyverno \
  --create-namespace \
  -f manifests/kyverno/values.yaml \
  --no-hooks
```

### values.yaml — points clés

```yaml
# Toutes les images depuis Harbor
image:
  registry: harbor.okd.lab/okd-mirror
  repository: kyverno/kyverno
  tag: v1.12.0

# Compatibilité OKD/OpenShift
openshift: true

# Force Ignore sur tous les webhooks
# (requis OKD SNO — voir limitations)
forceFailurePolicyIgnore: true
autoUpdateWebhooks: false

# Single replica pour lab SNO
admissionController:
  replicas: 1

# Cleanup jobs — image kubectl depuis Harbor
cleanupJobs:
  admissionReports:
    image:
      registry: harbor.okd.lab/okd-mirror
      repository: bitnami/kubectl
      tag: "1.28.5"
```

### Résultat

```bash
oc get pods -n kyverno
NAME                                       READY   STATUS      AGE
kyverno-admission-controller-xxx           1/1     Running     ✅
kyverno-background-controller-xxx          1/1     Running     ✅
kyverno-cleanup-controller-xxx             1/1     Running     ✅
kyverno-reports-controller-xxx             1/1     Running     ✅
kyverno-cleanup-admission-reports-xxx      0/1     Completed   ✅
kyverno-cleanup-cluster-admission-xxx      0/1     Completed   ✅
```

---

## ClusterPolicy — Verify Image Signatures (Cosign)

### Concept

```
SANS Kyverno :
  N'importe quelle image peut être déployée
  → Images non vérifiées, potentiellement compromises

AVEC Kyverno verifyImages :
  Avant chaque déploiement Pod :
  → Kyverno vérifie la signature Cosign de l'image
  → Si non signée (mode Enforce) → déploiement refusé
  → Si non signée (mode Audit)   → déploiement autorisé + violation enregistrée
```

### Policy déployée

```yaml
# manifests/kyverno-policies/01-verify-image-signature.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
  annotations:
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Audit    # Observer sans bloquer
  background: true                   # Scan ressources existantes
  rules:
    - name: verify-harbor-images
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces:
                - default
                - keycloak
                - vault
                - grafana-operator
      verifyImages:
        - imageReferences:
            - "harbor.okd.lab/okd-mirror/*"
          mutateDigest: false         # Mode Audit — ne pas modifier
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUGHKMeYu...
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true   # Airgap — pas accès sigstore.dev
                    ctlog:
                      ignoreSCT: true    # Airgap — pas accès CTLog
```

### Déploiement

```bash
./scripts/apply-kyverno-policies.sh

# Vérifier
oc get clusterpolicy
NAME                     ADMISSION   BACKGROUND   VALIDATE ACTION   READY
verify-image-signature   true        true         Audit             True ✅
```

---

## Limitations connues — OKD SNO Lab

### Limitation 1 — Webhook admission timeout

**Symptôme :**
```
Internal error occurred: failed calling webhook "mutate.kyverno.svc-fail":
Post "https://kyverno-svc.kyverno.svc:443/mutate/fail?timeout=10s":
context deadline exceeded
```

**Cause :**
L'API server OKD (static pod sur FCOS) ne peut pas joindre les services pods
via OVN-Kubernetes sur un cluster SNO à nœud unique.

```
API server (sur FCOS host)
    │
    └── essaie de joindre kyverno-svc.kyverno.svc:443
        → passe par OVN-Kubernetes
        → timeout sur SNO single node ❌
```

**Impact :** Les webhooks admission ne fonctionnent pas.
Le mode background scanning fonctionne correctement.

**En production :** Sur un cluster multi-nœuds (3 masters + workers),
l'API server peut joindre les services pods normalement. ✅

**Workaround lab :** `forceFailurePolicyIgnore: true` — tous les webhooks
passent en mode `Ignore` (si timeout → déploiement autorisé).

### Limitation 2 — DNS harbor.okd.lab non résolu depuis pods

**Symptôme :**
```
Get "https://harbor.okd.lab/v2/":
dial tcp: lookup harbor.okd.lab on 172.30.0.10:53: no such host
```

**Cause :** CoreDNS OKD ne connaît pas `harbor.okd.lab`.
Le `/etc/hosts` du nœud n'est pas automatiquement propagé aux pods.

**Impact :** Le background scanner ne peut pas vérifier les signatures
— il doit accéder à Harbor pour lire les métadonnées de signature.

**Fix production :** Ajouter `harbor.okd.lab` dans CoreDNS OKD :
```yaml
# oc edit configmap dns-default -n openshift-dns
data:
  Corefile: |
    .:5353 {
      hosts {
        192.168.241.20 harbor.okd.lab
        fallthrough
      }
      ...
    }
```

### Limitation 3 — ArgoCD namespaced mode

Kyverno crée des ressources cluster-level (ClusterRole, CRD) incompatibles
avec ArgoCD en mode namespaced. Solution : scripts dédiés.

```
scripts/install-kyverno.sh          → installe Kyverno via Helm
scripts/apply-kyverno-policies.sh   → applique les ClusterPolicies
```

---

## Ce qui fonctionne malgré les limitations

```
✅ Kyverno installé et Running (4 controllers)
✅ ClusterPolicy verify-image-signature → Ready
✅ Background scanning actif → scanne Grafana, Keycloak, Vault...
✅ Kyverno détecte les images non signées (logs reports-controller)
✅ Cleanup CronJobs → Completed (bitnami/kubectl depuis Harbor)
✅ Toutes les images depuis Harbor (airgap) ✅
```

**Le background scanner détecte bien les violations :**
```
engine.verify: image attestors verification failed
  policy: verify-image-signature
  namespace: grafana-operator
  pod: grafana-deployment-9cd775c94-5l4zr
  image: harbor.okd.lab/okd-mirror/grafana/grafana:latest
  → image non signée → violation enregistrée ✅
```

---

## Note architecture — ArgoCD vs Helm vs Scripts

### Pourquoi on a trois méthodes de déploiement ?

```
Via ArgoCD (GitOps) :
  → Keycloak, Grafana, Loki, ESO (OLM Subscriptions + CRs)
  → Fonctionne car ressources dans un namespace managé

Via Helm + Script :
  → Vault, Kyverno
  → Helm car chart officiel complexe
  → Script car ArgoCD namespaced ne peut pas gérer
    ClusterRoles/CRDs cluster-level

Via oc apply direct :
  → kube-bench Job, Prowler Job, Kyverno policies
  → Ressources simples ou ClusterPolicies
```

**En production avec ArgoCD cluster mode :**
Tout passerait par ArgoCD — pas de scripts séparés. Notre contrainte
est spécifique au mode namespaced imposé par l'installation OLM.

---

## Structure fichiers Phase 4

```
manifests/kyverno/
├── values.yaml                      # Helm values — images Harbor, OKD compat

manifests/kyverno-policies/
├── 00-cosign-pubkey.yaml            # ConfigMap clé publique Z3ROX Lab
└── 01-verify-image-signature.yaml   # ClusterPolicy Cosign verification

scripts/
├── install-kyverno.sh               # Installation Kyverno via Helm
└── apply-kyverno-policies.sh        # Application des ClusterPolicies
```

---

## Prochaines étapes Phase 4

```
❌ Fix DNS CoreDNS (harbor.okd.lab → 192.168.241.20)
❌ Signer les images Harbor avec Cosign
   (alpine, grafana, vault... → cosign sign --key cosign.key)
❌ Passer la policy en mode Enforce
❌ Falco runtime security
❌ GitLab in-cluster (airgap Git total)
❌ Cosign signing pipeline GitLab CI
```

---

## Problèmes rencontrés et solutions

| Problème | Cause | Solution |
|----------|-------|----------|
| `mutateDigest must be false for Audit` | Kyverno valide ses propres policies | Ajouter `mutateDigest: false` |
| `failed to load CTLogs public keys` | Kyverno essaie sigstore.dev (airgap) | `ignoreTlog: true` + `ignoreSCT: true` |
| `UPGRADE FAILED: another operation in progress` | Helm upgrade interrompu | `helm rollback kyverno -n kyverno` |
| `bitnami/kubectl:1.28.5 not found` | Image migrée sur ghcr.io (privé) | `docker pull bitnami/kubectl:latest` → push Harbor |
| `/bin/bash not found` | Image kubectl officielle sans bash | Utiliser `bitnami/kubectl:latest` |
| `ClusterRole cannot be managed (namespaced mode)` | ArgoCD mode namespaced | Helm direct + ClusterRoleBinding manuel |
| `harbor.okd.lab: no such host` | DNS CoreDNS OKD | Fix CoreDNS + hostAliases |
| Webhook timeout `context deadline exceeded` | API server OKD ne joint pas pods (SNO) | `forceFailurePolicyIgnore: true` |

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*Phase 4 Security & Compliance — Mars 2026*
