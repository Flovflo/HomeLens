# Vidéo : diagnostic et correctifs des 18–19 septembre 2026

## Cause de la perte de qualité

La caméra testée fournit du H.264 High en 3840 × 2160, avec une cadence annoncée de 25 images/s. Les journaux du pont montraient une configuration HomeKit sélectionnée en 1920 × 1080 à 15 images/s et 1 600 kbit/s. Le helper ne copiait la vidéo que si la résolution sélectionnée correspondait aux dimensions supposées de la caméra. Il réduisait donc systématiquement cette source 4K et la recompressait. De plus, la cadence négociée était calculée mais jamais appliquée à ffmpeg.

Le problème principal était cette politique de conversion, pas la capacité du M2. Le profil d'aperçu `sub` influençait également la configuration HomeKit générée par le CLI, même si le pont ouvrait toujours le flux principal.

## Enregistrements dans Maison

Dans Réglages, choisir **Enregistrement Maison → Originale / 4K**, puis **Appliquer au pont**. Tous les concentrateurs doivent être en version 27 pour ce mode. Équivalent CLI :

```sh
homelensctl recording-quality native
# Redémarrer le service installé pour appliquer le réglage.
launchctl kickstart -k gui/$(id -u)/com.homelens.app
```

Le mode `native` conserve les paquets vidéo H.264 ou HEVC du flux principal, leur résolution et leurs horodatages, sans décodage, mise à l'échelle ni réencodage vidéo. HEVC est étiqueté `hvc1` dans le MP4 fragmenté. L'audio est adapté au format AAC demandé par Maison, uniquement si l'option d'enregistrement audio de Maison est active.

La négociation HAP historique peut encore indiquer 1080p/H.264. En mode original, cela ne décrit pas nécessairement le contenu effectivement transporté dans le MP4. Le journal distingue désormais `resolution` / `negotiatedBitrateKbps` de `output` (codec, dimensions, cadence source et `copy`). Ne pas déduire la qualité du fichier des seuls champs de négociation.

Pour un ancien concentrateur, sélectionner **Compatible** ou `homelensctl recording-quality compatible`. Ce mode respecte les dimensions, la cadence, le débit et l'intervalle d'images-clés négociés. Le décodage, la mise à l'échelle et l'encodage utilisent VideoToolbox, avec les images conservées en surfaces matérielles. Les anciennes configurations sans ce réglage restent en mode compatible.

Le direct reste en H.264 sur SRTP et respecte les changements de débit/résolution demandés par Maison. Il utilise le flux principal pour les tailles HD. Le mode d'enregistrement ne change pas le codec de la caméra : après un changement H.264/H.265 dans Reolink, redémarrer le pont pour refaire la détection.

## Horodatages de la caméra : gel puis avance rapide

Mesures du 19 septembre sur une Reolink CX810 (firmware v3.1.0.5129, H.264 High 3840 × 2160, 6144 kbit/s, 25 i/s configurées, GOP 2 s, RTMP annoncé mais inaccessible) :

- Les horodatages RTP vidéo sautent d'environ 1,6 s juste après chaque image-clé (~730 Ko), puis les 49 images suivantes sont espacées de ~22 ms. La durée réelle d'un GOP varie de 2,4 à 2,9 s selon le transport (TCP ou UDP), ce qui prouve que ces horodatages suivent la file d'envoi de la caméra et non la capture.
- L'arrivée réelle des paquets est aussi en rafales (pause de ~0,7 s après l'image-clé), alors que l'audio arrive régulièrement sur la même connexion TCP : le goulot est l'encodeur de la caméra, pas le réseau.
- Aucun trou dans les `frame_num` H.264 : la caméra encode réellement 17 à 21 i/s en 4K, sans perdre d'images en cours de route.

Conséquences observées : l'aperçu macOS suit l'horloge audio (régulière), donc la vidéo gelait puis avançait d'un coup ; le direct HomeKit transmettait ce jitter en RTP, et l'iPhone, l'interprétant comme un réseau dégradé, renégociait 640 × 360 à 132 kbit/s, ce que le pont appliquait à la lettre.

