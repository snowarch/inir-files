import QtQuick
import qs.services
import qs.kit

// The chosen file over the whole window, as large as it goes. Arrows walk the folder; Space or Esc closes.
FocusScope {
    id: root
    required property var browser
    property var pane: null
    readonly property var folder: root.pane ? root.pane.folder : null
    readonly property bool shown: root.pane !== null
    readonly property var entry: root.folder ? root.folder.currentEntry ?? root.folder.chosen()[0] ?? null : null
    anchors.fill: parent
    z: 750
    visible: opacity > 0
    opacity: root.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }

    function toggle(p: var): void {
        if (root.shown) { root.close(); return }
        if (!p || p.folder.selCount === 0) return
        root.pane = p
        root.forceActiveFocus()
    }
    function close(): void {
        const p = root.pane
        root.pane = null
        if (p) p.forceActiveFocus()
    }
    function step(key: int): void {
        const f = root.folder
        if (!f || f.model.count === 0) return
        const next = root.pane.stepFrom(Math.max(0, f.current), key)
        if (next >= 0) f.moveTo(next, false, false)
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Space: case Qt.Key_Escape: root.close(); break
        case Qt.Key_Left: case Qt.Key_Right: case Qt.Key_Up: case Qt.Key_Down: root.step(event.key); break
        // Pages of a document.
        case Qt.Key_PageDown: if (look.page < look.pages - 1) look.page++; break
        case Qt.Key_PageUp: if (look.page > 0) look.page--; break
        case Qt.Key_Return: case Qt.Key_Enter:
            if (root.entry) { const e = root.entry; root.close(); root.browser.actions.open(root.browser.activePane, [e]) }
            break
        default: return
        }
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        color: "#0b0b0d"
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: root.close(); onWheel: wheel => wheel.accepted = true }
    }

    Item {
        id: top
        width: parent.width
        height: Theme.dp(56)
        Column {
            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(22)
            anchors.right: tools.left
            anchors.rightMargin: Theme.dp(12)
            anchors.verticalCenter: parent.verticalCenter
            Txt { width: parent.width; text: root.entry ? root.entry.name : ""; color: "#f4f5f7"; size: Theme.row; strong: true }
            Txt {
                width: parent.width
                color: Qt.rgba(1, 1, 1, 0.62)
                size: Theme.small
                text: {
                    if (!root.entry) return ""
                    const i = look.info
                    const parts = [root.entry.comment]
                    if (i.width > 0) parts.push(i.width + " × " + i.height)
                    if (i.media && i.media.duration > 0) parts.push(Fmt.duration(i.media.duration))
                    if (i.pdf && i.pdf.pages > 0) parts.push(I18n.n("%1 page", "%1 pages", i.pdf.pages))
                    if (!root.entry.dir) parts.push(Fmt.size(root.entry.size))
                    else if (i.files + i.dirs > 0) parts.push(Fmt.items(i.files + i.dirs))
                    if (root.folder) parts.push((root.folder.current + 1) + " / " + root.folder.model.count)
                    return parts.filter(s => s).join(" · ")
                }
            }
        }
        Row {
            id: tools
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.dp(4)
            Act { glyph: "open_in_new"; tint: "#f4f5f7"; round: true; tip: I18n.tr("Open"); onClicked: { const e = root.entry; root.close(); if (e) root.browser.actions.open(root.browser.activePane, [e]) } }
            Act { id: withAct; glyph: "apps"; tint: "#f4f5f7"; round: true; tip: I18n.tr("Open with"); onClicked: if (root.entry) root.browser.actions.openWithMenu([root.entry], withAct) }
            Act { glyph: "close"; tint: "#f4f5f7"; round: true; tip: I18n.tr("Close"); keys: "Space"; onClicked: root.close() }
        }
    }

    Media {
        id: look
        anchors.fill: parent
        anchors.topMargin: top.height
        anchors.leftMargin: Theme.dp(64)
        anchors.rightMargin: Theme.dp(64)
        anchors.bottomMargin: Theme.dp(28)
        large: true
        admin: !!root.folder && root.folder.admin
        entry: root.shown ? root.entry : null
    }
    Act {
        anchors.left: parent.left
        anchors.leftMargin: Theme.dp(14)
        anchors.verticalCenter: look.verticalCenter
        visible: root.folder && root.folder.current > 0
        size: Theme.dp(40)
        glyph: "chevron_left"
        tint: "#f4f5f7"
        round: true
        onClicked: root.step(Qt.Key_Left)
    }
    Act {
        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(14)
        anchors.verticalCenter: look.verticalCenter
        visible: root.folder && root.folder.current < root.folder.model.count - 1
        size: Theme.dp(40)
        glyph: "chevron_right"
        tint: "#f4f5f7"
        round: true
        onClicked: root.step(Qt.Key_Right)
    }
}
