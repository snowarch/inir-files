import QtQuick
import Quickshell
import qs.services

// One choice of a few, side by side in a pressed track; the chosen one raised.
Inset {
    id: root
    property var options: []      // [{ value, glyph, text, tip }]
    property var value
    signal chosen(var value)
    radius: height / 2
    implicitHeight: Theme.dp(32)
    implicitWidth: row.implicitWidth + Theme.dp(6)

    readonly property int index: root.options.findIndex(o => o.value === root.value)

    Rectangle {
        id: knob
        visible: root.index >= 0
        y: Theme.dp(3)
        height: parent.height - Theme.dp(6)
        radius: height / 2
        color: Theme.light ? "#ffffff" : Theme.mix(Theme.high, Theme.ink, 0.12)
        x: (row.children[root.index]?.x ?? 0) + Theme.dp(3)
        width: row.children[root.index]?.width ?? 0
        Behavior on x { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }
        Rectangle { x: parent.radius * 0.6; width: parent.width - parent.radius * 1.2; height: 1; color: Theme.edge }
    }
    Row {
        id: row
        x: Theme.dp(3)
        anchors.verticalCenter: parent.verticalCenter
        Repeater {
            model: root.options
            delegate: Item {
                id: seg
                required property var modelData
                required property int index
                readonly property bool on: root.index === seg.index
                width: content.implicitWidth + Theme.dp(seg.modelData.text ? 22 : 16)
                height: root.height - Theme.dp(6)
                Row {
                    id: content
                    anchors.centerIn: parent
                    spacing: Theme.dp(5)
                    Glyph {
                        visible: !!seg.modelData.glyph
                        anchors.verticalCenter: parent.verticalCenter
                        name: seg.modelData.glyph ?? ""
                        size: Theme.dp(17)
                        color: seg.on ? Theme.ink : Theme.ink2
                        fill: seg.on ? 1 : 0
                    }
                    Txt {
                        visible: !!seg.modelData.text
                        anchors.verticalCenter: parent.verticalCenter
                        text: seg.modelData.text ?? ""
                        size: Theme.small
                        strong: seg.on
                        color: seg.on ? Theme.ink : Theme.ink2
                    }
                }
                MouseArea {
                    id: segMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chosen(seg.modelData.value)
                }
                Timer {
                    interval: 650
                    running: segMouse.containsMouse && !!seg.modelData.tip
                    onTriggered: seg.QsWindow.window?.tips?.show(seg, seg.modelData.tip, seg.modelData.keys ?? "")
                }
                Connections {
                    target: segMouse
                    function onContainsMouseChanged() { if (!segMouse.containsMouse) seg.QsWindow.window?.tips?.hide(seg) }
                }
            }
        }
    }
}
