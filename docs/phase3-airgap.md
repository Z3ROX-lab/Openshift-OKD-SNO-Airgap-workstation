# Phase 3 — Airgap Simulation

> Reproduire un environnement déconnecté type grands comptes (défense, banque, télécom)

---

## Concept

Un cluster **airgap** est un cluster sans accès Internet direct. Toutes les images de conteneurs, les Helm charts et les mises à jour passent par des services **internes au cluster**.

C'est la configuration standard sur les environnements sensibles :
- 🏦 Banques / Finance
- 🛡️ Défense / Gouvernement
- 📡 Télécommunications (Nokia, Orange, Telefónica)

---

## Architecture cible

```
AVANT coupure Internet (WSL2, hôte)        APRÈS coupure Internet
────────────────────────────────           ──────────────────────────────────────

oc-mirror
  ├── quay.io → OKD release images         ArgoCD
  ├── quay.io → community-operator-index     ├── Git source → GitLab.apps.sno.okd.lab ✅
  ├── docker.io/goharbor → Harbor images     ├── Helm charts → Harbor.apps.sno.okd.lab ✅
  └── helm charts → Harbor OCI              └── Images → Harbor.apps.sno.okd.lab ✅
        ↓
  mirror-registry WSL2 (temporaire)        OKD SNO (réseau isolé)
        ↓                                    ├── Harbor (registry permanent)
  OKD installe Harbor via OperatorHub          │   ├── Images OCI
        ↓                                      │   ├── Helm charts OCI
  Images migrées → Harbor OpenShift            │   ├── Scan CVE (Trivy intégré)
        ↓                                      │   └── Signing (Cosign)
  mirror-registry WSL2 supprimé               ├── GitLab (source of truth ArgoCD)
                                              │   ├── Manifests Kubernetes
                                              │   ├── Helm values.yaml
                                              │   └── Kustomize overlays
                                              └── OperatorHub (CatalogSource mirror)
                                                  → Harbor, ArgoCD, Vault, Grafana...
```

**GitLab + Harbor = les deux piliers airgap.**
- **Harbor** : registry images + registry Helm OCI + scan CVE + signing
- **GitLab** : source of truth Git pour ArgoCD — remplace github.com en interne

---

## Pourquoi pas directement Harbor dans l'ISO ?

Harbor n'est pas dans quay.io — ses images viennent de `docker.io/goharbor/` et `ghcr.io`. Il faut donc les mirror **avant** de couper Internet via `oc-mirror` (qui supporte multi-source), puis installer Harbor via OperatorHub depuis le mirror local.

### Problème bootstrap (poule/œuf)

```
Pour installer Harbor → il faut des images Harbor
Pour avoir des images Harbor → il faut un registry
Pour avoir un registry → il faut Harbor
```

**Solution** : mirror-registry WSL2 comme registry temporaire de bootstrap, puis Harbor devient le registry permanent.

---

## Étapes détaillées

### Phase 3a — Préparer oc-mirror (connecté)

```bash
# Télécharger le plugin oc-mirror
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/oc-mirror.tar.gz
tar xvf oc-mirror.tar.gz
sudo mv oc-mirror /usr/local/bin/
chmod +x /usr/local/bin/oc-mirror
```

### Phase 3b — Configurer l'ImageSetConfig

```yaml
# airgap/imagesets/okd-4.17-imageset.yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
storageConfig:
  local:
    path: /tmp/oc-mirror-workspace
mirror:

  # OKD release images (quay.io)
  platform:
    channels:
      - name: stable-4.17
        type: okd

  # Operators depuis community-operator-index
  # On ne mirore que les operators dont on a besoin (pas tout l'index ~200 Go)
  operators:
    - catalog: registry.redhat.io/redhat/community-operator-index:v4.17
      packages:
        - name: harbor-operator
        - name: argocd-operator
        - name: vault
        - name: kyverno
        - name: grafana-operator
        - name: loki-operator
        - name: gitlab-operator-kubernetes

  # Images Harbor (docker.io/goharbor — pas dans quay.io)
  additionalImages:
    - name: docker.io/goharbor/harbor-operator:v1.3.0
    - name: docker.io/goharbor/harbor-core:v2.10.0
    - name: docker.io/goharbor/harbor-portal:v2.10.0
    - name: docker.io/goharbor/harbor-registryctl:v2.10.0
    - name: docker.io/goharbor/registry-photon:v2.10.0
    - name: docker.io/goharbor/harbor-db:v2.10.0
    - name: docker.io/goharbor/redis-photon:v2.10.0
    - name: docker.io/goharbor/trivy-adapter-photon:v2.10.0
    - name: docker.io/goharbor/nginx-photon:v2.10.0
    - name: quay.io/minio/minio:latest
    - name: quay.io/prometheus/prometheus:latest
```

