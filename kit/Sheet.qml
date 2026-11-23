import QtQuick
import QtQuick.Effects
import qs.services

// A question or a form over the window: the window steps back under a scrim, a card in the middle holds a title, its
// body and its actions. Esc or a click outside dismisses it.
FocusScope {
    id: root
    anchors.fill: parent
    z: 800
    property string title: ""
    property string subtitle: ""
    property real cardWidth: Theme.dp(440)
    property bool dismissable: true
    default property alias body: bodyCol.data
    property alias actions: actionsRow.data
    property bool closing: false
    // A wait before it shows, for work that may need no sheet at all; reveal() shows it at once.
    property int delay: 0
    // The card's own colour, for what fades into it.
    readonly property color face: card.color
    signal dismissed()

    function close(): void {
        if (root.closing) return
        root.closing = true
        wait.stop()
        fadeIn.stop()
        root.dismissed()
        fadeOut.start()
    }
    function reveal(): void { if (wait.running) { wait.stop(); fadeIn.start() } }

    // Tab stays in the sheet: past its last control it comes round to the first, and back. Qt walks the whole window.
    readonly property Item focusNow: Window.activeFocusItem
    property Item focusLast: null
    function holds(item: var): bool {
        for (let i = item; i; i = i.parent)
            if (i === root) return true
        return false
    }
    function edge(first: bool): var {
        const start = root.nextItemInFocusChain(true)
        if (!start || !root.holds(start)) return null
        let it = start
        for (let n = 0; !first && n < 500; n++) {
            const next = it.nextItemInFocusChain(true)
            if (!next || next === start || !root.holds(next)) break
            it = next
        }
        return it
    }
    onFocusNowChanged: {
        const f = root.focusNow
        if (!f || root.closing) return
        if (root.holds(f)) { root.focusLast = f; return }
        if (!f.activeFocusOnTab || !root.focusLast) return
        const ahead = root.focusLast.nextItemInFocusChain(true) === f
        root.edge(ahead)?.forceActiveFocus(ahead ? Qt.TabFocusReason : Qt.BacktabFocusReason)
    }
    Keys.onTabPressed: root.edge(true)?.forceActiveFocus(Qt.TabFocusReason)
    Keys.onBacktabPressed: root.edge(false)?.forceActiveFocus(Qt.BacktabFocusReason)
    Component.onCompleted: { root.forceActiveFocus(); if (root.delay > 0) wait.start(); else fadeIn.start() }
    Keys.onEscapePressed: if (root.dismissable) root.close()

    opacity: 0
    Timer { id: wait; interval: root.delay; onTriggered: fadeIn.start() }
    NumberAnimation { id: fadeIn; target: root; property: "opacity"; to: 1; duration: Theme.normal; easing.type: Easing.OutCubic }
    NumberAnimation { id: fadeOut; target: root; property: "opacity"; to: 0; duration: Theme.fast; onFinished: root.destroy() }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        MouseArea {
            anchors.fill: parent
            enabled: root.opacity > 0
            // Takes the hover too, so a tip of the page behind closes.
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onClicked: if (root.dismissable) root.close()
            onWheel: wheel => wheel.accepted = true
        }
    }
    RectangularShadow {
        anchors.fill: card
        radius: card.radius
        blur: Theme.dp(40)
        offset.y: Theme.dp(12)
        color: Theme.shadow
    }
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(root.cardWidth, root.width - Theme.dp(40))
        height: Math.min(content.implicitHeight + Theme.dp(44), root.height - Theme.dp(40))
        radius: Theme.corner
        color: Theme.light ? "#ffffff" : Theme.mix(Theme.surface, Theme.high, 0.9)
        scale: 0.96 + 0.04 * root.opacity
        clip: true
        Rectangle { x: parent.radius; width: parent.width - parent.radius * 2; y: 1; height: 1; color: Theme.edge }
        MouseArea { anchors.fill: parent }
        Column {
            id: content
            x: Theme.dp(22)
            y: Theme.dp(22)
            width: parent.width - Theme.dp(44)
            spacing: Theme.dp(14)
            Column {
                width: parent.width
                spacing: Theme.dp(4)
                visible: root.title.length > 0
                Txt {
                    width: parent.width
                    text: root.title
                    font.family: Theme.title
                    size: Theme.head * 1.12
                    strong: true
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
                Txt {
                    width: parent.width
                    visible: root.subtitle.length > 0
                    text: root.subtitle
                    color: Theme.ink2
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
            }
            Column {
                id: bodyCol
                width: parent.width
                spacing: Theme.dp(10)
            }
            Row {
                id: actionsRow
                anchors.right: parent.right
                spacing: Theme.dp(8)
                layoutDirection: Qt.LeftToRight
            }
        }
    }
}
