import QtQuick
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
    readonly property Item view: loader.item ? loader.item.view : null
    property bool dragging: false
    property bool dropHover: false
    property int narrowOnRelease: -1
    property string typed: ""
    property var memo: ({})
    property string shownPlace: ""

    function activate(): void {
        root.page.activePane = root
        root.forceActiveFocus()
    }
    onActiveFocusChanged: if (root.activeFocus) root.page.activePane = root

    Folder {
        id: folder
        onRevealed: i => { if (loader.item) loader.item.reveal(i) }
        onPlaceChanged: {
            if (root.view && root.shownPlace.length > 0) root.memo[root.shownPlace] = root.view.contentY
            root.shownPlace = folder.place
        }
        onReset: {
            // A new place arrives with a short fade, so the eye reads the swap as one step. Columns keep the columns
            // that stay, so they do not fade.
            if (Theme.motion && root.viewMode !== "columns") arrive.restart()
            const y = root.memo[folder.place]
            Qt.callLater(() => {
                const v = root.view
                if (!v) return
                if (y !== undefined && folder.current < 0) v.contentY = Math.min(y, Math.max(v.originY - v.topMargin, v.contentHeight - v.height + v.originY + v.bottomMargin))
                else if (folder.current < 0) v.positionViewAtBeginning()
            })
        }
    }

    // ---- pointer
    function pressItem(i: int, mouse: var, from: Item): void {
        root.activate()
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
    function releaseItem(i: int, mouse: var): void {
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
        if (k === Qt.Key_Backspace) {
            if (f.mode === "search") root.browser.head.backspaceSearch()
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
            if (f.mode === "search") root.browser.head.clearSearch()
            else if (f.selCount > 0) f.clearSel()
            event.accepted = true
            return
        }
        if (k === Qt.Key_Menu) {
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
            if (!drag.hasUrls || root.browser.actions.dropRefused(drag.urls, folder.mode === "trash" ? "trash:" : folder.path, true)) { drag.accepted = false; return }
            root.dropHover = true
        }
        onExited: root.dropHover = false
        onDropped: drop => {
            root.dropHover = false
            root.browser.actions.drop(drop, folder.mode === "trash" ? "trash:" : folder.path)
        }
    }

    Loader {
        id: loader
        anchors.fill: parent
        focus: true
        sourceComponent: root.viewMode === "list" ? listView : root.viewMode === "columns" ? columnsView : gridView
    }
    NumberAnimation { id: arrive; target: loader; property: "opacity"; from: 0; to: 1; duration: Theme.fast; easing.type: Easing.OutCubic }
    Component { id: gridView; GridPane { pane: root } }
    Component { id: listView; ListPane { pane: root } }
    Component { id: columnsView; ColumnsPane { pane: root } }
    // Ctrl or Alt with the wheel zooms the view: a step per notch, a touchpad adds up to one. A plain wheel scrolls on.
    MouseArea {
        anchors.fill: loader
        acceptedButtons: Qt.NoButton
        property real wheelSum: 0
        onWheel: wheel => {
            if (!(wheel.modifiers & (Qt.ControlModifier | Qt.AltModifier))) { wheel.accepted = false; return }
            const d = wheel.angleDelta.y || wheel.angleDelta.x
            if (d * wheelSum < 0) wheelSum = 0
            wheelSum += d
            const steps = Math.trunc(wheelSum / 120)
            if (steps !== 0) { wheelSum -= steps * 120; root.browser.actions.zoom(steps) }
        }
    }

    // ---- the place has nothing to show
    readonly property string blank: {
        const f = folder
        if (f.error.length > 0) return "error"
        if (f.loading || f.model.count > 0) return ""
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
                    name: ({ error: folder.error === "denied" ? "lock" : "error", searching: "search", nothing: "search_off", filtered: "filter_alt_off", trash: "delete", recent: "schedule", folder: "folder_open" })[root.blank] ?? "folder_open"
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
                    visible: root.blank === "error" && folder.error === "missing"
                    text: I18n.tr("Go up")
                    glyph: "arrow_upward"
                    onClicked: folder.goUp()
                }
            }
        }
    }

    // A thin ring around the pane while something can land in it.
    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.dp(4)
        radius: Theme.cardRadius - Theme.dp(4)
        color: Theme.alpha(Theme.accent, 0.05)
        border.width: Math.max(1, Theme.dp(2))
        border.color: Theme.alpha(Theme.accent, 0.7)
        visible: root.dropHover
    }
}
