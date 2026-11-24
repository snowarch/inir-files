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
    // The picture fills the whole square and is cut to it, as the gallery shows it, rather than fitting inside.
    property bool crop: false

    readonly property string path: root.entry?.path ?? ""
    readonly property real mtime: root.entry?.mtime ?? 0
    readonly property real dpr: root.Window.window?.devicePixelRatio ?? 1
    readonly property real px: (root.size + root.grow) * root.dpr
    readonly property string thumbSize: Core.thumbSize(root.px, root.crop)
    // Decode at the freedesktop bucket size, not the exact pixel width: zooming inside a bucket scales the resident GPU
    // texture immediately with zero disk re-decode.
    readonly property int thumbPx: root.thumbSize === "normal" ? 128 : root.thumbSize === "large" ? 256 : root.thumbSize === "x-large" ? 512 : 1024
    readonly property int iconPx: root.px <= 48 ? 48 : root.px <= 128 ? 128 : 256
    readonly property bool dir: root.entry?.dir === true
    // A drawn folder holds a picture from inside it: its cover, else its first picture.
    readonly property bool cover: root.dir && root.size >= 48 && Prefs.get("covers") !== false && Prefs.get("icons") !== "system"
        && root.entry.role !== "trash"
    readonly property bool wantsThumb: root.allowThumb && !!root.entry && root.size >= 28
        && (root.cover ? Core.thumbsOn(root.entry) : Core.wantsThumb(root.entry))
    property string thumbFile: ""
    // The core's answer is in: a picture, or none to be had.
    property bool thumbSettled: true
    property var asked: null

    implicitWidth: root.size
    implicitHeight: root.size
    opacity: root.dim ? 0.5 : (root.entry?.hidden ? 0.62 : 1)

    function ask(): void {
        if (root.asked) Core.unthumb(root.asked.path, root.asked.size, root.asked.mtime, root)
        root.asked = null
        if (!root.wantsThumb || root.path.length === 0) { root.thumbFile = ""; root.thumbSettled = true; return }
        root.asked = { path: root.path, size: root.thumbSize, mtime: root.mtime }
        const known = Core.thumb(root.path, root.thumbSize, root.mtime, root)
        root.thumbFile = known ?? ""
        root.thumbSettled = known !== null
    }
    onPathChanged: root.ask()
    onMtimeChanged: root.ask()
    onThumbSizeChanged: root.ask()
    onWantsThumbChanged: root.ask()
    Component.onCompleted: root.ask()
    Component.onDestruction: if (root.asked) Core.unthumb(root.asked.path, root.asked.size, root.asked.mtime, root)

    readonly property bool showThumb: !root.dir && root.thumbFile.length > 0 && thumb.status !== Image.Error
    readonly property bool thumbReady: root.showThumb && thumb.status === Image.Ready
    // A photo or a film on its way: a quiet tile where it lands, not an icon that gives way to it a moment later.
    readonly property bool awaiting: !root.dir && !root.thumbReady && (root.entry?.kind === "image" || root.entry?.kind === "video")
        && (!root.thumbSettled || root.showThumb)
    // A launcher wears its app's icon, with either set of icons: a theme name or a file.
    readonly property string appIcon: {
        const a = root.entry?.appIcon ?? ""
        return a.length === 0 ? "" : a.startsWith("/") ? Fmt.url(a) : Quickshell.iconPath(a, true) || ""
    }
    readonly property string systemIcon: {
        if (root.appIcon.length > 0) return root.appIcon
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
        fillMode: root.crop ? Image.PreserveAspectCrop : Image.PreserveAspectFit
        clip: root.crop
        asynchronous: true
        smooth: true
        // Bucket-sized decode: zooming inside a bucket never drops and re-decodes the texture.
        sourceSize.width: root.thumbPx
        sourceSize.height: root.thumbPx
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        // A hairline round the picture so a white page still has an edge.
        Rectangle {
            visible: thumb.status === Image.Ready && !root.crop
            x: (parent.width - thumb.paintedWidth) / 2
            y: (parent.height - thumb.paintedHeight) / 2
            width: thumb.paintedWidth
            height: thumb.paintedHeight
            color: "transparent"
            border.width: 1
            border.color: Theme.light ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.1)
        }
        // A film plays: a mark in the corner.
        // The Loader takes its size from the mark, so it is placed by the picture's own edges.
        Loader {
            readonly property real side: root.crop ? Math.max(18, Math.min(28, root.size * 0.14)) : Math.max(16, root.size * 0.26)
            readonly property real inset: root.crop ? Math.max(6, root.size * 0.04) : Math.max(4, root.size * 0.05)
            // A cropped picture paints past the square: its edges are the square's.
            readonly property real shownW: Math.min(thumb.paintedWidth, thumb.width)
            readonly property real shownH: Math.min(thumb.paintedHeight, thumb.height)
            active: root.badge && thumb.status === Image.Ready && root.entry?.kind === "video" && root.size >= 40
            x: (thumb.width - shownW) / 2 + inset
            y: (thumb.height + shownH) / 2 - side - inset
            sourceComponent: Rectangle {
            width: parent ? parent.side : 16
            height: width
            radius: width / 2
            color: Qt.rgba(0.03, 0.03, 0.04, 0.66)
            Glyph { anchors.centerIn: parent; name: "play_arrow"; fill: 1; size: parent.width * 0.68; color: "#ffffff" }
        } }
    }
    Rectangle {
        // Fades as the picture fades in over it.
        opacity: root.awaiting ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        anchors.centerIn: parent
        width: root.crop ? root.size + root.grow : Math.round((root.size + root.grow) * 0.94)
        height: root.crop ? width : Math.round(width * (root.entry?.kind === "video" ? 0.5625 : 0.75))
        radius: root.crop ? 0 : Math.max(2, Math.round(root.size * 0.04))
        color: Theme.fill
    }
    Loader {
        anchors.fill: parent
        active: !root.thumbReady && !root.awaiting && root.systemIcon.length > 0
        sourceComponent: Image {
            source: root.systemIcon
            sourceSize.width: root.iconPx
            sourceSize.height: root.iconPx
            asynchronous: true
            smooth: true
        }
    }
    Loader {
        anchors.fill: parent
        active: !root.thumbReady && !root.awaiting && root.systemIcon.length === 0
        sourceComponent: art
    }
    Component { id: art; FileArt {
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
    } }
}
