import QtQuick
import qs.services
import qs.kit

// One tab: a pane, or two side by side. The pane last used is the one the bar, the keys and the aside follow.
Item {
    id: root
    required property var browser
    property string startPath: Core.home
    property var startChosen: []
    property bool split: false
    property real ratio: 0.5
    property var activePane: first
    property string pendingSplitPlace: ""
    readonly property var secondPane: secondLoader.item
    readonly property var panes: root.split && root.secondPane ? [first, root.secondPane] : [first]
    readonly property string title: root.titleOf(root.activePane.folder)
    readonly property string glyph: root.glyphOf(root.activePane.folder)

    function titleOf(f: var): string {
        if (f.mode === "start") return I18n.tr("Start")
        if (f.mode === "trash") return I18n.tr("Trash")
        if (f.mode === "recent") return I18n.tr("Recent")
        if (f.mode === "search") return I18n.tr("Search “%1”", f.query)
        if (f.path === Core.home) return I18n.tr("Home")
        if (f.path === "/") return I18n.tr("Computer")
        return Fmt.name(f.path)
    }
    function glyphOf(f: var): string {
        if (f.mode === "start") return "space_dashboard"
        if (f.mode === "trash") return "delete"
        if (f.mode === "recent") return "schedule"
        if (f.mode === "search") return "search"
        if (f.path === Core.home) return "home"
        if (f.path === "/") return "hard_drive"
        return "folder"
    }
    function openSplit(place: string): void {
        const dest = place && place.length > 0 ? place : root.activePane.folder.place
        root.pendingSplitPlace = dest
        if (!root.split) {
            root.split = true
            if (root.secondPane) {
                root.secondPane.folder.go(dest, false)
                root.secondPane.activate()
            }
        } else if (root.secondPane) {
            root.secondPane.folder.go(dest, false)
            root.secondPane.activate()
        }
    }
    function toggleSplit(): void {
        if (!root.split) {
            root.openSplit(root.activePane.folder.place)
        } else {
            const keep = root.activePane
            const secondPlace = root.secondPane ? root.secondPane.folder.place : ""
            root.activePane = first
            root.split = false
            if (keep !== first && secondPlace.length > 0) first.folder.go(secondPlace)
            first.activate()
            Qt.callLater(gc)
        }
    }
    function detachPane(pane: var): void {
        if (!root.split || !root.secondPane) return
        const place = pane.folder.place
        const keep = pane === first ? root.secondPane : first
        root.activePane = keep
        root.toggleSplit()
        root.browser.newWindow(place)
    }
    function otherPane(pane: var): var { return root.split && root.secondPane ? (pane === first ? root.secondPane : first) : null }
    Component.onCompleted: {
        first.folder.choose = root.startChosen
        first.folder.go(root.startPath, false)
    }

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
                // Clear of the action buttons on the right: row start (50) and two buttons with margins (66).
                width: Math.min(implicitWidth, Math.max(Theme.dp(40), strip.width - Theme.dp(116)))
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(2)
            Act {
                size: Theme.dp(24)
                glyphSize: Theme.dp(15)
                glyph: "open_in_new"
                tip: I18n.tr("Move to new window")
                onClicked: root.detachPane(strip.pane)
            }
            Act {
                size: Theme.dp(24)
                glyphSize: Theme.dp(15)
                glyph: "close"
                tip: I18n.tr("Close this side")
                onClicked: { root.activePane = strip.pane === first ? (root.secondPane ?? first) : first; root.toggleSplit() }
            }
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
            id: splitEdge
            anchors.horizontalCenter: parent.horizontalCenter
            width: Theme.dp(9)
            height: parent.height
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            onPositionChanged: mouse => {
                if (!pressed) return
                const x = mapToItem(root, mouse.x, 0).x
                root.ratio = Math.max(0.22, Math.min(0.78, x / root.width))
            }
            onDoubleClicked: root.ratio = 0.5
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Theme.dp(2)
                height: parent.height
                color: splitEdge.pressed ? Theme.accent : Theme.ink3
                opacity: splitEdge.pressed ? 0.85 : splitEdge.containsMouse ? 0.38 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.hoverMs } }
            }
        }
    }
    Item {
        visible: root.split
        x: left.width + 1
        width: root.width - left.width - 1
        height: root.height
        Loader {
            id: rightStripLoader
            active: root.split && !!root.secondPane
            width: parent.width
            height: active ? Theme.dp(30) : 0
            sourceComponent: Strip { pane: root.secondPane; width: parent.width }
        }
        Loader {
            id: secondLoader
            active: root.split
            anchors.top: rightStripLoader.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            sourceComponent: Pane {
                browser: root.browser
                page: root
            }
            onLoaded: {
                const dest = root.pendingSplitPlace.length > 0 ? root.pendingSplitPlace : first.folder.place
                item.folder.go(dest, false)
                item.activate()
            }
        }
    }
}