### Phase 3c — Installer mirror-registry WSL2 (bootstrap temporaire)

```bash
# Télécharger mirror-registry (Quay léger — images dans quay.io ✅)
wget https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz
tar xvf mirror-registry.tar.gz

# Installer
sudo ./mirror-registry install \
  --quayHostname mirror.sno.okd.lab \
  --quayRoot /opt/mirror-registry

# Ajouter le CA cert au trust store WSL2
sudo cp /opt/mirror-registry/quay-rootCA/rootCA.pem \
  /usr/local/share/ca-certificates/mirror-registry.crt
sudo update-ca-certificates
```

### Phase 3d — Mirror toutes les images

```bash
# Authentification
podman login mirror.sno.okd.lab \
  -u init -p $(cat /opt/mirror-registry/quay-config/quay-config.yaml | grep PASSWORD | awk '{print $2}')

# Lancer le mirroring (~8-15 Go selon les operators sélectionnés)
oc-mirror --config airgap/imagesets/okd-4.17-imageset.yaml \
  docker://mirror.sno.okd.lab

# oc-mirror génère automatiquement dans oc-mirror-workspace/results-*/ :
# - ImageContentSourcePolicy → redirige docker.io/goharbor → mirror.sno.okd.lab
# - CatalogSource → community-operator-index depuis le mirror
```

### Phase 3e — Appliquer les ICSP et CatalogSource au cluster

```bash
# ImageContentSourcePolicy (redirige les pulls d'images)
oc apply -f oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml

# Désactiver les CatalogSources par défaut (pointent vers Internet)
oc patch OperatorHub cluster --type json \
  -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

# Appliquer le CatalogSource du mirror
oc apply -f oc-mirror-workspace/results-*/catalogSource-*.yaml
```

### Phase 3f — Couper l'accès Internet de la VM

```
VMware Workstation → VM Settings → Network Adapter
→ Changer VMnet8 (NAT) → VMnet1 (Host-only)
```

Valider que le cluster fonctionne toujours :

```bash
oc get nodes
oc get co
oc get pods -A | grep -v Running | grep -v Completed
```

### Phase 3g — Installer Harbor via OperatorHub

Depuis la console OKD :

```
OperatorHub → Chercher "Harbor"
→ Harbor Operator (community)
→ Install
→ Namespace : harbor-system
→ Update channel : stable
→ Install
```

> L'expérience UI est identique au mode connecté.
> OLM pull depuis `mirror.sno.okd.lab` de façon transparente grâce à l'ICSP.

Créer le CR HarborCluster :

```yaml
apiVersion: goharbor.io/v1beta1
kind: HarborCluster
metadata:
  name: harbor
  namespace: harbor-system
spec:
  version: v2.10.0
  logLevel: info
  expose:
    core:
      ingress:
        host: harbor.apps.sno.okd.lab
      tls:
        auto:
          commonName: harbor.apps.sno.okd.lab
  externalURL: https://harbor.apps.sno.okd.lab
  internalTLS:
    enabled: true
  imageChartStorage:
    filesystem:
      chartPersistentVolume:
        claimName: harbor-chart-pvc
      registryPersistentVolume:
        claimName: harbor-registry-pvc
  database:
    kind: PostgreSQL
    spec:
      postgresql:
        storage: 1Gi
  cache:
    kind: Redis
    spec:
      redis:
        storage: 1Gi
  trivy:
    enabled: true          # Scan CVE automatique ✅
    githubToken: ""
  jobservice:
    replicas: 1
  registry:
    replicas: 1
```

