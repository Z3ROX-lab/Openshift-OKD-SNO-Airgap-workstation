# ADR-005 — kube-bench et Prowler pour l'audit de conformité

## Statut

**Accepted** — Mars 2026

## Contexte

Dans un cluster OpenShift/OKD enterprise, il est nécessaire de **mesurer objectivement**
le niveau de sécurité et de conformité du cluster par rapport à des frameworks reconnus
(CIS Benchmark, NIS2, ISO 27001, NIST, ANSSI).

Deux outils complémentaires ont été retenus :
- **kube-bench** — audit CIS Kubernetes Benchmark
- **Prowler** — audit multi-frameworks (NIS2, ISO 27001, NIST, SOC2, DORA...)

Ces outils s'inscrivent dans une démarche **avant/après** :
1. Lancer kube-bench + Prowler → baseline de sécurité initiale
2. Appliquer Kyverno + MachineConfig + SCCs → corriger les findings
3. Re-lancer kube-bench + Prowler → démontrer l'amélioration

---

## kube-bench — CIS Kubernetes Benchmark

### Qu'est-ce que le CIS Kubernetes Benchmark ?

Le **Center for Internet Security (CIS)** publie un benchmark de sécurité
pour Kubernetes qui couvre :

```
CIS Kubernetes Benchmark — Sections
├── 1. Control Plane Components
│   ├── 1.1 Master Node Configuration Files
│   ├── 1.2 API Server
│   ├── 1.3 Controller Manager
│   └── 1.4 Scheduler
├── 2. etcd
├── 3. Control Plane Configuration
│   ├── 3.1 Authentication and Authorization
│   └── 3.2 Logging
├── 4. Worker Nodes
│   ├── 4.1 Worker Node Configuration Files
│   ├── 4.2 Kubelet
│   └── 4.3 Container Runtime
└── 5. Kubernetes Policies
    ├── 5.1 RBAC and Service Accounts
    ├── 5.2 Pod Security Standards
    ├── 5.3 Network Policies
    ├── 5.4 Secrets Management
    └── 5.7 General Policies
```

### Comment kube-bench fonctionne

```
┌─────────────────────────────────────────────────────────────────────┐
│                    KUBE-BENCH — FLOW                                │
│                                                                     │
│  Job Kubernetes                                                     │
│  ├── Image : aquasec/kube-bench                                     │
│  ├── hostPID: true (accès aux processus hôte)                      │
│  ├── Monte /etc, /var/lib/kubelet, /etc/kubernetes                  │
│  │                                                                  │
│  └── Vérifie :                                                      │
│      ├── Flags du kube-apiserver (--anonymous-auth, --audit-log...) │
│      ├── Permissions des fichiers de config                         │
│      ├── Configuration du kubelet                                   │
│      ├── Policies RBAC et Pod Security                             │
│      └── Configuration etcd                                         │
│                                                                     │
│  Output : PASS / FAIL / WARN par contrôle CIS                      │
│  Exemple :                                                          │
│  [PASS] 1.2.1 Ensure anonymous-auth is set to false                │
│  [FAIL] 1.2.6 Ensure audit logs are configured                     │
│  [WARN] 5.3.2 Ensure NetworkPolicies are configured                │
└─────────────────────────────────────────────────────────────────────┘
```

### Déploiement dans OKD

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: kube-bench
spec:
  template:
    spec:
      hostPID: true
      containers:
        - name: kube-bench
          image: harbor.okd.lab/okd-mirror/aquasec/kube-bench:latest
          command: ["kube-bench", "--benchmark", "cis-1.8"]
          volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
      restartPolicy: Never
```

---

## Prowler — Audit multi-frameworks

### Qu'est-ce que Prowler ?

Prowler est un outil open source d'audit de sécurité cloud et Kubernetes
qui mappe ses contrôles sur de nombreux frameworks de conformité :

```
Prowler — Frameworks supportés
├── CIS Kubernetes Benchmark
├── NIST SP 800-53
├── ISO 27001
├── SOC 2
├── NIS2 (EU)
├── DORA (EU)
├── PCI-DSS
├── GDPR
├── HIPAA
├── FedRAMP
└── ANSSI (partiel)
```

### Ce que Prowler vérifie sur Kubernetes

```
Prowler Kubernetes checks
├── IAM / RBAC
│   ├── Pas de ClusterAdmin inutiles
│   ├── Pas de wildcards dans les RBAC
│   └── Service Accounts avec droits minimaux
│
├── Network Security
│   ├── NetworkPolicies configurées
│   └── Pas de services exposés inutilement
│
├── Pod Security
│   ├── Pas de containers privileged
│   ├── runAsNonRoot enforced
│   └── readOnlyRootFilesystem
│
├── Secrets Management
│   ├── Pas de secrets en clair dans les envVars
│   └── Chiffrement etcd at rest
│
├── Logging & Monitoring
│   ├── Audit logs activés
│   └── Alertes configurées
│
└── Supply Chain
    ├── Images signées
    └── Scan CVE actif
```

### Output Prowler

```
Prowler génère des rapports :
├── HTML  → rapport visuel avec graphiques
├── JSON  → intégration SIEM (Splunk, Elastic)
├── CSV   → analyse Excel
└── OCSF  → Open Cybersecurity Schema Framework
```

### Déploiement dans OKD

```bash
# Lancer Prowler comme pod dans OKD
oc run prowler \
  --image=harbor.okd.lab/okd-mirror/toniblyx/prowler:latest \
  --restart=Never \
  -n prowler \
  -- prowler kubernetes \
     --output-formats html,json \
     --compliance nist_800_53_kubernetes nist_csf_1.1_kubernetes \
     --output-directory /tmp/prowler-output
