import QtQuick
import Quickshell
import qs.services
import qs.kit

// What a file holds, drawn as itself: a picture at full sharpness, a film or a song to play, a page of a PDF, text in
// its language's colours, a typeface's specimen, an archive's first entries. Anything else shows its icon.
Item {
    id: root
    property var entry: null
    property bool large: false
    // What the core knows of the file beyond its listing: size of a picture, streams of a film, pages, an archive's list.
    property var info: ({})
    readonly property string path: root.entry?.path ?? ""
    readonly property string kind: root.entry?.kind ?? ""
    readonly property string mime: root.entry?.mime ?? ""
    readonly property real dpr: root.Window.window?.devicePixelRatio ?? 1
    readonly property bool textual: root.kind === "text" || root.kind === "code"
    property var text: null
    property bool playing: false
    property int page: 0
    property bool source: false

    readonly property real ratio: {
        const w = root.info.width || root.info.media?.video?.width || 0
        const h = root.info.height || root.info.media?.video?.height || 0
        if (w > 0 && h > 0) return Math.max(0.42, Math.min(1.3, h / w))
        if (root.kind === "pdf") return 1.3
        if (root.kind === "video") return 0.5625
        return 0.75
    }
    implicitHeight: {
        if (root.kind === "folder" || root.kind === "" || root.kind === "file" || root.kind === "executable" || root.kind === "document" || root.kind === "disk") return Theme.dp(170)
        if (root.textual || root.kind === "archive") return Theme.dp(300)
        if (root.kind === "font") return Theme.dp(260)
        if (root.kind === "audio") return Theme.dp(250)
        return Math.round(root.width * root.ratio)
    }

    readonly property string key: root.path + "|" + (root.entry?.mtime ?? 0)
    function reset(): void { root.info = ({}); root.text = null; root.playing = root.large && (root.kind === "video" || root.kind === "audio"); root.page = 0; root.source = false }
    onPathChanged: root.reset()
    Component.onCompleted: { root.reset(); fetch.restart() }
    onKeyChanged: fetch.restart()
    // Arrows run through a folder fast: only the entry that stays asks the core.
    Timer {
        id: fetch
        interval: 90
        onTriggered: {
            const p = root.path
            if (p.length === 0) return
            Core.call("info", { path: p }, r => { if (r.ok && p === root.path) root.info = r })
            if (root.textual) Core.call("text", { path: p, limit: root.large ? 1048576 : 98304 }, r => { if (r.ok && p === root.path) root.text = r })
        }
    }

    // What the interface reads itself; anything else (PDF pages, AVIF, HEIC, JPEG XL, RAW ...) the core draws for it.
    readonly property bool qtReads: ["image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/svg+xml", "image/tiff",
        "image/x-icon", "image/vnd.microsoft.icon", "image/x-tga", "image/vnd.wap.wbmp"].includes(root.mime)
    readonly property int pages: root.kind === "pdf" ? Math.max(1, Number(root.info.pdf?.pages ?? 1)) : 1

    component Icon: Item {
        FileIcon {
            anchors.centerIn: parent
            size: Math.min(parent.width, parent.height, Theme.dp(root.large ? 360 : 150))
            entry: root.entry
        }
    }

    Loader {
        id: face
        anchors.fill: parent
        sourceComponent: {
            if (!root.entry) return null
            switch (root.kind) {
            case "image": return root.mime === "image/gif" || root.mime === "image/webp" ? animated : picture
            case "pdf": return picture
            case "video": return film
            case "audio": return song
            case "text": case "code": return lines
            case "font": return specimen
            case "archive": return archive
            case "app": return app
            }
            return icon
        }
    }

    Component { id: icon; Icon {} }

    Component {
        id: picture
        Item {
            id: pic
            // The page the core drew, at the size this face takes on screen.
            property string drawn: ""
            readonly property int side: Math.round(Math.max(64, width, height) * root.dpr)
            readonly property int count: root.qtReads ? img.frameCount : root.pages
            function draw(): void {
                if (root.qtReads || root.path.length === 0) return
                const p = root.path, page = root.page
                Core.call("render", { path: p, page: page, side: pic.side }, r => { if (r.ok && p === root.path && page === root.page) pic.drawn = r.file })
            }
            onSideChanged: redraw.restart()
            Connections {
                target: root
                function onPageChanged() { redraw.restart() }
                function onKeyChanged() { pic.drawn = ""; redraw.restart() }
            }
            Timer { id: redraw; interval: 120; onTriggered: pic.draw() }
            Component.onCompleted: pic.draw()

            Icon { anchors.fill: parent; visible: img.status !== Image.Ready }
            Image {
                id: img
                anchors.fill: parent
                source: root.qtReads ? Fmt.url(root.path) + "?" + (root.entry?.mtime ?? 0) : pic.drawn.length > 0 ? Fmt.url(pic.drawn) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                smooth: true
                mipmap: true
                autoTransform: true
                currentFrame: root.qtReads ? root.page : 0
                sourceSize.width: Math.round(Math.max(64, width) * root.dpr)
                sourceSize.height: Math.round(Math.max(64, height) * root.dpr)
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.fast } }
            }
            // Pages of a PDF.
            Rectangle {
                visible: pic.count > 1
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.dp(8)
                height: Theme.dp(32)
                width: pager.width + Theme.dp(8)
                radius: height / 2
                color: Qt.rgba(0.05, 0.05, 0.07, 0.72)
                Row {
                    id: pager
                    anchors.centerIn: parent
                    Act { size: Theme.dp(28); glyph: "chevron_left"; tint: "#ffffff"; round: true; enabled: root.page > 0; onClicked: root.page-- }
                    Txt { anchors.verticalCenter: parent.verticalCenter; text: (root.page + 1) + " / " + pic.count; color: "#ffffff"; size: Theme.small; font.features: { "tnum": 1 } }
                    Act { size: Theme.dp(28); glyph: "chevron_right"; tint: "#ffffff"; round: true; enabled: root.page < pic.count - 1; onClicked: root.page++ }
                }
            }
        }
    }

    Component {
        id: animated
        Item {
            Icon { anchors.fill: parent; visible: anim.status !== AnimatedImage.Ready }
            AnimatedImage {
                id: anim
                anchors.fill: parent
                source: Fmt.url(root.path) + "?" + (root.entry?.mtime ?? 0)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
                playing: root.visible
                smooth: true
            }
        }
    }

    Component {
        id: film
        Item {
            // The poster: the film's own frame across the whole face, its icon while there is none.
            FileIcon {
                id: poster
                anchors.fill: parent
                visible: !root.playing && poster.showThumb
                size: Math.max(width, height)
                entry: root.entry
                badge: false
            }
            Icon { anchors.fill: parent; visible: !root.playing && !poster.showThumb }
            Rectangle {
                visible: !root.playing
                anchors.centerIn: parent
                width: Theme.dp(root.large ? 72 : 52)
                height: width
                radius: width / 2
                color: playMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.72) : Qt.rgba(0, 0, 0, 0.55)
                Glyph { anchors.centerIn: parent; name: "play_arrow"; fill: 1; size: parent.width * 0.55; color: "#ffffff" }
                MouseArea { id: playMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.playing = true }
            }
            Loader {
                anchors.fill: parent
                active: root.playing
                source: "Player.qml"
                onLoaded: { item.video = true; item.autoplay = true; item.source = root.path }
            }
        }
    }

    Component {
        id: song
        Item {
            FileIcon {
                id: cover
                anchors.horizontalCenter: parent.horizontalCenter
                y: Theme.dp(4)
                size: Math.min(parent.width, parent.height - Theme.dp(56))
                entry: root.entry
            }
            Loader {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Theme.dp(40)
                source: "Player.qml"
                onLoaded: { item.video = false; item.autoplay = root.playing; item.source = root.path }
            }
        }
    }

    Component {
        id: lines
        Item {
        // Large, the text sits on a page of its own, as wide as reads well.
        Inset {
            id: sheet
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.large ? Math.min(parent.width, Theme.dp(940)) : parent.width
            height: parent.height
            radius: Theme.dp(14)
            color: root.large ? Theme.card : Theme.inset
            clip: true
            readonly property bool markdown: root.mime === "text/markdown" || root.path.toLowerCase().endsWith(".md")
            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: Theme.dp(root.large ? 28 : 12)
                contentWidth: Math.max(width, body.item ? body.item.implicitWidth : 0)
                contentHeight: body.item ? body.item.implicitHeight : 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Loader {
                    id: body
                    width: flick.width
                    sourceComponent: sheet.markdown && !root.source ? rich : code
                }
            }
            Act {
                visible: sheet.markdown
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.dp(6)
                size: Theme.dp(28)
                glyphSize: Theme.dp(16)
                glyph: root.source ? "article" : "code"
                tip: root.source ? I18n.tr("Show as page") : I18n.tr("Show the source")
                onClicked: root.source = !root.source
            }
            Txt {
                visible: root.text && root.text.truncated
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: Theme.dp(8)
                text: I18n.tr("Only the start is shown")
                size: Theme.caption
                color: Theme.ink3
            }
        }
        }
    }
    Component {
        id: rich
        // The core lays the page out in the theme's colours; a new theme or width lays it out again.
        Text {
            id: page
            property string html: ""
            readonly property real base: root.large ? Theme.row * 1.08 : Theme.body
            readonly property string look: [Theme.ink, Theme.ink2, Theme.ink3, Theme.line, Theme.fill, Theme.accent, Theme.mono, page.base, Math.round(page.width / 32), root.key].join("|")
            onLookChanged: ask.restart()
            Timer {
                id: ask
                interval: 60
                onTriggered: {
                    const p = root.path
                    if (p.length === 0 || page.width <= 0) return
                    // Colours as #AARRGGBB: Qt reads that form both in styles and in attributes.
                    const look = { ink: String(Theme.ink), ink2: String(Theme.ink2), ink3: String(Theme.ink3), line: String(Theme.alpha(Theme.ink, 0.14)), fill: String(Theme.fill),
                        accent: String(Theme.accent), mono: Theme.mono, base: page.base, width: Math.max(64, page.width - 4) }
                    Core.call("markdown", { path: p, limit: root.large ? 1048576 : 98304, look: look }, r => { if (r.ok && p === root.path) page.html = r.html })
                }
            }
            text: page.html
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            color: Theme.ink
            linkColor: Theme.accent
            font.family: Theme.sans
            font.pixelSize: page.base
            onLinkActivated: link => Qt.openUrlExternally(link)
            HoverHandler { cursorShape: page.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor }
        }
    }
    Component {
        id: code
        Loader {
            source: "Code.qml"
            onLoaded: { item.fileName = Fmt.name(root.path); item.text = Qt.binding(() => root.text ? root.text.text : "") }
            onStatusChanged: if (status === Loader.Error) sourceComponent = plain
        }
    }
    Component {
        id: plain
        TextEdit {
            readOnly: true
            selectByMouse: true
            textFormat: TextEdit.PlainText
            text: root.text ? root.text.text : ""
            color: Theme.ink
            font.family: Theme.mono
            font.pixelSize: Theme.small
        }
    }

    Component {
        id: specimen
        Item {
            FontLoader { id: face; source: Fmt.url(root.path) }
            Column {
                anchors.fill: parent
                spacing: Theme.dp(6)
                visible: face.status === FontLoader.Ready
                Text { text: "Aa"; font.family: face.name; font.pixelSize: Theme.dp(root.large ? 140 : 86); color: Theme.ink; width: parent.width; elide: Text.ElideRight }
                Text { text: face.name; font.family: Theme.sans; font.pixelSize: Theme.body; font.weight: Font.DemiBold; color: Theme.ink2 }
                Text { text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"; font.family: face.name; font.pixelSize: Theme.head; color: Theme.ink; width: parent.width; wrapMode: Text.WrapAnywhere }
                Text { text: "abcdefghijklmnopqrstuvwxyz 0123456789"; font.family: face.name; font.pixelSize: Theme.head; color: Theme.ink; width: parent.width; wrapMode: Text.WrapAnywhere }
                Text { text: I18n.tr("The quick brown fox jumps over the lazy dog."); font.family: face.name; font.pixelSize: Theme.row; color: Theme.ink2; width: parent.width; wrapMode: Text.Wrap }
            }
            Icon { anchors.fill: parent; visible: face.status === FontLoader.Error }
        }
    }

    Component {
        id: archive
        Inset {
            radius: Theme.dp(14)
            clip: true
            readonly property var a: root.info.archive ?? null
            Icon { anchors.fill: parent; visible: !parent.a }
            ListView {
                anchors.fill: parent
                anchors.margins: Theme.dp(8)
                clip: true
                visible: !!parent.a
                model: parent.a ? parent.a.top : []
                boundsBehavior: Flickable.StopAtBounds
                delegate: Item {
                    required property var modelData
                    width: ListView.view.width
                    height: Theme.dp(26)
                    readonly property bool folder: (root.info.archive.entries ?? []).some(n => n.replace(/^\.\//, "").startsWith(modelData + "/"))
                    Glyph { id: g; x: Theme.dp(4); anchors.verticalCenter: parent.verticalCenter; name: parent.folder ? "folder" : "draft"; fill: 1; size: Theme.dp(16); color: parent.folder ? Theme.folderFront : Theme.ink3 }
                    Txt { anchors.left: g.right; anchors.leftMargin: Theme.dp(8); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: modelData; size: Theme.body; elide: Text.ElideMiddle }
                }
            }
        }
    }

    Component {
        id: app
        Item {
            readonly property string iconFile: root.info.desktop?.icon ? (root.info.desktop.icon.startsWith("/") ? root.info.desktop.icon : Quickshell.iconPath(root.info.desktop.icon, true)) : ""
            Icon { anchors.fill: parent; visible: parent.iconFile.length === 0 }
            Image {
                visible: parent.iconFile.length > 0
                anchors.centerIn: parent
                width: Math.min(parent.width, parent.height, Theme.dp(128))
                height: width
                source: parent.iconFile.length > 0 ? (parent.iconFile.startsWith("/") ? Fmt.url(parent.iconFile) : parent.iconFile) : ""
                sourceSize: Qt.size(width * root.dpr, height * root.dpr)
                fillMode: Image.PreserveAspectFit
            }
        }
    }
}
