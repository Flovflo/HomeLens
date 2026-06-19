# HomeLens — comment ça fonctionne

HomeLens publie **une** caméra Reolink (RTSP/ONVIF) dans Apple Home, avec vidéo + audio en direct et HomeKit Secure Video (HSV). Il y a **deux parties bien séparées** :

1. **Le pont HomeKit** — le moteur, fiable, qui tourne en permanence.
2. **L'app macOS** — une fenêtre de supervision (aperçu, diagnostic, réglages). Elle ne fait pas tourner le pont.

```
  Caméra Reolink                 Mac (HomeLens)                         Apple Home
  ┌────────────┐   RTSP/ONVIF   ┌───────────────────────────┐  HAP    ┌──────────┐
  │ main 4K    │───────────────▶│ homelensctl homekit-run    │────────▶│ iPhone / │
  │ + AAC 16k  │                │  └─ helper Node (HAP)      │  SRTP   │ HomePod  │
  │ sub 360p   │                │     • publie l'accessoire  │◀───────▶│ Apple TV │
  └────────────┘                │     • live vidéo+audio     │         └──────────┘
                                │     • HSV (enregistrement) │
                                │     • mouvement ONVIF      │
                                │                            │
                                │ App macOS (fenêtre)        │   HLS local
                                │  └─ aperçu live ◀──────────┼── ffmpeg→HLS→AVPlayer
                                └───────────────────────────┘
```

## 1. Le pont HomeKit (la partie qui compte)

Apple ne permet pas à une app Swift de *publier* une caméra : `HomeKit.framework` ne fait que contrôler des accessoires existants. On utilise donc un petit **helper Node (HAP-NodeJS)** : `Helpers/HomeKitBridge/src/index.mjs`.

Le helper est lancé et supervisé par la commande **`homelensctl homekit-run`**, elle-même démarrée en permanence par un **agent launchd** (`com.flo.HomeLens`, KeepAlive → redémarre tout seul, au login et en cas de crash). C'est *la frontière de fiabilité* : le pont tourne 24/7, que la fenêtre de l'app soit ouverte ou non.

Ce que fait le helper :

- **Publication** de l'accessoire « Front Door » en HAP sur le port `51826`, annoncé en Bonjour (`_hap._tcp`) sur le réseau. PIN d'appairage `031-45-154`. Une fois appairé, les appareils Apple Home le retrouvent tout seuls.
- **Live (quand on regarde la caméra)** : Home négocie une résolution, le helper lance **ffmpeg** qui lit le flux RTSP et l'envoie en **SRTP** (chiffré) à l'appareil qui regarde. La vidéo part du **flux main (4K) réduit nettement** à la taille demandée (et non du petit flux sub agrandi). Tout le pipeline tourne sur le **Media Engine d'Apple Silicon** via VideoToolbox — **décodage matériel** (`-hwaccel videotoolbox`, frames `videotoolbox_vld`), **mise à l'échelle matérielle** (`scale_vt`, les frames restent sur le GPU), **encodage matériel** (`h264_videotoolbox`) → **~10 % de CPU** au lieu de ~35 %, net, sans chauffe. L'**audio** AAC de la caméra est transcodé en **Opus** ; le micro est annoncé, donc le son fonctionne.
  - ⚠️ **La résolution du LIVE est choisie par Apple/Home** (souvent 720p–1080p, même en très bon Wi-Fi local — Apple plafonne le streaming en direct). On offre jusqu'au 4K, mais Home décide. La **vraie 4K, c'est pour l'enregistrement (HSV)**, pas le direct.
- **HomeKit Secure Video (HSV)** : le helper garde en mémoire un *prebuffer* (les dernières secondes) en MP4 fragmenté. Quand l'ONVIF détecte un mouvement, Home demande l'enregistrement et le helper lui envoie l'init + les fragments (vidéo **+ audio réel**).
- **Mouvement** : `homelensctl` s'abonne aux événements ONVIF de la caméra (pull-point) et transmet « motion/person » au helper, qui met à jour le capteur de mouvement HomeKit (déclencheur HSV).

### Le piège du Mac multi-cartes (corrigé)
Si le Mac a **deux cartes réseau sur le même sous-réseau** (ici `en0`=192.168.0.12 et `en7`=192.168.0.10), la connexion HomeKit peut arriver sur une carte alors que la route vers l'iPhone sort par l'autre → l'iPhone reçoit la vidéo depuis une adresse inattendue et la **jette** (écran noir, pas de son). Le helper choisit donc l'adresse locale qui **route réellement** vers l'appareil qui regarde (`addressOverride`). Tu peux aussi forcer la carte dans **Réglages → Carte réseau** (voir §4).