```

---

## Complémentarité kube-bench / Prowler

```
kube-bench                           Prowler
──────────────────────────────       ──────────────────────────────
Focalisé CIS Benchmark               Multi-frameworks
Très détaillé sur la config OS       Vue conformité métier
Vérifie les fichiers système         Vérifie les ressources K8s
Output texte/JSON simple             Output HTML/JSON/CSV riche
Idéal pour : hardening OS            Idéal pour : audit conformité
Audience : SecOps / SRE              Audience : RSSI / Auditeurs
```

**En pratique les deux sont complémentaires :**
```
kube-bench → "Est-ce que le cluster est configuré correctement ?"
Prowler    → "Est-ce que le cluster est conforme à NIS2/ISO27001 ?"
```

---

## Démarche avant/après dans ce projet

```
PHASE 3 — Baseline (avant Kyverno)
┌─────────────────────────────────────────────────────────────────────┐
│  kube-bench → rapport CIS initial                                   │
│  Prowler    → rapport NIS2/ISO27001 initial                         │
│                                                                     │
│  Expected findings :                                                │
│  ├── [FAIL] NetworkPolicies manquantes sur certains namespaces     │
│  ├── [FAIL] Pas de resource limits sur certains pods               │
│  ├── [WARN] Audit logs non configurés                              │
│  └── [FAIL] Containers sans runAsNonRoot                           │
└─────────────────────────────────────────────────────────────────────┘
                          ↓
PHASE 4 — Remédiation (Kyverno + MachineConfig)
┌─────────────────────────────────────────────────────────────────────┐
│  Kyverno GENERATE → NetworkPolicy auto sur chaque namespace         │
│  Kyverno VALIDATE → resource limits obligatoires                   │
│  Kyverno MUTATE   → runAsNonRoot automatique                       │
│  MachineConfig    → audit logs kernel activés                      │
└─────────────────────────────────────────────────────────────────────┘
                          ↓
PHASE 4 — Re-audit (après Kyverno)
┌─────────────────────────────────────────────────────────────────────┐
│  kube-bench → rapport CIS amélioré                                  │
│  Prowler    → rapport NIS2/ISO27001 amélioré                        │
│                                                                     │
│  Démonstration portfolio :                                          │
│  ├── Score CIS : X% → Y% (+Z points)                               │
│  └── Conformité NIS2 : X% → Y%                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Intégration dans le workflow GitOps

```
manifests/
├── kube-bench/
│   ├── 00-namespace.yaml
│   └── 01-job.yaml          → Job kube-bench
└── prowler/
    ├── 00-namespace.yaml
    └── 01-job.yaml          → Job Prowler

argocd/applications/
├── kube-bench.yaml          → ArgoCD Application
└── prowler.yaml             → ArgoCD Application
```

Les rapports sont stockés dans :
```
├── Loki    → logs des jobs kube-bench/Prowler
├── Grafana → dashboard conformité
└── Harbor  → artifacts HTML/JSON des rapports
```

---

## Mapping frameworks de conformité

| Finding kube-bench | Framework | Remédiation |
|-------------------|-----------|-------------|
| NetworkPolicies manquantes | NIS2 Art.21, CIS 5.3 | Kyverno GENERATE |
| Pas de resource limits | CIS 5.2 | Kyverno VALIDATE |
| runAsRoot autorisé | CIS 5.2, NIST | Kyverno MUTATE + SCCs |
| Audit logs désactivés | NIS2 Art.21, ISO 27001 A.12.4 | MachineConfig |
| Secrets en envVars | CIS 5.4, NIST | Vault + ESO |
| Images non signées | CIS 5.7, DORA | Cosign + Kyverno VERIFY |
| RBAC trop permissif | CIS 5.1, ISO 27001 A.9 | RBAC review |

---

## Décision

**kube-bench + Prowler sont retenus** pour l'audit de conformité dans ce projet.

### Justifications

1. **Open source** — pas de licence, compétences transférables
2. **Standards reconnus** — CIS, NIS2, ISO 27001, NIST
3. **GitOps** — déployés via ArgoCD comme des Jobs Kubernetes
4. **Avant/après** — démarche démonstrative puissante pour le portfolio
5. **Airgap** — images mirrorées dans Harbor via oc-mirror
6. **Complémentaires** — kube-bench (OS/config) + Prowler (conformité métier)

### Alternatives considérées

| Alternative | Raison du rejet |
|-------------|-----------------|
| Red Hat ACS Compliance | Payant, nécessite abonnement Red Hat |
| Trivy (mode compliance) | Focalisé images, moins complet que Prowler sur K8s |
| Checkov | Focalisé IaC/manifests, pas runtime cluster |
| OpenSCAP | Complexe, peu adapté aux containers |

---

## Références

- [kube-bench GitHub](https://github.com/aquasecurity/kube-bench)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [Prowler GitHub](https://github.com/prowler-cloud/prowler)
- [NIS2 Directive](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32022L2555)
- [ISO 27001:2022](https://www.iso.org/standard/82875.html)
- [NIST SP 800-190](https://csrc.nist.gov/publications/detail/sp/800-190/final)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*ADR-005 — kube-bench et Prowler — Mars 2026*
