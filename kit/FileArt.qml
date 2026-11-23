import QtQuick
import QtQuick.Shapes
import qs.services

// A file or folder drawn, not looked up: a folder is the accent as two sheets with a paper between them and its
// role marked on the front; a file is a page with its corner folded, its kind in the middle and its type on a tag.
// Small, each is its glyph alone.
Item {
    id: root
    property bool folder: false
    property string kind: "file"
    property string role: ""
    property string ext: ""
    property bool link: false
    property bool broken: false
    property bool locked: false
    property real size: 64
    implicitWidth: root.size
    implicitHeight: root.size

    readonly property bool tiny: root.size < 30
    readonly property var roleGlyphs: ({ home: "home", desktop: "desktop_windows", documents: "description", downloads: "download",
        music: "music_note", pictures: "image", videos: "movie", templates: "dashboard_customize", public: "public", trash: "delete" })
    readonly property var kindGlyphs: ({ image: "image", video: "movie", audio: "music_note", archive: "folder_zip", disk: "album",
        pdf: "picture_as_pdf", app: "widgets", document: "description", font: "font_download", executable: "terminal",
        text: "notes", code: "code", file: "draft", folder: "folder" })
    readonly property color kindTint: Theme.kindColor(root.kind)

    // ---- small: the glyph alone
    Glyph {
        visible: root.tiny
        anchors.centerIn: parent
        size: root.size
        name: root.folder ? (root.roleGlyphs[root.role] && root.role !== "trash" ? "folder_special" : "folder") : (root.kindGlyphs[root.kind] ?? "draft")
        fill: 1
        color: root.folder ? Theme.folderFront : root.kindTint
    }

    // ---- a folder
    Item {
        visible: !root.tiny && root.folder
        anchors.fill: parent
        readonly property real s: root.size
        readonly property real r: Math.max(2, s * 0.085)
        Rectangle { // the tab
            x: parent.s * 0.03; y: parent.s * 0.1
            width: parent.s * 0.4; height: parent.s * 0.2
            radius: parent.r
            color: Theme.folderBack
        }
        Rectangle { // the back sheet
            x: parent.s * 0.03; y: parent.s * 0.16
            width: parent.s * 0.94; height: parent.s * 0.7
            radius: parent.r
            color: Theme.folderBack
        }
        Rectangle { // the paper between
            x: parent.s * 0.11; y: parent.s * 0.22
            width: parent.s * 0.78; height: parent.s * 0.4
            radius: parent.r * 0.6
            color: Theme.paper
            rotation: -2.5
            antialiasing: true
        }
        Rectangle { // the front sheet
            id: front
            x: parent.s * 0.03; y: parent.s * 0.31
            width: parent.s * 0.94; height: parent.s * 0.55
            radius: parent.r
            color: Theme.folderFront
            Rectangle { // light along its top
                x: parent.radius; width: parent.width - parent.radius * 2
                height: Math.max(1, root.size / 96)
                color: Qt.rgba(1, 1, 1, Theme.light ? 0.55 : 0.32)
            }
            Glyph {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: root.size * 0.01
                visible: (root.roleGlyphs[root.role] ?? "") !== "" && root.size >= 40
                name: root.roleGlyphs[root.role] ?? ""
                size: root.size * 0.28
                fill: 1
                color: Theme.folderMark
            }
        }
    }

    // ---- a page
    Item {
        id: page
        visible: !root.tiny && !root.folder
        anchors.fill: parent
        readonly property real s: root.size
        readonly property real w: s * 0.72
        readonly property real h: s * 0.9
        readonly property real x0: (s - w) / 2 + s * 0.02
        readonly property real y0: (s - h) / 2
        readonly property real f: w * 0.3
        readonly property real r: Math.max(2, s * 0.07)
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: Theme.paper
                strokeColor: Theme.light ? Qt.rgba(0, 0, 0, 0.1) : "transparent"
                strokeWidth: Theme.light ? 1 : 0
                joinStyle: ShapePath.RoundJoin
                startX: page.x0 + page.r; startY: page.y0
                PathLine { x: page.x0 + page.w - page.f; y: page.y0 }
                PathLine { x: page.x0 + page.w; y: page.y0 + page.f }
                PathLine { x: page.x0 + page.w; y: page.y0 + page.h - page.r }
                PathArc { x: page.x0 + page.w - page.r; y: page.y0 + page.h; radiusX: page.r; radiusY: page.r }
                PathLine { x: page.x0 + page.r; y: page.y0 + page.h }
                PathArc { x: page.x0; y: page.y0 + page.h - page.r; radiusX: page.r; radiusY: page.r }
                PathLine { x: page.x0; y: page.y0 + page.r }
                PathArc { x: page.x0 + page.r; y: page.y0; radiusX: page.r; radiusY: page.r }
            }
            ShapePath { // the fold
                fillColor: Theme.paperFold
                strokeColor: "transparent"
                startX: page.x0 + page.w - page.f; startY: page.y0
                PathLine { x: page.x0 + page.w - page.f; y: page.y0 + page.f - page.r * 0.6 }
                PathQuad { x: page.x0 + page.w - page.f + page.r * 0.6; y: page.y0 + page.f; controlX: page.x0 + page.w - page.f; controlY: page.y0 + page.f }
                PathLine { x: page.x0 + page.w; y: page.y0 + page.f }
                PathLine { x: page.x0 + page.w - page.f; y: page.y0 }
            }
        }
        Glyph {
            x: page.x0 + (page.w - width) / 2
            y: page.y0 + page.h * 0.42 - height / 2
            name: root.kindGlyphs[root.kind] ?? "draft"
            size: root.size * 0.32
            fill: 1
            color: root.kindTint
        }
        // Its type on a tag over the lower edge.
        Rectangle {
            visible: root.size >= 44 && root.ext.length > 0 && root.ext.length <= 5
            x: page.x0 - root.size * 0.04
            y: page.y0 + page.h * 0.7
            height: Math.round(root.size * 0.17)
            width: tag.implicitWidth + height * 0.8
            radius: height * 0.3
            color: root.kindTint
            Txt {
                id: tag
                anchors.centerIn: parent
                text: root.ext.toUpperCase()
                size: Math.max(7, root.size * 0.105)
                strong: true
                font.letterSpacing: root.size * 0.004
                color: Theme.luminance(root.kindTint) > 0.4 ? "#101114" : "#ffffff"
            }
        }
    }

    // A link carries an arrow; a broken one, a cross.
    Rectangle {
        visible: root.link && root.size >= 24
        width: Math.max(12, root.size * 0.28)
        height: width
        radius: width / 2
        x: root.size * 0.02
        y: root.size - height - root.size * 0.02
        color: Theme.raised
        Glyph {
            anchors.centerIn: parent
            name: root.broken ? "link_off" : "north_east"
            size: parent.width * 0.7
            weight: 600
            color: root.broken ? Theme.danger : Theme.ink
        }
    }
    Rectangle {
        visible: root.locked && root.size >= 24
        width: Math.max(12, root.size * 0.28)
        height: width
        radius: width / 2
        x: root.size - width - root.size * 0.02
        y: root.size - height - root.size * 0.02
        color: Theme.raised
        Glyph { anchors.centerIn: parent; name: "lock"; size: parent.width * 0.66; fill: 1; color: Theme.ink2 }
    }
}
