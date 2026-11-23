import QtQuick
import Quickshell
import qs.services

// What stands for a file: its thumbnail once there is one, else the system's icon or the drawn art.
Item {
    id: root
    property var entry: null
    property real size: 64
    property bool allowThumb: true
    property bool dim: false
    // The play mark on a film's thumbnail; off where a play button of its own sits over it.
    property bool badge: true
    // How much larger than size a thumbnail may draw: the grid lets a picture fill its whole plate.
    property real grow: 0

    readonly property string path: root.entry?.path ?? ""
    readonly property real mtime: root.entry?.mtime ?? 0
    readonly property real dpr: root.Window.window?.devicePixelRatio ?? 1
    readonly property real px: (root.size + root.grow) * root.dpr
    readonly property string thumbSize: root.px <= 128 ? "normal" : root.px <= 256 ? "large" : root.px <= 512 ? "x-large" : "xx-large"
    readonly property bool dir: root.entry?.dir === true
    // A drawn folder holds a picture from inside it: its cover, else its first picture.
    readonly property bool cover: root.dir && root.size >= 48 && Prefs.get("covers") !== false && Prefs.get("icons") !== "system"
        && root.entry.role !== "trash"
    readonly property bool wantsThumb: root.allowThumb && !!root.entry && root.size >= 28
        && Prefs.get("thumbnails") !== "never" && !(Prefs.get("thumbnails") === "local" && root.entry.remote === true)
        && (root.cover || root.entry.thumb === true
            && !(["image", "pdf"].includes(root.entry.kind) && root.entry.size > Number(Prefs.get("thumbLimit")) * 1000000))
    property string thumbFile: ""
    property var asked: null

    implicitWidth: root.size
    implicitHeight: root.size
    opacity: root.dim ? 0.5 : (root.entry?.hidden ? 0.62 : 1)

    function ask(): void {
        if (root.asked) Core.unthumb(root.asked.path, root.asked.size, root.asked.mtime, root)
        root.asked = null
        if (!root.wantsThumb || root.path.length === 0) { root.thumbFile = ""; return }
        root.asked = { path: root.path, size: root.thumbSize, mtime: root.mtime }
        root.thumbFile = Core.thumb(root.path, root.thumbSize, root.mtime, root)
    }
    onPathChanged: root.ask()
    onMtimeChanged: root.ask()
    onThumbSizeChanged: root.ask()
    onWantsThumbChanged: root.ask()
    Component.onCompleted: root.ask()
    Component.onDestruction: if (root.asked) Core.unthumb(root.asked.path, root.asked.size, root.asked.mtime, root)

    readonly property bool showThumb: !root.dir && root.thumbFile.length > 0 && thumb.status !== Image.Error
    readonly property string systemIcon: {
        if (Prefs.get("icons") !== "system" || !root.entry) return ""
        const roles = { home: "user-home", desktop: "user-desktop", documents: "folder-documents", downloads: "folder-download",
            music: "folder-music", pictures: "folder-pictures", videos: "folder-videos", templates: "folder-templates", public: "folder-publicshare" }
        const name = root.entry.role ? roles[root.entry.role] : root.entry.icon
        return Quickshell.iconPath(name, true) || Quickshell.iconPath(root.entry.generic ?? "", true) || ""
    }

    Image {
        id: thumb
        anchors.centerIn: parent
        width: root.size + root.grow
        height: width
        visible: root.showThumb
        source: root.thumbFile.length > 0 && !root.dir ? Fmt.url(root.thumbFile) + "?" + root.mtime : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        sourceSize.width: root.px
        sourceSize.height: root.px
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        // A hairline round the picture so a white page still has an edge.
        Rectangle {
            visible: thumb.status === Image.Ready
            x: (parent.width - thumb.paintedWidth) / 2
            y: (parent.height - thumb.paintedHeight) / 2
            width: thumb.paintedWidth
            height: thumb.paintedHeight
            color: "transparent"
            border.width: 1
            border.color: Theme.light ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.1)
        }
        // A film plays: a mark in the corner.
        Rectangle {
            visible: root.badge && thumb.status === Image.Ready && root.entry?.kind === "video" && root.size >= 40
            width: Math.max(16, root.size * 0.26)
            height: width
            radius: width / 2
            x: (parent.width - thumb.paintedWidth) / 2 + Math.max(4, root.size * 0.05)
            y: (parent.height + thumb.paintedHeight) / 2 - height - Math.max(4, root.size * 0.05)
            color: Qt.rgba(0.03, 0.03, 0.04, 0.66)
            Glyph { anchors.centerIn: parent; name: "play_arrow"; fill: 1; size: parent.width * 0.68; color: "#ffffff" }
        }
    }
    Image {
        anchors.fill: parent
        visible: !root.showThumb && root.systemIcon.length > 0
        source: root.systemIcon
        sourceSize.width: root.px
        sourceSize.height: root.px
        asynchronous: true
        smooth: true
    }
    FileArt {
        visible: !root.showThumb && root.systemIcon.length === 0 || (root.showThumb && thumb.status !== Image.Ready && root.systemIcon.length === 0)
        anchors.fill: parent
        size: root.size
        folder: root.entry?.dir ?? false
        kind: root.entry?.kind ?? "file"
        role: root.entry?.role ?? ""
        ext: {
            const n = root.entry?.name ?? ""
            const at = Fmt.stem(n)
            return at < n.length ? n.slice(at + 1).split(".").pop() : ""
        }
        link: root.entry?.link ?? false
        broken: root.entry?.broken ?? false
        cover: root.cover ? root.thumbFile : ""
    }
}
