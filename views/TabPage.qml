import QtQuick
import qs.services
import qs.kit

// One tab: a pane, or two side by side. The pane last used is the one the bar, the keys and the aside follow.
Item {
    id: root
    required property var browser
    property string startPath: Core.home
    property bool split: false
    property real ratio: 0.5
    property var activePane: first
    readonly property var panes: root.split ? [first, second] : [first]
    readonly property string title: root.titleOf(root.activePane.folder)
    readonly property string glyph: root.glyphOf(root.activePane.folder)

    function titleOf(f: var): string {
        if (f.mode === "trash") return I18n.tr("Trash")
        if (f.mode === "recent") return I18n.tr("Recent")
        if (f.mode === "search") return I18n.tr("Search “%1”", f.query)
        if (f.path === Core.home) return I18n.tr("Home")
        if (f.path === "/") return I18n.tr("Computer")
        return Fmt.name(f.path)
    }
    function glyphOf(f: var): string {
        if (f.mode === "trash") return "delete"
        if (f.mode === "recent") return "schedule"
        if (f.mode === "search") return "search"
        if (f.path === Core.home) return "home"
        if (f.path === "/") return "hard_drive"
        return "folder"
    }
    function toggleSplit(): void {
        if (!root.split) {
            second.folder.go(root.activePane.folder.place, false)
            root.split = true
            second.activate()
        } else {
            const keep = root.activePane
            root.split = false
            if (keep === second) first.folder.go(second.folder.place)
            first.activate()
        }
    }
    function otherPane(pane: var): var { return root.split ? (pane === first ? second : first) : null }
    Component.onCompleted: first.folder.go(root.startPath, false)

    component Strip: Rectangle {
        id: strip
        required property var pane
        height: root.split ? Theme.dp(30) : 0
        visible: root.split
        color: "transparent"
        Row {
            anchors.verticalCenter: parent.verticalCenter
            x: Theme.dp(14)
            spacing: Theme.dp(7)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(7)
                height: width
                radius: width / 2
                color: strip.pane.active ? Theme.accent : Theme.ink3
                opacity: strip.pane.active ? 1 : 0.5
            }
            Glyph { anchors.verticalCenter: parent.verticalCenter; name: root.glyphOf(strip.pane.folder); size: Theme.dp(15); color: strip.pane.active ? Theme.ink : Theme.ink3; fill: strip.pane.active ? 1 : 0 }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                text: strip.pane.folder.mode === "folder" ? Fmt.pretty(strip.pane.folder.path) : root.titleOf(strip.pane.folder)
                size: Theme.small
                strong: strip.pane.active
                color: strip.pane.active ? Theme.ink : Theme.ink3
                elide: Text.ElideMiddle
                // Clear of the close button: the row's start (50) and the button with its margins (38).
                width: Math.min(implicitWidth, strip.width - Theme.dp(88))
            }
        }
        Act {
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(6)
            anchors.verticalCenter: parent.verticalCenter
            size: Theme.dp(24)
            glyphSize: Theme.dp(15)
            glyph: "close"
            tip: I18n.tr("Close this side")
            onClicked: { root.activePane = strip.pane; root.toggleSplit() }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
        TapHandler { onTapped: strip.pane.activate() }
    }

    Item {
        id: left
        width: root.split ? Math.round((root.width - 1) * root.ratio) : root.width
        height: root.height
        Strip { id: leftStrip; pane: first; width: parent.width }
        Pane {
            id: first
            browser: root.browser
            page: root
            anchors.top: leftStrip.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            focus: true
        }
    }
    Rectangle {
        id: divider
        visible: root.split
        x: left.width
        width: 1
        height: root.height
        color: Theme.line
        MouseArea {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Theme.dp(9)
            height: parent.height
            cursorShape: Qt.SplitHCursor
            onPositionChanged: mouse => {
                if (!pressed) return
                const x = mapToItem(root, mouse.x, 0).x
                root.ratio = Math.max(0.22, Math.min(0.78, x / root.width))
            }
            onDoubleClicked: root.ratio = 0.5
        }
    }
    Item {
        visible: root.split
        x: left.width + 1
        width: root.width - left.width - 1
        height: root.height
        Strip { id: rightStrip; pane: second; width: parent.width }
        Pane {
            id: second
            browser: root.browser
            page: root
            anchors.top: rightStrip.bottom
            anchors.bottom: parent.bottom
            width: parent.width
        }
    }
}
