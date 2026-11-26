import QtQuick
import QtQuick.Effects
import Quickshell
import qs.services
import qs.kit

// Instant keyboard-first jump & command palette (Ctrl+K / Ctrl+P): fuzzy jump across places, bookmarks, drives,
// recently visited folders, current folder entries and actions. Enter opens here, Ctrl+Enter in a new tab,
// Alt+Enter in a new tiled window (Niri / Umbriel).
Item {
    id: root
    required property var browser
    property bool shown: false
    property int current: 0
    property string query: ""
    property var pool: []

    anchors.fill: parent
    z: 860
    visible: root.shown || card.opacity > 0.01

    function open(initial: var): void {
        root.browser.menus.close()
        root.pool = root.buildPool()
        root.query = typeof initial === "string" ? initial : ""
        input.text = root.query
        root.current = 0
        root.shown = true
        Qt.callLater(() => { input.forceActiveFocus(); input.selectAll() })
    }
    function close(): void {
        if (!root.shown) return
        root.shown = false
        Qt.callLater(root.browser.focusPane)
    }

    function fold(s: string): string {
        return (s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
    }
    function scoreItem(label: string, detail: string, q: string): int {
        if (q.length === 0) return 0
        const a = root.fold(label)
        if (a === q) return 0
        const idx = a.indexOf(q)
        if (idx === 0) return 1
        if (idx > 0) return (a[idx - 1] === " " || a[idx - 1] === "/" || a[idx - 1] === "-" || a[idx - 1] === "_") ? 2 : 5
        // Fuzzy subsequence on label
        let qi = 0, gaps = 0, prev = -1
        for (let i = 0; i < a.length && qi < q.length; i++) {
            if (a[i] === q[qi]) {
                if (prev >= 0 && i > prev + 1) gaps += i - prev - 1
                prev = i
                qi++
            }
        }
        if (qi === q.length) return 12 + Math.min(40, gaps)
        const b = root.fold(detail)
        if (b.indexOf(q) >= 0) return 22
        return -1
    }

    function buildPool(): var {
        const b = root.browser
        const pane = b.activePane
        const f = pane ? pane.folder : null
        const out = []
        const seenPath = {}
        const addPlace = (path, title, detail, glyph, kind, extra) => {
            if (!path || seenPath[path]) return
            seenPath[path] = true
            out.push(Object.assign({ kind: kind, title: title, detail: detail, glyph: glyph, path: path, keys: "" }, extra ?? {}))
        }

        // 1. System places
        const home = Core.places.home || Core.home
        addPlace("start:", I18n.tr("Start"), I18n.tr("Start page"), "space_dashboard", "place")
        addPlace(home, I18n.tr("Home"), "~", "home", "place")
        addPlace("recent:", I18n.tr("Recent"), I18n.tr("Recent files"), "schedule", "place")
        const roleGlyphs = { desktop: "desktop_windows", documents: "description", downloads: "download", music: "music_note", pictures: "image", videos: "movie" }
        const roleNames = { desktop: I18n.tr("Desktop"), documents: I18n.tr("Documents"), downloads: I18n.tr("Downloads"),
            music: I18n.tr("Music"), pictures: I18n.tr("Pictures"), videos: I18n.tr("Videos") }
        for (const d of Core.places.xdg ?? []) {
            if (roleNames[d.role]) addPlace(d.path, roleNames[d.role], Fmt.pretty(d.path), roleGlyphs[d.role], "place")
        }
        addPlace("trash:", I18n.tr("Trash"), Fmt.items(Core.places.trash ?? 0), "delete", "place")

        // 2. Bookmarks
        const looks = Prefs.get("marks") ?? {}
        for (const m of Core.places.bookmarks ?? []) {
            if (!m.exists) continue
            addPlace(m.path, m.name, m.remote ? m.path : Fmt.pretty(m.path), looks[m.path]?.glyph || (m.remote ? "lan" : "bookmark"), "bookmark", { remote: m.remote === true })
        }

        // 3. Drives & network mounts
        for (const d of Core.places.devices ?? []) {
            const p = d.root ? "/" : (d.path || ("dev:" + d.device))
            const name = d.root ? I18n.tr("Computer") : (d.label || d.model || I18n.tr("%1 volume", Fmt.size(d.size)))
            const glyph = d.root ? "computer" : d.tran === "usb" || d.removable ? "usb" : "hard_drive"
            const mounted = d.mounted || d.root
            const det = d.size > 0 ? (mounted ? I18n.tr("%1 free of %2", Fmt.size(d.free), Fmt.size(d.size)) : I18n.tr("%1 · Not mounted", Fmt.size(d.size))) : ""
            addPlace(p, name, det, glyph, "drive", { device: d.device, mounted: mounted })
        }
        for (const n of Core.places.network ?? []) {
            addPlace(n.path, Fmt.share(n), n.fstype ?? "", n.kind === "phone" ? "smartphone" : "lan", "place")
        }

        // 4. Recently visited folders
        for (const vp of Prefs.recall("visited", [])) {
            addPlace(vp, Fmt.name(vp), Fmt.pretty(Fmt.parent(vp)), "history", "visited")
        }

        // 5. Entries in current folder (shown when typing)
        if (f && f.mode === "folder") {
            const lim = Math.min(f.all.length, 400)
            for (let i = 0; i < lim; i++) {
                const e = f.all[i]
                if (!seenPath[e.path]) {
                    out.push({ kind: "entry", title: e.name, detail: e.dir ? I18n.tr("Folder") : Fmt.size(e.size), glyph: e.dir ? "folder" : "draft", path: e.path, entry: e, keys: "" })
                }
            }
        }

        // 6. Commands
        const cmd = (title, glyph, keys, run, detail) => out.push({ kind: "command", title: title, detail: detail ?? I18n.tr("Command"), glyph: glyph, keys: keys, run: run })
        if (f && f.mode === "folder") {
            cmd(I18n.tr("Analyze disk space"), "donut_large", "Ctrl+Shift+U", () => b.actions.analyzeSpace(pane))
            cmd(I18n.tr("Filter this folder"), "filter_list", "Ctrl+/", () => pane.openFilter())
            cmd(I18n.tr("New folder"), "create_new_folder", "Ctrl+Shift+N", () => b.actions.newFolder(pane))
            cmd(I18n.tr("Open in terminal"), "terminal", "F4", () => b.actions.terminal(f.path))
            cmd(I18n.tr("Add to bookmarks"), "bookmark_add", "Ctrl+B", () => b.actions.bookmark(f.path))
            if (f.admin) cmd(I18n.tr("Exit administrator mode"), "logout", "", () => b.actions.exitAdmin(pane))
            else cmd(I18n.tr("Open as Administrator"), "admin_panel_settings", "", () => b.actions.openAsAdmin(pane, f.path))
        }
        cmd(I18n.tr("Split view"), "vertical_split", "F3", () => b.currentPage?.toggleSplit())
        cmd(I18n.tr("New tab"), "add", "Ctrl+T", () => b.newTab(f ? f.place : ""))
        cmd(I18n.tr("Duplicate tab"), "tab_duplicate", "Ctrl+Shift+D", () => b.duplicateTab(b.tabIndex))
        if (b.tabs.length > 1) cmd(I18n.tr("Move tab to new window"), "open_in_new", "Ctrl+Alt+W", () => b.detachTab(b.tabIndex))
        cmd(I18n.tr("New window"), "open_in_new", "Ctrl+N", () => b.newWindow(f ? f.place : ""))
        cmd(I18n.tr("Grid"), "grid_view", "Ctrl+1", () => b.actions.setView("grid"))
        cmd(I18n.tr("List"), "view_list", "Ctrl+2", () => b.actions.setView("list"))
        cmd(I18n.tr("Columns"), "view_column", "Ctrl+3", () => b.actions.setView("columns"))
        cmd(I18n.tr("Gallery"), "photo_library", "Ctrl+4", () => b.actions.setView("gallery"))
        cmd(I18n.tr("Show hidden files"), "visibility", "Ctrl+H", () => Prefs.set("hidden", !Prefs.get("hidden")))
        cmd(I18n.tr("Preview"), "view_sidebar", "Ctrl+I", () => Prefs.set("aside", !Prefs.get("aside")))
        cmd(I18n.tr("Places"), "side_navigation", "F9", () => b.toggleRail())
        cmd(I18n.tr("Connect to server…"), "add_link", "", () => b.actions.connect("", false))
        cmd(Theme.light ? I18n.tr("Dark") : I18n.tr("Light"), Theme.light ? "dark_mode" : "light_mode", "", () => Prefs.set("scheme", Theme.light ? "dark" : "light"))
        cmd(I18n.tr("Settings"), "settings", "Ctrl+,", () => b.actions.settings())
        return out
    }

    readonly property var matches: {
        const raw = root.query.trim()
        const cmdOnly = raw.startsWith(">")
        const q = root.fold(cmdOnly ? raw.slice(1).trim() : raw)
        const ranked = []
        for (let i = 0; i < root.pool.length; i++) {
            const it = root.pool[i]
            if (cmdOnly && it.kind !== "command") continue
            // Current-folder entries surface once the person starts typing.
            if (q.length === 0 && it.kind === "entry") continue
            const s = root.scoreItem(it.title, it.detail ?? "", q)
            if (s < 0) continue
            const bias = q.length === 0
                ? (it.kind === "place" ? 0 : it.kind === "bookmark" ? 2 : it.kind === "drive" ? 4 : it.kind === "visited" ? 6 : 12)
                : (it.kind === "command" ? 1 : 0)
            ranked.push({ item: it, score: s * 10 + bias, order: i })
        }
        ranked.sort((a, b) => a.score - b.score || a.order - b.order)
        return ranked.slice(0, 36).map(r => r.item)
    }
    onMatchesChanged: root.current = 0

    function activate(it: var, mode: string): void {
        if (!it) return
        root.close()
        const b = root.browser
        const pane = b.activePane
        if (it.kind === "command") { it.run(); return }
        if (it.remote) { b.actions.connect(it.path, mode === "tab"); return }
        if (it.kind === "drive" && !it.mounted) {
            Core.call("mount", { device: it.device }, r => {
                if (!r.ok) { Toast.fail(I18n.tr("Could not mount: %1", r.error)); return }
                Core.refreshPlaces()
                if (r.path) {
                    if (mode === "window") b.newWindow(r.path)
                    else if (mode === "tab") b.newTab(r.path)
                    else if (pane) pane.folder.go(r.path)
                }
            })
            return
        }
        if (it.kind === "entry" && !it.entry.dir) {
            if (pane) b.actions.open(pane, [it.entry])
            return
        }
        if (mode === "window") b.newWindow(it.path)
        else if (mode === "tab") b.newTab(it.path)
        else if (pane) pane.folder.go(it.path)
    }

    // Scrim
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        opacity: root.shown ? 0.55 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Item {
        id: card
        x: Math.round((parent.width - width) / 2)
        y: Math.round(Math.max(Theme.dp(48), parent.height * 0.11))
        width: Math.min(parent.width - Theme.dp(32), Theme.dp(560))
        height: Math.min(parent.height - y - Theme.dp(32), topBar.height + listHeight + footBar.height + Theme.dp(16))
        readonly property real listHeight: Math.min(Theme.dp(360), Math.max(Theme.dp(44), root.matches.length * Theme.dp(40)))
        opacity: root.shown ? 1 : 0
        scale: root.shown ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }

        RectangularShadow {
            anchors.fill: face
            radius: face.radius
            blur: Theme.dp(36)
            offset.y: Theme.dp(10)
            color: Theme.shadow
        }
        Rectangle {
            id: face
            anchors.fill: parent
            radius: Theme.cardRadius
            color: Theme.raised
            border.width: 1
            border.color: Theme.line
            clip: true

            Rectangle { x: parent.radius; width: parent.width - parent.radius * 2; height: 1; color: Theme.edge }

            // ---- input bar
            Item {
                id: topBar
                width: parent.width
                height: Theme.dp(52)
                Glyph {
                    id: bolt
                    x: Theme.dp(16)
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.query.trim().startsWith(">") ? "terminal" : "bolt"
                    size: Theme.dp(20)
                    color: Theme.accentInk
                }
                TextInput {
                    id: input
                    anchors.left: bolt.right
                    anchors.leftMargin: Theme.dp(10)
                    anchors.right: clearBtn.visible ? clearBtn.left : parent.right
                    anchors.rightMargin: Theme.dp(14)
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.ink
                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                    selectedTextColor: Theme.ink
                    font.family: Theme.sans
                    font.pixelSize: Theme.head
                    renderType: TextInput.NativeRendering
                    selectByMouse: true
                    onTextChanged: root.query = text
                    Keys.onEscapePressed: root.close()
                    Keys.onDownPressed: {
                        if (root.matches.length > 0) {
                            root.current = (root.current + 1) % root.matches.length
                            list.positionViewAtIndex(root.current, ListView.Contain)
                        }
                    }
                    Keys.onUpPressed: {
                        if (root.matches.length > 0) {
                            root.current = (root.current - 1 + root.matches.length) % root.matches.length
                            list.positionViewAtIndex(root.current, ListView.Contain)
                        }
                    }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            const m = (event.modifiers & Qt.AltModifier) ? "window" : (event.modifiers & Qt.ControlModifier) ? "tab" : "here"
                            root.activate(root.matches[root.current], m)
                            event.accepted = true
                        }
                    }
                    Txt {
                        visible: input.text.length === 0
                        x: Theme.dp(2)
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Jump to a place, file or > command…")
                        size: Theme.row
                        color: Theme.ink3
                    }
                }
                Act {
                    id: clearBtn
                    visible: input.text.length > 0
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    size: Theme.dp(26)
                    glyphSize: Theme.dp(16)
                    glyph: "close"
                    onClicked: { input.text = ""; input.forceActiveFocus() }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
            }

            // ---- matches
            ListView {
                id: list
                anchors.top: topBar.bottom
                anchors.topMargin: Theme.dp(6)
                anchors.bottom: footBar.top
                anchors.bottomMargin: Theme.dp(6)
                anchors.left: parent.left
                anchors.leftMargin: Theme.dp(8)
                anchors.right: parent.right
                anchors.rightMargin: Theme.dp(8)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.matches
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool active: root.current === row.index
                    width: list.width
                    height: Theme.dp(40)
                    radius: Theme.round(10)
                    color: row.active ? Theme.accentPlate : rowHit.containsMouse ? Theme.fill : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.hoverMs } }

                    Glyph {
                        id: rGlyph
                        x: Theme.dp(12)
                        anchors.verticalCenter: parent.verticalCenter
                        name: row.modelData.glyph
                        size: Theme.dp(18)
                        fill: row.active ? 1 : 0
                        color: row.active ? Theme.accentInk : Theme.ink2
                    }
                    Txt {
                        id: rTitle
                        anchors.left: rGlyph.right
                        anchors.leftMargin: Theme.dp(10)
                        anchors.right: rTrail.left
                        anchors.rightMargin: Theme.dp(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.title
                        size: Theme.row
                        strong: row.active
                        color: row.active ? Theme.accentInk : Theme.ink
                        elide: Text.ElideMiddle
                    }
                    Row {
                        id: rTrail
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.dp(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.dp(10)
                        Txt {
                            visible: (row.modelData.detail ?? "").length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.detail ?? ""
                            size: Theme.small
                            color: row.active ? Theme.accentInk : Theme.ink3
                            width: Math.min(implicitWidth, Theme.dp(200))
                            elide: Text.ElideMiddle
                            horizontalAlignment: Text.AlignRight
                        }
                        Txt {
                            visible: (row.modelData.keys ?? "").length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.keys ?? ""
                            size: Theme.caption
                            color: row.active ? Theme.accentInk : Theme.ink3
                        }
                    }
                    MouseArea {
                        id: rowHit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onPositionChanged: if (root.current !== row.index) root.current = row.index
                        onClicked: mouse => {
                            const m = mouse.button === Qt.MiddleButton || (mouse.modifiers & Qt.ControlModifier) ? "tab"
                                : (mouse.modifiers & Qt.AltModifier) ? "window" : "here"
                            root.activate(row.modelData, m)
                        }
                    }
                }
            }

            Txt {
                visible: root.matches.length === 0
                anchors.centerIn: list
                text: I18n.tr("Nothing matches")
                size: Theme.small
                color: Theme.ink3
            }

            // ---- compact key hint footer
            Item {
                id: footBar
                anchors.bottom: parent.bottom
                width: parent.width
                height: Theme.dp(32)
                Rectangle { width: parent.width; height: 1; color: Theme.line }
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(14)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(14)
                    Txt { text: "Enter · " + I18n.tr("Open"); size: Theme.caption; color: Theme.ink3 }
                    Txt { text: "Ctrl+Enter · " + I18n.tr("New tab"); size: Theme.caption; color: Theme.ink3 }
                    Txt { text: "Alt+Enter · " + I18n.tr("New window"); size: Theme.caption; color: Theme.ink3 }
                }
            }
        }
    }
}
