# Phase 3 — Airgap Simulation

> Reproduire un environnement déconnecté type grands comptes (défense, banque, télécom)

---

## Concept

Un cluster **airgap** est un cluster sans accès Internet direct. Toutes les images de conteneurs et les mises à jour passent par un **mirror registry interne**.

C'est la configuration standard sur les environnements sensibles :
- 🏦 Banques / Finance
- 🛡️ Défense / Gouvernement
- 📡 Télécommunications (Nokia, Orange, Telefónica)

---

## Stack airgap

```
Internet (hôte)
     │
     ▼
oc-mirror (hôte)
     │  télécharge les images OKD + operators
     ▼
Mirror Registry (dans le cluster OKD)
     │  Quay / Harbor / mirror-registry
     ▼
OKD SNO (réseau isolé, sans Internet)
```

---

## Étapes

### 1. Installer oc-mirror

```bash
# Télécharger le plugin oc-mirror
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/oc-mirror.tar.gz
tar xvf oc-mirror.tar.gz
sudo mv oc-mirror /usr/local/bin/
chmod +x /usr/local/bin/oc-mirror
```

### 2. Configurer l'ImageSetConfig

```yaml
# airgap/imagesets/okd-4.17-imageset.yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
storageConfig:
  local:
    path: /tmp/oc-mirror-workspace
mirror:
  platform:
    channels:
      - name: stable-4.17
        type: okd
  operators:
    - catalog: registry.redhat.io/redhat/community-operator-index:v4.17
      packages:
        - name: argocd-operator
        - name: vault
        - name: kyverno
        - name: falco
  additionalImages:
    - name: quay.io/minio/minio:latest
    - name: docker.io/grafana/grafana:latest
    - name: quay.io/prometheus/prometheus:latest
```

### 3. Miroir des images (sur l'hôte avec Internet)

```bash
# Lancer le mirroring (plusieurs heures, ~50-100 Go)
oc-mirror --config airgap/imagesets/okd-4.17-imageset.yaml \
  docker://mirror.sno.okd.lab:5000

# Appliquer les IDMS/ITMS générés au cluster
oc apply -f oc-mirror-workspace/results-*/
```

### 4. Couper l'accès Internet de la VM

```
VMware Workstation → VM Settings → Network Adapter
→ Changer de VMnet8 (NAT) vers VMnet1 (Host-only)
```

### 5. Valider que le cluster fonctionne toujours

```bash
oc get nodes
oc get co
oc get pods -A | grep -v Running
```

---

## Prochaine étape

→ [Phase 4 — Security & Scanning](phase4-security.md)
