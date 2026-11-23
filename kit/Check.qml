import QtQuick
import qs.services

// A box to tick, with its words beside it.
Item {
    id: root
    property bool checked: false
    property string text: ""
    signal toggled(bool value)
    implicitHeight: Theme.dp(26)
    implicitWidth: box.width + (root.text.length > 0 ? label.implicitWidth + Theme.dp(8) : 0)

    Rectangle {
        id: box
        width: Theme.dp(18)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        radius: Theme.round(5)
        color: root.checked ? Theme.accent : Theme.inset
        border.width: root.checked ? 0 : 1
        border.color: Theme.line
        Glyph {
            anchors.centerIn: parent
            visible: root.checked
            name: "check"
            size: Theme.dp(15)
            weight: 600
            color: Theme.inkAccent
        }
    }
    Txt {
        id: label
        anchors.left: box.right
        anchors.leftMargin: Theme.dp(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