## 2. L'aperçu live dans l'app macOS

`AVPlayer` ne lit pas le RTSP. L'app lance donc **ffmpeg** qui reconditionne le RTSP en **HLS** (segments de 1 s) dans un dossier temporaire, servi par un mini serveur HTTP local (loopback, `LocalHLSServer`), lu par `AVPlayer` (`LivePlayerService` + `LivePlayerView`).

- **« Rapide »** = flux *sub* (faible latence). Le flux sub a un GOP très long, donc on le **ré-encode** avec une image-clé par seconde pour des segments fluides.
- **« Qualité »** = flux *main* (pleine résolution), copié tel quel.
- Bouton 🔊 = mute/unmute (`AVPlayer.isMuted`).

C'est totalement indépendant du pont HomeKit (aucun rapport avec l'iPhone ni le SRTP).

## 3. Jusqu'où on monte en 4K

La caméra : **main = H.264 High 3840×2160 (4K) + AAC 16 kHz**, **sub = 640×360**.

Le pont **annonce à Home tout l'éventail jusqu'au 4K**, pour le live *et* l'enregistrement :
`3840×2160 · 2560×1440 · 1920×1080 · 1280×720 · 640×360 · 320×180`.

- **HSV (enregistrement)** : quand Home choisit le 4K natif, le helper **copie le flux 4K de la caméra sans le ré-encoder** → vraie 4K, qualité d'origine, et quasi aucun CPU (important car le prebuffer tourne en continu). Si Home choisit plus petit, il transcode à cette taille.
- **Live** : Home choisit lui-même la résolution du direct (souvent ≤ 1080p — c'est Apple qui décide pour le streaming, pas nous). On lui offre quand même jusqu'au 4K.
- **fps** : annoncé à 15 i/s. C'est volontaire — le 4K en temps réel reste fluide à 15 i/s ; monter à 25 risquerait de faire décrocher le transcodage quand il a lieu.

Donc : **on donne tout (jusqu'au 4K) à Home**, et Home prend ce qu'il veut selon le contexte.

## 4. Choisir la carte réseau

**Réglages → Carte réseau** :
- **Automatique** (recommandé) : le pont choisit l'interface qui atteint Apple Home.
- **enX · IP** : force le pont à publier sur cette carte précise (utile si le Mac a plusieurs cartes).

Changer la carte puis **« Appliquer au pont »** réécrit la config et redémarre l'agent launchd pour appliquer le réglage.

## 5. Diagnostic (mode debug)

Onglet **Diagnostic** (ou `homelensctl doctor` en terminal) : teste toute la chaîne et affiche vert/orange/rouge —
**Caméra** (ping, RTSP main/sub, audio, ONVIF, image) → **Relai HomeLens** (ffmpeg, node, pont actif, port 51826) → **Réseau & Apple** (Internet, Bonjour, iCloud) → **Apple Home** (appairage, HSV, audio). On voit immédiatement *où* ça coince.

## 6. Déployer / appliquer des changements

Le pont tourne depuis l'app *packagée* (`dist/HomeLens.app`), pas depuis les sources. Après une modif de code :

```bash
./script/package_app.sh          # reconstruit + embarque le helper (node_modules inclus)
./script/install_bridge_agent.sh # (ré)installe l'agent launchd qui lance homekit-run
```

Vérifier : `homelensctl doctor` (chaîne verte) ou l'onglet Diagnostic.

## Fichiers clés

| Rôle | Fichier |
|---|---|
| Helper HAP (live, HSV, snapshot, mouvement) | `Helpers/HomeKitBridge/src/index.mjs` |
| CLI / supervision du pont | `Sources/HomeLensCLI/main.swift` (`homekit-run`, `doctor`) |
| Moteur de diagnostic (partagé CLI+GUI) | `Sources/HomeLensCore/DiagnosticsRunner.swift` |
| Config caméra + carte réseau | `Sources/HomeLensCore/CameraConfig.swift`, `HomeKitBridgeConfig.swift` |
| Aperçu live in-app | `Sources/HomeLens/Services/LivePlayerService.swift`, `LocalHLSServer.swift`, `Views/LivePlayerView.swift` |
| Interface | `Sources/HomeLens/Views/ContentView.swift`, `ViewModels/AppModel.swift` |
| Agent launchd du pont | `script/install_bridge_agent.sh` |
