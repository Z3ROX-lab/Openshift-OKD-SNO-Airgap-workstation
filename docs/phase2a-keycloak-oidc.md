# Phase 2a — Keycloak OIDC : Identity Provider OKD SNO

## Objectif

Déployer Keycloak 26.5.5 sur OKD SNO via l'Operator Hub et le configurer comme Identity Provider OIDC pour la console OKD et la CLI `oc`.

## Architecture

```
Utilisateur
    │
    ▼
Console OKD / oc CLI
    │  OAuth2 Authorization Code Flow
    ▼
oauth-openshift.apps.sno.okd.lab  (OAuth Server OKD)
    │  OIDC redirect
    ▼
keycloak.apps.sno.okd.lab/realms/okd  (Keycloak)
    │  JWT token
    ▼
OKD API Server  (validation token)
```

## Composants déployés

| Composant | Version | Namespace | Status |
|-----------|---------|-----------|--------|
| Keycloak Operator | 26.5.5 | keycloak | ✅ Succeeded |
| Keycloak Instance | 26.5.5 | keycloak | ✅ Running |
| OAuth CR OKD | - | openshift-config | ✅ Configured |

## Prérequis

- OKD SNO 4.15 installé et opérationnel (Phase 1)
- Certificats kubelet valides (`scripts/okd-approve-csr.sh`)
- Router HAProxy up (port 443 accessible)

## Installation

### Étape 1 — Installer le Keycloak Operator

Via OperatorHub console OKD :

```
Operators → OperatorHub → "keycloak"
→ Keycloak Operator v26.5.5 (Community, Red Hat)
→ Update channel  : fast
→ Version         : 26.5.5
→ Installation mode : A specific namespace
→ Namespace       : keycloak (Create Project)
→ Update approval : Automatic
→ Install
```

Vérification :
```bash
oc get csv -n keycloak
# → keycloak-operator.v26.5.5   Succeeded
```

### Étape 2 — Copier le certificat TLS wildcard

```bash
./manifests/keycloak/01-tls-secret.sh
```

Ce script copie le wildcard cert `*.apps.sno.okd.lab` depuis `openshift-ingress` vers le namespace `keycloak`.

### Étape 3 — Déployer l'instance Keycloak

```bash
oc apply -f manifests/keycloak/02-keycloak-instance.yaml
```

L'instance Keycloak utilise le mode dev (H2 embarqué) — suffisant pour le lab portfolio.

Vérification :
```bash
oc get pods -n keycloak
# → keycloak-0   1/1   Running
oc get route -n keycloak
# → keycloak.apps.sno.okd.lab
```

Accès console : `https://keycloak.apps.sno.okd.lab`

Récupérer les credentials initiaux :
```bash
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Étape 4 — Configurer le Realm et le Client Keycloak

#### Créer le Realm `okd`

```
Administration Console → master dropdown → Create Realm
→ Realm name : okd
→ Create
```

#### Créer le Client OIDC `openshift`

```
Realm okd → Clients → Create client
→ Client type    : OpenID Connect
→ Client ID      : openshift
→ Next
→ Client authentication : On
→ Standard flow  : ✅
→ Next
→ Valid redirect URIs : https://oauth-openshift.apps.sno.okd.lab/*
→ Save
```

Récupérer le client secret :
```
Clients → openshift → Credentials → Client Secret
```

### Étape 5 — Configurer l'OAuth OKD

```bash
# Créer le secret avec le client secret Keycloak
oc create secret generic keycloak-client-secret \
  --from-literal=clientSecret=<CLIENT_SECRET> \
  -n openshift-config

# Appliquer la configuration OAuth
oc apply -f manifests/keycloak/04-oauth-cluster.yaml
```

Attendre le redémarrage du pod oauth :
```bash
watch oc get pods -n openshift-authentication
```

## Validation

### Test login console OKD via Keycloak

1. Ouvrir `https://console-openshift-console.apps.sno.okd.lab`
2. Cliquer sur "keycloak" (nouvel IDP)
3. Se connecter avec un utilisateur Keycloak du realm `okd`

### Créer un utilisateur de test dans Keycloak

```
Realm okd → Users → Add user
→ Username : admin-okd
→ Email    : admin-okd@okd.lab
→ Save
→ Credentials → Set password : Admin123!
→ Temporary : Off
```

### Donner les droits cluster-admin

```bash
oc adm policy add-cluster-role-to-user cluster-admin admin-okd
```

## DNS requis

Entrée dans `/etc/hosts` WSL2 et `C:\Windows\System32\drivers\etc\hosts` :

```
192.168.241.10 keycloak.apps.sno.okd.lab
```

## Fichiers manifests

| Fichier | Description |
|---------|-------------|
| `manifests/keycloak/01-tls-secret.sh` | Copie wildcard cert OKD → namespace keycloak |
| `manifests/keycloak/02-keycloak-instance.yaml` | CR Keycloak instance |
| `manifests/keycloak/03-client-secret.yaml` | Placeholder secret client (ne pas commiter la valeur réelle) |
| `manifests/keycloak/04-oauth-cluster.yaml` | OAuth CR OKD → Keycloak OIDC |

## Notes importantes

- Le secret `keycloak-initial-admin` est **temporaire** — créer un admin permanent puis supprimer `temp-admin`
- Le mode dev Keycloak (H2) ne persiste pas les données si le pod redémarre — Phase 3 ajoutera PostgreSQL avec PVC
- Le client secret ne doit **jamais** être commité en clair dans Git — utiliser SealedSecrets (Phase 4)
- Après chaque reboot OKD, relancer `./scripts/okd-approve-csr.sh` pour renouveler les certs kubelet

## Screenshots

| Fichier | Contenu |
|---------|---------|
| `keycloak-operator-hub.png` | Sélection Keycloak Operator dans OperatorHub |
| `keycloak-operator-install-config.png` | Configuration installation operator |
| `keycloak-operator-installing.png` | Installation en cours |
| `keycloak-operator-succeeded.png` | Operator Succeeded |
| `keycloak-operator-installed.png` | Vue Installed Operators namespace keycloak |
| `keycloak-login-page.png` | Page login Keycloak |
| `keycloak-create-realm.png` | Création realm okd |
| `keycloak-realm-okd-created.png` | Realm okd créé |
| `keycloak-client-openshift.png` | Client openshift configuré |
| `keycloak-client-credentials.png` | Client secret |
