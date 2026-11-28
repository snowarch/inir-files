import QtQuick
import QtQuick.Effects
import qs.services
import qs.kit

// Back and forward away from the bar, on the pane under the pointer: the mouse's side buttons (kernels name them side
// and extra, or back and forward; both pairs count) and a sideways two-finger swipe on a touchpad. A swipe pulls an
// arrow in from the pane's edge; once it has come far enough it fills, and letting go there goes. A swipe that starts
// up or down, a view that scrolls sideways itself, or no place that way leaves the gesture to the views.
MouseArea {
    id: root
    required property var browser
    acceptedButtons: Qt.BackButton | Qt.ForwardButton | Qt.ExtraButton3 | Qt.ExtraButton4
    readonly property bool free: !root.browser.busy && root.browser.renaming.length === 0
    readonly property bool rtl: Qt.application.layoutDirection === Qt.RightToLeft

    onPressed: mouse => {
        const pane = root.browser.paneAt(root, mouse.x, mouse.y, false)
        if (!pane || !root.free) return
        pane.activate()
        if (mouse.button === Qt.BackButton || mouse.button === Qt.ExtraButton4) pane.folder.goBack()
        else pane.folder.goForward()
    }

    // A newer navigation supersedes a swipe that has not been committed yet.
    Connections {
        target: root.pane?.folder ?? null
        function onPlaceChanged() { root.end(false) }
        function onModeChanged() { root.end(false) }
    }

    // ---- the swipe: one gesture runs from ScrollBegin to ScrollEnd. Where the compositor sends no phases, a run of fine
    // steps that ends in a still moment is one gesture. A wheel's notches are not fine and pass by.
    property var pane: null
    property int side: -1               // -1 back, 1 forward
    property int mode: 0                // 0 not known yet, 1 a swipe, 2 left to the views
    property real dx: 0
    property real dy: 0
    property real pull: 0               // how far the arrow has come, 0 to 1
    property bool armed: false
    property bool phased: false
    readonly property real reach: Theme.dp(132)

    function settle(go: bool): void {
        const pane = root.pane
        root.pane = null
        away.restart()
        if (go && pane) pane.folder.travel(root.side)
    }

    function end(go: bool): void {
        if (root.mode === 1) root.settle(go)
        root.mode = 0
        root.dx = 0
        root.dy = 0
        stale.stop()
    }

    onWheel: wheel => {
        wheel.accepted = false
        const ph = wheel.phase
        const fine = wheel.pixelDelta.x !== 0 || wheel.pixelDelta.y !== 0
        if (ph === Qt.ScrollMomentum || (ph === Qt.NoScrollPhase && !fine)) return
        if (ph === Qt.ScrollBegin) root.end(false)
        // The end goes on to the views too, so a list that saw the start sees its gesture close.
        if (ph === Qt.ScrollEnd) { root.end(root.armed); return }
        root.phased = ph !== Qt.NoScrollPhase
        stale.restart()
        if (root.mode === 2) return
        root.dx += wheel.pixelDelta.x
        root.dy += wheel.pixelDelta.y
        if (root.mode === 0) {
            if (Math.hypot(root.dx, root.dy) < Theme.dp(10)) return
            root.mode = 2
            if (wheel.modifiers !== Qt.NoModifier || !root.free || root.browser.railOpen) return
            if (Math.abs(root.dx) < Math.abs(root.dy) * 2) return
            const pane = root.browser.paneAt(root, wheel.x, wheel.y, true)
            // A scroll toward the left shows what lies left: the place before.
            const side = (root.dx > 0) !== root.rtl ? -1 : 1
            if (!pane || pane.sideways || (side < 0 ? pane.folder.back : pane.folder.forward).length === 0) return
            const at = pane.mapToItem(root, 0, 0)
            lane.x = at.x
            lane.y = at.y
            lane.width = pane.width
            lane.height = pane.height
            away.stop()
            root.pane = pane
            root.side = side
            root.armed = false
            root.mode = 1
        }
        wheel.accepted = true
        root.pull = Math.max(0, Math.min(1, root.side * (root.rtl ? root.dx : -root.dx) / root.reach))
        root.armed = root.pull >= 1
    }
    // Without phases a still moment is the end. With them it means the end never came (some trackpoints): it lets go.
    Timer { id: stale; interval: root.phased ? 1200 : 220; onTriggered: root.end(!root.phased && root.armed) }
    NumberAnimation { id: away; target: root; property: "pull"; to: 0; duration: Theme.fast; easing.type: Easing.OutCubic }

    Item {
        id: lane
        clip: true
        visible: root.pull > 0
        // The arrow comes in on the side the swipe pulls from: the left for back, unless the language reads leftward.
        readonly property bool fromLeft: (root.side < 0) !== root.rtl
        RectangularShadow {
            anchors.fill: chip
            radius: chip.radius
            blur: Theme.dp(14)
            color: Theme.shadow
            opacity: chip.opacity
        }
        Rectangle {
            id: chip
            readonly property real size: Theme.dp(44)
            readonly property real inset: -chip.size + (chip.size + Theme.dp(18)) * root.pull
            width: chip.size
            height: chip.size
            radius: chip.size / 2
            x: lane.fromLeft ? chip.inset : lane.width - chip.size - chip.inset
            y: Math.round((lane.height - chip.size) / 2)
            opacity: Math.min(1, root.pull * 1.6)
            color: root.armed ? Theme.accent : Theme.card
            border.width: root.armed ? 0 : 1
            border.color: Theme.line
            Behavior on color { ColorAnimation { duration: Theme.fast } }
            Glyph {
                anchors.centerIn: parent
                name: lane.fromLeft ? "arrow_back" : "arrow_forward"
                size: Theme.dp(22)
                color: root.armed ? Theme.inkAccent : Theme.ink
                fill: root.armed ? 1 : 0
            }
        }
    }
}
