import QtQuick
import QtQuick.Controls.Basic as QQC
import qs.services
import qs.kit

// The entries as a grid of pictures. The cells share the width evenly, so a row never ends in a ragged gap.
Item {
    id: root
    required property var pane
    readonly property alias view: grid
    readonly property var sizes: [40, 56, 72, 96, 128, 176, 240]
    readonly property int zoom: Math.max(1, Math.min(root.sizes.length, Number(Prefs.get("zoom"))))
    readonly property real iconSize: Theme.dp(root.sizes[root.zoom - 1])
    readonly property real grow: Theme.dp(12)
    readonly property real minCell: root.iconSize + Theme.dp(52)
    readonly property int columns: Math.max(1, Math.floor((grid.width - 1) / root.minCell))
    readonly property real labelHeight: Math.ceil(metrics.height * 2) + Theme.dp(10)

    function reveal(i: int): void { if (i >= 0) grid.positionViewAtIndex(i, GridView.Contain) }
    // The next index for a key, or -1 when the key does not move in a grid.
    function step(from: int, key: int): int {
        const per = Math.max(1, Math.floor(grid.height / grid.cellHeight))
        switch (key) {
        case Qt.Key_Left: return from - 1
        case Qt.Key_Right: return from + 1
        case Qt.Key_Up: return from < 0 ? 0 : (from - root.columns >= 0 ? from - root.columns : from)
        case Qt.Key_Down: return from < 0 ? 0 : (from + root.columns < grid.count ? from + root.columns : Math.min(grid.count - 1, Math.floor(from / root.columns) < Math.floor((grid.count - 1) / root.columns) ? grid.count - 1 : from))
        case Qt.Key_PageUp: return Math.max(0, from - root.columns * per)
        case Qt.Key_PageDown: return Math.min(grid.count - 1, from + root.columns * per)
        }
        return -1
    }
    // What a band covers, in the grid's own coordinates: a cell counts when the band meets its picture or its name.
    function indicesIn(x1: real, y1: real, x2: real, y2: real): var {
        const out = []
        const cw = grid.cellWidth, ch = grid.cellHeight
        if (cw <= 0 || ch <= 0) return out
        const boxW = root.iconSize + Theme.dp(18)
        for (let row = Math.max(0, Math.floor(y1 / ch)); row <= Math.floor(y2 / ch); row++) {
            for (let col = Math.max(0, Math.floor(x1 / cw)); col <= Math.min(root.columns - 1, Math.floor(x2 / cw)); col++) {
                const i = row * root.columns + col
                if (i >= grid.count) break
                const bx = col * cw + (cw - boxW) / 2, by = row * ch + Theme.dp(4)
                if (x2 >= bx && x1 <= bx + boxW && y2 >= by && y1 <= by + ch - Theme.dp(8)) out.push(i)
            }
        }
        return out
    }

    FontMetrics { id: metrics; font.family: Theme.sans; font.pixelSize: Theme.body }

    // The rest of the folder's pictures are made while the first screen is looked at, so a scroll finds them ready.
    function ahead(): void {
        const f = root.pane.folder
        if (f.mode === "folder" && !f.remote) Core.thumbAhead(f.all, Core.thumbSize((root.iconSize + root.grow) * (root.Window.window?.devicePixelRatio ?? 1)))
    }
    Timer { id: aheadSoon; interval: 250; onTriggered: root.ahead() }
    Connections { target: root.pane.folder; function onReset() { aheadSoon.restart() } }
    Component.onCompleted: aheadSoon.restart()
    onIconSizeChanged: aheadSoon.restart()

    Band {
        anchors.fill: parent
        pane: root.pane
        view: grid
        indicesIn: root.indicesIn
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.leftMargin: Theme.dp(10)
        anchors.rightMargin: Theme.dp(10)
        topMargin: Theme.dp(10)
        bottomMargin: Theme.dp(24)
        clip: true
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        cellWidth: Math.floor(grid.width / root.columns)
        cellHeight: root.iconSize + Theme.dp(26) + root.labelHeight
        cacheBuffer: Math.max(0, grid.cellHeight * 2)
        // Cells scrolled out are handed to the entries scrolling in, not made again.
        reuseItems: true
        model: root.pane.folder.model
        currentIndex: -1
        delegate: Cell {
            pane: root.pane
            iconSize: root.iconSize
            grow: root.grow
            width: grid.cellWidth
            height: grid.cellHeight
        }
        QQC.ScrollBar.vertical: Scroller {}
    }
}
