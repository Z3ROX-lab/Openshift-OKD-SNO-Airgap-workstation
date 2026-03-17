# ADR-003 — Kyverno comme Policy Engine de sécurité cluster

## Statut

**Accepted** — Mars 2026

## Contexte

Dans un cluster OKD/OpenShift enterprise, il est nécessaire d'appliquer et d'enforcer
des politiques de sécurité de façon **déclarative, automatique et auditable** sur
l'ensemble des ressources Kubernetes — pods, namespaces, images, configurations.

Les équipes SecOps ont besoin d'un outil qui :
- Bloque les déploiements non conformes
- Corrige automatiquement les configurations manquantes
- Génère des ressources de sécurité sur chaque namespace
- Vérifie la provenance et la signature des images (supply chain)
- S'intègre nativement dans un workflow GitOps

---

## Problème sans Policy Engine

```
Sans Kyverno — cluster "open bar"
──────────────────────────────────────────────────────────
Dev déploie un container privileged         → autorisé ✅ (mauvais)
Dev oublie les resource limits              → autorisé ✅ (mauvais)
Dev utilise une image latest non signée     → autorisé ✅ (mauvais)
Nouveau namespace sans NetworkPolicy        → autorisé ✅ (mauvais)
Image avec CVE Critical déployée            → autorisée ✅ (mauvais)
Container qui tourne en root                → autorisé ✅ (mauvais)

→ Surface d'attaque maximale
→ Aucune cohérence de sécurité
→ Audit impossible
```

---

## Kyverno — architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    KYVERNO — ARCHITECTURE                           │
│                                                                     │
│  Git (source de vérité)                                             │
│  └── policies/                                                      │
│      ├── validate/                                                  │
│      ├── mutate/                                                    │
│      ├── generate/                                                  │
│      └── verify/                                                    │
│              │                                                      │
│              │ ArgoCD sync                                          │
│              ▼                                                      │
│  Kyverno (NS: kyverno)                                              │
│  ├── kyverno-admission-controller   ← webhook Kubernetes            │
│  ├── kyverno-background-controller  ← generate + cleanup           │
│  ├── kyverno-cleanup-controller     ← TTL policies                 │
│  └── kyverno-reports-controller     ← audit reports               │
│              │                                                      │
│              │ intercepte TOUTES les requêtes API Kubernetes        │
│              ▼                                                      │
│  Kubernetes API Server                                              │
│  ├── CREATE pod        → Kyverno VALIDATE + MUTATE + VERIFY        │
│  ├── CREATE namespace  → Kyverno GENERATE (NetworkPolicy, quota...) │
│  ├── UPDATE deployment → Kyverno VALIDATE                          │
│  └── DELETE resource   → Kyverno VALIDATE                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Les 4 modes d'action

### 1. VALIDATE — Bloquer ou alerter

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Enforce   # Enforce = bloque | Audit = alerte seulement
  rules:
    - name: check-privileged
      match:
        resources:
          kinds: [Pod]
      validate:
        message: "Privileged containers interdits — politique SecOps"
        pattern:
          spec:
            containers:
              - securityContext:
                  privileged: "false"
```

**Cas d'usage VALIDATE :**
```
├── Interdire containers privileged
├── Interdire hostNetwork / hostPID / hostIPC
├── Exiger runAsNonRoot: true
├── Exiger resource limits CPU/RAM
├── Exiger labels obligatoires (team, env, app)
├── Interdire tag :latest
├── Autoriser uniquement harbor.okd.lab comme registry
├── Exiger readOnlyRootFilesystem
└── Interdire capabilities dangereuses (NET_RAW, SYS_ADMIN...)
```

### 2. MUTATE — Corriger automatiquement

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-security-context
spec:
  rules:
    - name: set-security-context
      match:
        resources:
          kinds: [Pod]
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
            containers:
              - (name): "*"
                securityContext:
                  allowPrivilegeEscalation: false
                  readOnlyRootFilesystem: true
```

**Cas d'usage MUTATE :**
```
├── Ajouter runAsNonRoot automatiquement
├── Injecter des labels manquants
├── Ajouter des annotations de monitoring
├── Forcer readOnlyRootFilesystem
├── Ajouter toleration pour nœuds dédiés
└── Injecter sidecar de logging
```

### 3. GENERATE — Créer des ressources automatiquement

```yaml
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
        synchronize: true    # Met à jour si la policy change
        data:
          spec:
            podSelector: {}
            policyTypes: [Ingress, Egress]
```

**Cas d'usage GENERATE :**
```
├── NetworkPolicy default-deny sur chaque namespace
├── ResourceQuota sur chaque namespace
├── LimitRange sur chaque namespace
├── RoleBinding viewer pour l'équipe dev
├── Secret de pull Harbor sur chaque namespace
└── ConfigMap de configuration standard
```

### 4. VERIFY IMAGE — Supply Chain Security

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-cosign-signature
      match:
        resources:
          kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.okd.lab/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ... contenu de cosign.pub ...
                      -----END PUBLIC KEY-----
          attestations:
            - type: https://cosign.sigstore.dev/attestation/vuln/v1
              conditions:
                - all:
                    - key: "{{ scanner }}"
                      operator: Equals
                      value: "trivy"
