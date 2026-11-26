import QtQuick
import qs.services
import qs.kit

// The bar over the panes: the way back and up, where the pane is, search, how the place is shown, and the window's own
// controls. Its empty space moves the window.
Item {
    id: root
    required property var browser
    readonly property var pane: root.browser.activePane
    readonly property var folder: root.pane ? root.pane.folder : null
    property bool searchOpen: false
    // Narrow tiling windows (Niri/Umbriel half-tiles) collapse the 4-button pill into a single 1-click view button
    // instead of hiding view switching inside More.
    readonly property bool compact: root.width < Theme.dp(620) || (root.searchOpen && root.width < Theme.dp(760))
    readonly property var viewOrder: ["grid", "list", "columns", "gallery"]
    function viewGlyph(mode: string): string {
        return ({ grid: "grid_view", list: "view_list", columns: "view_column", gallery: "photo_library" })[mode] ?? "grid_view"
    }
    function cycleView(step: int): void {
        const cur = root.pane ? root.pane.viewMode : "grid"
        const i = root.viewOrder.indexOf(cur)
        const next = root.viewOrder[((i < 0 ? 0 : i) + step + root.viewOrder.length) % root.viewOrder.length]
        root.browser.actions.setView(next)
    }
    implicitHeight: Theme.dp(58)

    function startSearch(text: string): void {
        root.searchOpen = true
        search.text = text
        search.input.forceActiveFocus()
        search.input.cursorPosition = search.text.length
        debounce.restart()
    }
    function focusSearch(): void {
        root.searchOpen = true
        search.focusAll()
    }
    function clearSearch(): void {
        debounce.stop()
        search.text = ""
        root.searchOpen = false
        if (root.folder && root.folder.mode === "search") root.folder.stopSearch(true)
        if (root.pane) root.pane.forceActiveFocus()
    }
    // The places one way, nearest first, under the button: a pick goes straight there.
    function history(way: int, from: Item): void {
        const f = root.folder
        const page = root.browser.currentPage
        if (!f || !page) return
        const places = way < 0 ? f.back.slice().reverse() : f.forward
        root.browser.menus.openAt(places.slice(0, 16).map((p, i) => {
            const like = p.endsWith(":") ? { mode: p.slice(0, -1), path: "", query: "" } : { mode: "folder", path: p, query: "" }
            return { text: page.titleOf(like), glyph: page.glyphOf(like), run: () => f.travel(way * (i + 1)) }
        }), from, true)
    }
    function backspaceSearch(): void {
        search.text = search.text.slice(0, -1)
        if (search.text.length === 0) root.clearSearch()
        else debounce.restart()
    }
    function editPath(): void { path.edit() }

    Connections {
        target: root.folder
        function onModeChanged() {
            if (root.folder.mode !== "search" && !search.input.activeFocus) { search.text = ""; root.searchOpen = false }
        }
    }
    onPaneChanged: {
        search.text = root.folder && root.folder.mode === "search" ? root.folder.query : ""
        root.searchOpen = search.text.length > 0
    }
    Timer {
        id: debounce
        interval: 220
        onTriggered: if (root.folder) root.folder.search(search.text)
    }

    DragHandler {
        target: null
        grabPermissions: PointerHandler.CanTakeOverFromItems
        onActiveChanged: if (active) root.browser.startSystemMove()
    }
    TapHandler {
        acceptedButtons: Qt.LeftButton
        onDoubleTapped: root.browser.toggleMaximized()
    }

    Row {
        id: nav
        x: Theme.dp(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.dp(2)
        Act {
            visible: !root.browser.railDocked
            glyph: "side_navigation"
            tip: I18n.tr("Places")
            keys: "F9"
            on: root.browser.railOpen
            onClicked: root.browser.toggleRail()
        }
        // A middle click opens the place in a new tab; a right click or a long press lists the places that way.
        Act {
            id: backAct
            glyph: "arrow_back"
            tip: I18n.tr("Back")
            keys: "Alt+←"
            menu: true
            enabled: root.folder && root.folder.back.length > 0
            onClicked: m => { if (m.button === Qt.MiddleButton) root.browser.newTab(root.folder.back[root.folder.back.length - 1]); else root.folder.goBack() }
            onMenuRequested: root.history(-1, backAct)
        }
        Act {
            id: forwardAct
            glyph: "arrow_forward"
            tip: I18n.tr("Forward")
            keys: "Alt+→"
            menu: true
            enabled: root.folder && root.folder.forward.length > 0
            onClicked: m => { if (m.button === Qt.MiddleButton) root.browser.newTab(root.folder.forward[0]); else root.folder.goForward() }
            onMenuRequested: root.history(1, forwardAct)
        }
        Act {
            glyph: "arrow_upward"
            tip: I18n.tr("Enclosing folder")
            keys: "Alt+↑"
            enabled: root.folder && root.folder.mode === "folder" && root.folder.path !== "/"
            onClicked: root.folder.goUp()
        }
    }

    PathBar {
        id: path
        browser: root.browser
        anchors.left: nav.right
        anchors.leftMargin: Theme.dp(8)
        anchors.right: tools.left
        anchors.rightMargin: Theme.dp(10)
        anchors.verticalCenter: parent.verticalCenter
        height: Theme.dp(36)
    }

    Row {
        id: tools
        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.dp(4)

        Item {
            anchors.verticalCenter: parent.verticalCenter
            height: Theme.dp(36)
            width: root.searchOpen ? Math.min(Theme.dp(260), Math.max(Theme.dp(160), root.width * 0.22)) : Theme.dp(32)
            Behavior on width { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
            Act {
                visible: !root.searchOpen
                anchors.verticalCenter: parent.verticalCenter
                glyph: "search"
                tip: I18n.tr("Search")
                keys: "Ctrl+F"
                onClicked: root.focusSearch()
            }
            Field {
                id: search
                visible: root.searchOpen
                anchors.fill: parent
                radius: Theme.round(12)
                glyph: "search"
                placeholder: root.folder && root.folder.content ? I18n.tr("Text inside files") : I18n.tr("Search names")
                onEdited: {
                    if (search.text.length === 0) { debounce.stop(); if (root.folder && root.folder.mode === "search") root.folder.stopSearch(true) }
                    else debounce.restart()
                }
                onAccepted: {
                    debounce.stop()
                    if (search.text.length > 0 && root.folder) {
                        if (root.folder.mode !== "search" || root.folder.query !== search.text) root.folder.search(search.text)
                        root.pane.forceActiveFocus()
                        if (root.folder.model.count > 0) root.folder.only(0)
                    }
                }
                onEscaped: root.clearSearch()
                Connections {
                    target: search.input
                    function onActiveFocusChanged() { if (!search.input.activeFocus && search.text.length === 0) root.searchOpen = false }
                }
                Keys.onDownPressed: { root.pane.forceActiveFocus(); if (root.folder.model.count > 0) root.folder.only(0) }
            }
        }
        Segments {
            visible: !root.compact && (!root.folder || root.folder.mode !== "start")
            anchors.verticalCenter: parent.verticalCenter
            value: root.pane ? root.pane.viewMode : "grid"
            options: [
                { value: "grid", glyph: "grid_view", tip: I18n.tr("Grid"), keys: "Ctrl+1" },
                { value: "list", glyph: "view_list", tip: I18n.tr("List"), keys: "Ctrl+2" },
                { value: "columns", glyph: "view_column", tip: I18n.tr("Columns"), keys: "Ctrl+3" },
                { value: "gallery", glyph: "photo_library", tip: I18n.tr("Gallery"), keys: "Ctrl+4" }
            ]
            onChosen: value => root.browser.actions.setView(value)
        }
        Act {
            id: viewAct
            visible: root.compact && (!root.folder || root.folder.mode !== "start")
            anchors.verticalCenter: parent.verticalCenter
            glyph: root.viewGlyph(root.pane ? root.pane.viewMode : "grid")
            tip: I18n.tr("View")
            onClicked: m => {
                if (m && m.button === Qt.MiddleButton) root.cycleView(1)
                else root.browser.menus.openAt(root.browser.actions.viewEntries(), viewAct, true)
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: wheel => {
                    const d = wheel.angleDelta.y || wheel.angleDelta.x
                    if (d !== 0) root.cycleView(d > 0 ? -1 : 1)
                }
            }
        }
        Act {
            id: sortAct
            visible: !root.folder || root.folder.mode !== "start"
            anchors.verticalCenter: parent.verticalCenter
            glyph: "sort"
            tip: I18n.tr("Sort")
            onClicked: root.browser.menus.openAt(root.browser.actions.sortEntries(), sortAct, true)
        }
        Act {
            id: newTabAct
            visible: root.browser.tabs.length <= 1 && !root.browser.chooser
            anchors.verticalCenter: parent.verticalCenter
            glyph: "add"
            tip: I18n.tr("New tab")
            keys: "Ctrl+T"
            onClicked: m => root.browser.newTab(m && m.button === Qt.MiddleButton ? root.browser.defaultPlace() : (root.folder ? root.folder.place : ""))
        }
        Act {
            id: moreAct
            anchors.verticalCenter: parent.verticalCenter
            glyph: "more_horiz"
            tip: I18n.tr("More")
            onClicked: root.browser.menus.openAt(root.browser.actions.moreEntries(root.pane, root.compact), moreAct, true)
        }
        Act {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.browser.asideRoom
            glyph: "view_sidebar"
            tip: I18n.tr("Preview")
            keys: "Ctrl+I"
            on: Prefs.get("aside")
            onClicked: Prefs.set("aside", !Prefs.get("aside"))
        }
        Item { width: Theme.dp(4); height: 1 }
        Act {
            anchors.verticalCenter: parent.verticalCenter
            glyph: "close"
            round: true
            tip: I18n.tr("Close window")
            onClicked: root.browser.closeWindow()
        }
    }
}
