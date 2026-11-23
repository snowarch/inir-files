import QtQuick
import Quickshell
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The places down the left: the person's own folders, bookmarks, disks and shares, and the trash. Every place takes a
// drop; a disk shows how full it is and can be put away from here.
Item {
    id: root
    required property var browser
    readonly property var places: Core.places
    readonly property var folder: root.browser.activePane ? root.browser.activePane.folder : null
    readonly property string place: root.folder ? root.folder.place : ""

    // ---- bookmarks: an order the person just made shows at once, before the core writes it back. Each one can wear
    // its own glyph and colour (settings "marks"); a section folds away (settings "fold").
    property var pendingMarks: null
    property int moving: 0
    Connections { target: Core; function onPlacesChanged() { if (root.moving === 0) root.pendingMarks = null } }
    readonly property var allMarks: root.places.bookmarks ?? []
    readonly property var looks: Prefs.get("marks") ?? ({})
    property int dragFrom: -1
    property int dragTo: -1
    property int insertAt: -1
    property Item insertBy: null
    readonly property var glyphChoices: [
        { glyph: "bookmark", text: I18n.tr("Bookmark") }, { glyph: "folder", text: I18n.tr("Folder") }, { glyph: "star", text: I18n.tr("Star") },
        { glyph: "favorite", text: I18n.tr("Heart") }, { glyph: "work", text: I18n.tr("Work") }, { glyph: "school", text: I18n.tr("Study") },
        { glyph: "code", text: I18n.tr("Code") }, { glyph: "palette", text: I18n.tr("Design") }, { glyph: "sports_esports", text: I18n.tr("Games") },
        { glyph: "music_note", text: I18n.tr("Music") }, { glyph: "image", text: I18n.tr("Pictures") }, { glyph: "movie", text: I18n.tr("Videos") },
        { glyph: "cloud", text: I18n.tr("Cloud") }, { glyph: "download", text: I18n.tr("Downloads") }
    ]
    readonly property var tintChoices: [
        { key: "", text: I18n.tr("Default") }, { key: "accent", text: I18n.tr("Accent") }, { key: "secondary", text: I18n.tr("Secondary accent") },
        { key: "tertiary", text: I18n.tr("Tertiary accent") }, { key: "red", text: I18n.tr("Red") }, { key: "amber", text: I18n.tr("Amber") },
        { key: "green", text: I18n.tr("Green") }
    ]
    function folded(section: string): bool { return (Prefs.get("fold") ?? {})[section] === true }
    function fold(section: string): void {
        const f = Object.assign({}, Prefs.get("fold") ?? {})
        f[section] = !f[section]
        Prefs.set("fold", f)
    }
    function look(path: string, key: string, value: string): void {
        const all = Object.assign({}, root.looks)
        const one = Object.assign({}, all[path] ?? {})
        one[key] = value
        all[path] = one
        Prefs.set("marks", all)
    }
    // A place among the bookmarks shown, as an index of the whole file, which also holds the remote ones.
    function fileIndex(k: int): int {
        if (k >= root.marks.length) return root.allMarks.length
        return Math.max(0, root.allMarks.findIndex(b => b.path === root.marks[k].path))
    }
    function moveMark(path: string, to: int): void {
        const from = root.marks.findIndex(m => m.path === path)
        if (from < 0 || to < 0 || to >= root.marks.length || to === from) return
        const at = root.fileIndex(to)
        const next = (root.pendingMarks ?? root.allMarks.filter(b => !b.remote)).slice()
        next.splice(to, 0, next.splice(from, 1)[0])
        root.pendingMarks = next
        root.moving++
        Core.call("bookmark_move", { path: path, at: at }, r => { root.moving--; Core.takeBookmarks(r); if (!r.ok) root.pendingMarks = null })
    }
    // The menu stays open on Move up and Move down, so a bookmark can go several steps.
    function moveFromMenu(it: var, index: int, step: int): void {
        root.moveMark(it.path, index + step)
        root.browser.menus.refresh(root.menuFor(it, index + step))
    }

    readonly property var roleGlyphs: ({ desktop: "desktop_windows", documents: "description", downloads: "download", music: "music_note",
        pictures: "image", videos: "movie", templates: "draft", public: "public" })
    readonly property var roleNames: ({ desktop: I18n.tr("Desktop"), documents: I18n.tr("Documents"), downloads: I18n.tr("Downloads"),
        music: I18n.tr("Music"), pictures: I18n.tr("Pictures"), videos: I18n.tr("Videos") })

    readonly property var own: {
        const out = [{ path: root.places.home || Core.home, name: I18n.tr("Home"), glyph: "home", kind: "place" },
            { path: "recent:", name: I18n.tr("Recent"), glyph: "schedule", kind: "recent" }]
        for (const role of ["desktop", "documents", "downloads", "music", "pictures", "videos"]) {
            const d = (root.places.xdg ?? []).find(x => x.role === role)
            if (d && d.path !== root.places.home) out.push({ path: d.path, name: root.roleNames[role], glyph: root.roleGlyphs[role], kind: "place" })
        }
        out.push({ path: "trash:", name: I18n.tr("Trash"), glyph: "delete", kind: "trash", count: root.places.trash ?? 0 })
        return out
    }
    readonly property var marks: (root.pendingMarks ?? root.allMarks.filter(b => !b.remote)).map(b => ({
        path: b.path, name: b.name, glyph: b.exists ? (root.looks[b.path]?.glyph || "bookmark") : "bookmark_remove",
        tint: root.looks[b.path]?.tint ?? "", kind: "bookmark", missing: !b.exists
    }))
    readonly property var disks: (root.places.devices ?? []).map(d => ({
        path: d.root ? "/" : d.path,
        name: d.root ? I18n.tr("Computer") : (d.label || d.model || I18n.tr("%1 volume", Fmt.size(d.size))),
        glyph: d.root ? "computer" : d.tran === "usb" || d.removable ? "usb" : d.fstype === "iso9660" || d.fstype === "udf" ? "album" : "hard_drive",
        kind: "device", device: d.device, drive: d.drive, mounted: d.mounted || d.root, removable: d.removable, root: d.root,
        meter: d.size > 0 && (d.mounted || d.root) ? 1 - d.free / d.size : -1,
        detail: d.size > 0 ? (d.mounted || d.root ? I18n.tr("%1 free of %2", Fmt.size(d.free), Fmt.size(d.size)) : Fmt.size(d.size)) : ""
    }))
    readonly property var shares: (root.places.network ?? []).map(n => ({
        path: n.path, name: n.label, glyph: n.kind === "phone" ? "smartphone" : n.fstype === "sftp" || n.fstype === "fuse.sshfs" ? "dns" : "lan",
        kind: "share", mounted: true, removable: true,
        meter: n.size > 0 ? 1 - n.free / n.size : -1, detail: n.size > 0 ? I18n.tr("%1 free of %2", Fmt.size(n.free), Fmt.size(n.size)) : n.fstype
    }))

    function open(item: var, newTab: bool): void {
        if (item.kind === "device" && !item.mounted) {
            Core.call("mount", { device: item.device }, r => {
                if (!r.ok) { Toast.fail(I18n.tr("Could not mount: %1", r.error)); return }
                Core.refreshPlaces()
                if (r.path) newTab ? root.browser.newTab(r.path) : root.folder.go(r.path)
            })
            return
        }
        if (newTab) root.browser.newTab(item.path)
        else root.folder.go(item.path)
        root.browser.activePane.forceActiveFocus()
    }
    function eject(item: var): void {
        const busy = root.place === item.path || root.place.startsWith(item.path + "/")
        if (busy) root.folder.go(Core.home)
        Core.call("unmount", { device: item.device ?? "", path: item.path, eject: item.removable === true && !!item.drive, drive: item.drive ?? "" }, r => {
            if (!r.ok) Toast.fail(r.error === "busy" ? I18n.tr("%1 is in use. Close what uses it, then try again.", item.name) : I18n.tr("Could not put %1 away: %2", item.name, r.error))
            else Toast.show(I18n.tr("%1 can be unplugged", item.name), "", null)
            Core.refreshPlaces()
        })
    }

    // A section's title; a click folds the section away and back.
    component Heading: Item {
        id: heading
        property string text
        property string section: ""
        readonly property bool folded: heading.section.length > 0 && root.folded(heading.section)
        width: parent ? parent.width : 0
        height: Theme.dp(34)
        Caption {
            id: headCaption
            x: Theme.dp(20)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.dp(6)
            text: heading.text
            color: headMouse.containsMouse ? Theme.ink2 : Theme.ink3
        }
        Glyph {
            visible: heading.section.length > 0 && (headMouse.containsMouse || heading.folded)
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(18)
            anchors.verticalCenter: headCaption.verticalCenter
            name: "expand_more"
            size: Theme.dp(18)
            color: Theme.ink3
            rotation: heading.folded ? -90 : 0
            Behavior on rotation { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
        }
        MouseArea {
            id: headMouse
            anchors.fill: parent
            enabled: heading.section.length > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.fold(heading.section)
        }
    }

    component Place: Item {
        id: place
        required property var modelData
        required property int index
        readonly property var it: place.modelData
        readonly property bool current: root.place === place.it.path && place.it.path.length > 0
        property bool dropping: false
        readonly property bool mark: place.it.kind === "bookmark"
        readonly property bool full: place.it.kind === "trash" && (place.it.count ?? 0) > 0
        // A bookmark lifted by the pointer follows it; the others open a gap where it would land.
        readonly property bool lifted: reorder.active
        readonly property real shift: {
            if (!place.mark || root.dragFrom < 0 || place.lifted) return 0
            const i = place.index, f = root.dragFrom, t = root.dragTo
            if (f < t && i > f && i <= t) return -place.height
            if (f > t && i >= t && i < f) return place.height
            return 0
        }
        width: parent ? parent.width : 0
        height: Theme.dp(place.it.meter >= 0 ? 44 : 34)
        z: place.lifted ? 2 : 0
        transform: Translate {
            y: place.lifted ? reorder.translation.y : place.shift
            Behavior on y { enabled: !place.lifted; NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
        }
        HoverHandler { id: rowHover }
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(10)
            anchors.rightMargin: Theme.dp(10)
            radius: Theme.dp(10)
            color: place.lifted ? Theme.raised : place.dropping ? Theme.selectionHover : place.current ? Theme.accentPlate : placeMouse.pressed ? Theme.fillPress : rowHover.hovered ? Theme.fill : "transparent"
            border.width: place.dropping ? Math.max(1, Theme.dp(1.5)) : place.lifted && !Theme.light ? 1 : 0
            border.color: place.dropping ? Theme.accent : Theme.line
            Behavior on color { ColorAnimation { duration: Theme.fast } }
        }
        // Where a dropped folder joins the bookmarks.
        Rectangle {
            visible: place.mark && (root.insertAt === place.index || root.insertAt === place.index + 1 && place.index === root.marks.length - 1)
            x: Theme.dp(16)
            width: parent.width - Theme.dp(32)
            height: Theme.dp(2)
            radius: height / 2
            y: root.insertAt === place.index ? -height / 2 : parent.height - height / 2
            color: Theme.accent
        }
        Glyph {
            id: placeGlyph
            x: Theme.dp(21)
            y: Math.round(Theme.dp(17) - height / 2)
            name: place.it.glyph
            size: Theme.dp(19)
            fill: place.current || place.full ? 1 : 0
            color: place.current ? Theme.accentInk : place.it.tint ? (Theme.tints[place.it.tint] ?? Theme.inkNav) : Theme.inkNav
            opacity: place.it.missing || (place.it.kind === "device" && !place.it.mounted) ? 0.55 : 1
        }
        Txt {
            anchors.left: placeGlyph.right
            anchors.leftMargin: Theme.dp(11)
            anchors.right: tail.left
            anchors.rightMargin: Theme.dp(6)
            y: Math.round(Theme.dp(17) - height / 2)
            text: place.it.name
            size: Theme.row
            strong: place.current
            color: place.current ? Theme.accentInk : Theme.inkNav
            opacity: place.it.missing ? 0.6 : 1
        }
        Meter {
            visible: (place.it.meter ?? -1) >= 0
            anchors.left: placeGlyph.right
            anchors.leftMargin: Theme.dp(11)
            anchors.right: tail.left
            anchors.rightMargin: Theme.dp(6)
            y: Theme.dp(31)
            height: Theme.dp(3)
            value: Math.max(0, place.it.meter ?? 0)
        }
        Item {
            id: tail
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(16)
            y: Theme.dp(17) - height / 2
            width: ejectAct.visible ? ejectAct.width : sweep.visible ? sweep.width : count.visible ? count.width : 0
            height: Theme.dp(24)
            // What the trash holds, as a count on a chip; pointed at, the chip gives way to the button that empties it.
            Rectangle {
                id: count
                visible: (place.it.count ?? 0) > 0 && !sweep.visible
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(height, countText.implicitWidth + Theme.dp(12))
                height: Theme.dp(20)
                radius: height / 2
                color: place.current ? Theme.alpha(Theme.accentInk, 0.16) : Theme.fillHover
                Txt {
                    id: countText
                    anchors.centerIn: parent
                    text: Fmt.num(place.it.count ?? 0, 0)
                    size: Theme.caption
                    strong: true
                    color: place.current ? Theme.accentInk : Theme.ink2
                }
            }
            Act {
                id: sweep
                visible: place.full && rowHover.hovered
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.dp(24)
                glyphSize: Theme.dp(16)
                glyph: "delete_sweep"
                tip: I18n.tr("Empty trash")
                onClicked: root.browser.actions.emptyTrash()
            }
            Act {
                id: ejectAct
                visible: (place.it.kind === "device" && place.it.mounted && !place.it.root && place.it.removable) || place.it.kind === "share"
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.dp(24)
                glyphSize: Theme.dp(16)
                glyph: "eject"
                tip: I18n.tr("Put away")
                onClicked: root.eject(place.it)
            }
        }
        MouseArea {
            id: placeMouse
            anchors.fill: parent
            anchors.rightMargin: ejectAct.visible || sweep.visible ? Theme.dp(44) : 0
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    const p = placeMouse.mapToItem(root.browser.stage, mouse.x, mouse.y)
                    root.browser.menus.open(root.menuFor(place.it, place.index), p.x, p.y)
                } else root.open(place.it, mouse.button === Qt.MiddleButton)
            }
        }
        DragHandler {
            id: reorder
            enabled: place.mark && root.marks.length > 1
            target: null
            xAxis.enabled: false
            grabPermissions: PointerHandler.CanTakeOverFromItems
            onActiveChanged: {
                if (active) { root.dragFrom = place.index; root.dragTo = place.index; return }
                const to = root.dragTo
                root.dragFrom = -1
                root.dragTo = -1
                root.moveMark(place.it.path, to)
            }
            onTranslationChanged: if (active) root.dragTo = Math.max(0, Math.min(root.marks.length - 1, place.index + Math.round(translation.y / place.height)))
        }
        // A drop goes into the place; on a bookmark's top or bottom edge, a folder joins the bookmarks there.
        DropArea {
            anchors.fill: parent
            enabled: place.it.kind !== "recent" && (place.mark || !place.it.missing) && (place.it.kind !== "device" || place.it.mounted)
            function slot(y: real): int {
                if (!place.mark) return -1
                if (y < place.height * 0.3) return place.index
                if (y > place.height * 0.7) return place.index + 1
                return -1
            }
            function aim(drag: var): void {
                const s = slot(drag.y)
                if (s >= 0 || root.insertBy === place) { root.insertAt = s; root.insertBy = s >= 0 ? place : null }
                place.dropping = s < 0 && !place.it.missing && !root.browser.actions.dropRefused(drag.urls, place.it.path)
            }
            onEntered: drag => {
                if (!drag.hasUrls) { drag.accepted = false; return }
                aim(drag)
            }
            onPositionChanged: drag => aim(drag)
            onExited: {
                place.dropping = false
                if (root.insertBy === place) { root.insertAt = -1; root.insertBy = null }
            }
            onDropped: drop => {
                const s = slot(drop.y)
                place.dropping = false
                root.insertAt = -1
                root.insertBy = null
                if (s >= 0) root.browser.actions.bookmarkDropped(drop, root.fileIndex(s))
                else if (!place.it.missing && !root.browser.actions.dropRefused(drop.urls, place.it.path)) root.browser.actions.drop(drop, place.it.path)
            }
        }
        // The room on a disk shows in the window's tip, over the rows, never under the row below.
        Timer {
            interval: place.QsWindow.window?.tips?.delay ?? 650
            running: placeMouse.containsMouse && !placeMouse.pressed && (place.it.detail ?? "").length > 0
            onTriggered: place.QsWindow.window?.tips?.show(place, place.it.detail, "", true)
        }
        Connections {
            target: placeMouse
            function onContainsMouseChanged() { if (!placeMouse.containsMouse) place.QsWindow.window?.tips?.hide(place) }
            function onPressedChanged() { if (placeMouse.pressed) place.QsWindow.window?.tips?.hide(place) }
        }
    }

    function menuFor(it: var, index: int): var {
        const out = []
        if (it.kind === "device" && !it.mounted) return [{ text: I18n.tr("Mount"), glyph: "hard_drive", run: () => root.open(it, false) }]
        out.push({ text: I18n.tr("Open in new tab"), glyph: "tab", run: () => root.open(it, true) })
        if (it.kind !== "recent" && it.kind !== "trash") {
            out.push({ text: I18n.tr("Open in terminal"), glyph: "terminal", run: () => root.browser.actions.terminal(it.path) })
            out.push({ separator: true })
            out.push({ text: I18n.tr("Copy path"), glyph: "content_copy", run: () => root.browser.actions.copyText(it.path) })
        }
        if (it.kind === "bookmark") {
            out.push({ separator: true })
            out.push({ text: I18n.tr("Rename bookmark"), glyph: "edit", run: () => root.browser.actions.renameBookmark(it) })
            const own = root.looks[it.path] ?? {}
            out.push({ text: I18n.tr("Icon"), glyph: own.glyph || "bookmark", sub: root.glyphChoices.map(c => ({
                text: c.text, glyph: c.glyph, current: (own.glyph || "bookmark") === c.glyph, run: () => root.look(it.path, "glyph", c.glyph) })) })
            out.push({ text: I18n.tr("Color"), glyph: "palette", sub: root.tintChoices.map(c => ({
                text: c.text, glyph: "circle", fill: 1, tint: c.key ? Theme.tints[c.key] : Theme.inkNav, current: (own.tint ?? "") === c.key,
                run: () => root.look(it.path, "tint", c.key) })) })
            out.push({ text: I18n.tr("Move up"), glyph: "arrow_upward", keep: true, enabled: index > 0, run: () => root.moveFromMenu(it, index, -1) })
            out.push({ text: I18n.tr("Move down"), glyph: "arrow_downward", keep: true, enabled: index < root.marks.length - 1, run: () => root.moveFromMenu(it, index, 1) })
            out.push({ text: I18n.tr("Remove bookmark"), glyph: "bookmark_remove", danger: true, run: () => {
                Core.call("bookmark_remove", { path: it.path }, r => Core.takeBookmarks(r))
                if (root.looks[it.path]) { const all = Object.assign({}, root.looks); delete all[it.path]; Prefs.set("marks", all) }
            } })
        }
        if (it.kind === "trash") out.push({ text: I18n.tr("Empty trash"), glyph: "delete_forever", danger: true, enabled: (it.count ?? 0) > 0, run: () => root.browser.actions.emptyTrash() })
        if ((it.kind === "device" && !it.root) || it.kind === "share") {
            out.push({ separator: true })
            out.push({ text: it.removable ? I18n.tr("Eject") : I18n.tr("Unmount"), glyph: "eject", run: () => root.eject(it) })
        }
        if (it.kind !== "recent" && it.kind !== "trash") out.push({ text: I18n.tr("Properties"), glyph: "info", keys: "Alt+Enter", run: () => root.browser.actions.propertiesOf([it.path]) })
        return out
    }

    // ---- the app's own corner: it moves the window
    Item {
        id: top
        width: parent.width
        height: Theme.dp(58)
        DragHandler {
            target: null
            onActiveChanged: if (active) root.browser.startSystemMove()
        }
        Row {
            x: Theme.dp(20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(10)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(28)
                height: width
                radius: Theme.dp(9)
                color: Theme.accent
                Glyph { anchors.centerIn: parent; name: "folder"; fill: 1; size: Theme.dp(17); color: Theme.inkAccent }
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("Files")
                font.family: Theme.title
                size: Theme.head
                strong: true
            }
        }
    }

    Flickable {
        id: flick
        anchors.top: top.bottom
        anchors.bottom: foot.top
        width: parent.width
        contentHeight: col.implicitHeight + Theme.dp(12)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: Scroller {}
        Column {
            id: col
            width: flick.width
            Repeater { model: root.own; delegate: Place {} }
            Heading {
                text: I18n.tr("Bookmarks")
                section: "bookmarks"
                DropArea {
                    anchors.fill: parent
                    onEntered: drag => { if (!drag.hasUrls) drag.accepted = false }
                    onDropped: drop => root.browser.actions.bookmarkDropped(drop, root.fileIndex(0))
                }
            }
            Column {
                width: col.width
                visible: !root.folded("bookmarks")
            Item {
                visible: root.marks.length === 0
                width: col.width
                height: hint.implicitHeight + Theme.dp(16)
                Txt {
                    id: hint
                    x: Theme.dp(20)
                    width: parent.width - Theme.dp(40)
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Drop a folder here to keep it")
                    size: Theme.small
                    color: Theme.ink3
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
                DropArea {
                    anchors.fill: parent
                    onEntered: drag => { if (!drag.hasUrls) drag.accepted = false }
                    onDropped: drop => root.browser.actions.bookmarkDropped(drop)
                }
            }
            Repeater { model: root.marks; delegate: Place {} }
            }
            Heading { text: I18n.tr("Devices"); section: "devices" }
            Column {
                width: col.width
                visible: !root.folded("devices")
                Repeater { model: root.disks; delegate: Place {} }
            }
            Heading { visible: root.shares.length > 0; text: I18n.tr("Network"); section: "network" }
            Column {
                width: col.width
                visible: !root.folded("network")
                Repeater { model: root.shares; delegate: Place {} }
            }
        }
    }

    Item {
        id: foot
        anchors.bottom: parent.bottom
        width: parent.width
        height: Theme.dp(52)
        Rectangle {
            id: settingsPlate
            anchors.fill: parent
            anchors.margins: Theme.dp(10)
            radius: Theme.dp(10)
            color: settingsMouse.pressed ? Theme.fillPress : settingsMouse.containsMouse ? Theme.fill : "transparent"
            Glyph { id: gear; x: Theme.dp(11); anchors.verticalCenter: parent.verticalCenter; name: "settings"; size: Theme.dp(19); color: Theme.inkNav }
            Txt { anchors.left: gear.right; anchors.leftMargin: Theme.dp(11); anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Settings"); size: Theme.row; color: Theme.inkNav }
            Txt { anchors.right: parent.right; anchors.rightMargin: Theme.dp(10); anchors.verticalCenter: parent.verticalCenter; text: "Ctrl+,"; size: Theme.caption; color: Theme.ink3 }
            MouseArea { id: settingsMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.browser.actions.settings() }
        }
    }
}
