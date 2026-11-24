import QtQuick
import QtQuick.Controls.Basic as QQC
import Quickshell
import qs.services
import qs.kit

// The start page: restrained, system-focused and customizable. No redundant card soup — clean tonal surfaces,
// crisp instant hover, and live section toggles from the top-right customize control.
Item {
    id: root
    required property var pane
    readonly property var browser: root.pane.browser
    readonly property var folder: root.pane.folder
    readonly property Item view: flick
    readonly property bool sideways: false

    function reveal(i: int): void {}
    function step(i: int, key: int): int {
        const delta = key === Qt.Key_PageDown ? flick.height * 0.85 : key === Qt.Key_PageUp ? -flick.height * 0.85 : key === Qt.Key_Down ? Theme.dp(72) : key === Qt.Key_Up ? -Theme.dp(72) : 0
        if (delta !== 0) flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + delta))
        return -1
    }

    // ---- live section customization
    readonly property var sections: Object.assign({ banner: true, places: true, drives: true, recent: true, bookmarks: false }, Prefs.get("startSections") ?? {})
    function toggleSection(key: string): void {
        const next = Object.assign({}, root.sections)
        next[key] = !next[key]
        Prefs.set("startSections", next)
    }
    function customizeEntries(): var {
        const s = root.sections
        const item = (key, text, glyph) => ({
            text: text, glyph: glyph, checked: s[key] === true, keep: true,
            run: () => { root.toggleSection(key); root.browser.menus.refresh(root.customizeEntries()) }
        })
        return [
            { header: I18n.tr("Sections") },
            item("banner", I18n.tr("Wallpaper header"), "wallpaper"),
            item("places", I18n.tr("System folders"), "folder"),
            item("drives", I18n.tr("Storage"), "hard_drive"),
            item("recent", I18n.tr("Recent files"), "schedule"),
            item("bookmarks", I18n.tr("Bookmarks"), "bookmark"),
            { separator: true },
            {
                text: I18n.tr("Open new windows on Start"), glyph: "space_dashboard",
                checked: Prefs.get("start") === true, keep: true,
                run: () => { Prefs.set("start", !Prefs.get("start")); root.browser.menus.refresh(root.customizeEntries()) }
            }
        ]
    }

    property int hour: new Date().getHours()
    onVisibleChanged: if (visible) root.hour = new Date().getHours()

    readonly property string greeting: {
        const who = Core.places.user ?? ""
        if (root.hour >= 5 && root.hour < 12) return who.length > 0 ? I18n.tr("Good morning, %1", who) : I18n.tr("Good morning")
        if (root.hour >= 12 && root.hour < 19) return who.length > 0 ? I18n.tr("Good afternoon, %1", who) : I18n.tr("Good afternoon")
        return who.length > 0 ? I18n.tr("Good evening, %1", who) : I18n.tr("Good evening")
    }
    readonly property string wallSource: {
        if (!root.sections.banner) return ""
        const w = Theme.wallpaper
        if (!w || w.length === 0 || /\.(mp4|webm|mkv|mov|avi|m4v)$/i.test(w)) return ""
        return Fmt.url(w)
    }
    readonly property real dpr: root.Window.window?.devicePixelRatio ?? 1

    readonly property var roleGlyphs: ({ desktop: "desktop_windows", documents: "description", downloads: "download", music: "music_note", pictures: "image", videos: "movie" })
    readonly property var roleNames: ({ desktop: I18n.tr("Desktop"), documents: I18n.tr("Documents"), downloads: I18n.tr("Downloads"),
        music: I18n.tr("Music"), pictures: I18n.tr("Pictures"), videos: I18n.tr("Videos") })
    readonly property var quickPlaces: {
        const home = Core.places.home || Core.home
        const out = [{ path: home, name: I18n.tr("Home"), glyph: "home" }]
        for (const role of ["desktop", "documents", "downloads", "music", "pictures", "videos"]) {
            const d = (Core.places.xdg ?? []).find(x => x.role === role)
            if (d && d.path !== home) out.push({ path: d.path, name: root.roleNames[role], glyph: root.roleGlyphs[role] })
        }
        return out
    }
    readonly property var looks: Prefs.get("marks") ?? ({})
    readonly property var marks: (Core.places.bookmarks ?? []).filter(b => b.exists).map(b => ({
        path: b.path, name: b.name, remote: b.remote === true,
        glyph: root.looks[b.path]?.glyph || (b.remote ? (/^(sftp|ssh):/i.test(b.path) ? "dns" : "lan") : "bookmark"),
        tint: root.looks[b.path]?.tint ?? ""
    }))
    readonly property var recents: {
        void root.folder.selRev
        return root.folder.all.slice(0, 6)
    }
    readonly property var drives: {
        const out = []
        for (const d of Core.places.devices ?? []) {
            const mounted = d.mounted || d.root
            out.push({
                path: d.root ? "/" : d.path,
                name: d.root ? I18n.tr("Computer") : (d.label || d.model || I18n.tr("%1 volume", Fmt.size(d.size))),
                glyph: d.root ? "computer" : d.tran === "usb" || d.removable ? "usb" : d.fstype === "iso9660" || d.fstype === "udf" ? "album" : "hard_drive",
                kind: "device", device: d.device, drive: d.drive, mounted: mounted, removable: d.removable, root: d.root,
                fstype: d.fstype ?? "", server: false,
                meter: d.size > 0 && mounted ? 1 - d.free / d.size : -1,
                detail: d.size > 0 ? (mounted ? I18n.tr("%1 free of %2", Fmt.size(d.free), Fmt.size(d.size)) : I18n.tr("%1 · Not mounted", Fmt.size(d.size))) : (mounted ? "" : I18n.tr("Not mounted"))
            })
        }
        for (const n of Core.places.network ?? []) {
            out.push({
                path: n.path, name: Fmt.share(n),
                glyph: n.kind === "phone" ? "smartphone" : n.fstype === "sftp" || n.fstype === "fuse.sshfs" ? "dns" : "lan",
                kind: "share", device: "", drive: "", mounted: true, removable: true, root: false,
                fstype: n.fstype ?? "", server: n.kind !== "phone",
                meter: n.size > 0 ? 1 - n.free / n.size : -1,
                detail: n.size > 0 ? I18n.tr("%1 free of %2", Fmt.size(n.free), Fmt.size(n.size)) : (n.fstype ?? "")
            })
        }
        return out
    }
    readonly property string systemSummary: {
        const parts = []
        if (Core.places.host) parts.push(Core.places.host)
        const rootDisk = (Core.places.devices ?? []).find(d => d.root)
        if (rootDisk && rootDisk.size > 0) parts.push(I18n.tr("%1 free", Fmt.size(rootDisk.free)))
        return parts.join(" · ")
    }

    function openDrive(d: var, newTab: bool): void {
        if (d.kind === "device" && !d.mounted) {
            Core.call("mount", { device: d.device }, r => {
                if (!r.ok) { Toast.fail(I18n.tr("Could not mount: %1", r.error)); return }
                Core.refreshPlaces()
                if (r.path) newTab ? root.browser.newTab(r.path) : root.folder.go(r.path)
            })
            return
        }
        if (newTab) root.browser.newTab(d.path)
        else root.folder.go(d.path)
        root.pane.forceActiveFocus()
    }
    function ejectDrive(d: var): void {
        Core.call("unmount", { device: d.device ?? "", path: d.path, eject: d.removable === true && !!d.drive, drive: d.drive ?? "" }, r => {
            if (!r.ok) Toast.fail(r.error === "busy" ? I18n.tr("%1 is in use. Close what uses it, then try again.", d.name) : d.server ? I18n.tr("Could not disconnect %1: %2", d.name, r.error) : I18n.tr("Could not put %1 away: %2", d.name, r.error))
            else Toast.show(d.server ? I18n.tr("Disconnected from %1", d.name) : I18n.tr("%1 can be unplugged", d.name), "", null)
            Core.refreshPlaces()
        })
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(height, col.y + col.implicitHeight + Theme.dp(40))
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: Scroller {}

        MouseArea {
            width: flick.width
            height: flick.contentHeight
            onPressed: root.pane.activate()
        }

        // ---- atmospheric wallpaper backdrop melting seamlessly into Theme.canvas (no harsh boxed frame)
        Item {
            id: wallBand
            visible: root.sections.banner && wallImg.status === Image.Ready
            width: flick.width
            height: Theme.dp(156)
            clip: true

            Image {
                id: wallImg
                anchors.fill: parent
                source: root.wallSource
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                sourceSize.width: Math.max(1, Math.round(flick.width * root.dpr))
                opacity: status === Image.Ready ? (Theme.light ? 0.34 : 0.42) : 0
                Behavior on opacity { NumberAnimation { duration: Theme.normal } }
            }
            // Soft fade into Theme.canvas along the bottom so the wallpaper belongs to the surface.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0; color: Theme.alpha(Theme.canvas, Theme.light ? 0.25 : 0.2) }
                    GradientStop { position: 0.62; color: Theme.alpha(Theme.canvas, Theme.light ? 0.72 : 0.65) }
                    GradientStop { position: 1; color: Theme.canvas }
                }
            }
        }

        Column {
            id: col
            readonly property real pad: flick.width < Theme.dp(560) ? Theme.dp(18) : Theme.dp(32)
            width: Math.min(flick.width - pad * 2, Theme.dp(820))
            anchors.horizontalCenter: parent.horizontalCenter
            y: wallBand.visible ? Theme.dp(34) : Theme.dp(24)
            spacing: Theme.dp(26)

            // ---- header: clean greeting + system summary + customize button
            Item {
                width: col.width
                height: headCol.implicitHeight

                Column {
                    id: headCol
                    anchors.left: parent.left
                    anchors.right: tuneAct.left
                    anchors.rightMargin: Theme.dp(12)
                    spacing: Theme.dp(3)
                    Txt {
                        width: parent.width
                        text: root.greeting
                        font.family: Theme.title
                        size: flick.width < Theme.dp(560) ? Theme.titleSize : Theme.display
                        strong: true
                        color: Theme.ink
                    }
                    Txt {
                        width: parent.width
                        visible: text.length > 0
                        text: root.systemSummary
                        size: Theme.small
                        color: Theme.ink2
                    }
                }
                Act {
                    id: tuneAct
                    anchors.right: parent.right
                    anchors.verticalCenter: headCol.verticalCenter
                    glyph: "tune"
                    tip: I18n.tr("Customize start page")
                    onClicked: root.browser.menus.openAt(root.customizeEntries(), tuneAct, true)
                }
            }

            // ---- system folders (compact tonal strip, zero noisy borders, crisp instant hover)
            Column {
                width: col.width
                spacing: Theme.dp(10)
                visible: root.sections.places && root.quickPlaces.length > 0
                Caption { text: I18n.tr("System folders") }

                Grid {
                    id: placesGrid
                    width: parent.width
                    columns: col.width >= Theme.dp(660) ? 4 : col.width >= Theme.dp(420) ? 3 : 2
                    columnSpacing: Theme.dp(8)
                    rowSpacing: Theme.dp(8)
                    readonly property real tileW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

                    Repeater {
                        model: root.quickPlaces
                        delegate: Rectangle {
                            id: pTile
                            required property var modelData
                            property bool dropping: false
                            width: placesGrid.tileW
                            height: Theme.dp(44)
                            radius: Theme.radius
                            color: pTile.dropping ? Theme.selectionHover : pHit.pressed ? Theme.cardPress : pHit.containsMouse ? Theme.cardHover : Theme.card
                            border.width: pTile.dropping ? Math.max(1, Theme.dp(1.5)) : 0
                            border.color: Theme.accent
                            Behavior on color { ColorAnimation { duration: Theme.hoverMs } }

                            Glyph {
                                id: pGlyph
                                x: Theme.dp(13)
                                anchors.verticalCenter: parent.verticalCenter
                                name: pTile.modelData.glyph
                                size: Theme.dp(18)
                                fill: pHit.containsMouse ? 1 : 0
                                color: pHit.containsMouse ? Theme.accentInk : Theme.ink2
                            }
                            Txt {
                                anchors.left: pGlyph.right
                                anchors.leftMargin: Theme.dp(10)
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(12)
                                anchors.verticalCenter: parent.verticalCenter
                                text: pTile.modelData.name
                                size: Theme.row
                                strong: true
                                color: Theme.ink
                            }
                            MouseArea {
                                id: pHit
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                onClicked: mouse => {
                                    if (mouse.button === Qt.MiddleButton) root.browser.newTab(pTile.modelData.path)
                                    else if (mouse.button === Qt.RightButton) {
                                        const at = pHit.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                        root.browser.actions.placeMenu(pTile.modelData.path, at.x, at.y)
                                    } else {
                                        root.folder.go(pTile.modelData.path)
                                        root.pane.forceActiveFocus()
                                    }
                                }
                            }
                            DropArea {
                                anchors.fill: parent
                                onEntered: drag => {
                                    if (!drag.hasUrls || root.browser.actions.dropRefused(drag.urls, pTile.modelData.path)) { drag.accepted = false; return }
                                    pTile.dropping = true
                                }
                                onExited: pTile.dropping = false
                                onDropped: drop => { pTile.dropping = false; root.browser.actions.drop(drop, pTile.modelData.path) }
                            }
                        }
                    }
                }
            }

            // ---- storage & network mounts (real system utility)
            Column {
                width: col.width
                spacing: Theme.dp(10)
                visible: root.sections.drives && root.drives.length > 0

                Item {
                    width: parent.width
                    height: devCap.implicitHeight
                    Caption { id: devCap; anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Storage") }
                    Txt {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Connect a server")
                        size: Theme.small
                        color: connHit.containsMouse ? Theme.ink : Theme.ink3
                        MouseArea {
                            id: connHit
                            anchors.fill: parent
                            anchors.margins: -Theme.dp(4)
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.browser.actions.connect("", false)
                        }
                    }
                }

                Grid {
                    id: drivesGrid
                    width: parent.width
                    columns: col.width >= Theme.dp(560) ? 2 : 1
                    columnSpacing: Theme.dp(10)
                    rowSpacing: Theme.dp(10)
                    readonly property real driveW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

                    Repeater {
                        model: root.drives
                        delegate: Rectangle {
                            id: dCard
                            required property var modelData
                            readonly property var it: dCard.modelData
                            width: drivesGrid.driveW
                            height: dCard.it.meter >= 0 ? Theme.dp(68) : Theme.dp(56)
                            radius: Theme.radius
                            color: dHit.pressed ? Theme.cardPress : dHover.hovered ? Theme.cardHover : Theme.card
                            Behavior on color { ColorAnimation { duration: Theme.hoverMs } }
                            HoverHandler { id: dHover }

                            Glyph {
                                id: dGlyph
                                x: Theme.dp(15)
                                anchors.verticalCenter: parent.verticalCenter
                                name: dCard.it.glyph
                                size: Theme.dp(20)
                                color: dHover.hovered && dCard.it.mounted ? Theme.accentInk : Theme.ink2
                                opacity: dCard.it.mounted ? 1 : 0.5
                            }
                            Column {
                                anchors.left: dGlyph.right
                                anchors.leftMargin: Theme.dp(13)
                                anchors.right: dEject.visible ? dEject.left : parent.right
                                anchors.rightMargin: Theme.dp(14)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.dp(5)

                                Item {
                                    width: parent.width
                                    height: dName.implicitHeight
                                    Txt {
                                        id: dName
                                        anchors.left: parent.left
                                        anchors.right: fsTxt.visible ? fsTxt.left : parent.right
                                        anchors.rightMargin: Theme.dp(8)
                                        text: dCard.it.name
                                        size: Theme.row
                                        strong: true
                                        color: Theme.ink
                                    }
                                    Txt {
                                        id: fsTxt
                                        visible: dCard.it.fstype.length > 0
                                        anchors.right: parent.right
                                        anchors.baseline: dName.baseline
                                        text: dCard.it.fstype
                                        size: Theme.caption
                                        color: Theme.ink3
                                    }
                                }
                                Meter {
                                    visible: dCard.it.meter >= 0
                                    width: parent.width
                                    height: Theme.dp(3)
                                    value: Math.max(0, dCard.it.meter)
                                }
                                Txt {
                                    width: parent.width
                                    visible: dCard.it.detail.length > 0
                                    text: dCard.it.detail
                                    size: Theme.small
                                    color: dCard.it.meter > 0.9 ? Theme.danger : Theme.ink3
                                }
                            }
                            MouseArea {
                                id: dHit
                                anchors.fill: parent
                                anchors.rightMargin: dEject.visible ? Theme.dp(40) : 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: mouse => root.openDrive(dCard.it, mouse.button === Qt.MiddleButton)
                            }
                            Act {
                                id: dEject
                                visible: (dCard.it.kind === "device" && dCard.it.mounted && !dCard.it.root && dCard.it.removable) || dCard.it.kind === "share"
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(8)
                                anchors.verticalCenter: parent.verticalCenter
                                size: Theme.dp(28)
                                glyphSize: Theme.dp(17)
                                glyph: "eject"
                                tip: dCard.it.server ? I18n.tr("Disconnect") : I18n.tr("Put away")
                                onClicked: root.ejectDrive(dCard.it)
                            }
                        }
                    }
                }
            }

            // ---- recent files (clean borderless list, hidden completely when empty)
            Column {
                width: col.width
                spacing: Theme.dp(8)
                visible: root.sections.recent && root.recents.length > 0

                Item {
                    width: parent.width
                    height: recentCap.implicitHeight
                    Caption { id: recentCap; anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Recent") }
                    Txt {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("See all")
                        size: Theme.small
                        color: allHit.containsMouse ? Theme.ink : Theme.ink3
                        MouseArea {
                            id: allHit
                            anchors.fill: parent
                            anchors.margins: -Theme.dp(4)
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.folder.go("recent:")
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.dp(2)

                    Repeater {
                        model: root.recents
                        delegate: Rectangle {
                            id: rRow
                            required property var modelData
                            required property int index
                            width: parent.width
                            height: Theme.dp(44)
                            radius: Theme.round(10)
                            color: rHit.pressed ? Theme.fillPress : rHover.hovered ? Theme.fill : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.hoverMs } }
                            HoverHandler { id: rHover }

                            FileIcon {
                                id: rIcon
                                x: Theme.dp(10)
                                anchors.verticalCenter: parent.verticalCenter
                                size: Theme.dp(26)
                                entry: rRow.modelData
                            }
                            Txt {
                                id: rName
                                anchors.left: rIcon.right
                                anchors.leftMargin: Theme.dp(10)
                                anchors.right: rMeta.left
                                anchors.rightMargin: Theme.dp(12)
                                anchors.verticalCenter: parent.verticalCenter
                                text: rRow.modelData.name
                                size: Theme.row
                                color: Theme.ink
                                elide: Text.ElideMiddle
                            }
                            Txt {
                                id: rMeta
                                anchors.right: showFolderAct.visible ? showFolderAct.left : parent.right
                                anchors.rightMargin: Theme.dp(10)
                                anchors.verticalCenter: parent.verticalCenter
                                readonly property string where: Fmt.pretty(Fmt.parent(rRow.modelData.path))
                                readonly property string when: Fmt.when(rRow.modelData.mtime)
                                text: col.width >= Theme.dp(540) && when.length > 0 ? where + " · " + when : when || where
                                size: Theme.small
                                color: Theme.ink3
                                elide: Text.ElideMiddle
                                width: Math.min(implicitWidth, col.width * 0.42)
                                horizontalAlignment: Text.AlignRight
                            }
                            MouseArea {
                                id: rHit
                                anchors.fill: parent
                                anchors.rightMargin: showFolderAct.visible ? Theme.dp(38) : 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                onClicked: mouse => {
                                    root.pane.activate()
                                    if (mouse.button === Qt.RightButton) {
                                        root.folder.only(rRow.index)
                                        const at = rHit.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                        root.browser.actions.itemMenu(root.pane, at.x, at.y)
                                    } else if (mouse.button === Qt.MiddleButton) {
                                        if (rRow.modelData.dir) root.browser.newTab(rRow.modelData.path)
                                        else root.browser.newTab(Fmt.parent(rRow.modelData.path), [rRow.modelData.path])
                                    } else {
                                        root.browser.actions.open(root.pane, [rRow.modelData])
                                    }
                                }
                            }
                            Act {
                                id: showFolderAct
                                visible: rHover.hovered
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(6)
                                anchors.verticalCenter: parent.verticalCenter
                                size: Theme.dp(28)
                                glyphSize: Theme.dp(17)
                                glyph: "folder_open"
                                tip: I18n.tr("Show in folder")
                                onClicked: {
                                    root.folder.focusPath = rRow.modelData.path
                                    root.folder.go(Fmt.parent(rRow.modelData.path))
                                }
                            }
                        }
                    }
                }
            }

            // ---- bookmarks (optional, off by default to avoid duplicating the Rail)
            Column {
                width: col.width
                spacing: Theme.dp(10)
                visible: root.sections.bookmarks && root.marks.length > 0
                Caption { text: I18n.tr("Bookmarks") }

                Flow {
                    width: parent.width
                    spacing: Theme.dp(8)
                    Repeater {
                        model: root.marks
                        delegate: Rectangle {
                            id: mChip
                            required property var modelData
                            height: Theme.dp(34)
                            width: Math.min(col.width, mRow.implicitWidth + Theme.dp(22))
                            radius: Theme.round(10)
                            color: mHit.pressed ? Theme.cardPress : mHit.containsMouse ? Theme.cardHover : Theme.card
                            Behavior on color { ColorAnimation { duration: Theme.hoverMs } }
                            Row {
                                id: mRow
                                anchors.centerIn: parent
                                spacing: Theme.dp(7)
                                Glyph {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: mChip.modelData.glyph
                                    size: Theme.dp(16)
                                    color: mChip.modelData.tint ? (Theme.tints[mChip.modelData.tint] ?? Theme.ink2) : Theme.ink2
                                }
                                Txt {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: mChip.modelData.name
                                    size: Theme.small
                                    color: Theme.ink
                                    width: Math.min(implicitWidth, Theme.dp(200))
                                }
                            }
                            MouseArea {
                                id: mHit
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                onClicked: mouse => {
                                    if (mChip.modelData.remote) { root.browser.actions.connect(mChip.modelData.path, mouse.button === Qt.MiddleButton); return }
                                    if (mouse.button === Qt.MiddleButton) root.browser.newTab(mChip.modelData.path)
                                    else if (mouse.button === Qt.RightButton) {
                                        const at = mHit.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                        root.browser.actions.placeMenu(mChip.modelData.path, at.x, at.y)
                                    } else {
                                        root.folder.go(mChip.modelData.path)
                                        root.pane.forceActiveFocus()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
