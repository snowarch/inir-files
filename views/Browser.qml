import QtQuick
import QtQuick.Effects
import Quickshell
import qs.services
import qs.kit

// One window of the file manager: the places down the left, tabs of panes in the middle, the chosen file on the right.
FloatingWindow {
    id: root
    property string startPath: ""
    property bool restoreTabs: false
    // The entries to choose in the first tab, and their properties shown at once.
    property var startChosen: []
    property bool startProps: false
    signal newWindowRequested(string path)
    signal closeRequested()

    title: (root.currentPage ? root.currentPage.title + " — " : "") + I18n.tr("Files")
    color: Theme.rail
    // The size is the window's own, never the density's: it opens as it was last left, and only the person or the
    // compositor changes it.
    implicitWidth: 1240
    implicitHeight: 800
    minimumSize: Qt.size(560, 400)
    onWidthChanged: keepSize.restart()
    onHeightChanged: keepSize.restart()
    Timer {
        id: keepSize
        interval: 800
        onTriggered: {
            const w = stageItem.Window.window
            if (!w || w.visibility === Window.Maximized || w.visibility === Window.FullScreen || root.width < 560 || root.height < 400) return
            Prefs.remember("window", { w: Math.round(root.width), h: Math.round(root.height) })
        }
    }

    readonly property Item stage: stageItem
    readonly property bool windowActive: stageItem.Window.active
    property var tabs: []
    property int tabIndex: 0
    // The places of the tabs closed last, for Ctrl+Shift+T.
    property var closedTabs: []
    readonly property var currentPage: root.tabs[root.tabIndex] ?? null
    readonly property var activePane: root.currentPage ? root.currentPage.activePane : null
    property string renaming: ""
    readonly property alias actions: actionsItem
    readonly property alias menus: menuHost
    readonly property alias tips: tipHost
    readonly property alias head: headItem
    readonly property alias quickLook: look
    readonly property bool busy: sheets.children.length > 0 || menuHost.visible || look.shown
    readonly property bool keysFree: !root.busy && root.renaming.length === 0
    // A narrow window lays the places over the panes on demand, and keeps the preview for a window with room for it.
    readonly property bool narrow: stageItem.width < Theme.dp(800)
    readonly property bool railDocked: !root.narrow && Prefs.get("rail") === true
    property bool railOpen: false
    readonly property real railWidth: Theme.dp(228)
    readonly property bool asideRoom: stageItem.width - (root.railDocked ? root.railWidth : 0) - aside.open >= Theme.dp(600)
    onNarrowChanged: root.railOpen = false
    function toggleRail(): void {
        if (root.narrow) root.railOpen = !root.railOpen
        else Prefs.set("rail", !Prefs.get("rail"))
    }

    // ---- tabs
    function newTab(path: string, chosen: var): void {
        const page = pageComponent.createObject(pages, { browser: root, startPath: path && path.length > 0 ? path : Core.home, startChosen: chosen ?? [] })
        page.anchors.fill = pages
        page.visible = Qt.binding(() => root.currentPage === page)
        root.tabs = root.tabs.concat([page])
        root.tabIndex = root.tabs.length - 1
        Qt.callLater(root.focusPane)
    }
    function closeTab(i: int): void {
        if (root.tabs.length <= 1) { root.closeWindow(); return }
        const page = root.tabs[i]
        root.closedTabs = root.closedTabs.concat([page.activePane.folder.place]).slice(-10)
        const list = root.tabs.slice()
        list.splice(i, 1)
        const current = root.currentPage
        root.tabs = list
        root.tabIndex = current === page ? Math.min(i, list.length - 1) : list.indexOf(current)
        page.destroy()
        Qt.callLater(root.focusPane)
    }
    function moveTab(from: int, to: int): void {
        if (from === to || to < 0 || to >= root.tabs.length) return
        const current = root.currentPage
        const list = root.tabs.slice()
        list.splice(to, 0, list.splice(from, 1)[0])
        root.tabs = list
        root.tabIndex = list.indexOf(current)
    }
    function reopenTab(): void {
        if (root.closedTabs.length === 0) return
        const place = root.closedTabs[root.closedTabs.length - 1]
        root.closedTabs = root.closedTabs.slice(0, -1)
        root.newTab(place)
    }
    function stepTab(d: int): void {
        if (root.tabs.length > 1) root.tabIndex = (root.tabIndex + d + root.tabs.length) % root.tabs.length
    }
    function focusPane(): void { if (root.activePane) root.activePane.forceActiveFocus() }
    // The pane under a point of `item`; over neither, the active one, or null when `exact`.
    function paneAt(item: Item, x: real, y: real, exact: bool): var {
        for (const p of root.currentPage ? root.currentPage.panes : []) if (p.contains(p.mapFromItem(item, x, y))) return p
        return exact ? null : root.activePane
    }
    onTabIndexChanged: Qt.callLater(root.focusPane)
    onCurrentPageChanged: saveTabs.restart()

    // The tabs of the last window are there again the next time.
    Timer {
        id: saveTabs
        interval: 1500
        onTriggered: Prefs.remember("tabs", { paths: root.tabs.map(p => p.activePane.folder.place).filter(p => p !== "recent:" && p.indexOf(":") < 0 || p === "trash:"), index: root.tabIndex })
    }
    Connections {
        target: root.activePane ? root.activePane.folder : null
        function onPlaceChanged() { saveTabs.restart(); root.railOpen = false }
    }

    // ---- the window itself
    function newWindow(path: string): void { root.newWindowRequested(path) }
    function startSystemMove(): void { const w = stageItem.Window.window; if (w && w.startSystemMove) w.startSystemMove() }
    function toggleMaximized(): void {
        const w = stageItem.Window.window
        if (!w) return
        if (w.visibility === Window.Maximized) w.showNormal()
        else w.showMaximized()
    }
    function closeWindow(): void {
        saveTabs.stop()
        saveTabs.triggered()
        root.closeRequested()
    }
    // A sheet over the window; the pane takes the keys again once it goes.
    function sheet(component: Component, props: var): var {
        menuHost.close()
        const s = component.createObject(sheets, props)
        if (s) s.dismissed.connect(() => Qt.callLater(root.focusPane))
        return s
    }

    Component.onCompleted: {
        const size = Prefs.recall("window", null)
        if (size && size.w >= 560 && size.h >= 400) { root.implicitWidth = size.w; root.implicitHeight = size.h }
        const saved = root.restoreTabs && root.startPath.length === 0 && Prefs.get("restoreTabs") ? Prefs.recall("tabs", null) : null
        if (saved && saved.paths && saved.paths.length > 0) {
            for (const p of saved.paths) root.newTab(p)
            root.tabIndex = Math.max(0, Math.min(saved.index ?? 0, root.tabs.length - 1))
        } else root.newTab(root.startPath, root.startChosen)
        if (root.startProps && root.startChosen.length > 0) Qt.callLater(root.actions.propertiesOf, root.startChosen)
    }

    Component { id: pageComponent; TabPage {} }

    Item {
        id: stageItem
        anchors.fill: parent
        focus: true

        // The room the docked places take; the panes start after it.
        Item {
            id: railSlot
            width: root.railDocked ? root.railWidth : 0
            height: parent.height
            Behavior on width { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
        }

        // The panes sit on a card of their own, a step down from the window around them.
        Rectangle {
            id: canvas
            anchors.left: railSlot.right
            anchors.leftMargin: Math.max(0, Theme.dp(8) - railSlot.width)
            anchors.right: aside.left
            anchors.rightMargin: Math.max(0, Theme.dp(8) - aside.width)
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(8)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.dp(8)
            radius: Theme.corner
            color: Theme.canvas
            clip: true

            TabStrip {
                id: strip
                browser: root
                width: parent.width
                height: root.tabs.length > 1 ? implicitHeight : 0
                visible: height > 0
                clip: true
                Behavior on height { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
            }
            Head {
                id: headItem
                browser: root
                anchors.top: strip.bottom
                width: parent.width
                height: implicitHeight
            }
            Filters {
                id: filters
                browser: root
                anchors.top: headItem.bottom
                width: parent.width
                height: filters.shown ? implicitHeight : 0
                visible: height > 0
                clip: true
                Behavior on height { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
            }
            Item {
                id: pages
                anchors.top: filters.bottom
                anchors.bottom: status.top
                width: parent.width
            }
            Status {
                id: status
                browser: root
                anchors.bottom: parent.bottom
                width: parent.width
                height: implicitHeight
            }
        }

        Aside {
            id: aside
            browser: root
            anchors.right: parent.right
            height: parent.height
        }

        MouseArea {
            anchors.fill: parent
            z: 639
            visible: root.narrow && root.railOpen
            onClicked: root.railOpen = false
            Rectangle { anchors.fill: parent; color: Theme.scrim; opacity: 0.6 }
        }
        Item {
            id: railBox
            width: root.railWidth
            height: parent.height
            x: root.railDocked || (root.narrow && root.railOpen) ? 0 : -width - Theme.dp(40)
            z: root.narrow ? 640 : 0
            visible: x > -width - Theme.dp(40)
            Behavior on x { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
            RectangularShadow {
                anchors.fill: parent
                visible: root.narrow
                blur: Theme.dp(32)
                color: Theme.shadow
            }
            Rectangle { anchors.fill: parent; visible: root.narrow; color: Theme.rail }
            Rail { id: rail; browser: root; anchors.fill: parent }
        }

        Travel { browser: root; anchors.fill: parent; z: 600 }

        ToastBar {
            anchors.horizontalCenter: canvas.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: status.height + Theme.dp(14)
            z: 700
        }
        QuickLook { id: look; browser: root }
        Item { id: sheets; anchors.fill: parent; z: 800 }
        MenuHost { id: menuHost }
        TipHost { id: tipHost; anchors.fill: parent; z: 950 }
        Actions { id: actionsItem; browser: root }
    }

    // ---- keys: the ones that act on files wait while a sheet, a menu or a name being typed has them
    component Key: Shortcut {
        property bool always: false
        enabled: always ? !root.busy : root.keysFree
        context: Qt.WindowShortcut
    }
    readonly property var pane: root.activePane
    Key { sequences: [StandardKey.Copy]; onActivated: root.actions.copy(root.pane) }
    Key { sequences: [StandardKey.Cut]; onActivated: root.actions.cut(root.pane) }
    Key { sequences: [StandardKey.Paste]; onActivated: root.actions.paste(root.pane, "") }
    Key { sequence: "Ctrl+Shift+C"; onActivated: root.actions.copyPath(root.pane) }
    Key { sequence: "Delete"; onActivated: root.actions.trash(root.pane) }
    Key { sequence: "Shift+Delete"; onActivated: root.actions.deleteForever(root.pane) }
    Key { sequence: "F2"; onActivated: root.actions.rename(root.pane) }
    Key { sequence: "Ctrl+D"; onActivated: root.actions.duplicate(root.pane) }
    Key { sequence: "Ctrl+B"; onActivated: if (root.actions.here(root.pane).length > 0) root.actions.bookmark(root.actions.here(root.pane)) }
    Key { sequences: [StandardKey.SelectAll]; onActivated: root.pane.folder.selectAll() }
    Key { sequence: "Ctrl+Shift+I"; onActivated: root.pane.folder.invertSel() }
    Key { sequence: "Ctrl+H"; always: true; onActivated: Prefs.set("hidden", !Prefs.get("hidden")) }
    Key { sequence: "Ctrl+L"; always: true; onActivated: root.head.editPath() }
    Key { sequences: [StandardKey.Find]; always: true; onActivated: root.head.focusSearch() }
    Key { sequence: "Ctrl+T"; always: true; onActivated: root.newTab(root.pane ? root.pane.folder.place : "") }
    Key { sequence: "Ctrl+W"; always: true; onActivated: root.closeTab(root.tabIndex) }
    Key { sequence: "Ctrl+Shift+T"; always: true; onActivated: root.reopenTab() }
    Key { sequence: "Ctrl+Tab"; always: true; onActivated: root.stepTab(1) }
    Key { sequence: "Ctrl+Shift+Tab"; always: true; onActivated: root.stepTab(-1) }
    Key { sequence: "Ctrl+PgDown"; always: true; onActivated: root.stepTab(1) }
    Key { sequence: "Ctrl+PgUp"; always: true; onActivated: root.stepTab(-1) }
    Key { sequences: ["Alt+Left", "Back"]; always: true; onActivated: root.pane.folder.goBack() }
    Key { sequences: ["Alt+Right", "Forward"]; always: true; onActivated: root.pane.folder.goForward() }
    Key { sequence: "Alt+Up"; always: true; onActivated: root.pane.folder.goUp() }
    Key { sequence: "Alt+Home"; always: true; onActivated: root.pane.folder.go(Core.places.home || Core.home) }
    Key { sequence: "Ctrl+Shift+N"; onActivated: root.actions.newFolder(root.pane) }
    Key { sequence: "Ctrl+N"; always: true; onActivated: root.newWindow(root.pane ? root.pane.folder.place : "") }
    Key { sequences: [StandardKey.Undo]; onActivated: root.actions.undo() }
    Key { sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]; onActivated: root.actions.redo() }
    Key { sequence: "Ctrl+S"; onActivated: root.actions.selectByName(root.pane) }
    Key { sequence: "Ctrl+1"; always: true; onActivated: root.actions.setView("grid") }
    Key { sequence: "Ctrl+2"; always: true; onActivated: root.actions.setView("list") }
    Key { sequence: "Ctrl+3"; always: true; onActivated: root.actions.setView("columns") }
    Key { sequence: "Ctrl+4"; always: true; onActivated: root.actions.setView("gallery") }
    Key { sequence: "Ctrl+I"; always: true; onActivated: Prefs.set("aside", !Prefs.get("aside")) }
    Key { sequence: "F9"; always: true; onActivated: root.toggleRail() }
    Key { sequence: "Escape"; enabled: root.railOpen; onActivated: root.railOpen = false }
    Key { sequence: "F3"; always: true; onActivated: if (root.currentPage) root.currentPage.toggleSplit() }
    Key { sequence: "F4"; always: true; onActivated: { const d = root.actions.here(root.pane); if (d.length > 0) root.actions.terminal(d) } }
    Key { sequence: "F5"; always: true; onActivated: root.pane.folder.reload() }
    Key { sequence: "Ctrl+R"; always: true; onActivated: root.pane.folder.reload() }
    Key { sequence: "Alt+Return"; onActivated: root.actions.properties(root.pane) }
    Key { sequence: "Ctrl+="; always: true; onActivated: root.actions.zoom(1) }
    Key { sequence: "Ctrl++"; always: true; onActivated: root.actions.zoom(1) }
    Key { sequence: "Ctrl+-"; always: true; onActivated: root.actions.zoom(-1) }
    Key { sequence: "Ctrl+0"; always: true; onActivated: root.actions.resetZoom() }
    // Alt with a digit picks that tab; Alt+9 the last one, as in a web browser.
    Instantiator {
        model: 9
        delegate: Key {
            required property int index
            sequence: "Alt+" + (index + 1)
            always: true
            onActivated: { if (index === 8) root.tabIndex = root.tabs.length - 1; else if (index < root.tabs.length) root.tabIndex = index }
        }
    }
    Key { sequence: "Ctrl+,"; always: true; onActivated: root.actions.settings() }
    Key { sequence: "Ctrl+Q"; always: true; onActivated: root.closeWindow() }
}