Correctif : les paquets vidéo sont réhorodatés avant décodage ou copie, avec le filtre `setts` de ffmpeg 8 placé avant `-i` (`smoothedTimestampArgs` côté Node, `VideoPipeline.smoothedTimestampArguments` côté Swift, même expression). Cadence nominale pour les K premières images (K = 2 × cadence, borné entre 20 et 100), puis cadence moyenne de la sortie depuis son origine, asservie à l'horloge source avec un gain 1/K. L'état est ancré sur la sortie, avec une origine à 0 quand le premier paquet n'a pas d'horodatage : c'est le cas de la première image-clé RTSP de cette caméra (`pts = N/A`), et une première version ancrée sur l'entrée produisait des images espacées d'un seul tick. Un horodatage d'entrée absent est extrapolé à la cadence courante. Aucun paquet n'est supprimé, réordonné ni réencodé ; les empreintes SHA-256 restent identiques. Sur les captures réelles, l'écart entre images passe de 0 à 1,6 s vers 36 à 88 ms (36 à 61 ms en sortie du prébuffer sur la caméra le 19 septembre) ; l'alignement moyen avec l'audio est conservé, avec une ondulation résiduelle inférieure à une seconde au sein d'un GOP. Cette approche suppose l'absence d'images B (cas des Reolink : `max_num_ref_frames = 1`). L'aperçu macOS met en tampon 3 s pour absorber les rafales.

### Direct HomeKit : relais de régulation

Même avec des horodatages lissés, ffmpeg transmet les paquets RTP dès que la caméra les livre, donc en rafales : mesuré sur le direct 4K, jusqu'à 1,4 s sans paquet, puis un GOP entier, soit des paquets jusqu'à 1,25 s en retard sur leur horaire (écart total 2,5 s). Le tampon de gigue de l'iPhone est bien plus petit : micro-coupures à chaque rafale. Le helper intercale désormais un relais local (`PacedRelay`) : ffmpeg envoie en SRTP vers la boucle locale, et le relais libère chaque paquet vidéo à l'instant de son horodatage RTP plus une marge (1 s au départ, élargie jusqu'au plus grand retard observé, bornée à 2,5 s). Les paquets d'une même image sont en outre étalés à 40 Mbit/s au lieu de partir d'un bloc : une image-clé 4K de 730 Ko (600 paquets et plus) envoyée d'un coup provoquait des pertes de 20 à 30 paquets, donc des images corrompues ; étalée sur ~150 ms, plus aucune perte mesurée. L'audio et les rapports RTCP suivent la même marge, donc l'alignement audio/vidéo ne change pas. Une seule file FIFO et un seul minuteur garantissent l'ordre des paquets (des minuteurs par paquet réordonnaient les paquets d'une même image). Les paquets SRTP restent opaques : ni rechiffrement ni renumérotation. Mesuré sur la caméra : écart de sortie de 181 ms au plus (étalement des images-clés compris), ordre des séquences conservé, 25 paquets au maximum par envoi. Le prix est une latence supplémentaire d'environ une seconde sur le direct.

### Fin des clips HSV

Un plafond accessoire `maxSeconds` de 20 s faisait terminer le clip par le pont pendant que le mouvement continuait ; le concentrateur n'accuse jamais cette fin, et HAP-NodeJS force la fermeture 12 s plus tard avec `CANCELLED` (clips de 32 s dans les journaux). Le concentrateur termine les clips lui-même (fermeture ou fin de mouvement) ; le plafond passe à 600 s comme simple garde-fou. Les clips terminés par fin de mouvement sont acquittés (`reason=acknowledged`).

Le direct HomeKit en mode original copie le H.264 4K sur le réseau local (même sous-réseau IPv4) et ignore les reconfigurations de débit demandées par Maison, comme Scrypted ; hors réseau local ou avec une source HEVC, il reste sur l'encodeur VideoToolbox négocié.

## Pourquoi garder le transport existant

