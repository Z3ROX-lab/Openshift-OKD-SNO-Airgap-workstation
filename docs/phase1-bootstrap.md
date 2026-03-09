# Phase 1 — SNO Bootstrap

> Provisionner le cluster OKD SNO via Agent-based Installer sur VMware Workstation

---

## Prérequis

### 1. Télécharger les binaires OKD 4.17

```bash
# Linux/WSL
OKD_VERSION=4.17.0-0.okd-2024-11-16-084457

# openshift-install
wget https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-install-linux-${OKD_VERSION}.tar.gz
tar xvf openshift-install-linux-${OKD_VERSION}.tar.gz
sudo mv openshift-install /usr/local/bin/

# oc CLI
wget https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-client-linux-${OKD_VERSION}.tar.gz
tar xvf openshift-client-linux-${OKD_VERSION}.tar.gz
sudo mv oc kubectl /usr/local/bin/

# Vérification
openshift-install version
oc version
```

### 2. Configurer dnsmasq sur l'hôte

```bash
# /etc/dnsmasq.d/okd-sno.conf
address=/api.sno.okd.lab/192.168.100.10
address=/api-int.sno.okd.lab/192.168.100.10
address=/.apps.sno.okd.lab/192.168.100.10
address=/mirror.sno.okd.lab/192.168.100.10

# Restart dnsmasq
sudo systemctl restart dnsmasq
```

> **Windows host** : utiliser Acrylic DNS Proxy ou ajouter les entrées dans `C:\Windows\System32\drivers\etc\hosts`

---

## Génération de l'ISO Agent-based

```bash
# Créer le répertoire de travail
mkdir -p ~/okd-sno-install
cp install/install-config.yaml ~/okd-sno-install/
cp install/agent-config.yaml ~/okd-sno-install/

# IMPORTANT : openshift-install consomme et supprime ces fichiers
# Toujours travailler depuis une copie

# Générer l'ISO
openshift-install agent create image --dir ~/okd-sno-install/

# Résultat attendu
ls ~/okd-sno-install/
# agent.x86_64.iso   auth/   rendezvousIP
```

---

## Création de la VM VMware Workstation

### Specs VM
| Paramètre | Valeur |
|-----------|--------|
| OS Guest | Red Hat Enterprise Linux 9 (64-bit) |
| vCPU | 8 |
| RAM | 24576 MB (24 Go) |
| Disk | 120 Go — **thin provisioned** sur D: |
| Network | VMnet8 (NAT) |
| Firmware | UEFI (désactiver Secure Boot) |

### Étapes
1. **New Virtual Machine** → Custom
2. **Installer disc image file (ISO)** → `agent.x86_64.iso`
3. Guest OS : **Red Hat Enterprise Linux 9 64-bit**
4. Name : `okd-sno-master`
5. Processors : **8 vCPU** (4 cores × 2 threads)
6. Memory : **24576 MB**
7. Network : **VMnet8 (NAT)**
8. Disk : **120 Go, thin provisioned**, stocker sur `D:`
9. **Edit VM Settings** → Options → Advanced → Firmware : **UEFI**

### Récupérer la MAC address
`VM Settings → Network Adapter → Advanced → MAC Address`  
→ Mettre à jour `agent-config.yaml` avec cette valeur

---

## Démarrage et installation

```bash
# Surveiller l'installation depuis l'hôte
openshift-install agent wait-for bootstrap-complete \
  --dir ~/okd-sno-install/ \
  --log-level=info

# Puis attendre la complétion totale
openshift-install agent wait-for install-complete \
  --dir ~/okd-sno-install/ \
  --log-level=info

# Durée attendue : 45-75 minutes
```

### Credentials post-install

```bash
# kubeconfig
export KUBECONFIG=~/okd-sno-install/auth/kubeconfig

# kubeadmin password
cat ~/okd-sno-install/auth/kubeadmin-password

# Vérifications
oc get nodes
oc get clusterversion
oc get co   # Tous les cluster operators doivent être Available
```

---

## Validation ✅

```bash
# Node status
oc get nodes
# NAME         STATUS   ROLES                         AGE   VERSION
# sno-master   Ready    control-plane,master,worker   1h    v1.30.x

# Cluster version
oc get clusterversion
# NAME      VERSION                            AVAILABLE   PROGRESSING   SINCE   STATUS
# version   4.17.0-0.okd-2024-11-16-084457   True        False         1h      Cluster version is 4.17.x

# Console URL
oc whoami --show-console
# https://console-openshift-console.apps.sno.okd.lab
```

### Accès console web
1. Ouvrir `https://console-openshift-console.apps.sno.okd.lab`
2. Login : `kubeadmin` / `<contenu de auth/kubeadmin-password>`

---

## Troubleshooting courant

| Symptôme | Cause probable | Solution |
|----------|---------------|----------|
| ISO ne boote pas | Secure Boot activé | Désactiver dans VM Settings → UEFI |
| `api.sno.okd.lab` unreachable | DNS non résolu | Vérifier dnsmasq / hosts file |
| Installation bloquée à 70% | RAM insuffisante | Vérifier que la VM a bien 24 Go |
| Cluster operators dégradés | Disk I/O trop lent | Vérifier thin provisioning sur D: |
| MAC address mismatch | `agent-config.yaml` incorrect | Corriger et regénérer l'ISO |

---

## Prochaine étape

→ [Phase 2 — HashiCorp Vault + CI/CD](phase2-vault-cicd.md)
