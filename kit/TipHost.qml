import QtQuick
import qs.services

// A tip under the control pointed at: what it does and its keys.
Item {
    id: root
    anchors.fill: parent
    z: 950
    property Item target: null
    property string text: ""
    property string keys: ""

    function show(item: Item, text: string, keys: string): void {
        root.target = item
        root.text = text
        root.keys = keys ?? ""
        const p = item.mapToItem(root, item.width / 2, item.height + Theme.dp(6))
        const w = tip.width
        tip.x = Math.max(Theme.dp(6), Math.min(root.width - w - Theme.dp(6), p.x - w / 2))
        tip.y = p.y + tip.height > root.height - Theme.dp(6) ? item.mapToItem(root, 0, 0).y - tip.height - Theme.dp(6) : p.y
        tip.shown = true
    }
    function hide(item: Item): void { if (!item || item === root.target) tip.shown = false }

    Rectangle {
        id: tip
        property bool shown: false
        width: row.implicitWidth + Theme.dp(18)
        height: Theme.dp(26)
        radius: height / 2
        color: Theme.light ? "#1c1d21" : Theme.mix(Theme.highest, Theme.ink, 0.1)
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.dp(8)
            Txt { text: root.text; size: Theme.small; color: Theme.light ? "#f2f3f5" : Theme.ink }
            Txt { visible: root.keys.length > 0; text: root.keys; size: Theme.small; color: Theme.light ? Qt.rgba(1, 1, 1, 0.6) : Theme.ink3 }
        }
    }
}
