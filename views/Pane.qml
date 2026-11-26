import QtQuick
import QtQuick.Effects
import qs.services
import qs.kit

// One place on screen: the folder model, the view that draws it, the keys that move through it and what is dropped
// on its empty space. A tab holds one pane, or two side by side.
FocusScope {
    id: root
    required property var browser
    required property var page
    property alias folder: folder
    readonly property bool active: root.browser.activePane === root
    property string viewMode: Prefs.get("view")
    property bool filterOpen: false
    function openFilter(): void {
        if (folder.mode === "start" || folder.mode === "search") return
        root.filterOpen = true
        Qt.callLater(() => { if (filterLoader.item) filterLoader.item.focusInput() })
    }
    function closeFilter(): void {
        root.filterOpen = false
        folder.filterText = ""
        root.forceActiveFocus()
    }
    function setViewMode(mode: string): void {
        root.viewMode = mode
        Prefs.set("view", mode)
        if (folder.mode === "folder" && folder.path.length > 0) {
            const mem = Object.assign({}, Prefs.recall("folderViews", {}))
            delete mem[folder.path]
            mem[folder.path] = mode
            const keys = Object.keys(mem)
            if (keys.length > 200) delete mem[keys[0]]
            Prefs.remember("folderViews", mem)
        }
    }
    // Each pane holds its own zoom (seeded from Prefs on creation) so Ctrl+Scroll never re-layouts other windows or hidden tabs.
    property int zoom: 3
    property int listZoom: 1
    readonly property bool gridZoomMode: root.viewMode === "grid" || root.viewMode === "gallery"
    Component.onCompleted: {
        root.zoom = Math.max(1, Math.min(7, Number(Prefs.get("zoom"))))
        root.listZoom = Math.max(0, Math.min(2, Number(Prefs.get("listZoom"))))
    }
    function setZoom(v: int): void {
        if (root.gridZoomMode) {
            const next = Math.max(1, Math.min(7, v))
            if (root.zoom === next) return
            root.zoom = next
            Prefs.set("zoom", next)
        } else {
            const next = Math.max(0, Math.min(2, v))
            if (root.listZoom === next) return
            root.listZoom = next
            Prefs.set("listZoom", next)
        }
    }
    function stepZoom(step: int): void { root.setZoom((root.gridZoomMode ? root.zoom : root.listZoom) + step) }
    function resetZoom(): void { root.setZoom(Number(Prefs.defaults[root.gridZoomMode ? "zoom" : "listZoom"])) }
    readonly property Item view: loader.item ? loader.item.view : null
    // The view scrolls sideways itself (columns, a list wider than the pane): a sideways swipe is its own.
    readonly property bool sideways: loader.item?.sideways ?? false
    property bool dropHover: false
    property int narrowOnRelease: -1
    // A finger hold opened a menu: the lift that ends it does nothing more.
    property bool held: false
    property string typed: ""
    property var memo: ({})
    property string shownPlace: ""
    property bool pendingScroll: false
    // Unload the visual delegate tree of background tabs after 5 s to reclaim GPU textures and QML items,
    // while keeping rapid Ctrl+Tab switching instantaneous and preserving Folder state + scroll position.
    property bool viewAwake: true
    readonly property bool pageShown: root.page ? root.page.visible : true
    onPageShownChanged: {
        if (root.pageShown) {
            sleepView.stop()
            root.viewAwake = true
        } else {
            if (root.view && root.shownPlace.length > 0) root.memo[root.shownPlace] = root.view.contentY
            sleepView.restart()
        }
    }
    Timer {
        id: sleepView
        interval: 5000
        onTriggered: {
            if (!root.pageShown) {
                root.viewAwake = false
                Qt.callLater(gc)
            }
        }
    }

    function activate(): void {
        root.page.activePane = root
        root.forceActiveFocus()
    }
    onActiveFocusChanged: if (root.activeFocus) root.page.activePane = root

    Folder {
        id: folder
        onRevealed: i => { if (loader.item && !root.pendingScroll) loader.item.reveal(i) }
        onPlaceChanged: {
            if (root.view && root.shownPlace.length > 0) root.memo[root.shownPlace] = root.view.contentY
            root.shownPlace = folder.place
            root.filterOpen = false
        }
        onReset: {
            if (folder.mode === "folder") {
                const mem = Prefs.recall("folderViews", {})
                const want = mem[folder.path] ?? Prefs.get("view")
                if (root.viewMode !== want) root.viewMode = want
            }
            // A new place arrives with a short fade, so the eye reads the swap as one step. Columns keep the columns
            // that stay, so they do not fade.
            if (Theme.motion && root.viewMode !== "columns") arrive.restart()
            root.pendingScroll = true
        }
        onApplied: {
            if (!root.pendingScroll) return
            root.pendingScroll = false
            const place = folder.place
            const y = root.memo[place]
            const idx = folder.current
            Qt.callLater(() => {
                if (!root || folder.place !== place) return
                const v = root.view
                if (!v) return
                if (idx >= 0 && loader.item) loader.item.reveal(idx)
                else if (y !== undefined) v.contentY = Math.min(y, Math.max(v.originY - v.topMargin, v.contentHeight - v.height + v.originY + v.bottomMargin))
                else if (v.positionViewAtBeginning) v.positionViewAtBeginning()
                else v.contentY = v.originY
            })
        }
    }

    // ---- pointer
    function pressItem(i: int, mouse: var, from: Item): void {
        root.activate()
        root.held = false
        const f = folder
        const path = f.all[i]?.path ?? ""
        const ctrl = (mouse.modifiers & Qt.ControlModifier) !== 0
        const shift = (mouse.modifiers & Qt.ShiftModifier) !== 0
        root.narrowOnRelease = -1
        if (mouse.button === Qt.RightButton) {
            if (!f.isSel(path)) f.only(i)
            const p = from.mapToItem(root.browser.stage, mouse.x, mouse.y)
            root.browser.actions.itemMenu(root, p.x, p.y)
            return
        }
        if (mouse.button === Qt.MiddleButton) return
        if (shift) f.range(i, ctrl)
        else if (ctrl) f.toggle(i)
        else if (f.isSel(path)) {
            // A press on what is already chosen keeps the whole choice, so it can be dragged; a plain click narrows it.
            root.narrowOnRelease = i
            f.current = i
            f.anchor = i
            f.selRev++
        } else f.only(i)
    }
    // A finger held on a thing: its menu. The lift that ends the hold neither narrows the choice nor opens the thing.
    function holdItem(i: int, at: point, from: Item): void {
        const f = folder
        if (root.browser.busy || i < 0 || i >= f.all.length) return
        if (!f.isSel(f.all[i].path)) f.only(i)
        root.narrowOnRelease = -1
        root.held = true
        const p = from.mapToItem(root.browser.stage, at.x, at.y)
        root.browser.actions.itemMenu(root, p.x, p.y)
    }
    function releaseItem(i: int, mouse: var): void {
        if (root.held) { root.held = false; return }
        const plain = mouse.button === Qt.LeftButton && (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) === 0
        if (plain && root.narrowOnRelease === i && folder.selCount > 1) folder.only(i)
        root.narrowOnRelease = -1
        if (plain && Prefs.get("singleClick")) root.openItem(i, false)
    }
    function openItem(i: int, newTab: bool): void {
        const e = folder.all[i]
        if (!e) return
        if (newTab) {
            if (e.dir) root.browser.newTab(e.path)
            return
        }
        const list = folder.isSel(e.path) && folder.selCount > 1 ? folder.chosen() : [e]
        root.browser.actions.open(root, list)
    }
    function openSelection(inTabs: bool): void {
        const list = folder.chosen()
        if (list.length === 0) return
        if (inTabs) {
            for (const e of list) if (e.dir) root.browser.newTab(e.path)
            return
        }
        root.browser.actions.open(root, list)
    }
    // Where the menu key opens a menu: beside the current entry, or in the middle of the pane.
    function menuPoint(): point {
        const v = root.view
        const i = folder.current
        if (v && i >= 0 && v.itemAtIndex) {
            const it = v.itemAtIndex(i)
            if (it) return it.mapToItem(root.browser.stage, it.width / 2, it.height / 2)
        }
        return root.mapToItem(root.browser.stage, root.width / 2, root.height / 3)
    }

    // Where an arrow key leads from an entry, in the shape the view draws.
    function stepFrom(i: int, key: int): int { return loader.item ? loader.item.step(i, key) : -1 }

    // ---- keys
    Keys.onPressed: event => {
        const f = folder
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if ((event.modifiers & Qt.AltModifier) !== 0) return
        const v = loader.item
        if (!v) return
        const k = event.key
        if (f.mode === "start") {
            if (k === Qt.Key_Up || k === Qt.Key_Down || k === Qt.Key_PageUp || k === Qt.Key_PageDown) { v.step(-1, k); event.accepted = true; return }
            if (k === Qt.Key_Home && root.view) { root.view.contentY = 0; event.accepted = true; return }
            if (k === Qt.Key_End && root.view) { root.view.contentY = Math.max(0, root.view.contentHeight - root.view.height); event.accepted = true; return }
            if (k === Qt.Key_Backspace && f.back.length > 0) { f.goBack(); event.accepted = true; return }
            if (!ctrl && event.text.length === 1 && event.text >= " " && event.text !== "\u007f") { root.browser.head.startSearch(event.text); event.accepted = true }
            return
        }
        if ((k === Qt.Key_Left || k === Qt.Key_Right) && v.lateral && !ctrl && !shift && v.lateral(k)) { event.accepted = true; return }
        if (k === Qt.Key_Home) { f.moveTo(0, shift, ctrl); event.accepted = true; return }
        if (k === Qt.Key_End) { f.moveTo(f.model.count - 1, shift, ctrl); event.accepted = true; return }
        if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Up || k === Qt.Key_Down || k === Qt.Key_PageUp || k === Qt.Key_PageDown) {
            const to = v.step(f.current, k)
            if (to >= 0) f.moveTo(to, shift, ctrl)
            event.accepted = true
            return
        }
        if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.openSelection(ctrl || shift); event.accepted = true; return }
        // Backspace goes back, as in other file managers; with nowhere back, up. Typed letters lose their last first.
        if (k === Qt.Key_Backspace) {
            if (root.typed.length > 0) { root.typed = root.typed.slice(0, -1); typing.restart() }
            else if (f.mode === "search") root.browser.head.backspaceSearch()
            else if (f.back.length > 0) f.goBack()
            else f.goUp()
            event.accepted = true
            return
        }
        if (k === Qt.Key_Space && root.typed.length === 0) {
            if (ctrl) { if (f.current >= 0) f.toggle(f.current) }
            else root.browser.quickLook.toggle(root)
            event.accepted = true
            return
        }
        if (k === Qt.Key_Escape) {
            if (root.filterOpen || f.filterText.length > 0) root.closeFilter()
            else if (f.mode === "search") root.browser.head.clearSearch()
            else if (f.selCount > 0) f.clearSel()
            else if (root.browser.chooser) root.browser.cancelChooser()
            event.accepted = true
            return
        }
        if (k === Qt.Key_Menu || (k === Qt.Key_F10 && shift)) {
            const p = root.menuPoint()
            if (f.selCount > 0) root.browser.actions.itemMenu(root, p.x, p.y)
            else root.browser.actions.backgroundMenu(root, p.x, p.y)
            event.accepted = true
            return
        }
        if (!ctrl && event.text.length === 1 && event.text >= " " && event.text !== "\u007f") {
            if (!Prefs.get("typeAhead")) { root.browser.head.startSearch(event.text); event.accepted = true; return }
            root.typed += event.text.toLowerCase()
            typing.restart()
            const start = f.current >= 0 && root.typed.length === 1 ? f.current + 1 : Math.max(0, f.current)
            const n = f.all.length
            for (let s = 0; s < n; s++) {
                const i = (start + s) % n
                if (f.all[i].name.toLowerCase().startsWith(root.typed)) { f.only(i); break }
            }
            event.accepted = true
        }
    }
    Timer { id: typing; interval: 900; onTriggered: root.typed = "" }

    // ---- what is dropped on empty space lands in the place itself
    DropArea {
        anchors.fill: parent
        enabled: (folder.mode === "folder" && folder.writable) || folder.mode === "trash"
        onEntered: drag => {
            if (!drag.hasUrls || root.browser.actions.dropRefused(drag.urls, folder.mode === "trash" ? "trash:" : folder.path)) { drag.accepted = false; return }
            root.dropHover = true
        }
        onExited: root.dropHover = false
        onDropped: drop => {
            root.dropHover = false
            root.browser.actions.drop(drop, folder.mode === "trash" ? "trash:" : folder.path)
        }
    }

    // A drag out of the pane rides here, not on the cell or row it starts from: a folder that opens under the pointer
    // drops those, and the drag has to outlive them.
    Item {
        id: carrier
        property string uris: ""
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
        Drag.proposedAction: Qt.MoveAction
        Drag.mimeData: ({ "text/uri-list": carrier.uris })
        // Qt leaves an automatic drag active once it ends: the next one starts only from false.
        Drag.onDragFinished: carrier.Drag.active = false
    }
    // A press readies the drag: the chosen things, or the paths given, and the picture of what was pressed under the
    // pointer.
    function ready(icon: Item, side: real, paths: var): void {
        carrier.uris = (paths ?? folder.chosenPaths()).map(p => Fmt.url(p)).join("\r\n")
        carrier.Drag.hotSpot.x = side / 2
        carrier.Drag.hotSpot.y = side / 2
        carrier.Drag.imageSource = ""
        if (icon) icon.grabToImage(r => carrier.Drag.imageSource = r.url)
    }
    // The drag starts once the move that asked for it has returned, so no delegate is on the stack while it runs.
    function carry(): void { Qt.callLater(() => { if (!carrier.Drag.active && !root.held) carrier.Drag.active = true }) }

    Loader {
        id: loader
        anchors.fill: parent
        focus: true
        active: root.viewAwake
        sourceComponent: folder.mode === "start" ? homeView : root.viewMode === "list" ? listView : root.viewMode === "columns" ? columnsView : root.viewMode === "gallery" ? galleryView : gridView
        onLoaded: {
            const place = folder.place
            const y = root.memo[place]
            const idx = folder.current
            Qt.callLater(() => {
                if (!root || folder.place !== place) return
                const v = root.view
                if (!v) return
                if (y !== undefined) v.contentY = Math.min(y, Math.max(v.originY - v.topMargin, v.contentHeight - v.height + v.originY + v.bottomMargin))
                else if (idx >= 0 && loader.item) loader.item.reveal(idx)
            })
        }
    }
    NumberAnimation { id: arrive; target: loader; property: "opacity"; from: 0; to: 1; duration: Theme.fast; easing.type: Easing.OutCubic }
    Component { id: homeView; HomePane { pane: root } }
    Component { id: gridView; GridPane { pane: root } }
    Component { id: listView; ListPane { pane: root } }
    Component { id: columnsView; ColumnsPane { pane: root } }
    Component { id: galleryView; GalleryPane { pane: root } }
    // Ctrl or Alt with the wheel zooms the view: a step per notch, a touchpad adds up to one. A plain wheel scrolls on.
    MouseArea {
        anchors.fill: loader
        acceptedButtons: Qt.NoButton
        property real wheelSum: 0
        onWheel: wheel => {
            if (folder.mode === "start" || !(wheel.modifiers & (Qt.ControlModifier | Qt.AltModifier))) { wheel.accepted = false; return }
            const d = wheel.angleDelta.y || wheel.angleDelta.x
            if (d * wheelSum < 0) wheelSum = 0
            wheelSum += d
            const steps = Math.trunc(wheelSum / 120)
            if (steps !== 0) { wheelSum -= steps * 120; root.stepZoom(steps) }
        }
    }

    // ---- the place has nothing to show
    readonly property string blank: {
        const f = folder
        if (f.mode === "start") return ""
        if (f.error.length > 0) return "error"
        if (f.loading || f.model.count > 0) return ""
        if (f.mode !== "search" && f.filterText.trim().length > 0) return "infilter"
        if (f.mode === "search") return f.searching ? "searching" : f.found.length > 0 ? "filtered" : (f.query.length > 0 ? "nothing" : "")
        return f.mode
    }
    Item {
        anchors.fill: parent
        anchors.topMargin: root.viewMode === "list" ? Theme.dp(32) : 0
        visible: root.blank.length > 0 && root.viewMode !== "columns"
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.dp(48), Theme.dp(360))
            spacing: Theme.dp(10)
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Theme.dp(76)
                height: width
                radius: width / 2
                color: Theme.fill
                Glyph {
                    anchors.centerIn: parent
                    visible: root.blank !== "searching"
                    name: ({ error: folder.error === "denied" ? "lock" : "error", searching: "search", nothing: "search_off", filtered: "filter_alt_off", infilter: "filter_list_off", trash: "delete", recent: "schedule", folder: "folder_open" })[root.blank] ?? "folder_open"
                    size: Theme.dp(34)
                    color: Theme.ink3
                }
                Ring {
                    anchors.centerIn: parent
                    visible: root.blank === "searching"
                    width: Theme.dp(34)
                    height: width
                    value: -1
                }
            }
            Txt {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                size: Theme.head
                strong: true
                font.family: Theme.title
                text: {
                    switch (root.blank) {
                    case "error": return folder.error === "denied" ? I18n.tr("No permission to open this folder") : folder.error === "missing" ? I18n.tr("This folder no longer exists") : I18n.tr("This place could not be read")
                    case "searching": return I18n.tr("Searching")
                    case "nothing": return I18n.tr("Nothing matches “%1”", folder.query)
                    case "infilter": return I18n.tr("Nothing matches “%1”", folder.filterText.trim())
                    case "filtered": return I18n.tr("Nothing of this kind")
                    case "trash": return I18n.tr("The trash is empty")
                    case "recent": return I18n.tr("No recent files")
                    }
                    return I18n.tr("This folder is empty")
                }
            }
            Txt {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.ink2
                text: {
                    switch (root.blank) {
                    case "error": return folder.error === "denied" || folder.error === "missing" ? Fmt.pretty(folder.path) : Errors.text(folder.error)
                    case "searching": return I18n.tr("%1 items checked", Fmt.num(folder.scanned, 0))
                    case "nothing": return folder.content ? I18n.tr("No file below %1 holds this text.", Fmt.pretty(folder.searchRoot)) : I18n.tr("No name below %1 holds these words. Try the text inside files.", Fmt.pretty(folder.searchRoot))
                    case "infilter": return I18n.n("%1 item hidden by filter.", "%1 items hidden by filter.", folder.rawAll.length)
                    case "filtered": return I18n.n("%1 result of another kind.", "%1 results of other kinds.", folder.found.length)
                    case "trash": return I18n.tr("What you delete waits here until you empty it.")
                    case "recent": return I18n.tr("Files you open in your apps show up here.")
                    }
                    return folder.hiddenCount > 0 ? I18n.n("It holds %1 hidden item.", "It holds %1 hidden items.", folder.hiddenCount) : I18n.tr("Drop files here, or make a new folder.")
                }
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.dp(8)
                topPadding: Theme.dp(4)
                Pill {
                    visible: root.blank === "folder" && folder.writable
                    text: I18n.tr("New folder")
                    glyph: "create_new_folder"
                    onClicked: root.browser.actions.newFolder(root)
                }
                Pill {
                    visible: root.blank === "folder" && folder.hiddenCount > 0
                    text: I18n.tr("Show hidden")
                    glyph: "visibility"
                    onClicked: Prefs.set("hidden", true)
                }
                Pill {
                    visible: root.blank === "nothing" && !folder.content
                    text: I18n.tr("Search inside files")
                    glyph: "manage_search"
                    onClicked: folder.content = true
                }
                Pill {
                    visible: root.blank === "filtered"
                    text: I18n.tr("Show all kinds")
                    glyph: "filter_alt_off"
                    onClicked: folder.filterKind("")
                }
                Pill {
                    visible: root.blank === "infilter"
                    text: I18n.tr("Clear filter")
                    glyph: "filter_list_off"
                    onClicked: root.closeFilter()
                }
                Pill {
                    visible: root.blank === "error" && folder.error === "missing"
                    text: I18n.tr("Go up")
                    glyph: "arrow_upward"
                    onClicked: folder.goUp()
                }
            }
        }
    }

    // Floating instant in-folder filter bar (Ctrl+/), built only while open.
    Loader {
        id: filterLoader
        active: root.filterOpen
        z: 10
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.dp(14)
        sourceComponent: Item {
            id: fBar
            width: Math.min(root.width - Theme.dp(32), Theme.dp(340))
            height: Theme.dp(40)
            function focusInput(): void { fInput.forceActiveFocus(); fInput.selectAll() }
            RectangularShadow {
                anchors.fill: fPlate
                radius: fPlate.radius
                blur: Theme.dp(20)
                offset.y: Theme.dp(6)
                color: Theme.shadow
            }
            Rectangle {
                id: fPlate
                anchors.fill: parent
                radius: height / 2
                color: Theme.raised
                border.width: 1
                border.color: Theme.line
                Glyph {
                    id: fGlyph
                    x: Theme.dp(14)
                    anchors.verticalCenter: parent.verticalCenter
                    name: "filter_list"
                    size: Theme.dp(17)
                    color: Theme.accentInk
                }
                TextInput {
                    id: fInput
                    anchors.left: fGlyph.right
                    anchors.leftMargin: Theme.dp(8)
                    anchors.right: fCount.left
                    anchors.rightMargin: Theme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.ink
                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                    selectedTextColor: Theme.ink
                    font.family: Theme.sans
                    font.pixelSize: Theme.row
                    renderType: TextInput.NativeRendering
                    selectByMouse: true
                    text: folder.filterText
                    onTextChanged: folder.filterText = text
                    Keys.onEscapePressed: root.closeFilter()
                    Keys.onReturnPressed: { root.forceActiveFocus(); if (folder.model.count > 0) folder.only(0) }
                    Keys.onEnterPressed: { root.forceActiveFocus(); if (folder.model.count > 0) folder.only(0) }
                    Keys.onDownPressed: { root.forceActiveFocus(); if (folder.model.count > 0) folder.only(0) }
                    Txt {
                        visible: fInput.text.length === 0
                        x: Theme.dp(2)
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Filter this folder…")
                        size: Theme.small
                        color: Theme.ink3
                    }
                }
                Txt {
                    id: fCount
                    anchors.right: fClose.left
                    anchors.rightMargin: Theme.dp(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: folder.filterText.trim().length > 0 ? (folder.all.length + "/" + folder.rawAll.length) : ""
                    size: Theme.caption
                    color: Theme.ink3
                    font.features: { "tnum": 1 }
                }
                Act {
                    id: fClose
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(6)
                    anchors.verticalCenter: parent.verticalCenter
                    size: Theme.dp(26)
                    glyphSize: Theme.dp(15)
                    glyph: "close"
                    tip: I18n.tr("Clear filter")
                    onClicked: root.closeFilter()
                }
            }
        }
    }

    // A thin ring around the pane while something can land in it.
    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.dp(4)
        radius: Math.max(0, Theme.cardRadius - Theme.round(4))
        color: Theme.alpha(Theme.accent, 0.05)
        border.width: Math.max(1, Theme.dp(2))
        border.color: Theme.alpha(Theme.accent, 0.7)
        visible: root.dropHover
    }
}
