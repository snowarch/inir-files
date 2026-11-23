import QtQuick
import qs.services

// A tip under the control pointed at, or beside a row of the places: what it does and its keys.
Item {
    id: root
    anchors.fill: parent
    z: 950
    property Item target: null
    property string text: ""
    property string keys: ""

    // Where the tip hangs from: the point under the control, or the one beside the row. The place itself is a binding,
    // as the Row under the text takes its new width only at the next layout.
    property point at: Qt.point(0, 0)
    property real above: 0
    property bool beside: false
    function show(item: Item, text: string, keys: string, beside: bool): void {
        root.target = item
        root.text = text
        root.keys = keys ?? ""
        root.beside = beside === true
        root.at = root.beside ? item.mapToItem(root, item.width + Theme.dp(4), item.height / 2) : item.mapToItem(root, item.width / 2, item.height + Theme.dp(6))
        root.above = item.mapToItem(root, 0, 0).y - Theme.dp(6)
        tip.shown = true
    }
    function hide(item: Item): void {
        if (item && item !== root.target) return
        if (tip.shown) cool.restart()
        tip.shown = false
    }
    // Warm right after a tip: the next control's tip comes at once and the tip glides over to it.
    readonly property bool warm: tip.shown || cool.running
    readonly property int delay: root.warm ? 60 : 650
    Timer { id: cool; interval: 600 }

    Rectangle {
        id: tip
        property bool shown: false
        width: row.implicitWidth + Theme.dp(20)
        height: Theme.dp(30)
        x: Math.round(root.beside ? Math.min(root.width - width - Theme.dp(6), root.at.x)
            : Math.max(Theme.dp(6), Math.min(root.width - width - Theme.dp(6), root.at.x - width / 2)))
        y: Math.round(root.beside ? root.at.y - height / 2 : root.at.y + height > root.height - Theme.dp(6) ? root.above - height : root.at.y)
        radius: Theme.dp(9)
        color: Theme.light ? "#1c1d21" : Theme.mix(Theme.highest, Theme.ink, 0.1)
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        Behavior on x { enabled: tip.visible; NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: tip.visible; NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
        Behavior on width { enabled: tip.visible; NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.dp(8)
            Txt { text: root.text; size: Theme.body; color: Theme.light ? "#f2f3f5" : Theme.ink }
            Txt { visible: root.keys.length > 0; text: root.keys; size: Theme.small; color: Theme.light ? Qt.rgba(1, 1, 1, 0.62) : Theme.ink2 }
        }
    }
}