```

**Cas d'usage VERIFY :**
```
├── Vérifier signature Cosign avant tout déploiement
├── Vérifier attestation Trivy (scan passé + 0 CVE Critical)
├── Interdire images depuis registries non autorisés
└── Exiger digest sha256 (pas de tag mutable)
```

---

## Kyverno vs SCCs OpenShift

```
SCCs OpenShift                         Kyverno
──────────────────────────────────     ──────────────────────────────────
Spécifique OpenShift/OKD               Multi-plateforme (K8s, OKD, EKS...)
Gère permissions OS (uid, capabilities) Gère TOUTES les ressources Kubernetes
Assigné aux ServiceAccounts            Policies sur n'importe quelle ressource
Pas de logique conditionnelle          CEL expressions + JMESPath
Pas de génération de ressources        GENERATE intégré
Config dans le cluster                 GitOps natif (YAML dans Git)
Pas de rapports d'audit natifs         PolicyReport + ClusterPolicyReport
```

**En pratique — les deux sont complémentaires :**
```
SCCs  → contrôle au niveau OS (uid, capabilities, volumes)
Kyverno → contrôle au niveau Kubernetes (configs, images, labels)
```

---

## Organisation des policies en enterprise

```
policies/
├── baseline/              ← Minimum pour tout cluster
│   ├── disallow-privileged-containers.yaml
│   ├── disallow-host-namespaces.yaml
│   ├── require-resource-limits.yaml
│   ├── require-labels.yaml
│   └── default-networkpolicy-generate.yaml
│
├── restricted/            ← Namespaces sensibles
│   ├── require-cosign-signature.yaml
│   ├── disallow-latest-tag.yaml
│   ├── require-non-root.yaml
│   └── readonly-rootfs.yaml
│
├── compliance/            ← Frameworks réglementaires
│   ├── cis-benchmark.yaml
│   ├── nist-800-53.yaml
│   ├── pci-dss.yaml
│   └── anssi-recommandations.yaml
│
└── supply-chain/          ← Sécurité de la chaîne CI/CD
    ├── verify-cosign.yaml
    ├── verify-trivy-attestation.yaml
    └── allow-only-harbor.yaml
```

---

## Intégration dans ce projet (Phase 4)

```
Phase 4 — Kyverno + Supply Chain Security
                                                
Git (policies/)                                 
      │ ArgoCD sync                             
      ▼                                         
Kyverno déployé via ArgoCD                      
      │                                         
      ├── VALIDATE : pas de privileged, pas de root
      │                                         
      ├── GENERATE : NetworkPolicy default-deny  
      │              sur chaque namespace        
      │                                         
      ├── VERIFY : signature Cosign obligatoire  
      │            pour harbor.okd.lab/*         
      │                                         
      └── MUTATE : injection security context    
                   automatique                  
                                                
Harbor (harbor.okd.lab)                         
      │                                         
      ├── Trivy scan CVE ← auto au push         
      └── Cosign signature ← CI/CD              
                                                
OKD — seules les images signées + scannées      
      peuvent être déployées ✅                  
```

---

## Audit et reporting

Kyverno génère des rapports d'audit natifs :

```bash
# Voir les violations de policies
oc get policyreport -A

# Voir les violations cluster-wide
oc get clusterpolicyreport

# Détail d'une violation
oc describe policyreport -n my-namespace
```

Ces rapports sont consultables dans :
- Console OKD → Observe → (avec le plugin Kyverno)
- Grafana (via métriques Kyverno exportées vers Prometheus)
- Export SIEM (Splunk, Elastic)

---

## Décision

**Kyverno est retenu** comme policy engine pour ce projet.

### Justifications

1. **GitOps natif** — policies en YAML dans Git, déployées par ArgoCD
2. **Multi-usage** — VALIDATE + MUTATE + GENERATE + VERIFY en un seul outil
3. **Supply Chain** — intégration native Cosign/Sigstore
4. **Kubernetes natif** — pas de sidecar, webhook admission standard
5. **Rapports d'audit** — PolicyReport CRD intégré
6. **Communauté active** — CNCF Graduated project

### Alternatives considérées

| Alternative | Raison du rejet |
|-------------|-----------------|
| OPA/Gatekeeper | Rego language complexe, pas de GENERATE natif |
| SCCs seules | Limité à l'OS, pas de supply chain, pas de GENERATE |
| Pod Security Admission (PSA) | Trop limité, pas de GENERATE ni VERIFY |
| Falco | Runtime security seulement, pas d'admission control |

---

## Références

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno CNCF Graduation](https://www.cncf.io/projects/kyverno/)
- [Kyverno vs OPA](https://kyverno.io/docs/writing-policies/compare/)
- [Supply Chain Security with Kyverno + Cosign](https://kyverno.io/docs/writing-policies/verify-images/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*ADR-003 — Kyverno Policy Engine — Mars 2026*
