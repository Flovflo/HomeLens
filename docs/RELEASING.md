# Publier une release signée + notarisée

Pour qu'un·e utilisateur·rice puisse **double-cliquer** sur l'app sans aucun
avertissement macOS, il faut la **signer** avec un certificat *Developer ID* puis
la faire **notariser** par Apple. Ça nécessite le **programme Apple Developer
payant** (99 $/an) — un compte gratuit ne peut pas créer de Developer ID.

À faire **une seule fois** : étapes 1 et 2. Ensuite, chaque release = une commande (étape 3).

---

## Étape 1 — Certificat « Developer ID Application »

### Sans Xcode (via Trousseau d'accès)
1. **Trousseau d'accès** → menu **Trousseau d'accès › Assistant de certification ›
   Demander un certificat à une autorité de certification…**
   - Adresse e-mail : ton e-mail Apple Developer
   - **Demande : « Enregistré sur le disque »** → enregistre `CertificateSigningRequest.certSigningRequest`.
2. Va sur **https://developer.apple.com/account** → **Certificates** → **＋** →
   choisis **« Developer ID Application »** → téléverse le fichier CSR → **télécharge** le `.cer`.
3. **Double-clique** le `.cer` : il s'installe dans le trousseau **« session »** (login),
   apparié à la clé privée générée à l'étape 1.

### Avec Xcode (plus simple si tu l'as)
Xcode → **Settings › Accounts** → sélectionne ton équipe → **Manage Certificates…**
→ **＋** → **Developer ID Application**.

### Vérifier
```bash
security find-identity -v -p codesigning
# doit afficher :  "Developer ID Application: Ton Nom (XXXXXXXXXX)"
```
Le `XXXXXXXXXX` entre parenthèses est ton **Team ID**.

---

## Étape 2 — Identifiants de notarisation

Recommandé : une **clé API App Store Connect** (révocable, pas de mot de passe Apple ID).

1. **https://appstoreconnect.apple.com** → **Users and Access** → onglet
   **Integrations** → **App Store Connect API** → **＋** pour générer une clé
   (rôle **Developer** suffit).
2. **Télécharge le fichier `AuthKey_XXXXXXXX.p8`** (téléchargeable **une seule fois**).
   Note le **Key ID** et l'**Issuer ID** affichés sur la page.
3. Enregistre tout ça dans le Trousseau (rien n'est écrit dans le dépôt) :
   ```bash
   ./script/setup_notary.sh           # crée le profil "homelens-notary"
   ```
   Choisis **« App Store Connect API key »** et colle : Issuer ID, Key ID,
   chemin du `.p8`.

> Alternative : Apple ID + **mot de passe pour application** (créé sur
> https://appleid.apple.com → *Connexion et sécurité*) + Team ID. `setup_notary.sh`
> propose aussi cette méthode.

---

## Étape 3 — Publier

```bash
./script/release.sh v0.1.0
```

Ce script enchaîne automatiquement :
1. `package_app.sh` — build auto-contenu (ffmpeg + Node.js intégrés)
2. **signe** (Developer ID, *hardened runtime*) → **notarise** → **agrafe** l'app
3. construit le **DMG** à partir de l'app signée
4. **signe + notarise + agrafe** le DMG
5. crée la **release GitHub** `v0.1.0` avec le DMG en pièce jointe

À la fin, n'importe qui peut télécharger le DMG depuis la page Releases,
glisser l'app dans Applications et l'ouvrir **sans avertissement**.

---

## Détails techniques

- Le *hardened runtime* (obligatoire pour la notarisation) casse Node.js (JIT V8)
  et les dylibs relogés sauf entitlements : voir
  [`script/entitlements/helper.entitlements`](../script/entitlements/helper.entitlements)
  (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`),
  appliquées à `node`, `ffmpeg`, `ffprobe` et aux addons natifs `.node`.
- Tous les binaires Mach-O du bundle sont signés *inside-out* avant de sceller le `.app`.
- Surcharges possibles : `SIGN_IDENTITY="Developer ID Application: …"` et
  `NOTARY_PROFILE=homelens-notary`.
