import QtQuick
import QtQuick.Controls.Basic as QQC
import Quickshell
import qs.services
import qs.kit

// The aside: the chosen file drawn as itself, what it is, and the facts that matter for its kind. Several chosen show
// what they add up to; none chosen shows the folder.
Item {
    id: root
    required property var browser
    readonly property var pane: root.browser.activePane
    readonly property var folder: root.pane ? root.pane.folder : null
    readonly property var list: root.folder ? root.folder.chosen() : []
    readonly property bool many: root.list.length > 1
    property var here: null
    readonly property var entry: root.list.length === 1 ? root.list[0] : root.list.length === 0 ? root.here : null
    readonly property var info: media.info
    readonly property bool placeOnly: root.list.length === 0 && root.folder !== null && root.folder.mode !== "folder"

    // ---- the folder itself, when nothing is chosen
    readonly property string herePath: root.folder && root.folder.mode === "folder" ? root.folder.path : ""
    onHerePathChanged: { root.here = null; hereTimer.restart() }
    Timer {
        id: hereTimer
        interval: 60
        onTriggered: {
            const p = root.herePath
            const adm = root.folder && root.folder.admin === true
            if (p.length > 0) Core.call("stat", { paths: [p], admin: adm }, r => { if (root && r.ok && r.entries.length > 0 && p === root.herePath) root.here = r.entries[0] })
        }
    }
    Connections {
        target: Core
        function onChanged(paths) { if (root.herePath.length > 0 && paths.indexOf(root.herePath) >= 0) hereTimer.restart() }
        function onSizeEvent(d) { if (d.token === root.sizeToken) root.sizing = d }
    }

    // ---- how much a folder or a choice holds, walked by the core as it grows
    property var sizing: null
    property string sizeToken: ""
    property int sizeSerial: 0
    readonly property var measured: root.many ? root.list.filter(e => e.dir).length > 0 ? root.list.map(e => e.path) : [] : root.list.length === 1 && root.list[0].dir ? [root.list[0].path] : []
    onMeasuredChanged: sizeTimer.restart()
    Timer {
        id: sizeTimer
        interval: 280
        onTriggered: {
            if (root.sizeToken.length > 0) Core.call("cancel", { token: root.sizeToken })
            root.sizing = null
            root.sizeToken = ""
            if (root.measured.length === 0) return
            root.sizeToken = "aside-" + (++root.sizeSerial)
            Core.call("dirsize", { token: root.sizeToken, paths: root.measured })
        }
    }
    readonly property real total: root.sizing ? root.sizing.size : root.list.reduce((s, e) => s + (e.dir ? 0 : e.size), 0)
    function sizeText(): string {
        if (root.sizing) {
            const s = Fmt.size(root.sizing.size) + " · " + Fmt.items(root.sizing.files + root.sizing.dirs)
            return root.sizing.done ? s : s + "…"
        }
        return root.measured.length > 0 ? I18n.tr("Measuring…") : Fmt.size(root.total)
    }

    // ---- what is said about the file
    readonly property var kindNames: ({
        folder: I18n.tr("Folders"), image: I18n.tr("Pictures"), video: I18n.tr("Videos"), audio: I18n.tr("Audio"),
        document: I18n.tr("Documents"), pdf: I18n.tr("PDFs"), archive: I18n.tr("Archives"), code: I18n.tr("Code"),
        text: I18n.tr("Text"), font: I18n.tr("Fonts"), app: I18n.tr("Apps"), executable: I18n.tr("Programs"),
        disk: I18n.tr("Disk images"), file: I18n.tr("Other files")
    })
    readonly property var facts: {
        const out = []
        const add = (key, value, run, path) => { if (value !== undefined && value !== null && String(value).length > 0) out.push({ key: key, value: String(value), run: run ?? null, path: path === true }) }
        const section = text => out.push({ section: text })
        if (root.many) {
            const counts = {}
            for (const e of root.list) counts[e.kind] = (counts[e.kind] ?? 0) + 1
            section(I18n.tr("Kinds"))
            for (const k of Object.keys(counts).sort((a, b) => counts[b] - counts[a])) add(root.kindNames[k] ?? k, counts[k])
            return out
        }
        const e = root.entry
        const i = root.info
        if (!e) return out
        section(I18n.tr("Details"))
        add(I18n.tr("Kind"), i.comment || e.comment)
        if (e.dir) {
            if (i.files !== undefined) add(I18n.tr("Contains"), Fmt.items(i.files + i.dirs) + (i.hiddenItems > 0 ? " · " + I18n.n("%1 hidden", "%1 hidden", i.hiddenItems) : ""))
            if (root.list.length === 1) add(I18n.tr("Size"), root.sizeText())
            if (i.space && i.space.total > 0) add(I18n.tr("Free"), I18n.tr("%1 of %2", Fmt.size(i.space.free), Fmt.size(i.space.total)))
        } else {
            const bytes = i.size ?? e.size
            add(I18n.tr("Size"), Fmt.size(bytes) + (bytes >= 1000 ? " (" + I18n.n("%1 byte", "%1 bytes", bytes) + ")" : ""))
        }
        if (i.width > 0) add(I18n.tr("Dimensions"), i.width + " × " + i.height + (i.width * i.height >= 1e6 ? " · " + Fmt.num(i.width * i.height / 1e6, 1) + " MP" : ""))
        const m = i.media
        if (m) {
            section(e.kind === "audio" ? I18n.tr("Sound") : I18n.tr("Film"))
            const t = m.tags ?? {}
            add(I18n.tr("Title"), t.title)
            add(I18n.tr("Artist"), t.artist || t.album_artist)
            add(I18n.tr("Album"), t.album)
            add(I18n.tr("Year"), t.date)
            add(I18n.tr("Genre"), t.genre)
            if (m.duration > 0) add(I18n.tr("Length"), Fmt.duration(m.duration))
            if (m.video) add(I18n.tr("Picture"), [m.video.codec.toUpperCase(), m.video.width + " × " + m.video.height, m.video.fps > 0 ? Fmt.num(m.video.fps, m.video.fps % 1 === 0 ? 0 : 2) + " fps" : "", m.video.hdr, m.video.depth > 8 ? m.video.depth + "-bit" : ""].filter(s => s).join(" · "))
            if (m.audio) add(I18n.tr("Sound"), [m.audio.codec.toUpperCase(), m.audio.rate > 0 ? Fmt.num(m.audio.rate / 1000, m.audio.rate % 1000 === 0 ? 0 : 1) + " kHz" : "", m.audio.layout || (m.audio.channels ? I18n.n("%1 channel", "%1 channels", m.audio.channels) : ""), m.audio.depth > 0 ? m.audio.depth + "-bit" : ""].filter(s => s).join(" · "))
            if (m.bitrate > 0) add(I18n.tr("Bit rate"), Fmt.num(m.bitrate / 1000, 0) + " kb/s")
            if (m.audioTracks > 1) add(I18n.tr("Sound tracks"), m.audioTracks)
            if (m.subtitles > 0) add(I18n.tr("Subtitles"), m.subtitles)
            if (m.chapters > 0) add(I18n.tr("Chapters"), m.chapters)
            add(I18n.tr("Container"), m.container)
        }
        const x = i.exif
        if (x) {
            section(I18n.tr("Photo"))
            add(I18n.tr("Camera"), x.camera)
            add(I18n.tr("Lens"), x.lens)
            add(I18n.tr("Exposure"), [x.aperture ? "ƒ/" + x.aperture.replace(/^f\//i, "") : "", x.exposure, x.iso ? "ISO " + x.iso : "", x.focal].filter(s => s).join(" · "))
            add(I18n.tr("Taken"), x.taken)
            if (x.gps) add(I18n.tr("Place"), Fmt.num(x.gps.lat, 5) + ", " + Fmt.num(x.gps.lon, 5), () => Qt.openUrlExternally("https://www.openstreetmap.org/?mlat=" + x.gps.lat + "&mlon=" + x.gps.lon + "#map=15/" + x.gps.lat + "/" + x.gps.lon))
            add(I18n.tr("Software"), x.software)
        }
        const p = i.pdf
        if (p) {
            section(I18n.tr("Document"))
            add(I18n.tr("Title"), p.title)
            add(I18n.tr("Author"), p.author)
            if (p.pages > 0) add(I18n.tr("Pages"), p.pages)
            add(I18n.tr("Page size"), p.pageSize)
            add(I18n.tr("Made with"), p.creator || p.producer)
            if (p.encrypted && p.encrypted !== "no") add(I18n.tr("Protected"), I18n.tr("Yes"))
        }
        const a = i.archive
        if (a) {
            section(I18n.tr("Archive"))
            add(I18n.tr("Holds"), Fmt.items(a.count))
        }
        const d = i.desktop
        if (d) {
            section(I18n.tr("App"))
            add(I18n.tr("Name"), d.name)
            add(I18n.tr("About"), d.comment)
            add(I18n.tr("Runs"), d.exec)
        }
        if (i.text && i.text.lines !== undefined && (e.kind === "text" || e.kind === "code")) add(I18n.tr("Lines"), Fmt.num(i.text.lines, 0) + (i.text.truncated ? "+" : ""))
        section(I18n.tr("Dates"))
        add(I18n.tr("Modified"), Fmt.full(i.mtime ?? e.mtime))
        if (i.btime > 0) add(I18n.tr("Created"), Fmt.full(i.btime))
        if (e.deleted > 0) add(I18n.tr("Deleted"), Fmt.full(e.deleted))
        section(I18n.tr("Place"))
        if (e.origin) add(I18n.tr("From"), Fmt.pretty(e.origin), null, true)
        else if (i.parent && !Fmt.mountName(e.path)) add(I18n.tr("Folder"), Fmt.pretty(i.parent), () => root.pane.folder.go(i.parent, true), true)
        if (i.target) add(I18n.tr("Points to"), Fmt.pretty(i.target), null, true)
        if (i.modeText) add(I18n.tr("Access"), i.modeText + " · " + i.owner + (i.group && i.group !== i.owner ? ":" + i.group : ""))
        return out
    }

    // ---- what a place without a file of its own says (start, trash, recent, search)
    readonly property var placeFace: {
        const f = root.folder
        if (!f) return ({})
        if (f.mode === "start") return { glyph: "space_dashboard", title: I18n.tr("Start"), text: Core.places.host ?? "" }
        if (f.mode === "trash") return { glyph: "delete", title: I18n.tr("Trash"), text: Fmt.items(f.model.count) }
        if (f.mode === "recent") return { glyph: "schedule", title: I18n.tr("Recent"), text: Fmt.items(f.model.count) }
        return { glyph: "search", title: I18n.tr("Search"), text: f.searching ? I18n.tr("Searching…") : I18n.n("%1 result", "%1 results", f.model.count) }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: col.implicitHeight + Theme.dp(36)
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        QQC.ScrollBar.vertical: Scroller {}

        Column {
            id: col
            x: Theme.dp(18)
            y: Theme.dp(18)
            width: flick.width - Theme.dp(36)
            spacing: Theme.dp(14)

            Media {
                id: media
                width: parent.width
                height: implicitHeight
                visible: !root.many && !root.placeOnly && !!root.entry
                entry: root.many || root.placeOnly ? null : root.entry
                admin: !!root.folder && root.folder.admin
            }

            // Several chosen: their icons stacked like cards.
            Item {
                visible: root.many
                width: parent.width
                height: Theme.dp(170)
                Repeater {
                    model: root.many ? root.list.slice(0, 3).reverse() : []
                    FileIcon {
                        required property var modelData
                        required property int index
                        readonly property int depth: Math.min(root.list.length, 3) - 1 - index
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: depth * Theme.dp(18) - Theme.dp(18)
                        rotation: (depth - 1) * 7
                        size: Theme.dp(120)
                        entry: modelData
                        opacity: 1 - depth * 0.12
                    }
                }
            }

            Glyph {
                visible: root.placeOnly
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.placeFace.glyph ?? ""
                size: Theme.dp(72)
                color: Theme.ink3
            }

            Column {
                width: parent.width
                spacing: Theme.dp(3)
                Txt {
                    width: parent.width
                    text: root.many ? Fmt.items(root.list.length) : root.placeOnly ? root.placeFace.title ?? "" : root.entry ? (root.entry.path === Core.home ? I18n.tr("Home") : Fmt.mountName(root.entry.path) || root.entry.name || "/") : ""
                    font.family: Theme.title
                    size: Theme.head
                    strong: true
                    // Breaks between words; a name with no spaces breaks anywhere.
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 3
                    horizontalAlignment: Text.AlignHCenter
                }
                Txt {
                    width: parent.width
                    text: root.many ? root.sizeText() : root.placeOnly ? root.placeFace.text ?? "" : root.entry ? (root.entry.dir ? (root.info.files !== undefined ? Fmt.items(root.info.files + root.info.dirs) : "") : [root.entry.comment, Fmt.size(root.entry.size)].filter(s => s).join(" · ")) : ""
                    color: Theme.ink2
                    size: Theme.small
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Row {
                id: acts
                visible: !root.placeOnly && (root.many || !!root.entry)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.dp(6)
                readonly property var targets: root.list.length > 0 ? root.list : root.here ? [root.here] : []
                Pill {
                    kind: "solid"
                    glyph: "open_in_new"
                    text: root.list.length === 0 ? I18n.tr("Terminal here") : I18n.tr("Open")
                    onClicked: root.list.length === 0 ? root.browser.actions.terminal(root.herePath) : root.browser.actions.open(root.pane, root.list)
                }
                Act {
                    id: withAct
                    visible: root.list.length > 0
                    anchors.verticalCenter: parent.verticalCenter
                    round: true
                    glyph: "apps"
                    tip: I18n.tr("Open with")
                    onClicked: root.browser.actions.openWithMenu(root.list, withAct)
                }
                Act {
                    id: moreAct
                    anchors.verticalCenter: parent.verticalCenter
                    round: true
                    glyph: "more_horiz"
                    tip: I18n.tr("More")
                    onClicked: {
                        const p = moreAct.mapToItem(root.browser.stage, 0, moreAct.height + Theme.dp(4))
                        if (root.list.length === 0) root.browser.actions.backgroundMenu(root.pane, p.x, p.y)
                        else root.browser.actions.itemMenu(root.pane, p.x, p.y)
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.dp(2)
                Repeater {
                    model: root.facts
                    Item {
                        required property var modelData
                        readonly property bool head: modelData.section !== undefined
                        width: col.width
                        height: head ? Theme.dp(34) : Math.max(Theme.dp(22), value.implicitHeight + Theme.dp(4))
                        Caption {
                            visible: parent.head
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.dp(6)
                            text: parent.modelData.section ?? ""
                        }
                        Txt {
                            visible: !parent.head
                            width: parent.width * 0.36
                            height: Theme.dp(22)
                            text: parent.modelData.key ?? ""
                            color: Theme.ink3
                            size: Theme.small
                        }
                        Txt {
                            id: value
                            visible: !parent.head
                            x: parent.width * 0.36 + Theme.dp(8)
                            y: Theme.dp(3)
                            width: parent.width - x
                            text: parent.modelData.value ?? ""
                            color: parent.modelData.run ? Theme.accentInk : Theme.ink
                            size: Theme.small
                            // A path keeps one line and loses its middle; the whole path shows in a tip.
                            wrapMode: parent.modelData.path ? Text.NoWrap : Text.WrapAtWordBoundaryOrAnywhere
                            elide: parent.modelData.path ? Text.ElideMiddle : Text.ElideNone
                            verticalAlignment: Text.AlignTop
                            font.underline: !!parent.modelData.run && valueMouse.containsMouse
                            MouseArea {
                                id: valueMouse
                                anchors.fill: parent
                                enabled: !!parent.parent.modelData.run || value.truncated
                                hoverEnabled: true
                                cursorShape: parent.parent.modelData.run ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (parent.parent.modelData.run) parent.parent.modelData.run()
                                onContainsMouseChanged: if (!containsMouse) value.QsWindow.window?.tips?.hide(value)
                            }
                            Timer {
                                interval: value.QsWindow.window?.tips?.delay ?? 650
                                running: valueMouse.containsMouse && value.truncated
                                onTriggered: value.QsWindow.window?.tips?.show(value, value.text, "")
                            }
                        }
                    }
                }
            }
        }
    }
}
