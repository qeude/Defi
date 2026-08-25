# Overview macOS dans Paneru, OmniWM et Rift

Recherche effectuée le 23 août 2026 sur les dépôts officiels, aux révisions suivantes :

- [Paneru `bcf248e`](https://github.com/karinushka/paneru/tree/bcf248ef60aa4c0b49002161b97bc6e268b05aa7)
- [OmniWM `430ec6c`](https://github.com/BarutSRB/OmniWM/tree/430ec6c902b12e0a32332a8fe40541d73d8d4b2d)
- [Rift `be8afef`](https://github.com/acsandmann/rift/tree/be8afef6036c77b67b4c49725ced6414601d63b0)

## Réponse courte

Paneru ne dessine pas d'overview. Il laisse le Dock afficher Mission Control, ce qui lui donne de vraies miniatures sans demander lui-même Screen Recording. En contrepartie, macOS ne connaît pas ses workspaces virtuels et ne peut pas montrer leur organisation comme Niri.

OmniWM et Rift dessinent leur propre vue, mais récupèrent tous deux les pixels des fenêtres avec ScreenCaptureKit. Sans Screen Recording, OmniWM conserve une vue utile faite de cartes, icônes, titres et géométrie logique. Rift conserve surtout des cadres vides. Aucun des trois ne produit les pixels réels d'autres applications dans un overview personnalisé sans la permission de capture.

Apple demande le consentement de la personne avant toute capture ScreenCaptureKit et une clé `NSScreenCaptureUsageDescription` dans l'application. Le framework peut signaler que la personne a refusé la permission. [Documentation ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [erreurs de permission](https://developer.apple.com/documentation/screencapturekit/error-constants)

| Projet | Vue personnalisée | Pixels des fenêtres | Sans Screen Recording | Fenêtre d'overlay | Activation par geste de l'overview |
| --- | --- | --- | --- | --- | --- |
| Paneru | Non, Mission Control natif | Rendus par macOS | Oui, car Paneru ne capture rien | Aucune pour l'overview | Geste Mission Control géré par macOS |
| OmniWM | Oui | ScreenCaptureKit | Cartes avec icône, titre et structure | `NSPanel` AppKit par moniteur | Non documentée, raccourci global |
| Rift | Oui, expérimental | ScreenCaptureKit | Cadres sans contenu capturé | Fenêtre CGS et `CAContext` privés | Non, raccourcis ou commandes |

## Paneru

### Ce qu'il affiche

Paneru s'appuie sur les Spaces et Mission Control de macOS. Son README décrit des bandes séparées par workspace macOS et des workspaces virtuels internes, mais ne présente aucun overview propriétaire. [README](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/README.md#L25-L44)

Le code confirme ce choix. `MissionControlHandler` trouve le processus `com.apple.dock`, crée un `AXObserver` et écoute `AXExposeShowAllWindows`, `AXExposeShowFrontWindows`, `AXExposeShowDesktop` et `AXExposeExit`. Ces noms de notifications ne font pas partie de l'API Accessibility publique documentée. [Observation du Dock](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/platform/mission_control.rs#L51-L82), [installation de l'observer](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/platform/mission_control.rs#L88-L146)

À l'entrée dans Mission Control, Paneru marque la vue native active et interrompt son scrolling. À la sortie, il recherche les fenêtres déplacées par l'utilisateur et réconcilie son modèle. [Réaction aux événements Mission Control](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/ecs/triggers.rs#L348-L399)

Les overlays AppKit de Paneru ne sont pas des miniatures. Ce sont des fenêtres transparentes et non interactives, une par écran, utilisées pour l'assombrissement et la bordure de focus. [Fabrique et gestion des overlays](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/overlay.rs#L211-L267)

### Permissions et capture

Paneru exige Accessibility pour déplacer les fenêtres. Son `Info.plist` ne contient aucune justification de capture d'écran et le code ne contient aucun pipeline ScreenCaptureKit. Les vraies miniatures appartiennent au Dock, pas au processus Paneru. [Permission documentée](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/README.md#L68-L76), [`Info.plist`](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/assets/Info.plist#L1-L14)

Ce chemin utilise tout de même des API privées pour coopérer avec Mission Control, puisque les notifications `AXExpose*` observées sur le Dock sont non documentées. Paneru utilise aussi SkyLight dans son gestionnaire de fenêtres, mais pas pour fabriquer des miniatures d'overview. [Déclaration de l'intégration SkyLight](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/manager.rs#L195-L214)

### Gestes

Paneru installe un `CGEventTap` HID, convertit les événements de geste en `NSEvent`, lit `allTouches()` et suit les positions `NSTouch`. Si aucun nombre de doigts valide n'est configuré, il laisse explicitement les gestes natifs à macOS. Cette mécanique sert au scrolling et au changement de workspace virtuel, pas à une vue Paneru. [Event tap](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/platform/input.rs#L146-L180), [décodage des gestes](https://github.com/karinushka/paneru/blob/bcf248ef60aa4c0b49002161b97bc6e268b05aa7/src/platform/input.rs#L372-L464)

## OmniWM

### Ce qu'il affiche

OmniWM possède un vrai overview de ses workspaces. Il projette la liste des moniteurs, workspaces et fenêtres depuis son modèle, puis récupère la structure Niri de chaque workspace sous forme de colonnes, largeurs et hauteurs. Il ne redimensionne pas les vraies fenêtres pour construire cette projection. [Construction du snapshot](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Overview/OverviewController.swift#L704-L750), [snapshot des colonnes Niri](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Layout/Niri/NiriOverviewSnapshot.swift#L24-L46)

OmniWM crée un `NSPanel` borderless par moniteur. Chaque panel occupe l'écran, accepte la souris, vit au niveau `.screenSaver` et rejoint tous les Spaces. Le panel principal devient la fenêtre clavier, les autres restent visibles. [Configuration du panel](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Overview/OverviewWindow.swift#L26-L52), [création par moniteur](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Overview/OverviewController.swift#L1143-L1220)

La vue est interactive. Le code et la documentation couvrent sélection, recherche, fermeture, navigation clavier, déplacement structurel et glisser-déposer entre workspaces et colonnes. [Comportement documenté](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/README.md#L695-L712)

### Miniatures et fallback sans capture

À l'ouverture, OmniWM démarre une capture asynchrone. Il vérifie `CGPreflightScreenCaptureAccess()`, demande les fenêtres avec `SCShareableContent`, crée un filtre `desktopIndependentWindow` et appelle `SCScreenshotManager.captureImage`. Il limite le travail à quatre captures concurrentes et met les images en cache pour le rendu. [Pipeline de capture](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Overview/OverviewController.swift#L1270-L1383)

Si Screen Recording manque, `startThumbnailCapture` s'arrête avant toute capture. Le renderer dessine quand même le fond, la bordure, l'icône d'application, le titre et le nom de l'application. Il ajoute l'image seulement quand le cache contient une miniature. L'overview reste donc navigable et fidèle à la structure, mais ne montre pas le contenu des fenêtres. [Image conditionnelle](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Overview/OverviewRenderer.swift#L420-L465), [icône et textes](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Overview/OverviewRenderer.swift#L480-L572)

Le produit assume ce compromis. Accessibility et Input Monitoring sont obligatoires au lancement, Screen Recording est optionnel. L'écran de permissions propose « Continue Without Screen Recording », et `Info.plist` explique l'usage des captures. [Modèle des permissions](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/UI/LaunchPermissionsWindowController.swift#L10-L47), [vérification et demande](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/UI/LaunchPermissionsWindowController.swift#L90-L137), [`Info.plist`](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Info.plist#L23-L30)

### API privées et gestes

Le rendu de l'overview lui-même repose sur AppKit, Core Graphics et ScreenCaptureKit publics. OmniWM charge toutefois `MultitouchSupport.framework` dynamiquement et résout les symboles privés `MTDevice*` pour ses gestes globaux. Si le framework ou un symbole manque, cette source devient indisponible. [Chargement de MultitouchSupport](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/Sources/OmniWM/Core/Multitouch/MultitouchBinding.swift#L59-L95)

Le README n'associe pas ces gestes à l'ouverture de l'overview. Il documente un raccourci global pour l'overview et réserve les gestes trackpad au scrolling des colonnes et au changement de workspace. Pour les swipes verticaux à trois ou quatre doigts, il demande même de désactiver le geste Mission Control de macOS afin d'éviter le conflit. [Ouverture de l'overview](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/README.md#L695-L703), [gestes trackpad](https://github.com/BarutSRB/OmniWM/blob/430ec6c902b12e0a32332a8fe40541d73d8d4b2d/README.md#L747-L751)

## Rift

### Ce qu'il affiche

Rift appelle sa vue « Mission Control ». Elle est expérimentale et désactivée par défaut. Deux commandes ouvrent soit tous les workspaces, soit une vue éclatée des fenêtres du workspace courant. [Configuration par défaut](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/rift.default.toml#L215-L221), [commandes d'ouverture](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/rift.default.toml#L495-L500)

L'acteur copie un snapshot du runtime puis transmet soit les workspaces, soit les fenêtres actives à l'overlay. Les clics déclenchent un changement de workspace ou le focus d'une fenêtre, puis ferment la vue. [Cycle de l'acteur](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/actor/mission_control.rs#L64-L123), [modes d'affichage](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/actor/mission_control.rs#L127-L189)

Son overlay n'est pas un `NSWindow`. Rift crée une fenêtre WindowServer avec `SLSNewWindowWithOpaqueShapeAndContext`, puis essaie d'y attacher un `CALayer` via la classe privée `CAContext`, `remoteContextWithOptions:` et `SLSSetWindowLayerContext`. Une voie de repli dessine le layer dans un contexte de fenêtre SkyLight. [Création de la fenêtre CGS](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/sys/cgs_window.rs#L90-L123), [liaison du `CAContext`](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/sys/cgs_window.rs#L224-L239), [hébergement et repli](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/ui/mission_control.rs#L1263-L1316)

### Miniatures et permissions

Les pixels ne viennent pas de ces API privées. Rift utilise `SCShareableContent`, un filtre `desktopIndependentWindow` et `SCScreenshotManager`. Il récupère l'`IOSurface` du sample buffer et l'assigne au contenu du `CALayer` correspondant. [Préparation des captures](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/ui/mission_control.rs#L110-L187), [capture du sample buffer](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/ui/mission_control.rs#L197-L258), [affectation aux layers](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/ui/mission_control.rs#L1064-L1152)

Quand ScreenCaptureKit échoue, Rift ignore l'erreur et laisse le layer sans contenu. Les bordures et les labels de workspace restent dessinés, mais le code n'ajoute ni icône, ni titre à chaque carte. Le fallback sans capture est donc moins lisible que celui d'OmniWM. [Layers de fenêtres](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/ui/mission_control.rs#L1010-L1062), [échec de capture toléré](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/ui/mission_control.rs#L226-L266)

Le dépôt audité ne vérifie pas `CGPreflightScreenCaptureAccess`, ne demande pas `CGRequestScreenCaptureAccess` et son `Info.plist` n'a pas de `NSScreenCaptureUsageDescription`. Il invite seulement à accorder Accessibility. Cela ne contourne pas la protection de macOS, puisque ScreenCaptureKit exige le consentement. C'est une lacune du packaging ou de l'expérience de permission de cette fonctionnalité expérimentale. [`Info.plist`](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/assets/Info.plist#L1-L20), [demande Accessibility](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/sys/accessibility.rs#L61-L88), [règle Apple](https://developer.apple.com/documentation/screencapturekit)

### Gestes

Les gestes de Rift ne servent pas à ouvrir son Mission Control. Ils servent au changement de workspace et au scrolling. Rift lit directement des événements CGS de type 29 et leurs collections digitizer IOHID via un `CGEventTap` HID. Cette voie est explicitement décrite comme privée dans le code. [Description du gesture tap](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/actor/gesture_tap.rs#L1-L6), [installation du tap](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/actor/gesture_tap.rs#L336-L399), [décodage CGS et IOHID](https://github.com/acsandmann/rift/blob/be8afef6036c77b67b4c49725ced6414601d63b0/src/sys/gesture.rs#L1-L60)

## Décision sur Screen Recording pour Defi

### Ce que la permission autorise

Sans le picker système, ScreenCaptureKit demande le consentement avant de capturer. macOS conserve ce choix dans `Privacy & Security > Screen & System Audio Recording`, sous la forme d'une autorisation révocable par application. La permission donne donc à Defi la capacité de lire les pixels de l'écran et des autres applications. Elle n'est pas limitée aux fenêtres gérées par Defi. [Présentation de ScreenCaptureKit par Apple](https://developer.apple.com/videos/play/wwdc2022/10156/), [réglage de confidentialité macOS](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)

Dans macOS Tahoe, le dialogue peut proposer `Allow` ou `Allow While Using the App`. Apple publie ces deux choix, mais n'explique pas comment le second s'applique à un daemon sans fenêtre active. Defi devra tester ce cas avant de compter sur une autorisation limitée à l'utilisation de l'application. [Dialogue d'autorisation dans macOS Tahoe](https://support.apple.com/guide/mac-help/mchl592e5686/mac)

Il faut aussi prévoir une friction au premier accord. Le projet d'exemple ScreenCaptureKit d'Apple indique qu'après avoir accordé Screen Recording, il faut redémarrer l'application pour activer la capture. Pour Defi, cela implique au minimum un redémarrage propre du service. [Projet d'exemple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

Depuis macOS Sonoma, `SCContentSharingPicker` offre une autorisation plus étroite. La personne choisit explicitement une fenêtre, une application ou un écran, puis l'application peut capturer cette sélection pendant la session sans obtenir la permission globale Screen Recording. Apple recommande ce picker pour le partage d'écran. Il ne convient toutefois pas à l'overview de Defi : demander à la personne de sélectionner chaque fenêtre gérée casserait l'ouverture instantanée et ne donnerait pas automatiquement accès aux nouveaux contenus. [Modèle d'autorisation du picker](https://developer.apple.com/videos/play/wwdc2023/10053/?time=377), [`SCContentSharingPicker`](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker)

Apple justifie ce picker par la friction de la permission globale et par son risque de partage excessif. Ce constat concerne un outil de visioconférence, mais la même permission paraîtra large pour une fonction d'overview qui peut déjà fonctionner sans pixels. [Présentation des changements de confidentialité](https://developer.apple.com/videos/play/wwdc2023/10053/?time=347)

### Permission accordée, capture inactive

Une permission accordée est un état TCC, pas une capture permanente. `SCStream` ne fournit des images qu'après `startCapture()` et cesse après `stopCapture()`. Si Defi n'instancie aucun flux au repos, il n'a ni cadence d'images, ni pool de surfaces de capture à entretenir. Apple ne publie toutefois aucune mesure permettant d'affirmer que le coût exact de la permission inutilisée est nul. [Cycle de vie de `SCStream`](https://developer.apple.com/documentation/screencapturekit/scstream), [fonctionnement des surfaces](https://developer.apple.com/videos/play/wwdc2022/10155/?time=1183)

Pour des miniatures, Defi n'a pas besoin d'un flux. `SCScreenshotManager.captureImage` produit une image ponctuelle de manière asynchrone sans créer de `SCScreenshotManager` ni de `SCStream`. Le coût se limite alors aux captures demandées à l'ouverture de l'overview et aux images conservées par Defi. Apple ne donne pas de budget chiffré pour une rafale de captures, il faudra donc mesurer sur le bureau réel avant d'en fixer le parallélisme. [API de capture ponctuelle](https://developer.apple.com/videos/play/wwdc2023/10136/?time=586)

### Coexistence avec Zoom, Meet ou un autre partage

ScreenCaptureKit n'est pas une ressource exclusive. Apple décrit le menu Vidéo comme listant chaque application qui possède un flux actif et les flux associés à chacune. Le framework accepte aussi plusieurs flux dans une même application. Un flux Defi peut donc coexister avec celui d'un outil de visioconférence, et une capture ponctuelle a une durée encore plus courte. [Intégration multi-application des flux](https://developer.apple.com/videos/play/wwdc2023/10136/?time=144), [`maximumStreamCount`](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker/maximumstreamcount-66khx)

Apple ne publie en revanche ni limite globale inter-application, ni garantie de débit quand plusieurs captures sollicitent le GPU et la mémoire en même temps. La coexistence fonctionnelle ne garantit donc pas un coût nul. Pour Defi, des captures ponctuelles, sans audio et seulement à l'ouverture de l'overview, évitent de laisser un concurrent permanent à Zoom ou Meet. ScreenCaptureKit utilise des surfaces GPU et Apple indique qu'augmenter leur nombre augmente la mémoire consommée. [Coût des surfaces de capture](https://developer.apple.com/videos/play/wwdc2022/10155/?time=1183)

### Indicateurs visibles dans macOS

Un `SCStream` actif apparaît dans le menu Vidéo de macOS avec une prévisualisation et des commandes pour modifier ou arrêter le partage. L'écran verrouillé peut aussi afficher « Your screen is being observed » pendant un enregistrement ou un partage. Apple associe ces signaux à une capture active, pas au simple fait que la permission reste accordée dans Réglages Système. [Menu Vidéo des flux actifs](https://developer.apple.com/videos/play/wwdc2023/10136/?time=144), [rappel sur l'écran verrouillé](https://support.apple.com/120315)

Apple documente `SCScreenshotManager` comme une capture ponctuelle distincte d'un `SCStream`, mais ne précise pas quel indicateur apparaît pendant cet appel bref. Defi ne doit donc pas promettre que la capture de miniatures sera invisible dans l'interface de confidentialité de toutes les versions de macOS. [Différence entre flux et capture ponctuelle](https://developer.apple.com/videos/play/wwdc2023/10136/?time=586)

### Contenus protégés

La permission Screen Recording ne contourne pas la protection du contenu. Une application peut protéger un `AVSampleBufferDisplayLayer` contre la capture. Pour les vidéos chiffrées Clear Key lues par `AVPlayer`, la capture est désactivée par défaut et l'option qui l'autorise n'a aucun effet sur FairPlay Streaming. Apple prévient aussi que certaines fenêtres, comme celles d'Apple TV, peuvent ne pas être enregistrables. Une miniature peut donc contenir une zone vide ou protégée même quand le reste de la fenêtre est disponible. Defi doit conserver sa carte avec icône et titre comme repli et ne pas relancer indéfiniment une capture vide. [`preventsCapture`](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture), [`allowsCaptureOfClearKeyVideo`](https://developer.apple.com/documentation/avfoundation/avplayer/allowscaptureofclearkeyvideo), [limites de l'enregistrement macOS](https://support.apple.com/fr-fr/102618)

### Ce que verra une personne pendant un partage d'écran

Si Zoom, Meet, FaceTime ou un autre outil partage l'écran entier, l'overlay Defi est une fenêtre visible de cet écran et fera partie du partage. Ses cartes, titres et miniatures peuvent alors révéler le contenu d'autres workspaces. Si l'outil partage une fenêtre ou une application choisie, ScreenCaptureKit limite au contraire la sortie à cette sélection. L'overlay Defi n'en fait pas partie, sauf si la personne choisit Defi lui-même. FaceTime expose les trois choix écran, fenêtre et application dans l'interface système. [Filtres de capture](https://developer.apple.com/videos/play/wwdc2022/10155/?time=282), [choix proposés par FaceTime](https://support.apple.com/guide/facetime/fctmdcf2007a/mac)

Ce comportement ne vient pas du fait que Defi possède la permission. Une version sans miniatures afficherait elle aussi son overlay pendant le partage de l'écran entier. La différence tient aux informations montrées dans les cartes. Il faut donc considérer l'overview comme Mission Control : l'ouvrir pendant un partage plein écran montre la vue d'ensemble au public. Mission Control affiche lui aussi toutes les fenêtres ouvertes et les Spaces quand la personne l'active. [Comportement de Mission Control](https://support.apple.com/guide/mac-help/mh35798/mac)

Defi ne peut pas rendre son overlay invisible à toutes les applications de partage avec `NSWindow.sharingType = .none`. Apple classe désormais cette valeur comme une constante historique que macOS n'utilise plus. L'application qui partage garde la maîtrise de son propre filtre, Defi ne peut pas lui imposer une exclusion. [`NSWindow.SharingType`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum)

### Fenêtres parquées hors écran

Le filtre `desktopIndependentWindow` est adapté au parking de Defi. Apple indique qu'il capture tout le contenu d'une fenêtre même si elle est masquée par une autre, complètement hors écran, sur un autre écran ou un autre Space. Il faut obtenir les candidates avec `onScreenWindowsOnly: false`. Une capture basée sur un display aurait le comportement opposé : elle retirerait une fenêtre déplacée hors de l'écran. [Capture d'une fenêtre hors écran](https://developer.apple.com/videos/play/wwdc2022/10155/?time=575), [`onScreenWindowsOnly`](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getexcludingdesktopwindows(_:onscreenwindowsonly:completionhandler:))

Les fenêtres minimisées sont une exception. Apple met leur flux en pause jusqu'à leur restauration. Cela ne bloque pas Defi, qui parque les fenêtres par position et ne les minimise pas. Sur les versions qui exposent cette option, `ignoreGlobalClipSingleWindow` permet aussi d'inclure le contenu déplacé au-delà des limites de clipping du display d'origine. [Comportement d'une fenêtre minimisée](https://developer.apple.com/videos/play/wwdc2022/10155/?time=599), [`ignoreGlobalClipSingleWindow`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/ignoreglobalclipsinglewindow)

ScreenCaptureKit garantit la composition de la fenêtre hors écran, pas la fréquence à laquelle l'application propriétaire redessine son contenu quand elle n'est pas visible. Defi doit accepter une miniature ancienne et la remplacer par sa carte si la capture échoue. Aucune documentation Apple consultée ne promet la fraîcheur d'une fenêtre parquée.

### Acceptation utilisateur

Il n'existe pas de statistique publique solide sur le taux d'acceptation de Screen Recording pour les window managers macOS. Les dépôts de Paneru, OmniWM et Rift ne publient ni taux d'activation, ni taux de refus. Leur existence ou leur nombre d'étoiles ne mesure pas l'acceptation de cette permission.

Les choix d'Apple donnent tout de même une direction produit. Mission Control fournit un overview sans demander une permission tierce. FaceTime et Screenshot attendent une action explicite, puis demandent à la personne de choisir ce qu'elle partage ou enregistre. Les Human Interface Guidelines recommandent de demander une permission au moment où la personne utilise la fonction qui la nécessite, et d'éviter une demande au lancement quand l'accès n'est pas indispensable. [Mission Control](https://support.apple.com/guide/mac-help/mh35798/mac), [outil Screenshot](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac), [règles Apple sur les permissions](https://developer.apple.com/design/human-interface-guidelines/privacy)

La décision du geste reste séparée. Aucun des deux overview personnalisés audités ne fournit le geste vertical de Niri. Paneru conserve le geste Mission Control natif. OmniWM et Rift utilisent des mécanismes privés ou non documentés pour d'autres gestes, puis ouvrent leur overview par raccourci ou commande.

### Recommandation

Livrer d'abord l'overview complet sans Screen Recording, avec cartes, icônes, titres et géométrie logique. Ajouter les vraies miniatures comme option explicite, désactivée par défaut, et ne demander la permission que lorsque la personne active cette option depuis l'overview ou les réglages.

Quand l'option est active, utiliser `SCScreenshotManager` à l'ouverture de l'overview, une capture `desktopIndependentWindow` par fenêtre, `onScreenWindowsOnly: false`, `ignoreGlobalClipSingleWindow: true`, sans audio et sans flux permanent. Garder les images en mémoire le temps de l'overview, puis les jeter. Conserver la carte schématique en cas de refus, de contenu protégé, de miniature ancienne ou d'erreur. Documenter qu'un partage de l'écran entier montre l'overview et son contenu.

Ce choix garde le comportement de Niri sans rendre une permission large obligatoire. Il évite aussi un flux GPU permanent et laisse les personnes qui acceptent Screen Recording obtenir les vraies miniatures. Aucun des deux modes n'a besoin d'une API privée.
