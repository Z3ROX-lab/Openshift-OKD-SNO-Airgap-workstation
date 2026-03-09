# HAProxy — Load Balancer pour OKD SNO

> HAProxy tourne sur l'hôte (WSL/Windows) et redirige le trafic vers le nœud SNO.

---

## Architecture

```
Client (hôte ou réseau local)
         │
         ▼
    HAProxy (hôte)
    ├── :6443  ──► SNO :6443   (OpenShift API)
    ├── :22623 ──► SNO :22623  (Machine Config Server)
    ├── :80    ──► SNO :80     (Ingress HTTP)
    └── :443   ──► SNO :443    (Ingress HTTPS — Console, ArgoCD, Vault...)
         │
         ▼
  192.168.100.10 (VM SNO — VMnet8)
```

---

## Installation sur WSL (Ubuntu)

```bash
sudo apt update && sudo apt install -y haproxy

# Copier la config
sudo cp haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg

# Vérifier la config
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Démarrer
sudo systemctl enable haproxy
sudo systemctl start haproxy

# Vérifier le statut
sudo systemctl status haproxy
```

---

## Stats HAProxy

Accessible depuis l'hôte : `http://localhost:9000/stats`  
Login : `admin` / `okdlab`

---

## Test de connectivité post-bootstrap

```bash
# API OpenShift
curl -k https://api.sno.okd.lab:6443/version

# Console (doit rediriger vers login)
curl -k -I https://console-openshift-console.apps.sno.okd.lab
```

---

## Notes

- En SNO, tous les backends pointent vers **un seul serveur** — le `balance roundrobin` n'a pas d'effet mais garde la config extensible si tu passes en compact cluster plus tard.
- Le port `22623` (MCS) n'est utile que pendant le bootstrap. Tu peux le laisser actif sans risque.
- HAProxy dans WSL **ne démarre pas automatiquement** au boot Windows — lancer manuellement avec `sudo systemctl start haproxy` ou ajouter un script de démarrage WSL.
