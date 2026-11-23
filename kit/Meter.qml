import QtQuick
import qs.services

// How full something is: a groove pressed in, filled in the accent, red past nine tenths.
Item {
    id: root
    property real value: 0
    implicitHeight: Theme.dp(4)
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.fillPress
    }
    Rectangle {
        height: parent.height
        radius: height / 2
        width: Math.max(height, parent.width * Math.max(0, Math.min(1, root.value)))
        color: root.value > 0.9 ? Theme.danger : Theme.accent
        Behavior on width { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutCubic } }
    }
}
