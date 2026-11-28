import QtQuick
import qs.services
import qs.kit

// The band the pointer draws over empty space to choose what it touches; near an edge the view scrolls on.
MouseArea {
    id: root
    required property var pane
    required property Flickable view
    // Indices inside a rectangle given in the view's content coordinates.
    property var indicesIn: (x1, y1, x2, y2) => []
    // The row under a point, for views whose rows are wider than what they draw: a click there chooses the row.
    property var rowAt: (x, y) => -1
    property point start
    property point end
    property bool drawing: false
    property string clickedPath: ""
    property var base: null
    property real edgeSpeed: 0

    z: -1
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: false

    function content(x: real, y: real): point { return root.mapToItem(root.view.contentItem, x, y) }
    function update(): void {
        const x1 = Math.min(root.start.x, root.end.x), x2 = Math.max(root.start.x, root.end.x)
        const y1 = Math.min(root.start.y, root.end.y), y2 = Math.max(root.start.y, root.end.y)
        rect.x = x1; rect.y = y1; rect.width = x2 - x1; rect.height = y2 - y1
        root.pane.folder.setSel(root.indicesIn(x1, y1, x2, y2), root.base !== null, root.base)
    }

    onPressed: mouse => {
        root.pane.forceActiveFocus()
        root.pane.held = false
        const ctrl = mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)
        if (mouse.button === Qt.RightButton) {
            if (!ctrl) root.pane.folder.clearSel()
            const p = root.mapToItem(root.pane.browser.stage, mouse.x, mouse.y)
            root.pane.browser.actions.backgroundMenu(root.pane, p.x, p.y)
            return
        }
        root.base = ctrl ? Object.assign({}, root.pane.folder.selected) : null
        if (!ctrl) root.pane.folder.clearSel()
        root.start = root.content(mouse.x, mouse.y)
        root.end = root.start
        root.drawing = false
    }
    onPositionChanged: mouse => {
        if (!(mouse.buttons & Qt.LeftButton)) return
        root.end = root.content(mouse.x, mouse.y)
        if (!root.drawing && Math.abs(root.end.x - root.start.x) + Math.abs(root.end.y - root.start.y) < 6) return
        root.drawing = true
        root.edgeSpeed = mouse.y < Theme.dp(30) ? -Math.min(30, Theme.dp(30) - mouse.y) : mouse.y > root.height - Theme.dp(30) ? Math.min(30, mouse.y - root.height + Theme.dp(30)) : 0
        root.update()
    }
    onReleased: mouse => {
        root.clickedPath = ""
        if (root.pane.held) { root.pane.held = false; root.drawing = false; root.edgeSpeed = 0; return }
        if (!root.drawing && mouse.button === Qt.LeftButton) {
            const i = root.rowAt(root.start.x, root.start.y)
            if (i >= 0) {
                root.clickedPath = root.pane.folder.all[i]?.path ?? ""
                if (mouse.modifiers & Qt.ShiftModifier) root.pane.folder.range(i, (mouse.modifiers & Qt.ControlModifier) !== 0)
                else if (mouse.modifiers & Qt.ControlModifier) root.pane.folder.toggle(i)
                else root.pane.folder.only(i)
            }
        }
        root.drawing = false
        root.edgeSpeed = 0
    }
    onCanceled: { root.clickedPath = ""; root.drawing = false; root.edgeSpeed = 0 }
    // A finger held on empty space: the place's menu, or the row's where a row runs under it.
    Hold {
        onHeld: at => {
            if (root.drawing || root.pane.browser.busy) return
            const c = root.content(at.x, at.y)
            const i = root.rowAt(c.x, c.y)
            if (i >= 0) { root.pane.holdItem(i, at, root); return }
            root.pane.held = true
            const p = root.mapToItem(root.pane.browser.stage, at.x, at.y)
            root.pane.browser.actions.backgroundMenu(root.pane, p.x, p.y)
        }
    }
    // List metadata shares the band with empty space. Open only if both clicks hit the same entry.
    onDoubleClicked: mouse => {
        const path = root.clickedPath
        root.clickedPath = ""
        if (mouse.button === Qt.LeftButton && mouse.modifiers === Qt.NoModifier && path.length > 0) {
            const at = root.content(mouse.x, mouse.y)
            const i = root.rowAt(at.x, at.y)
            if (root.pane.folder.all[i]?.path === path) {
                root.pane.openItem(i, false)
                return
            }
        }
        mouse.accepted = false
    }

    Timer {
        interval: 16
        repeat: true
        running: root.drawing && root.edgeSpeed !== 0
        onTriggered: {
            const v = root.view
            const before = v.contentY
            v.contentY = Math.max(v.originY - v.topMargin, Math.min(v.contentY + root.edgeSpeed, v.originY + v.contentHeight + v.bottomMargin - v.height))
            root.end = Qt.point(root.end.x, root.end.y + v.contentY - before)
            root.update()
        }
    }

    Rectangle {
        id: rect
        parent: root.view.contentItem
        visible: root.drawing
        z: 50
        radius: Theme.round(4)
        color: Theme.alpha(Theme.accent, 0.12)
        border.width: 1
        border.color: Theme.alpha(Theme.accent, 0.6)
    }
}
