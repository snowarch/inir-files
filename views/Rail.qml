import QtQuick
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
    readonly property var marks: (root.places.bookmarks ?? []).filter(b => !b.remote).map(b => ({ path: b.path, name: b.name, glyph: b.exists ? "bookmark" : "bookmark_remove", kind: "bookmark", missing: !b.exists }))
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

    component Heading: Item {
        id: heading
        property string text
        width: parent ? parent.width : 0
        height: Theme.dp(34)
        Caption {
            x: Theme.dp(20)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.dp(6)
            text: heading.text
        }
    }

    component Place: Item {
        id: place
        required property var modelData
        required property int index
        readonly property var it: place.modelData
        readonly property bool current: root.place === place.it.path && place.it.path.length > 0
        property bool dropping: false
        width: parent ? parent.width : 0
        height: Theme.dp(place.it.meter >= 0 ? 44 : 34)
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(10)
            anchors.rightMargin: Theme.dp(10)
            radius: Theme.dp(10)
            color: place.dropping ? Theme.selectionHover : place.current ? Theme.accentPlate : placeMouse.pressed ? Theme.fillPress : placeMouse.containsMouse ? Theme.fill : "transparent"
            border.width: place.dropping ? Math.max(1, Theme.dp(1.5)) : 0
            border.color: Theme.accent
            Behavior on color { ColorAnimation { duration: Theme.fast } }
        }
        Glyph {
            id: placeGlyph
            x: Theme.dp(21)
            y: Theme.dp(17) - height / 2
            name: place.it.glyph
            size: Theme.dp(19)
            fill: place.current ? 1 : 0
            color: place.current ? Theme.accentInk : Theme.inkNav
            opacity: place.it.missing || (place.it.kind === "device" && !place.it.mounted) ? 0.55 : 1
        }
        Txt {
            anchors.left: placeGlyph.right
            anchors.leftMargin: Theme.dp(11)
            anchors.right: tail.left
            anchors.rightMargin: Theme.dp(6)
            y: Theme.dp(17) - height / 2
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
            width: ejectAct.visible ? ejectAct.width : count.visible ? count.implicitWidth : 0
            height: Theme.dp(24)
            Txt {
                id: count
                visible: (place.it.count ?? 0) > 0
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: Fmt.num(place.it.count ?? 0, 0)
                size: Theme.small
                color: place.current ? Theme.accentInk : Theme.ink3
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
            anchors.rightMargin: ejectAct.visible ? Theme.dp(44) : 0
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    const p = placeMouse.mapToItem(root.browser.stage, mouse.x, mouse.y)
                    root.browser.menus.open(root.menuFor(place.it, place.index), p.x, p.y)
                } else root.open(place.it, mouse.button === Qt.MiddleButton)
            }
        }
        DropArea {
            anchors.fill: parent
            enabled: place.it.kind !== "recent" && !place.it.missing && (place.it.kind !== "device" || place.it.mounted)
            onEntered: drag => {
                if (!drag.hasUrls || root.browser.actions.dropRefused(drag.urls, place.it.path)) { drag.accepted = false; return }
                place.dropping = true
            }
            onExited: place.dropping = false
            onDropped: drop => { place.dropping = false; root.browser.actions.drop(drop, place.it.path) }
        }
        Rectangle {
            visible: (place.it.detail ?? "").length > 0 && placeMouse.containsMouse
            z: 10
            x: Theme.dp(52)
            y: parent.height - Theme.dp(2)
            width: detailText.implicitWidth + Theme.dp(14)
            height: Theme.dp(22)
            radius: Theme.dp(7)
            color: Theme.raised
            Txt { id: detailText; anchors.centerIn: parent; text: place.it.detail ?? ""; size: Theme.small; color: Theme.ink2 }
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
            out.push({ text: I18n.tr("Move up"), glyph: "arrow_upward", enabled: index > 0, run: () => { Core.call("bookmark_move", { path: it.path, at: index - 1 }, () => Core.refreshPlaces()) } })
            out.push({ text: I18n.tr("Move down"), glyph: "arrow_downward", enabled: index < root.marks.length - 1, run: () => { Core.call("bookmark_move", { path: it.path, at: index + 1 }, () => Core.refreshPlaces()) } })
            out.push({ text: I18n.tr("Remove bookmark"), glyph: "bookmark_remove", danger: true, run: () => { Core.call("bookmark_remove", { path: it.path }, () => Core.refreshPlaces()) } })
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
                visible: true
                text: I18n.tr("Bookmarks")
                DropArea {
                    anchors.fill: parent
                    onEntered: drag => { if (!drag.hasUrls) drag.accepted = false }
                    onDropped: drop => root.browser.actions.bookmarkDropped(drop)
                }
            }
            Item {
                visible: root.marks.length === 0
                width: col.width
                height: Theme.dp(34)
                Txt {
                    x: Theme.dp(20)
                    width: parent.width - Theme.dp(40)
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Drop a folder here to keep it")
                    size: Theme.small
                    color: Theme.ink3
                }
                DropArea {
                    anchors.fill: parent
                    onEntered: drag => { if (!drag.hasUrls) drag.accepted = false }
                    onDropped: drop => root.browser.actions.bookmarkDropped(drop)
                }
            }
            Repeater { model: root.marks; delegate: Place {} }
            Heading { text: I18n.tr("Devices") }
            Repeater { model: root.disks; delegate: Place {} }
            Heading { visible: root.shares.length > 0; text: I18n.tr("Network") }
            Repeater { model: root.shares; delegate: Place {} }
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
