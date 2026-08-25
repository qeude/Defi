# Comment OmniWM traite les onglets natifs macOS

Recherche effectuée le 25 août 2026 sur OmniWM `v0.6.3`, commit
[`33b748b04fc85412feefafdf2ce72f5a2154e585`](https://github.com/BarutSRB/OmniWM/tree/33b748b04fc85412feefafdf2ce72f5a2154e585).
Les constats ci-dessous viennent du dépôt officiel et de la documentation Apple.

## Conclusion

OmniWM ne cherche pas à reconstruire un groupe d'onglets à partir de
`AXTabGroup` et des titres. Il traite le changement d'onglet natif comme un
remplacement de l'incarnation physique d'une seule fenêtre logique. Quand un
nouveau WindowServer ID apparaît et qu'une fenêtre compatible du même processus
n'est plus visible, OmniWM remplace l'ancien token par le nouveau sans retirer
puis réinsérer le nœud de layout.

C'est le point à reprendre dans Defi. Le premier correctif de cette branche
savait masquer des fenêtres physiques derrière un représentant, mais le
représentant restait identifié par son `WindowID`. Si Ghostty change ce WindowID
lors de l'ouverture ou de la sélection d'un onglet, le runtime pouvait encore
voir une suppression suivie d'une création et modifier la colonne.

## Le modèle d'identité d'OmniWM

OmniWM sépare trois identités :

- `WindowToken` contient le PID et le WindowServer ID courant.
- `WindowHandle` est une référence stable. Son token peut changer sans changer
  l'objet tenu par le layout.
- `AXWindowRef` pointe vers l'`AXUIElement` courant.

La documentation d'architecture explique explicitement qu'un rekey repointe le
handle lorsque l'application détruit et recrée sa fenêtre
([`ARCHITECTURE.md`, lignes 286-312](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/docs/ARCHITECTURE.md#L286-L312)).
`WindowModel.rekeyWindow` remplace les index par token et WindowServer ID tout en
gardant le même `WindowHandle`
([`WindowModel.swift`, lignes 270-316](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Workspace/WindowModel.swift#L270-L316)).

Le commit qui a introduit le cas Ghostty dit pourquoi : Ghostty remplace son ID
de fenêtre de premier niveau pendant les changements d'onglet. Un remove/add
déplaçait la colonne et le viewport, alors qu'un rekey en place conserve les
deux sans interruption
([commit `3a402cb2`](https://github.com/BarutSRB/OmniWM/commit/3a402cb26c0f9887f8d47782ce7ab2d3cc7a51a9)).

## Comment le remplacement est reconnu

`AXEventHandler.structuralReplacementMatch` examine les fenêtres déjà gérées
par le même PID. Un ancien token ne devient candidat que dans deux cas :

- sa destruction attend déjà dans le burst courant ;
- une observation WindowServer faisant autorité ne le voit plus parmi les
  fenêtres visibles.

La fonction refuse le remplacement si plusieurs anciens tokens correspondent
([`AXEventHandler.swift`, lignes 3350-3479](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/AXEventHandler.swift#L3350-L3479)).
Un test verrouille le cas négatif : une nouvelle fenêtre visible de la même
application reste une nouvelle colonne et n'est pas transformée en onglet
([`RuntimeArchitectureTests.swift`, lignes 4518-4601](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Tests/OmniWMTests/RuntimeArchitectureTests.swift#L4518-L4601)).

La corrélation compare des faits structurels : bundle, workspace, mode,
rôle, sous-rôle, niveau WindowServer, parent et frame. Les frames peuvent
différer de 96 points sur leur centre et de 64 points sur leur taille. Le titre
est conservé dans les métadonnées, mais ne participe pas au match
([`WindowModel.swift`, lignes 12-39](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Workspace/WindowModel.swift#L12-L39),
[`AXEventHandler.swift`, lignes 3481-3599](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/AXEventHandler.swift#L3481-L3599)).
Le passage d'une allowlist Ghostty/navigateurs à cette corrélation générique est
documenté par le
[`commit d88231b1`](https://github.com/BarutSRB/OmniWM/commit/d88231b18180162107ef8c47df6a34ca0ae8ab22).

OmniWM gère aussi les deux ordres d'événements. Les créations et destructions
sont regroupées pendant 150 ms par PID et workspace. Une paire unique et
compatible est appliquée immédiatement. Si le burst est ambigu ou ne correspond
pas, OmniWM rejoue les événements comme des créations et suppressions ordinaires
([`AXEventHandler.swift`, lignes 2978-3147](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/AXEventHandler.swift#L2978-L3147),
[`AXEventHandler.swift`, lignes 3608-3691](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/AXEventHandler.swift#L3608-L3691)).

## Ce que le rekey préserve

Le rekey n'est pas un simple renommage dans un dictionnaire. OmniWM :

- fait confirmer le nouveau binding par le gestionnaire AX avant de valider le
  changement ;
- repointe le monde et les moteurs Niri/Dwindle vers le nouveau token ;
- migre le focus, les intentions en attente, le scratchpad, les transactions de
  reveal et l'état d'application des frames ;
- force la prochaine frame sur la nouvelle fenêtre physique.

Les chemins exacts sont
[`rekeyManagedWindowIdentity`](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/AXEventHandler%2BManagedWindowIdentity.swift#L10-L77),
[`commitManagedWindowIdentityRebind`](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/AXEventHandler%2BManagedWindowIdentity.swift#L504-L549),
[`WorldStore`](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/World/WorldStore.swift#L249-L268) et
[`AXManager`](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Ax/AXManager.swift#L645-L739).

Le test le plus proche du bug Ghostty vérifie que l'ancien nœud garde son ID,
que le nombre et l'ordre des colonnes ne changent pas, qu'aucune animation de
scroll ne démarre et que le focus suit le nouveau token
([`RuntimeArchitectureTests.swift`, lignes 4715-4829](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Tests/OmniWMTests/RuntimeArchitectureTests.swift#L4715-L4829)).

Pendant qu'un rebind attend sa confirmation AX, un rescan conserve aussi le
token source au lieu d'admettre une deuxième fois la cible. Cette protection
évite une colonne vide et une double identité
([`WindowAdmissionIdentity.swift`, lignes 40-109](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/Controller/WindowAdmissionIdentity.swift#L40-L109),
[`commit 5dd1f042`](https://github.com/BarutSRB/OmniWM/commit/5dd1f042cb1f10fc415d1f0a38714e310402f4e4)).

## Ce qu'OmniWM ne fait pas

Une recherche sur tout le source au commit étudié ne trouve aucun usage de
`kAXTabsAttribute`, `kAXTabGroupRole`, `NSWindowTabGroup` ou
`tabbingIdentifier`. Les "native tabs" d'OmniWM reposent donc sur le
remplacement structurel d'une fenêtre visible, pas sur un modèle du contenu de
la barre d'onglets. Les colonnes tabulées propres à OmniWM sont une autre
fonctionnalité.

Apple décrit [`kAXTabsAttribute`](https://developer.apple.com/documentation/applicationservices/kaxtabsattribute)
comme la liste des objets d'accessibilité affichés par une vue d'onglets, et
[`kAXTabGroupRole`](https://developer.apple.com/documentation/applicationservices/kaxtabgrouprole)
comme une vue d'onglets. Ces API exposent le contrôle UI. Elles ne promettent pas
une correspondance stable entre un onglet, un `AXWindow` et un `CGWindowID`.

Cette approche ne couvre pas encore toutes les applications. L'issue officielle
ouverte [#595](https://github.com/BarutSRB/OmniWM/issues/595) rapporte qu'OmniWM
0.6.2 pouvait encore traiter des onglets Finder comme des fenêtres séparées et
faire glisser le layout à leur fermeture. Le rekey structurel est donc le bon
modèle pour Ghostty, pas une preuve qu'OmniWM a résolu tous les onglets natifs.

## Différence avec la branche Defi actuelle

Defi part du contrôle UI. `nativeWindowTabGroup` cherche un enfant
`AXTabGroup`, lit `AXTabs`, les titres et l'onglet sélectionné
([`SnapshotEngine.swift`, lignes 985-1024](../../Sources/DefiMacOS/SnapshotEngine.swift#L985-L1024)).
`nativeTabBackingWindowIDsByRepresentative` associe ensuite les fenêtres
physiques par PID, rôle, sous-rôle, multiensemble de titres et proximité des
frames, puis conserve les appartenances connues
([`WindowDiscoverySupport.swift`, lignes 109-215](../../Sources/DefiMacOS/WindowDiscoverySupport.swift#L109-L215)).
La découverte retire enfin ces backings du snapshot
([`MacOSPlatform+WindowSnapshotDiscovery.swift`, lignes 541-575](../../Sources/DefiMacOS/MacOSPlatform%2BWindowSnapshotDiscovery.swift#L541-L575)).

Cette logique répond à la question "quelles fenêtres physiques appartiennent
au groupe ?". OmniWM répond d'abord à une autre question : "le nouveau
WindowServer ID est-il la nouvelle incarnation de la fenêtre logique déjà dans
la colonne ?". C'est cette seconde réponse qui empêche le saut de colonne.

La branche ajoute maintenant `nativeWindowTabRepresentativeReplacements`. Le
helper forme une paire unique entre un ancien représentant disparu et le nouveau
représentant qui le contient parmi ses backings
([`WindowDiscoverySupport.swift`, lignes 109-132](../../Sources/DefiMacOS/WindowDiscoverySupport.swift#L109-L132)).
`DesktopSnapshot.windowIDReplacements` transporte cette paire jusqu'à
`reconcileWindows`, qui migre l'entrée runtime avant la phase remove/add
([`WindowReconciliation.swift`, lignes 163-260](../../Sources/DefiRuntime/WindowReconciliation.swift#L163-L260)).

Les tests couvrent maintenant le match unique et ambigu dans la découverte,
puis la conservation de la colonne, de sa largeur, du scroll et du focus dans le
runtime. Il reste utile d'avoir un test d'intégration du cycle complet Ghostty,
notamment quand un rescan intervient pendant le remplacement
([`WindowDiscoveryTests.swift`, lignes 964-997](../../Tests/DefiMacOSTests/WindowDiscoveryTests.swift#L964-L997),
[`WindowLifecycleTests.swift`, lignes 161-199](../../Tests/DefiRuntimeTests/WindowLifecycleTests.swift#L161-L199)).

## Recommandation pour Defi

La propagation `windowIDReplacements` suit le bon modèle. Pour garder les
garanties qu'OmniWM a dû ajouter au fil de plusieurs correctifs :

1. comparer le snapshot précédent au nouveau et former au plus une paire
   `ancien WindowID -> nouveau WindowID` par processus quand l'ancien n'est plus
   visible et que PID, rôle, sous-rôle, niveau et frame correspondent ;
2. refuser les matchs ambigus et traiter alors les fenêtres normalement ;
3. migrer l'entrée runtime, sa place dans la colonne, le focus, les largeurs, les
   targets et les travaux de frame avant la phase remove/add ;
4. protéger cette paire pendant les rescans jusqu'à la fin du rebind ;
5. garder `AXTabGroup` comme preuve du groupe ou comme moyen d'exclure les
   backings inactifs, mais ne plus utiliser les titres comme fondation de
   l'identité.

Defi dispose déjà de l'inventaire Quartz public et de `isOnscreen`
([`Platform.swift`, lignes 9-57](../../Sources/DefiMacOS/Platform.swift#L9-L57)).
Il faut commencer avec cette source et les snapshots existants. OmniWM obtient
son ensemble visible via `SkyLight.queryAllVisibleWindows`, une API privée qui
filtre aussi les tags et attributs WindowServer
([`SkyLight.swift`, lignes 898-943](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/Sources/OmniWM/Core/SkyLight/SkyLight.swift#L898-L943)).
Son README assume cet usage général des API privées
([`README.md`, lignes 422-428](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/README.md#L422-L428)).
La politique de Defi impose au contraire de démontrer l'insuffisance des API
publiques avant d'introduire un backend privé.

Enfin, OmniWM est sous
[`GPL-2.0-only`](https://github.com/BarutSRB/OmniWM/blob/33b748b04fc85412feefafdf2ce72f5a2154e585/LICENSE),
alors que Defi est sous MIT. Il faut reprendre le modèle et réimplémenter le
comportement, sans copier son code.
