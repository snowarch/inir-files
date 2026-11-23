import QtQuick
import qs.services

// The column on the right that tells about what is chosen. Its edge drags to resize it.
Item {
    id: root
    required property var browser
    readonly property bool shown: Prefs.get("aside") === true && root.browser.asideRoom
    property real open: Prefs.recall("asideWidth", Theme.dp(300))
    width: root.shown ? root.open : 0
    clip: true
    Behavior on width { enabled: !edge.pressed; NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }

    Loader {
        x: 0
        width: root.open
        height: parent.height
        active: root.shown || root.width > 0
        sourceComponent: Preview { browser: root.browser }
    }
    MouseArea {
        id: edge
        width: Theme.dp(6)
        height: parent.height
        x: -width / 2
        cursorShape: Qt.SizeHorCursor
        property real startX: 0
        property real startW: 0
        onPressed: mouse => { startX = mapToItem(null, mouse.x, 0).x; startW = root.open }
        onPositionChanged: mouse => {
            if (!pressed) return
            const dx = startX - mapToItem(null, mouse.x, 0).x
            root.open = Math.max(Theme.dp(240), Math.min(Theme.dp(560), startW + dx))
        }
        onReleased: Prefs.remember("asideWidth", root.open)
        onDoubleClicked: { root.open = Theme.dp(300); Prefs.remember("asideWidth", root.open) }
    }
}
