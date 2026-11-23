import QtQuick
import QtQuick.Effects
import qs.services

// Menus inside the window: a card at the pointer, a submenu beside its row, keys to walk them.
// An entry: { text, glyph, icon, keys, run, danger, enabled, checked, sub: [entries] }, { separator: true } or
// { header: "text" }.
FocusScope {
    id: root
    anchors.fill: parent
    visible: root.levels.length > 0
    z: 900

    property var levels: []        // [{ entries, x, y, current }]
    property Item returnFocus: null

    function open(entries: var, x: real, y: real): void {
        root.returnFocus = root.Window.window?.activeFocusItem ?? null
        root.levels = [{ entries: entries.filter(e => e), x: x, y: y, current: -1 }]
        root.forceActiveFocus()
    }
    function openAt(entries: var, item: Item, below: bool): void {
        const p = item.mapToItem(root, 0, below ? item.height + Theme.dp(4) : 0)
        root.open(entries, p.x, p.y)
    }
    function close(): void {
        root.levels = []
        if (root.returnFocus) root.returnFocus.forceActiveFocus()
    }
    function setCurrent(level: int, index: int): void {
        const l = root.levels.slice(0, level + 1)
        l[level] = Object.assign({}, l[level], { current: index })
        root.levels = l
    }
    function openSub(level: int, index: int, rowItem: Item): void {
        const e = root.levels[level].entries[index]
        if (!e?.sub) return
        const p = rowItem.mapToItem(root, rowItem.width + Theme.dp(4), -Theme.dp(6))
        const l = root.levels.slice(0, level + 1)
        l[level] = Object.assign({}, l[level], { current: index })
        l.push({ entries: e.sub.filter(s => s), x: p.x, y: p.y, current: -1, beside: rowItem.mapToItem(root, -Theme.dp(4), 0).x })
        root.levels = l
    }
    function activate(level: int, index: int): void {
        const e = root.levels[level]?.entries[index]
        if (!e || e.separator || e.header || e.enabled === false) return
        if (e.sub) return
        root.close()
        if (e.run) e.run()
    }
    function selectable(e: var): bool { return e && !e.separator && !e.header && e.enabled !== false }
    function step(dir: int): void {
        const level = root.levels.length - 1
        const l = root.levels[level]
        let i = l.current
        for (let n = 0; n < l.entries.length; n++) {
            i = (i + dir + l.entries.length) % l.entries.length
            if (root.selectable(l.entries[i])) break
        }
        root.setCurrent(level, i)
    }

    Keys.onPressed: event => {
        const level = root.levels.length - 1
        if (level < 0) return
        const l = root.levels[level]
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left && level > 0) {
            if (level > 0) root.levels = root.levels.slice(0, level)
            else root.close()
        } else if (event.key === Qt.Key_Down) root.step(1)
        else if (event.key === Qt.Key_Up) root.step(-1)
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const e = l.entries[l.current]
            if (e?.sub) root.openSub(level, l.current, cards.itemAt(level).rowAt(l.current))
            else if (event.key !== Qt.Key_Right) root.activate(level, l.current)
        }
        event.accepted = true
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: root.close()
        onWheel: wheel => wheel.accepted = true
    }

    FontMetrics { id: metrics; font.family: Theme.sans; font.pixelSize: Theme.body }

    Repeater {
        id: cards
        model: root.levels.length
        delegate: Item {
            id: card
            required property int index
            readonly property var level: root.levels[card.index] ?? ({ entries: [] })
            readonly property bool anyGlyph: card.level.entries.some(e => e.glyph || e.icon || e.checked !== undefined)
            readonly property real need: {
                let w = 0
                for (const e of card.level.entries) {
                    const t = metrics.advanceWidth(e.text ?? e.header ?? "") + (e.keys ? metrics.advanceWidth(e.keys) + Theme.dp(28) : 0) + (e.sub ? Theme.dp(22) : 0)
                    w = Math.max(w, t)
                }
                return w + Theme.dp(card.anyGlyph ? 52 : 28)
            }
            width: Math.max(Theme.dp(190), Math.min(Theme.dp(380), card.need))
            height: col.implicitHeight + Theme.dp(12)
            // Kept inside the window; a submenu that does not fit on the right opens on the left.
            x: {
                const want = card.level.x
                if (want + width <= root.width - Theme.dp(6)) return want
                return card.level.beside !== undefined ? Math.max(Theme.dp(6), card.level.beside - width) : Math.max(Theme.dp(6), root.width - width - Theme.dp(6))
            }
            y: Math.max(Theme.dp(6), Math.min(card.level.y, root.height - height - Theme.dp(6)))
            function rowAt(i: int): Item { return rows.itemAt(i) }

            opacity: 0
            scale: 0.97
            Component.onCompleted: { opacity = 1; scale = 1 }
            Behavior on opacity { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
            transformOrigin: Item.TopLeft

            RectangularShadow {
                anchors.fill: bg
                radius: bg.radius
                blur: Theme.dp(24)
                offset.y: Theme.dp(6)
                color: Theme.shadow
            }
            Rectangle {
                id: bg
                anchors.fill: parent
                radius: Theme.dp(14)
                color: Theme.raised
                border.width: Theme.light ? 0 : 1
                border.color: Theme.line
                Rectangle { x: parent.radius; width: parent.width - parent.radius * 2; y: 1; height: 1; color: Theme.edge }
            }
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
            Column {
                id: col
                x: Theme.dp(6)
                y: Theme.dp(6)
                width: parent.width - Theme.dp(12)
                Repeater {
                    id: rows
                    model: card.level.entries
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool sep: !!row.modelData.separator
                        readonly property bool header: row.modelData.header !== undefined
                        readonly property bool on: card.level.current === row.index
                        readonly property bool usable: row.modelData.enabled !== false
                        width: col.width
                        height: row.sep ? Theme.dp(9) : row.header ? Theme.dp(26) : Theme.dp(32)
                        Rectangle {
                            visible: row.sep
                            anchors.centerIn: parent
                            width: parent.width - Theme.dp(16)
                            height: 1
                            color: Theme.line
                        }
                        Caption {
                            visible: row.header
                            x: Theme.dp(10)
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.dp(4)
                            text: row.modelData.header ?? ""
                        }
                        Rectangle {
                            visible: !row.sep && !row.header
                            anchors.fill: parent
                            radius: Theme.dp(9)
                            color: row.on && row.usable ? (row.modelData.danger ? Theme.alpha(Theme.danger, 0.16) : Theme.fillHover) : "transparent"
                        }
                        Item {
                            id: lead
                            visible: !row.sep && !row.header && card.anyGlyph
                            x: Theme.dp(8)
                            width: Theme.dp(22)
                            height: parent.height
                            Glyph {
                                anchors.centerIn: parent
                                visible: !row.modelData.icon
                                name: row.modelData.checked === true ? "check" : row.modelData.checked === false ? "" : (row.modelData.glyph ?? "")
                                size: Theme.dp(18)
                                weight: row.modelData.checked === true ? 600 : 400
                                color: row.modelData.danger ? Theme.danger : row.modelData.checked === true ? Theme.accentInk : Theme.ink2
                            }
                            Image {
                                anchors.centerIn: parent
                                visible: !!row.modelData.icon
                                source: row.modelData.icon ?? ""
                                width: Theme.dp(18); height: width
                                sourceSize.width: width * 2; sourceSize.height: height * 2
                                asynchronous: true
                            }
                        }
                        Txt {
                            visible: !row.sep && !row.header
                            anchors.left: card.anyGlyph ? lead.right : parent.left
                            anchors.leftMargin: card.anyGlyph ? Theme.dp(6) : Theme.dp(12)
                            anchors.right: keys.left
                            anchors.rightMargin: Theme.dp(10)
                            height: parent.height
                            text: row.modelData.text ?? ""
                            color: row.modelData.danger ? Theme.danger : Theme.ink
                            opacity: row.usable ? 1 : 0.4
                        }
                        Txt {
                            id: keys
                            visible: !row.sep && !row.header
                            anchors.right: chevron.visible ? chevron.left : parent.right
                            anchors.rightMargin: Theme.dp(10)
                            height: parent.height
                            text: row.modelData.keys ?? ""
                            size: Theme.small
                            color: Theme.ink3
                        }
                        Glyph {
                            id: chevron
                            visible: !!row.modelData.sub
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.dp(6)
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevron_right"
                            size: Theme.dp(17)
                            color: Theme.ink3
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !row.sep && !row.header
                            hoverEnabled: true
                            onContainsMouseChanged: if (containsMouse) {
                                root.setCurrent(card.index, row.index)
                                if (row.modelData.sub) subTimer.restart()
                                else subTimer.stop()
                            }
                            onClicked: row.modelData.sub ? root.openSub(card.index, row.index, row) : root.activate(card.index, row.index)
                        }
                        Timer {
                            id: subTimer
                            interval: 180
                            onTriggered: if (row.on) root.openSub(card.index, row.index, row)
                        }
                    }
                }
            }
        }
    }
}
