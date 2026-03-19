# ADR-006 — ImageContentSourcePolicy et pattern Registry Airgap

## Statut

**Accepted** — Mars 2026

## Contexte

Dans un environnement airgap (sans accès Internet), les nœuds OKD/OpenShift
ne peuvent pas puller les images directement depuis les registries publics
(quay.io, docker.io, ghcr.io, registry.k8s.io...).

Il faut un mécanisme pour **rediriger transparentement** tous les pulls d'images
vers un registry interne (Harbor dans ce projet), sans modifier les manifests
des applications ni les Helm charts.

Ce mécanisme s'appelle **ImageContentSourcePolicy (ICSP)**.

---

## Problème sans ICSP

```
Sans ICSP — environnement airgap
──────────────────────────────────────────────────────────────────
Pod demande docker.io/grafana/grafana:12.4.1
      ↓
OKD essaie de contacter docker.io
      ↓
Timeout — pas d'Internet ❌
      ↓
Pod en ErrImagePull / ImagePullBackOff ❌

→ Impossible de déployer quoi que ce soit en airgap
  sans modifier CHAQUE manifest pour pointer sur Harbor
  → Pas scalable, pas maintenable
```

---

## Solution — ImageContentSourcePolicy (ICSP)

```
Avec ICSP — environnement airgap
──────────────────────────────────────────────────────────────────
Pod demande docker.io/grafana/grafana:12.4.1
      ↓
OKD consulte /etc/containers/registries.conf.d/ (ICSP appliqué)
      ↓
Règle trouvée : docker.io/grafana → harbor.okd.lab/okd-mirror/grafana
      ↓
OKD pull depuis harbor.okd.lab/okd-mirror/grafana/grafana:12.4.1
      ↓
Pod Running ✅ — TRANSPARENCE TOTALE
      ↓
Aucun changement dans les manifests ✅
```

---

## Architecture ICSP

