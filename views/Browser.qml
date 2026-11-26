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
    // Non-null when opened by xdg-desktop-portal (org.freedesktop.impl.portal.FileChooser).
    property var chooser: null
    property int chooserFilterIdx: 0
    property bool chooserAnswered: false
    property string chooserSaveName: ""
    signal newWindowRequested(string path)
    signal closeRequested()

    title: root.chooser
        ? (root.chooser.title || (root.chooser.kind === "save" ? I18n.tr("Save file") : root.chooser.directory ? I18n.tr("Select folder") : I18n.tr("Open file")))
        : (root.currentPage ? root.currentPage.title + " — " : "") + I18n.tr("Files")
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
    readonly property alias palette: paletteItem
    readonly property bool busy: sheets.children.length > 0 || menuHost.visible || look.shown || paletteItem.shown
    readonly property bool keysFree: !root.busy && root.renaming.length === 0
    // A narrow window lays the places over the panes on demand, and keeps the preview for a window with room for it.
    readonly property bool narrow: stageItem.width < Theme.dp(740)
    readonly property bool railDocked: !root.narrow && Prefs.get("rail") === true
    property bool railOpen: false
    property real railWidth: Math.max(Theme.dp(170), Math.min(Theme.dp(340), Number(Prefs.recall("railWidth", Theme.dp(228))) || Theme.dp(228)))
    readonly property bool asideRoom: stageItem.width - (root.railDocked ? root.railWidth : 0) - Theme.dp(240) >= Theme.dp(420)
    onNarrowChanged: root.railOpen = false
    function toggleRail(): void {
        if (root.narrow) root.railOpen = !root.railOpen
        else Prefs.set("rail", !Prefs.get("rail"))
    }

    // ---- tabs
    function defaultPlace(): string { return Prefs.get("start") === true ? "start:" : Core.home }
    function newTab(path: string, chosen: var, at: var): void {
        const page = pageComponent.createObject(pages, { browser: root, startPath: path && path.length > 0 ? path : root.defaultPlace(), startChosen: chosen ?? [] })
        page.anchors.fill = pages
        page.visible = Qt.binding(() => root.currentPage === page)
        const list = root.tabs.slice()
        const idx = typeof at === "number" && at >= 0 && at <= list.length ? at : list.length
        list.splice(idx, 0, page)
        root.tabs = list
        root.tabIndex = idx
        Qt.callLater(root.focusPane)
    }
    function closeTab(i: int, record: var): void {
        if (i < 0 || i >= root.tabs.length) return
        if (root.tabs.length <= 1) { root.closeWindow(); return }
        const page = root.tabs[i]
        if (record !== false) root.closedTabs = root.closedTabs.concat([page.activePane.folder.place]).slice(-10)
        const list = root.tabs.slice()
        list.splice(i, 1)
        const current = root.currentPage
        root.tabs = list
        root.tabIndex = current === page ? Math.min(i, list.length - 1) : list.indexOf(current)
        page.destroy()
        Qt.callLater(gc)
        Qt.callLater(root.focusPane)
    }
    function duplicateTab(i: int): void {
        const page = root.tabs[i]
        if (!page) return
        root.newTab(page.activePane.folder.place, [], i + 1)
    }
    // Detach a tab into its own window — tiling compositors (Niri, Umbriel) place it straight beside this one.
    function detachTab(i: int): void {
        const page = root.tabs[i]
        if (!page || root.tabs.length <= 1) return
        const place = page.activePane.folder.place
        root.closeTab(i, false)
        root.newWindow(place)
    }
    function closeOtherTabs(keep: int): void {
        if (keep < 0 || keep >= root.tabs.length || root.tabs.length <= 1) return
        const kept = root.tabs[keep]
        const closed = []
        for (let k = 0; k < root.tabs.length; k++) {
            if (k === keep) continue
            closed.push(root.tabs[k].activePane.folder.place)
            root.tabs[k].destroy()
        }
        root.closedTabs = root.closedTabs.concat(closed).slice(-10)
        root.tabs = [kept]
        root.tabIndex = 0
        Qt.callLater(gc)
        Qt.callLater(root.focusPane)
    }
    function closeTabsRight(from: int): void {
        if (from < 0 || from >= root.tabs.length - 1) return
        const closed = []
        const list = root.tabs.slice(0, from + 1)
        for (let k = from + 1; k < root.tabs.length; k++) {
            closed.push(root.tabs[k].activePane.folder.place)
            root.tabs[k].destroy()
        }
        root.closedTabs = root.closedTabs.concat(closed).slice(-10)
        root.tabs = list
        root.tabIndex = Math.min(root.tabIndex, list.length - 1)
        Qt.callLater(gc)
        Qt.callLater(root.focusPane)
    }
    function splitWithTab(i: int): void {
        if (i < 0 || i >= root.tabs.length || i === root.tabIndex || !root.currentPage) return
        const place = root.tabs[i].activePane.folder.place
        root.currentPage.openSplit(place)
        root.closeTab(i, false)
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
        onTriggered: Prefs.remember("tabs", { paths: root.tabs.map(p => p.activePane.folder.place).filter(p => p.indexOf(":") < 0 || p === "trash:" || p === "start:"), index: root.tabIndex })
    }
    Connections {
        target: root.activePane ? root.activePane.folder : null
        function onPlaceChanged() {
            saveTabs.restart()
            root.railOpen = false
            const f = root.activePane?.folder
            if (f && f.mode === "folder" && f.path.length > 0) {
                const prev = Prefs.recall("visited", []).filter(p => p !== f.path)
                Prefs.remember("visited", [f.path].concat(prev).slice(0, 30))
            }
        }
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
        if (root.chooser) {
            root.replyChooser(false, [], () => root.closeRequested())
            return
        }
        saveTabs.stop()
        saveTabs.triggered()
        root.closeRequested()
    }
    function replyChooser(ok: bool, paths: var, done: var): void {
        if (!root.chooser || root.chooserAnswered) { if (done) done(); return }
        root.chooserAnswered = true
        Core.call("chooser_reply", {
            token: root.chooser.token ?? "",
            ok: ok,
            paths: paths ?? [],
            filterIndex: root.chooserFilterIdx
        }, () => { if (done) done() })
    }
    function chooserReady(): bool {
        if (!root.chooser || !root.activePane) return false
        const f = root.activePane.folder
        void f.selRev
        if (root.chooser.kind === "save") return f.mode === "folder" && root.chooserSaveName.trim().length > 0
        if (root.chooser.directory) return f.mode === "folder"
        const chosen = f.chosen().filter(e => !e.dir)
        return chosen.length > 0
    }
    function acceptChooser(): void {
        if (!root.chooser || !root.activePane) return
        const f = root.activePane.folder
        if (root.chooser.kind === "save") {
            const name = root.chooserSaveName.trim()
            if (f.mode !== "folder" || name.length === 0) return
            root.replyChooser(true, [Fmt.join(f.path, name)], () => root.closeRequested())
            return
        }
        if (root.chooser.directory) {
            const dirs = f.chosen().filter(e => e.dir)
            const picked = dirs.length === 1 ? [dirs[0].path] : (f.mode === "folder" ? [f.path] : [])
            if (picked.length === 0) return
            root.replyChooser(true, picked, () => root.closeRequested())
            return
        }
        const files = f.chosen().filter(e => !e.dir).map(e => e.path)
        if (files.length === 0) return
        root.replyChooser(true, root.chooser.multiple ? files : [files[0]], () => root.closeRequested())
    }
    function cancelChooser(): void {
        root.replyChooser(false, [], () => root.closeRequested())
    }
    function applyChooserFilter(idx: int): void {
        root.chooserFilterIdx = idx
        const flist = root.chooser?.filters ?? []
        const rules = idx >= 0 && idx < flist.length ? (flist[idx].rules ?? []) : null
        for (const page of root.tabs) {
            if (page?.activePane?.folder) page.activePane.folder.portalFilter = rules
        }
    }
    Component.onDestruction: if (root.chooser && !root.chooserAnswered) root.replyChooser(false, [])
    // In Save mode, clicking an existing file fills the filename field for quick overwrite/edit.
    Connections {
        target: root.chooser && root.chooser.kind === "save" && root.activePane ? root.activePane.folder : null
        function onSelRevChanged() {
            const c = root.activePane.folder.chosen()
            if (c.length === 1 && !c[0].dir) root.chooserSaveName = c[0].name
        }
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
        if (root.chooser) {
            root.chooserSaveName = root.chooser.name ?? ""
            root.chooserFilterIdx = root.chooser.currentFilter ?? 0
            root.newTab(root.startPath || Core.home, [])
            Qt.callLater(() => root.applyChooserFilter(root.chooserFilterIdx))
            return
        }
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
            Behavior on width { enabled: !railEdge.pressed; NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
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
            // Administrator mode warning banner (Dolphin-style): unmistakable, one-click exit.
            Rectangle {
                id: adminBar
                readonly property bool active: !!root.activePane && root.activePane.folder.admin
                anchors.top: headItem.bottom
                width: parent.width
                height: active ? Theme.dp(38) : 0
                visible: height > 0
                clip: true
                color: Theme.alpha(Theme.warning, Theme.light ? 0.14 : 0.18)
                Behavior on height { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.alpha(Theme.warning, 0.35) }
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(14)
                    anchors.right: exitAdminBtn.left
                    anchors.rightMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(8)
                    Glyph {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "admin_panel_settings"
                        fill: 1
                        size: Theme.dp(17)
                        color: Theme.warning
                    }
                    Txt {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(Theme.dp(40), parent.width - Theme.dp(26))
                        text: I18n.tr("Acting as Administrator — changes affect system files")
                        size: Theme.small
                        strong: true
                        color: Theme.ink
                        elide: Text.ElideRight
                    }
                }
                Pill {
                    id: exitAdminBtn
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    compact: true
                    glyph: "logout"
                    text: I18n.tr("Exit")
                    onClicked: root.actions.exitAdmin(root.activePane)
                }
            }
            Filters {
                id: filters
                browser: root
                anchors.top: adminBar.bottom
                width: parent.width
                height: filters.shown ? implicitHeight : 0
                visible: height > 0
                clip: true
                Behavior on height { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
            }
            Item {
                id: pages
                anchors.top: filters.bottom
                anchors.bottom: chooserBar.visible ? chooserBar.top : status.top
                width: parent.width
            }
            // Portal FileChooser action bar (shown only when opened by an app via xdg-desktop-portal).
            Item {
                id: chooserBar
                visible: !!root.chooser
                anchors.bottom: status.top
                width: parent.width
                height: visible ? Theme.dp(54) : 0
                Rectangle { width: parent.width; height: 1; color: Theme.line }
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(14)
                    anchors.right: chooserBtns.left
                    anchors.rightMargin: Theme.dp(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(10)
                    Field {
                        id: saveField
                        visible: !!root.chooser && root.chooser.kind === "save"
                        width: Math.min(Theme.dp(340), Math.max(Theme.dp(160), parent.width - (filterBtn.visible ? filterBtn.width + Theme.dp(12) : 0)))
                        glyph: "edit"
                        placeholder: I18n.tr("File name")
                        text: root.chooserSaveName
                        onEdited: root.chooserSaveName = text
                        onAccepted: root.acceptChooser()
                        onEscaped: root.cancelChooser()
                    }
                    Pill {
                        id: filterBtn
                        visible: !!root.chooser && (root.chooser.filters ?? []).length > 0
                        compact: true
                        glyph: "filter_alt"
                        text: {
                            const fl = root.chooser?.filters ?? []
                            return root.chooserFilterIdx >= 0 && root.chooserFilterIdx < fl.length ? (fl[root.chooserFilterIdx].label || I18n.tr("Filter")) : I18n.tr("All files")
                        }
                        onClicked: {
                            const fl = root.chooser?.filters ?? []
                            const entries = fl.map((f, idx) => ({
                                text: f.label || I18n.tr("Filter"),
                                checked: root.chooserFilterIdx === idx,
                                run: () => root.applyChooserFilter(idx)
                            }))
                            entries.push({ text: I18n.tr("All files"), checked: root.chooserFilterIdx < 0, run: () => root.applyChooserFilter(-1) })
                            root.menus.openAt(entries, filterBtn, true)
                        }
                    }
                    Txt {
                        visible: !saveField.visible
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(Theme.dp(40), parent.width - (filterBtn.visible ? filterBtn.width + Theme.dp(12) : 0))
                        elide: Text.ElideMiddle
                        size: Theme.small
                        color: Theme.ink2
                        text: {
                            if (!root.chooser || !root.activePane) return ""
                            const f = root.activePane.folder
                            void f.selRev
                            if (root.chooser.directory) {
                                const dirs = f.chosen().filter(e => e.dir)
                                return dirs.length === 1 ? dirs[0].name : Fmt.pretty(f.path)
                            }
                            const files = f.chosen().filter(e => !e.dir)
                            if (files.length === 0) return root.chooser.multiple ? I18n.tr("Choose one or more files") : I18n.tr("Choose a file")
                            return files.length === 1 ? files[0].name : I18n.n("%1 file chosen", "%1 files chosen", files.length)
                        }
                    }
                }
                Row {
                    id: chooserBtns
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(14)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(8)
                    Pill {
                        text: I18n.tr("Cancel")
                        kind: "plain"
                        onClicked: root.cancelChooser()
                    }
                    Pill {
                        kind: "solid"
                        enabled: root.chooserReady()
                        text: {
                            const custom = (root.chooser?.acceptLabel ?? "").replace(/_/g, "").trim()
                            if (custom.length > 0) return custom
                            if (root.chooser?.kind === "save") return I18n.tr("Save")
                            return root.chooser?.directory ? I18n.tr("Select") : I18n.tr("Open")
                        }
                        onClicked: root.acceptChooser()
                    }
                }
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
        // Drag seam to resize the docked left sidebar; double-click resets to default width.
        MouseArea {
            id: railEdge
            visible: root.railDocked
            x: railSlot.width - width / 2
            width: Theme.dp(8)
            height: parent.height
            z: 5
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor
            property real startX: 0
            property real startW: 0
            onPressed: mouse => { startX = mapToItem(null, mouse.x, 0).x; startW = root.railWidth }
            onPositionChanged: mouse => {
                if (!pressed) return
                const dx = mapToItem(null, mouse.x, 0).x - startX
                const maxW = Math.min(Theme.dp(360), Math.max(Theme.dp(190), stageItem.width * 0.36))
                root.railWidth = Math.round(Math.max(Theme.dp(170), Math.min(maxW, startW + dx)))
            }
            onReleased: Prefs.remember("railWidth", Math.round(root.railWidth))
            onDoubleClicked: { root.railWidth = Theme.dp(228); Prefs.remember("railWidth", Math.round(root.railWidth)) }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: Theme.dp(16)
                width: Theme.dp(2)
                height: parent.height - Theme.dp(32)
                radius: 1
                color: railEdge.pressed ? Theme.accent : Theme.ink3
                opacity: railEdge.pressed ? 0.85 : railEdge.containsMouse ? 0.38 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.hoverMs } }
            }
        }

        Travel { browser: root; anchors.fill: parent; z: 600 }

        ToastBar {
            anchors.horizontalCenter: canvas.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: status.height + Theme.dp(14)
            z: 700
        }
        QuickLook { id: look; browser: root }
        CommandPalette { id: paletteItem; browser: root }
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
    Key { sequences: [StandardKey.SelectAll]; onActivated: if (root.pane.folder.mode !== "start") root.pane.folder.selectAll() }
    Key { sequence: "Ctrl+Shift+I"; onActivated: if (root.pane.folder.mode !== "start") root.pane.folder.invertSel() }
    Key { sequence: "Ctrl+H"; always: true; onActivated: Prefs.set("hidden", !Prefs.get("hidden")) }
    Key { sequence: "Ctrl+L"; always: true; onActivated: root.head.editPath() }
    Key { sequences: [StandardKey.Find]; always: true; onActivated: root.head.focusSearch() }
    Key { sequence: "Ctrl+T"; always: true; onActivated: root.newTab(root.pane ? root.pane.folder.place : "") }
    Key { sequence: "Ctrl+Shift+D"; always: true; onActivated: root.duplicateTab(root.tabIndex) }
    Key { sequence: "Ctrl+Alt+W"; always: true; onActivated: if (root.tabs.length > 1) root.detachTab(root.tabIndex) }
    Key { sequence: "Ctrl+W"; always: true; onActivated: root.closeTab(root.tabIndex) }
    Key { sequence: "Ctrl+Shift+T"; always: true; onActivated: root.reopenTab() }
    Key { sequence: "Ctrl+Tab"; always: true; onActivated: root.stepTab(1) }
    Key { sequence: "Ctrl+Shift+Tab"; always: true; onActivated: root.stepTab(-1) }
    Key { sequence: "Ctrl+PgDown"; always: true; onActivated: root.stepTab(1) }
    Key { sequence: "Ctrl+PgUp"; always: true; onActivated: root.stepTab(-1) }
    Key { sequence: "Ctrl+Shift+PgUp"; always: true; onActivated: root.moveTab(root.tabIndex, root.tabIndex - 1) }
    Key { sequence: "Ctrl+Shift+PgDown"; always: true; onActivated: root.moveTab(root.tabIndex, root.tabIndex + 1) }
    Key { sequences: ["Alt+Left", "Back"]; always: true; onActivated: root.pane.folder.goBack() }
    Key { sequences: ["Alt+Right", "Forward"]; always: true; onActivated: root.pane.folder.goForward() }
    Key { sequence: "Alt+Up"; always: true; onActivated: root.pane.folder.goUp() }
    Key { sequence: "Alt+Home"; always: true; onActivated: root.pane.folder.go(Core.places.home || Core.home) }
    Key { sequence: "Ctrl+Shift+N"; onActivated: root.actions.newFolder(root.pane) }
    Key { sequence: "Ctrl+N"; always: true; onActivated: root.newWindow(root.pane ? root.pane.folder.place : "") }
    Key { sequences: [StandardKey.Undo]; onActivated: root.actions.undo() }
    Key { sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]; onActivated: root.actions.redo() }
    Key { sequence: "Ctrl+S"; onActivated: if (root.pane.folder.mode !== "start") root.actions.selectByName(root.pane) }
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
    Key { sequence: "Ctrl+/"; onActivated: if (root.pane) root.pane.openFilter() }
    Key { sequences: ["Ctrl+K", "Ctrl+P"]; always: true; onActivated: paletteItem.open("") }
    Key { sequence: "Ctrl+Shift+U"; always: true; onActivated: root.actions.analyzeSpace(root.pane) }
    Key { sequence: "Ctrl+,"; always: true; onActivated: root.actions.settings() }
    Key { sequence: "Ctrl+Q"; always: true; onActivated: root.closeWindow() }
}
