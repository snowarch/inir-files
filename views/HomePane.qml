import QtQuick
import QtQuick.Controls.Basic as QQC
import QtQuick.Effects
import Quickshell
import qs.services
import qs.kit

// The start page: a greeting over the desktop's wallpaper, the person's folders and bookmarks, recent files and drives.
Item {
    id: root
    required property var pane
    readonly property var browser: root.pane.browser
    readonly property var folder: root.pane.folder
    readonly property Item view: flick
    readonly property bool sideways: false

    // Interface contract with Pane.qml (scrolling on PageUp/PageDown/arrows; no row selection here).
    function reveal(i: int): void {}
    function step(i: int, key: int): int {
        const delta = key === Qt.Key_PageDown ? flick.height * 0.85 : key === Qt.Key_PageUp ? -flick.height * 0.85 : key === Qt.Key_Down ? Theme.dp(72) : key === Qt.Key_Up ? -Theme.dp(72) : 0
        if (delta !== 0) flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + delta))
        return -1
    }

    property int hour: new Date().getHours()
    property string todayText: root.formatToday()
    onVisibleChanged: if (visible) { root.hour = new Date().getHours(); root.todayText = root.formatToday() }

    function formatToday(): string {
        const s = new Date().toLocaleDateString(Fmt.loc, Locale.LongFormat)
        return s.length > 0 ? s[0].toUpperCase() + s.slice(1) : s
    }
    readonly property string greeting: {
        const who = Core.places.user ?? ""
        if (root.hour >= 5 && root.hour < 12) return who.length > 0 ? I18n.tr("Good morning, %1", who) : I18n.tr("Good morning")
        if (root.hour >= 12 && root.hour < 19) return who.length > 0 ? I18n.tr("Good afternoon, %1", who) : I18n.tr("Good afternoon")
        return who.length > 0 ? I18n.tr("Good evening, %1", who) : I18n.tr("Good evening")
    }
    readonly property string wallSource: {
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
        return root.folder.all.slice(0, 8)
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
        contentHeight: col.implicitHeight + Theme.dp(44)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: Scroller {}

        // A click on empty ground focuses the pane without disturbing anything.
        MouseArea {
            width: flick.width
            height: Math.max(flick.height, flick.contentHeight)
            onPressed: root.pane.activate()
        }

        Column {
            id: col
            readonly property real pad: flick.width < Theme.dp(560) ? Theme.dp(16) : Theme.dp(28)
            width: Math.min(flick.width - pad * 2, Theme.dp(920))
            anchors.horizontalCenter: parent.horizontalCenter
            y: Theme.dp(20)
            spacing: Theme.dp(22)

            // ---- hero: greeting over the desktop's wallpaper
            Item {
                id: hero
                width: col.width
                height: flick.width < Theme.dp(560) ? Theme.dp(128) : Theme.dp(152)
                readonly property bool hasWall: wallImg.status === Image.Ready

                Rectangle {
                    id: heroMask
                    anchors.fill: parent
                    radius: Theme.cardRadius
                    visible: false
                    layer.enabled: true
                }

                Item {
                    anchors.fill: parent
                    layer.enabled: Theme.cardRadius > 0
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: heroMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                    // Fallback surface when no wallpaper is available.
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: Theme.mix(Theme.card, Theme.accent, Theme.light ? 0.16 : 0.22) }
                            GradientStop { position: 1; color: Theme.card }
                        }
                    }

                    Image {
                        id: wallImg
                        anchors.fill: parent
                        source: root.wallSource
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        // Width alone keeps the wallpaper sharp when PreserveAspectCrop zooms a tall picture to fill the banner.
                        sourceSize.width: Math.max(1, Math.round(hero.width * root.dpr))
                        opacity: status === Image.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                    }

                    // Contrast scrim so text reads cleanly over any wallpaper.
                    Rectangle {
                        anchors.fill: parent
                        visible: hero.hasWall
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.rgba(0.03, 0.04, 0.06, 0.24) }
                            GradientStop { position: 0.55; color: Qt.rgba(0.03, 0.04, 0.06, 0.44) }
                            GradientStop { position: 1; color: Qt.rgba(0.03, 0.04, 0.06, 0.72) }
                        }
                    }
                }

                // Subtle frame edge on top.
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cardRadius
                    color: "transparent"
                    border.width: 1
                    border.color: hero.hasWall ? Qt.rgba(1, 1, 1, 0.14) : Theme.line
                }

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.dp(24)
                    anchors.right: searchPill.visible ? searchPill.left : parent.right
                    anchors.rightMargin: Theme.dp(20)
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.dp(20)
                    spacing: Theme.dp(4)

                    Txt {
                        width: parent.width
                        text: root.greeting
                        font.family: Theme.title
                        size: flick.width < Theme.dp(560) ? Theme.titleSize : Theme.display
                        strong: true
                        color: hero.hasWall ? "#ffffff" : Theme.ink
                    }
                    Txt {
                        width: parent.width
                        text: Core.places.host ? root.todayText + " · " + Core.places.host : root.todayText
                        size: Theme.body
                        color: hero.hasWall ? Qt.rgba(1, 1, 1, 0.84) : Theme.ink2
                    }
                }

                // Quick search button on the hero when there is room.
                Rectangle {
                    id: searchPill
                    visible: hero.width >= Theme.dp(580)
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(20)
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.dp(20)
                    height: Theme.dp(36)
                    width: searchRow.implicitWidth + Theme.dp(24)
                    radius: height / 2
                    color: hero.hasWall
                        ? (searchHit.pressed ? Qt.rgba(0, 0, 0, 0.56) : searchHit.containsMouse ? Qt.rgba(0, 0, 0, 0.46) : Qt.rgba(0, 0, 0, 0.36))
                        : (searchHit.pressed ? Theme.fillPress : searchHit.containsMouse ? Theme.fillHover : Theme.fill)
                    border.width: 1
                    border.color: hero.hasWall ? Qt.rgba(1, 1, 1, 0.22) : Theme.line
                    Row {
                        id: searchRow
                        anchors.centerIn: parent
                        spacing: Theme.dp(8)
                        Glyph { anchors.verticalCenter: parent.verticalCenter; name: "search"; size: Theme.dp(17); color: hero.hasWall ? "#ffffff" : Theme.ink2 }
                        Txt { anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Search files"); size: Theme.small; strong: true; color: hero.hasWall ? "#ffffff" : Theme.ink }
                    }
                    MouseArea {
                        id: searchHit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.browser.head.focusSearch()
                    }
                }
            }

            // ---- places
            Column {
                width: col.width
                spacing: Theme.dp(10)
                Caption { text: I18n.tr("Places") }

                Grid {
                    id: placesGrid
                    width: parent.width
                    columns: col.width >= Theme.dp(680) ? 4 : col.width >= Theme.dp(440) ? 3 : 2
                    columnSpacing: Theme.dp(10)
                    rowSpacing: Theme.dp(10)
                    readonly property real tileW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

                    Repeater {
                        model: root.quickPlaces
                        delegate: Rectangle {
                            id: pCard
                            required property var modelData
                            property bool dropping: false
                            width: placesGrid.tileW
                            height: Theme.dp(56)
                            radius: Theme.radius
                            color: pCard.dropping ? Theme.selectionHover : pHit.pressed ? Theme.fillPress : pHit.containsMouse ? Theme.fillHover : Theme.card
                            border.width: pCard.dropping ? Math.max(1, Theme.dp(1.5)) : 1
                            border.color: pCard.dropping ? Theme.accent : Theme.line
                            Behavior on color { ColorAnimation { duration: Theme.fast } }

                            Rectangle {
                                id: badge
                                x: Theme.dp(10)
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.dp(36)
                                height: width
                                radius: Theme.round(9)
                                color: Theme.accentPlate
                                Glyph {
                                    anchors.centerIn: parent
                                    name: pCard.modelData.glyph
                                    size: Theme.dp(20)
                                    fill: 1
                                    color: Theme.accentInk
                                }
                            }
                            Txt {
                                anchors.left: badge.right
                                anchors.leftMargin: Theme.dp(11)
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(12)
                                anchors.verticalCenter: parent.verticalCenter
                                text: pCard.modelData.name
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
                                    if (mouse.button === Qt.MiddleButton) root.browser.newTab(pCard.modelData.path)
                                    else if (mouse.button === Qt.RightButton) {
                                        const at = pHit.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                        root.browser.actions.placeMenu(pCard.modelData.path, at.x, at.y)
                                    } else {
                                        root.folder.go(pCard.modelData.path)
                                        root.pane.forceActiveFocus()
                                    }
                                }
                            }
                            DropArea {
                                anchors.fill: parent
                                onEntered: drag => {
                                    if (!drag.hasUrls || root.browser.actions.dropRefused(drag.urls, pCard.modelData.path)) { drag.accepted = false; return }
                                    pCard.dropping = true
                                }
                                onExited: pCard.dropping = false
                                onDropped: drop => { pCard.dropping = false; root.browser.actions.drop(drop, pCard.modelData.path) }
                            }
                        }
                    }
                }
            }

            // ---- bookmarks (only when the person has some)
            Column {
                width: col.width
                spacing: Theme.dp(10)
                visible: root.marks.length > 0
                Caption { text: I18n.tr("Bookmarks") }

                Flow {
                    width: parent.width
                    spacing: Theme.dp(8)
                    Repeater {
                        model: root.marks
                        delegate: Rectangle {
                            id: mChip
                            required property var modelData
                            height: Theme.dp(36)
                            width: Math.min(col.width, mRow.implicitWidth + Theme.dp(22))
                            radius: Theme.round(10)
                            color: mHit.pressed ? Theme.fillPress : mHit.containsMouse ? Theme.fillHover : Theme.card
                            border.width: 1
                            border.color: Theme.line
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                            Row {
                                id: mRow
                                anchors.centerIn: parent
                                spacing: Theme.dp(7)
                                Glyph {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: mChip.modelData.glyph
                                    size: Theme.dp(17)
                                    color: mChip.modelData.tint ? (Theme.tints[mChip.modelData.tint] ?? Theme.ink2) : Theme.ink2
                                }
                                Txt {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: mChip.modelData.name
                                    size: Theme.small
                                    strong: true
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

            // ---- recent files
            Column {
                width: col.width
                spacing: Theme.dp(10)

                Item {
                    width: parent.width
                    height: recentCap.implicitHeight
                    Caption { id: recentCap; anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Recent") }
                    Txt {
                        visible: root.folder.all.length > 0
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("See all")
                        size: Theme.small
                        strong: true
                        color: allHit.containsMouse ? Theme.ink : Theme.accentInk
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

                Grid {
                    id: recentGrid
                    visible: root.recents.length > 0
                    width: parent.width
                    columns: col.width >= Theme.dp(620) ? 2 : 1
                    columnSpacing: Theme.dp(10)
                    rowSpacing: Theme.dp(8)
                    readonly property real rowW: Math.floor((width - columnSpacing * (columns - 1)) / columns)

                    Repeater {
                        model: root.recents
                        delegate: Rectangle {
                            id: rCard
                            required property var modelData
                            required property int index
                            width: recentGrid.rowW
                            height: Theme.dp(58)
                            radius: Theme.radius
                            color: rHit.pressed ? Theme.fillPress : rHover.hovered ? Theme.fillHover : Theme.card
                            border.width: 1
                            border.color: Theme.line
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                            HoverHandler { id: rHover }

                            FileIcon {
                                id: rIcon
                                x: Theme.dp(10)
                                anchors.verticalCenter: parent.verticalCenter
                                size: Theme.dp(36)
                                entry: rCard.modelData
                            }
                            Column {
                                anchors.left: rIcon.right
                                anchors.leftMargin: Theme.dp(11)
                                anchors.right: showFolderAct.visible ? showFolderAct.left : parent.right
                                anchors.rightMargin: Theme.dp(10)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.dp(1)
                                Txt {
                                    width: parent.width
                                    text: rCard.modelData.name
                                    size: Theme.row
                                    strong: true
                                    color: Theme.ink
                                    elide: Text.ElideMiddle
                                }
                                Txt {
                                    width: parent.width
                                    readonly property string where: Fmt.pretty(Fmt.parent(rCard.modelData.path))
                                    readonly property string when: Fmt.when(rCard.modelData.mtime)
                                    text: when.length > 0 ? where + " · " + when : where
                                    size: Theme.small
                                    color: Theme.ink3
                                    elide: Text.ElideMiddle
                                }
                            }
                            MouseArea {
                                id: rHit
                                anchors.fill: parent
                                anchors.rightMargin: showFolderAct.visible ? Theme.dp(40) : 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                onClicked: mouse => {
                                    root.pane.activate()
                                    if (mouse.button === Qt.RightButton) {
                                        root.folder.only(rCard.index)
                                        const at = rHit.mapToItem(root.browser.stage, mouse.x, mouse.y)
                                        root.browser.actions.itemMenu(root.pane, at.x, at.y)
                                    } else if (mouse.button === Qt.MiddleButton) {
                                        if (rCard.modelData.dir) root.browser.newTab(rCard.modelData.path)
                                        else root.browser.newTab(Fmt.parent(rCard.modelData.path), [rCard.modelData.path])
                                    } else {
                                        root.browser.actions.open(root.pane, [rCard.modelData])
                                    }
                                }
                            }
                            Act {
                                id: showFolderAct
                                visible: rHover.hovered
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(8)
                                anchors.verticalCenter: parent.verticalCenter
                                size: Theme.dp(28)
                                glyphSize: Theme.dp(17)
                                glyph: "folder_open"
                                tip: I18n.tr("Show in folder")
                                onClicked: {
                                    root.folder.focusPath = rCard.modelData.path
                                    root.folder.go(Fmt.parent(rCard.modelData.path))
                                }
                            }
                        }
                    }
                }

                // Quiet placeholder when there are no recent files yet.
                Card {
                    visible: !root.folder.loading && root.recents.length === 0
                    width: parent.width
                    height: Theme.dp(56)
                    radius: Theme.radius
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.dp(16)
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.dp(16)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.dp(12)
                        Glyph { anchors.verticalCenter: parent.verticalCenter; name: "schedule"; size: Theme.dp(20); color: Theme.ink3 }
                        Txt {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Theme.dp(32)
                            text: I18n.tr("Files you open in your apps show up here.")
                            size: Theme.small
                            color: Theme.ink3
                        }
                    }
                }
            }

            // ---- drives and network mounts
            Column {
                width: col.width
                spacing: Theme.dp(10)
                visible: root.drives.length > 0

                Item {
                    width: parent.width
                    height: devCap.implicitHeight
                    Caption { id: devCap; anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Devices") }
                    Txt {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Connect a server")
                        size: Theme.small
                        strong: true
                        color: connHit.containsMouse ? Theme.ink : Theme.accentInk
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
                            height: dCard.it.meter >= 0 ? Theme.dp(74) : Theme.dp(62)
                            radius: Theme.radius
                            color: dHit.pressed ? Theme.fillPress : dHover.hovered ? Theme.fillHover : Theme.card
                            border.width: 1
                            border.color: Theme.line
                            Behavior on color { ColorAnimation { duration: Theme.fast } }
                            HoverHandler { id: dHover }

                            Rectangle {
                                id: dBadge
                                x: Theme.dp(12)
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.dp(40)
                                height: width
                                radius: Theme.round(10)
                                color: dCard.it.mounted ? Theme.fill : Theme.inset
                                Glyph {
                                    anchors.centerIn: parent
                                    name: dCard.it.glyph
                                    size: Theme.dp(21)
                                    color: Theme.ink2
                                    opacity: dCard.it.mounted ? 1 : 0.55
                                }
                            }
                            Column {
                                anchors.left: dBadge.right
                                anchors.leftMargin: Theme.dp(12)
                                anchors.right: dEject.visible ? dEject.left : parent.right
                                anchors.rightMargin: Theme.dp(12)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.dp(5)

                                Row {
                                    width: parent.width
                                    spacing: Theme.dp(6)
                                    Txt {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: dCard.it.name
                                        size: Theme.row
                                        strong: true
                                        color: Theme.ink
                                        width: Math.min(implicitWidth, parent.width - (fsTag.visible ? fsTag.width + Theme.dp(8) : 0))
                                    }
                                    Rectangle {
                                        id: fsTag
                                        visible: dCard.it.fstype.length > 0
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: Theme.dp(18)
                                        width: fsTxt.implicitWidth + Theme.dp(10)
                                        radius: height / 2
                                        color: Theme.fill
                                        Txt {
                                            id: fsTxt
                                            anchors.centerIn: parent
                                            text: dCard.it.fstype
                                            size: Theme.caption
                                            color: Theme.ink3
                                        }
                                    }
                                }
                                Meter {
                                    visible: dCard.it.meter >= 0
                                    width: parent.width
                                    height: Theme.dp(4)
                                    value: Math.max(0, dCard.it.meter)
                                }
                                Txt {
                                    width: parent.width
                                    visible: dCard.it.detail.length > 0
                                    text: dCard.it.detail
                                    size: Theme.small
                                    color: Theme.ink3
                                }
                            }
                            MouseArea {
                                id: dHit
                                anchors.fill: parent
                                anchors.rightMargin: dEject.visible ? Theme.dp(42) : 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: mouse => root.openDrive(dCard.it, mouse.button === Qt.MiddleButton)
                            }
                            Act {
                                id: dEject
                                visible: (dCard.it.kind === "device" && dCard.it.mounted && !dCard.it.root && dCard.it.removable) || dCard.it.kind === "share"
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(10)
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
        }
    }
}
