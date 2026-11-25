import QtQuick
import qs.services

// The column on the right that tells about what is chosen. Its edge drags to resize it.
Item {
    id: root
    required property var browser
    readonly property bool shown: Prefs.get("aside") === true && root.browser.asideRoom
    property real open: Prefs.recall("asideWidth", Theme.dp(300))
    readonly property real maxWidth: Math.max(Theme.dp(220), Math.min(Theme.dp(560), root.browser.stage.width - (root.browser.railDocked ? root.browser.railWidth : 0) - Theme.dp(380)))
    readonly property real effectiveWidth: Math.max(Theme.dp(220), Math.min(root.open, root.maxWidth))
    width: root.shown ? root.effectiveWidth : 0
    clip: true
    Behavior on width { enabled: !edge.pressed; NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }

    Loader {
        x: 0
        width: root.effectiveWidth
        height: parent.height
        active: root.shown || root.width > 0
        sourceComponent: Preview { browser: root.browser }
    }
    MouseArea {
        id: edge
        width: Theme.dp(8)
        height: parent.height
        x: -width / 2
        hoverEnabled: true
        cursorShape: Qt.SizeHorCursor
        property real startX: 0
        property real startW: 0
        onPressed: mouse => { startX = mapToItem(null, mouse.x, 0).x; startW = root.effectiveWidth }
        onPositionChanged: mouse => {
            if (!pressed) return
            const dx = startX - mapToItem(null, mouse.x, 0).x
            root.open = Math.round(Math.max(Theme.dp(220), Math.min(root.maxWidth, startW + dx)))
        }
        onReleased: Prefs.remember("asideWidth", Math.round(root.open))
        onDoubleClicked: { root.open = Theme.dp(300); Prefs.remember("asideWidth", Math.round(root.open)) }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: Theme.dp(16)
            width: Theme.dp(2)
            height: parent.height - Theme.dp(32)
            radius: 1
            color: edge.pressed ? Theme.accent : Theme.ink3
            opacity: edge.pressed ? 0.85 : edge.containsMouse ? 0.38 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.hoverMs } }
        }
    }
}
