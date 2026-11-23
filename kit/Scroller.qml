import QtQuick
import QtQuick.Controls.Basic
import qs.services

// A thin bar along the edge, there while scrolling or pointed at.
ScrollBar {
    id: root
    policy: ScrollBar.AsNeeded
    minimumSize: 0.06
    padding: Theme.dp(2)
    contentItem: Rectangle {
        implicitWidth: root.hovered || root.pressed ? Theme.dp(7) : Theme.dp(4)
        implicitHeight: implicitWidth
        radius: width / 2
        color: root.pressed ? Theme.ink2 : Theme.ink3
        opacity: root.active ? (root.hovered ? 0.8 : 0.5) : 0
        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
        Behavior on implicitWidth { NumberAnimation { duration: Theme.fast } }
    }
    background: Item {}
}
