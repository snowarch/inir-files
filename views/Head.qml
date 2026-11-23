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
    // Too narrow for the view switch: the More menu offers it instead.
    readonly property bool compact: root.width < Theme.dp(600)
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
        Act {
            glyph: "arrow_back"
            tip: I18n.tr("Back")
            keys: "Alt+←"
            enabled: root.folder && root.folder.back.length > 0
            onClicked: root.folder.goBack()
        }
        Act {
            glyph: "arrow_forward"
            tip: I18n.tr("Forward")
            keys: "Alt+→"
            enabled: root.folder && root.folder.forward.length > 0
            onClicked: root.folder.goForward()
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
                radius: Theme.dp(12)
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
        Act {
            visible: root.searchOpen
            anchors.verticalCenter: parent.verticalCenter
            glyph: "text_snippet"
            tip: root.folder && root.folder.content ? I18n.tr("Searching inside files") : I18n.tr("Search inside files")
            on: root.folder ? root.folder.content : false
            onClicked: root.folder.content = !root.folder.content
        }
        Segments {
            visible: !root.compact
            anchors.verticalCenter: parent.verticalCenter
            value: root.pane ? root.pane.viewMode : "grid"
            options: [
                { value: "grid", glyph: "grid_view", tip: I18n.tr("Grid"), keys: "Ctrl+1" },
                { value: "list", glyph: "view_list", tip: I18n.tr("List"), keys: "Ctrl+2" },
                { value: "columns", glyph: "view_column", tip: I18n.tr("Columns"), keys: "Ctrl+3" }
            ]
            onChosen: value => root.browser.actions.setView(value)
        }
        Act {
            id: sortAct
            anchors.verticalCenter: parent.verticalCenter
            glyph: "sort"
            tip: I18n.tr("Sort")
            onClicked: root.browser.menus.openAt(root.browser.actions.sortEntries(), sortAct, true)
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
