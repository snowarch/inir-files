import QtQuick
import QtQuick.Effects
import qs.services

// Menus inside the window: a card at the pointer, a submenu beside its row, keys to walk them.
// An entry: { text, glyph, icon, keys, note, run, danger, enabled, checked, current, tint, fill, keep, sub: [entries] },
// { separator: true } or { header: "text" }. An entry with keep runs and leaves the menu open (Move up, Move down).
FocusScope {
    id: root
    anchors.fill: parent
    visible: root.levels.length > 0
    z: 900

    // The open cards and the row each points at, kept apart: a card's rows are made again only when its entries change,
    // so hovering a row never rebuilds the row under the pointer (that ate the click).
    property var levels: []        // [{ entries, x, y, beside }]
    property var currents: []      // the pointed row of each level, -1 for none
    property Item returnFocus: null

    function open(entries: var, x: real, y: real): void {
        if (root.levels.length === 0) root.returnFocus = root.Window.window?.activeFocusItem ?? null
        root.levels = [{ entries: entries.filter(e => e), x: x, y: y }]
        root.currents = [-1]
        root.forceActiveFocus()
    }
    function openAt(entries: var, item: Item, below: bool): void {
        const p = item.mapToItem(root, 0, below ? item.height + Theme.dp(4) : 0)
        root.open(entries, p.x, p.y)
    }
    // New rows for the open menu, in place: the card stays where it is and the pointed row stays pointed.
    function refresh(entries: var): void {
        if (root.levels.length === 0) return
        root.levels = [Object.assign({}, root.levels[0], { entries: entries.filter(e => e) })]
        root.currents = root.currents.slice(0, 1)
    }
    function close(): void {
        root.levels = []
        root.currents = []
        if (root.returnFocus) root.returnFocus.forceActiveFocus()
    }
    function setCurrent(level: int, index: int): void {
        if (root.currents[level] === index) return
        if (root.levels.length > level + 1) root.levels = root.levels.slice(0, level + 1)
        const c = root.currents.slice(0, level + 1)
        c[level] = index
        root.currents = c
    }
    function openSub(level: int, index: int, rowItem: Item): void {
        const e = root.levels[level].entries[index]
        if (!e?.sub || root.levels.length > level + 1 && root.currents[level] === index) return
        const p = rowItem.mapToItem(root, rowItem.width + Theme.dp(4), -Theme.dp(6))
        root.levels = root.levels.slice(0, level + 1).concat([{ entries: e.sub.filter(s => s), x: p.x, y: p.y, beside: rowItem.mapToItem(root, -Theme.dp(4), 0).x }])
        const c = root.currents.slice(0, level + 1)
        c[level] = index
        root.currents = c.concat([-1])
    }
    function activate(level: int, index: int): void {
        const e = root.levels[level]?.entries[index]
        if (!e || e.separator || e.header || e.enabled === false) return
        if (e.sub) return
        if (!e.keep) root.close()
        if (e.run) e.run()
    }
    function selectable(e: var): bool { return e && !e.separator && !e.header && e.enabled !== false }
    function step(dir: int): void {
        const level = root.levels.length - 1
        const l = root.levels[level]
        let i = root.currents[level] ?? -1
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
        const cur = root.currents[level] ?? -1
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left && level > 0) {
            if (level > 0) { root.levels = root.levels.slice(0, level); root.currents = root.currents.slice(0, level) }
            else root.close()
        } else if (event.key === Qt.Key_Down) root.step(1)
        else if (event.key === Qt.Key_Up) root.step(-1)
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const e = l.entries[cur]
            if (e?.sub) root.openSub(level, cur, cards.itemAt(level).rowAt(cur))
            else if (event.key !== Qt.Key_Right) root.activate(level, cur)
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
        model: 4                   // a card per level, made once; a card shows while its level is open
        delegate: Item {
            id: card
            required property int index
            readonly property var level: root.levels[card.index] ?? ({ entries: [], x: 0, y: 0 })
            property var entries: []
            // The card appears once as it opens; rows made again in an open card do not flash it.
            onLevelChanged: if (card.level.entries !== card.entries) {
                const was = card.entries.length > 0
                card.entries = card.level.entries
                if (!was && card.entries.length > 0) appear.restart()
            }
            visible: card.entries.length > 0
            readonly property bool anyGlyph: card.entries.some(e => e.glyph || e.icon || e.checked !== undefined)
            readonly property real need: {
                let w = 0
                for (const e of card.entries) {
                    const t = metrics.advanceWidth(e.text ?? e.header ?? "") * (e.current || e.checked === true ? 1.06 : 1) + (e.keys || e.note ? metrics.advanceWidth(e.keys ?? e.note) + Theme.dp(28) : 0) + (e.sub ? Theme.dp(22) : 0)
                    w = Math.max(w, t)
                }
                // The row's margins: the card's 6 on each side, the lead glyph (8 + 22 + 6) or 12, then 10 and 10 at the end.
                return w + Theme.dp(card.anyGlyph ? 70 : 46)
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

            transformOrigin: Item.TopLeft
            ParallelAnimation {
                id: appear
                NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: Theme.fast; easing.type: Easing.OutCubic }
                NumberAnimation { target: card; property: "scale"; from: 0.97; to: 1; duration: Theme.fast; easing.type: Easing.OutCubic }
            }

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
                radius: Theme.round(14)
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
                    model: card.entries
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool sep: !!row.modelData.separator
                        readonly property bool header: row.modelData.header !== undefined
                        readonly property bool on: (root.currents[card.index] ?? -1) === row.index
                        readonly property bool usable: row.modelData.enabled !== false
                        // The chosen one of a set, or a switch that is on: accent ink, a filled glyph.
                        readonly property bool chosen: row.modelData.current === true || row.modelData.checked === true
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
                            radius: Theme.round(9)
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
                                // A row with a glyph keeps it and fills it when on; a bare choice shows a check.
                                name: row.modelData.glyph ? row.modelData.glyph : row.modelData.checked === true ? "check" : ""
                                size: Theme.dp(18)
                                weight: !row.modelData.glyph && row.modelData.checked === true ? 600 : 400
                                fill: row.modelData.fill ?? (row.chosen ? 1 : 0)
                                color: row.modelData.danger ? Theme.danger : row.modelData.tint ? row.modelData.tint
                                     : row.modelData.checked === true || row.modelData.current ? Theme.accentInk : Theme.ink2
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
                            strong: row.chosen
                            color: row.modelData.danger ? Theme.danger : row.chosen ? Theme.accentInk : Theme.ink
                            opacity: row.usable ? 1 : 0.4
                        }
                        Txt {
                            id: keys
                            visible: !row.sep && !row.header
                            anchors.right: chevron.visible ? chevron.left : parent.right
                            anchors.rightMargin: Theme.dp(10)
                            height: parent.height
                            text: row.modelData.keys ?? row.modelData.note ?? ""
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