```
┌─────────────────────────────────────────────────────────────────────┐
│                    ICSP — COMMENT ÇA MARCHE                         │
│                                                                     │
│  1. oc-mirror génère automatiquement l'ICSP                         │
│     oc-mirror-workspace/results-*/imageContentSourcePolicy.yaml     │
│                                                                     │
│  2. oc apply -f imageContentSourcePolicy.yaml                       │
│              ↓                                                      │
│  3. MCO (MachineConfig Operator) détecte l'ICSP                    │
│              ↓                                                      │
│  4. MCO génère un MachineConfig                                     │
│     Écrit /etc/containers/registries.conf.d/harbor-mirror.conf      │
│     sur TOUS les nœuds du cluster                                   │
│              ↓                                                      │
│  5. Nœuds redémarrent (rolling restart)                             │
│     SNO : ~5 min d'indisponibilité                                  │
│     Multi-nœuds : rolling restart, pas d'indisponibilité           │
│              ↓                                                      │
│  6. Tous les pulls d'images redirigés vers Harbor ✅                │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  /etc/containers/registries.conf.d/harbor-mirror.conf       │   │
│  │  (généré automatiquement par MCO sur chaque nœud)           │   │
│  │                                                             │   │
│  │  [[registry]]                                               │   │
│  │  location = "docker.io/grafana"                             │   │
│  │  mirror-by-digest-only = true                               │   │
│  │  [[registry.mirror]]                                        │   │
│  │  location = "harbor.okd.lab/okd-mirror/grafana"             │   │
│  │                                                             │   │
│  │  [[registry]]                                               │   │
│  │  location = "docker.io/hashicorp"                           │   │
│  │  [[registry.mirror]]                                        │   │
│  │  location = "harbor.okd.lab/okd-mirror/hashicorp"           │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## CatalogSource — OperatorHub airgap

En complément de l'ICSP, oc-mirror génère aussi une **CatalogSource**
qui pointe l'OperatorHub vers Harbor :

```
Sans CatalogSource airgap :
  OperatorHub → quay.io/operatorhubio/catalog ❌ (pas d'Internet)

Avec CatalogSource airgap :
  OperatorHub → harbor.okd.lab/okd-mirror/operatorhubio/catalog ✅
```

```yaml
# catalogSource-cs-catalog.yaml (généré par oc-mirror)
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-catalog
  namespace: openshift-marketplace
spec:
  image: harbor.okd.lab/okd-mirror/operatorhubio/catalog:latest
  sourceType: grpc
  displayName: "Harbor Mirror Catalog"
```

---

## Flow complet airgap

```
┌─────────────────────────────────────────────────────────────────────┐
│                    FLOW COMPLET AIRGAP                              │
│                                                                     │
│  AVANT coupure Internet (connecté) :                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. oc-mirror → pull depuis quay.io/docker.io               │   │
│  │  2. oc-mirror → push vers harbor.okd.lab/okd-mirror         │   │
│  │  3. oc-mirror → génère ICSP + CatalogSource                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Appliquer sur le cluster (encore connecté) :                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  4. oc apply -f catalogSource-cs-catalog.yaml               │   │
│  │     → OperatorHub pointe sur Harbor                         │   │
│  │  5. oc apply -f imageContentSourcePolicy.yaml               │   │
│  │     → MCO écrit registries.conf sur tous les nœuds          │   │
│  │     → Nœuds redémarrent (~5 min SNO)                        │   │
│  │  6. oc patch OperatorHub cluster --disable-all-defaults=true│   │
│  │     → Désactive les CatalogSources Internet                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Couper Internet (VMnet8 → VMnet1) :                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  7. Cluster fonctionne sans Internet ✅                      │   │
│  │     Images → Harbor (ICSP)                                  │   │
│  │     OperatorHub → Harbor (CatalogSource)                    │   │
│  │     ArgoCD → GitHub via tinyproxy (airgap partiel)          │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Retour arrière (rollback)

Si on veut revenir à quay.io/docker.io :

```bash
# 1. Supprimer la redirection images
oc delete -f imageContentSourcePolicy.yaml
# → MCO reboot les nœuds → OKD retourne sur Internet

# 2. Supprimer le catalog Harbor
oc delete -f catalogSource-cs-catalog.yaml

# 3. Réactiver les sources Internet
oc patch OperatorHub cluster --type json \
  -p '[{"op":"add","path":"/spec/disableAllDefaultSources","value":false}]'
```

⚠️ **Chaque modification ICSP = reboot des nœuds** — en SNO cela
implique ~5 min d'indisponibilité. Planifier les changements ICSP
pendant les fenêtres de maintenance en production.

---

## Impact sur MachineConfig

L'ICSP est implémenté via MachineConfig — c'est pourquoi les nœuds redémarrent :

```
ICSP appliqué
      ↓
MCO génère rendered-master-xxxx (nouveau hash)
      ↓
MachineConfigPool master → UPDATING=True
      ↓
Nœud drain → reboot → uncordon
      ↓
MachineConfigPool master → UPDATED=True
      ↓
/etc/containers/registries.conf.d/harbor-mirror.conf présent ✅
```

Surveiller pendant l'application :
```bash
# Surveiller l'état des nœuds pendant le reboot
watch oc get mcp
watch oc get nodes

# Vérifier que l'ICSP est bien appliqué après reboot
oc debug node/sno-master -- chroot /host \
  cat /etc/containers/registries.conf.d/harbor-mirror.conf
```

---

## Résultats oc-mirror dans ce projet

```
oc-mirror-workspace/results-1773907915/
├── catalogSource-cs-catalog.yaml    → OperatorHub → Harbor ✅
├── imageContentSourcePolicy.yaml    → Redirection images → Harbor ✅
├── mapping.txt                      → Liste source → destination (info)
├── charts/                          → Helm charts (vide)
└── release-signatures/              → Signatures release (vide)

Images mirrorées dans Harbor (okd-mirror) :
├── toniblyx/prowler                 ✅
├── aquasec/kube-bench               ✅
├── operatorhubio/catalog            ✅ (index operators)
├── grafana/loki                     ✅
├── grafana/grafana                  ✅
├── grafana/grafana-operator         ✅
├── grafana/loki-operator            ✅
├── brancz/kube-rbac-proxy           ✅
├── hashicorp/vault                  ✅
├── observatorium/api                ✅
└── observatorium/opa-openshift      ✅

Total : 4.62 GiB
```

---

## Airgap partiel vs total dans ce projet

```
Airgap IMAGES (Phase 3 — ce qu'on fait) :
  Images → Harbor (ICSP) ✅
  OperatorHub → Harbor (CatalogSource) ✅
  ArgoCD → GitHub via tinyproxy ⚠️ (toujours connecté)

Airgap TOTAL (Phase 4) :
  Images → Harbor ✅
  OperatorHub → Harbor ✅
  ArgoCD → GitLab in-cluster ✅ (plus de tinyproxy)
  Cluster → 100% autonome ✅
```

---

## Commandes applicables dans ce projet

```bash
# Depuis le dossier oc-mirror-workspace/results-*/

# 1. Appliquer le catalog Harbor
oc apply -f catalogSource-cs-catalog.yaml

# 2. Appliquer la redirection images (déclenche reboot SNO)
oc apply -f imageContentSourcePolicy.yaml

# 3. Surveiller le reboot
watch oc get mcp
watch oc get nodes

# 4. Désactiver les sources Internet (après reboot)
oc patch OperatorHub cluster --type json \
  -p '[{"op":"add","path":"/spec/disableAllDefaultSources","value":true}]'

# 5. Vérifier que Harbor est bien utilisé
oc get catalogsource -n openshift-marketplace
oc debug node/sno-master -- chroot /host \
  cat /etc/containers/registries.conf.d/harbor-mirror.conf
```

---

## Décision

**ICSP + CatalogSource générés par oc-mirror sont retenus** comme
mécanisme de redirection d'images en airgap.

### Justifications

1. **Transparence totale** — aucun changement dans les manifests applicatifs
2. **Généré automatiquement** — oc-mirror produit l'ICSP exact
3. **GitOps** — ICSP et CatalogSource commités dans Git
4. **Réversible** — rollback simple via `oc delete`
5. **Standard OpenShift** — pattern officiel Red Hat pour l'airgap
6. **MachineConfig** — appliqué sur tous les nœuds automatiquement

### Alternatives considérées

| Alternative | Raison du rejet |
|-------------|-----------------|
| Modifier chaque manifest | Pas scalable — des centaines de manifests |
| Proxy HTTP transparent | Complexe, pas natif Kubernetes |
| Mirroring DNS | Risqué, casse les certificats TLS |
| registry:// dans chaque pod | Non maintenable |

---

## Références

- [ImageContentSourcePolicy — OKD Docs](https://docs.okd.io/latest/openshift_images/image-configuration.html)
- [oc-mirror — Airgap](https://docs.okd.io/latest/installing/disconnected_install/installing-mirroring-disconnected.html)
- [MachineConfig Operator](https://docs.okd.io/latest/post_installation_configuration/machine-configuration-tasks.html)
- [CatalogSource — OLM](https://olm.operatorframework.io/docs/concepts/crds/catalogsource/)

---

*Projet `Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation`*
*ADR-006 — ImageContentSourcePolicy et pattern Registry Airgap — Mars 2026*