### Phase 3h — Migrer les images vers Harbor

```bash
# Script de migration mirror-registry → Harbor
for image in $(skopeo list-tags docker://mirror.sno.okd.lab/goharbor); do
  skopeo copy \
    docker://mirror.sno.okd.lab/goharbor/${image} \
    docker://harbor.apps.sno.okd.lab/okd/${image}
done

# Mettre à jour l'ICSP pour pointer sur Harbor (registry permanent)
# mirror.sno.okd.lab → harbor.apps.sno.okd.lab
```

### Phase 3i — Configurer Harbor : Trivy + Cosign

**Trivy (scan CVE automatique)**

```
Harbor UI → Administration → Interrogation Services
→ Vulnerability → Enable auto-scan on push ✅
→ Schedule : Hourly
```

**Cosign (signing des images)**

```bash
# Générer une clé de signing
cosign generate-key-pair k8s://harbor-system/cosign-keys

# Signer une image après push
cosign sign --key k8s://harbor-system/cosign-keys \
  harbor.apps.sno.okd.lab/okd/my-app:latest

# Kyverno policy — vérifier la signature avant déploiement
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        resources:
          kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.apps.sno.okd.lab/*"
          attestors:
            - entries:
                - keys:
                    kms: k8s://harbor-system/cosign-keys
```

### Phase 3j — Configurer ArgoCD pour airgap

ArgoCD ne peut plus accéder à github.com ou aux Helm registries publics. Deux sources internes :

**Source Git → GitLab interne**

```yaml
# ArgoCD Application
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  source:
    repoURL: https://gitlab.apps.sno.okd.lab/z3rox/my-app.git  # ✅ interne
    targetRevision: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
```

**Source Helm → Harbor OCI**

```bash
# Pousser un Helm chart dans Harbor avant coupure Internet
helm pull hashicorp/vault --destination ./charts/
helm push charts/vault-*.tgz oci://harbor.apps.sno.okd.lab/helm-charts
```

```yaml
# ArgoCD Application avec Helm OCI
spec:
  source:
    repoURL: oci://harbor.apps.sno.okd.lab/helm-charts  # ✅ interne
    chart: vault
    targetRevision: 0.27.0
```

### Phase 3k — Validation airgap complète

```bash
# 1. Cluster opérationnel
oc get nodes && oc get co

# 2. OperatorHub affiche les operators depuis le mirror
oc get catalogsource -n openshift-marketplace

# 3. Harbor accessible
curl -k https://harbor.apps.sno.okd.lab/api/v2.0/health

# 4. Push d'une image test dans Harbor
podman pull registry.access.redhat.com/ubi9/ubi:latest
podman tag ubi9/ubi:latest harbor.apps.sno.okd.lab/test/ubi9:latest
podman push harbor.apps.sno.okd.lab/test/ubi9:latest
# → Trivy scan déclenché automatiquement ✅

# 5. Vérifier le scan Trivy
# Harbor UI → Projects → test → Repositories → ubi9 → Vulnerabilities

# 6. ArgoCD sync depuis GitLab
oc get applications -n argocd

# 7. Mise à jour cluster en airgap
oc-mirror --config airgap/imagesets/okd-4.17-imageset.yaml \
  docker://harbor.apps.sno.okd.lab
oc adm upgrade --to-image harbor.apps.sno.okd.lab/okd/release:4.17.1
```

---

## Résumé des composants airgap

| Composant | Rôle | Source images |
|-----------|------|--------------|
| mirror-registry (WSL2) | Bootstrap temporaire | quay.io (avant coupure) |
| Harbor (OpenShift) | Registry permanent — images + Helm OCI | Migré depuis mirror-registry |
| Trivy (intégré Harbor) | Scan CVE automatique à chaque push | Dans Harbor |
| Cosign | Signing + vérification images | Dans Harbor |
| GitLab (OpenShift) | Source Git pour ArgoCD | Via OperatorHub mirror |
| OperatorHub (mirror) | Installation operators sans Internet | CatalogSource mirror |
| ImageContentSourcePolicy | Redirection transparente des pulls | Généré par oc-mirror |

---

## Prochaine étape

→ [Phase 4 — Security & Scanning](phase4-security.md)
