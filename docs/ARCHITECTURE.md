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

Le helper est lancé et supervisé par la commande **`homelensctl homekit-run`**, elle-même démarrée en permanence par un **agent launchd** (`com.homelens.app`, KeepAlive → redémarre tout seul, au login et en cas de crash). C'est *la frontière de fiabilité* : le pont tourne 24/7, que la fenêtre de l'app soit ouverte ou non.

Ce que fait le helper :

- **Publication** de l'accessoire « Front Door » en HAP sur le port `51826`, annoncé en Bonjour (`_hap._tcp`) sur le réseau. PIN d'appairage `031-45-154`. Une fois appairé, les appareils Apple Home le retrouvent tout seuls.
- **Live** : Maison négocie la résolution et le débit H.264 ; ffmpeg utilise VideoToolbox pour décoder, réduire et encoder le flux principal. La cadence et les changements de paramètres demandés par Maison sont appliqués.
- **HomeKit Secure Video (HSV)** : le helper garde en mémoire un *prebuffer* (les dernières secondes) en MP4 fragmenté. Quand l'ONVIF détecte un mouvement, Home demande l'enregistrement et le helper lui envoie l'init + les fragments (vidéo **+ audio réel**).
- **Mouvement** : `homelensctl` s'abonne aux événements ONVIF de la caméra (pull-point) et transmet « motion/person » au helper, qui met à jour le capteur de mouvement HomeKit (déclencheur HSV).

### Le piège du Mac multi-cartes (corrigé)
Si le Mac a **deux cartes réseau sur le même sous-réseau** (ici `en0`=192.168.0.12 et `en7`=192.168.0.10), la connexion HomeKit peut arriver sur une carte alors que la route vers l'iPhone sort par l'autre → l'iPhone reçoit la vidéo depuis une adresse inattendue et la **jette** (écran noir, pas de son). Le helper choisit donc l'adresse locale qui **route réellement** vers l'appareil qui regarde (`addressOverride`). Tu peux aussi forcer la carte dans **Réglages → Carte réseau** (voir §4).

## 2. L'aperçu live dans l'app macOS

`AVPlayer` ne lit pas le RTSP. L'app lance donc **ffmpeg** qui reconditionne le RTSP en **HLS fMP4** (cible de 1 s, limitée par les images-clés en mode copie) dans un dossier temporaire, servi par un mini serveur HTTP local (loopback, `LocalHLSServer`), lu par `AVPlayer` (`LivePlayerService` + `LivePlayerView`).

- **« Rapide »** = flux *sub* (faible latence). Le flux sub a un GOP très long, donc on le **ré-encode avec VideoToolbox** avec une image-clé par seconde pour des segments fluides.
- **« Qualité »** (par défaut) = flux *main* (pleine résolution), vidéo copiée en HLS fMP4 compatible H.264/HEVC.
- Bouton 🔊 = mute/unmute (`AVPlayer.isMuted`).

C'est totalement indépendant du pont HomeKit (aucun rapport avec l'iPhone ni le SRTP).

## 3. Enregistrements 4K avec iOS/tvOS 27

Le réglage **Originale / 4K** conserve le flux principal H.264 ou HEVC sans réencodage vidéo, y compris lorsque la configuration HAP historique indique encore 1080p. Il nécessite des concentrateurs en version 27. Le mode **Compatible**, conservé pour les anciennes configurations, respecte la qualité négociée par Maison et transcode avec VideoToolbox.

Les propriétés réelles de la caméra sont détectées au démarrage. Le profil de l'aperçu n'impose aucune limite aux enregistrements. Les paramètres de négociation et le format de sortie sont journalisés séparément. Voir [l'audit vidéo](VIDEO_PIPELINE.md) pour les sources Apple, le support HEVC via HDS et les vérifications.

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