[Apple confirme la 4K avec iOS 27](https://www.apple.com/os/ios/). Son [guide HKSV de juin 2026](https://developer.apple.com/download/files/HomeKit-Secure-Video-Open-Source-Compatibility-Guide.pdf) décrit aussi de nouveaux services, des niveaux de qualité, HEVC, WebRTC et la publication CMAF. HomeLens n'annonce pas ces nouveaux services sans les implémenter.

La [documentation actuelle de Scrypted](https://docs.scrypted.app/homekit.html#homekit-secure-video-v3) confirme que le transport HDS historique accepte les enregistrements HEVC depuis iOS/tvOS 27. Son [mainteneur confirme également la 4K sur ce transport](https://www.reddit.com/r/Scrypted/comments/1wj4bez/ios_27_and_homekit_secure_video_version_3_h265/). C'est une preuve d'implémentation distincte du guide Apple, pas une nouvelle valeur de codec HAP inventée. Les faux identifiants HAP de niveaux 5.0/5.1 ont été supprimés ; le niveau réel du flux copié reste celui de la caméra.

## macOS et M2

L'aperçu sélectionne maintenant le flux principal par défaut. Le HLS est produit en fMP4, avec `hvc1` pour HEVC, conformément aux [règles HLS Apple](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/). AVPlayer décode le flux original. Le mode léger utilise également VideoToolbox au lieu de libx264 sur le CPU.

L'app attend l'initialisation MP4 et un segment réellement présent. Elle confirme la lecture avec AVPlayer, conserve les erreurs visibles et évite les pipes non lus qui pouvaient bloquer ffmpeg. Le démarrage HLS conserve l'[attente automatique d'AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling) : la désactiver avant le chargement reproduisait ici une première image figée, avec un état `.playing` mais un débit de lecture et une horloge à zéro. L'indication « En direct » vérifie aussi la vitesse et le temps de lecture.

La latence du HLS dépend toujours des images-clés de la caméra : une cible de segment d'une seconde ne peut pas créer une image-clé dans une vidéo copiée. Un GOP de 1 à 2 secondes côté caméra facilite l'aperçu et le prébuffer ; HomeLens ne modifie pas automatiquement ce réglage.

Lors d'une reconnexion du prébuffer, les lecteurs de l'ancienne session sont terminés avant l'arrivée du nouveau `moov`. Cela évite de mélanger deux générations d'encodeur. Si le prébuffer n'est pas disponible, la requête échoue dans un délai borné ; elle ne lance plus une seconde session RTSP concurrente pouvant attendre indéfiniment.

## Validation reproductible

```sh
swift build
./script/test_video_pipeline.sh
./script/test_video_pipeline.sh --media  # macOS + ffmpeg avec VideoToolbox
./script/package_app.sh
codesign --verify --deep --strict dist/HomeLens.app
```

Les tests médias génèrent des sources 4K H.264 et HEVC à 25 images/s. Ils vérifient les dimensions et la cadence, le décodage complet, le chemin compatible 1080p15 et l'identité SHA-256 de chaque paquet vidéo en mode original. Un test AVPlayer supplémentaire lit réellement le HLS des deux codecs via le serveur local et exige une horloge qui avance ainsi qu'une image 3840 × 2160. Ils n'utilisent ni caméra ni identifiants. Le lanceur Swift fonctionne avec les seuls Command Line Tools, sans XCTest.

Sur la vraie caméra, un échantillon issu du générateur de prébuffer corrigé a été décodé sans erreur : H.264 3840 × 2160, environ 6,1 Mbit/s vidéo, audio AAC 48 kHz. Le premier fragment était disponible en environ 4,2 secondes. Il s'agit d'une validation du flux envoyé à HomeKit ; seule la récupération d'un nouveau clip depuis Maison permet de vérifier ce qu'iCloud conserve effectivement. Aucun pourcentage de CPU universel ni délai identique à l'app Reolink n'est garanti.

Après installation le 19 septembre, le pont appairé a redémarré en mode `native`. Maison a sélectionné une configuration historique 1920 × 1080 / 30 images/s / 2 000 kbit/s ; les journaux du prébuffer confirment néanmoins une sortie H.264 3840 × 2160 avec `copy: true`, conformément au mode choisi. L'aperçu 4K fonctionne également dans l'application installée. La validation du fichier final conservé dans iCloud reste à effectuer depuis Maison.
