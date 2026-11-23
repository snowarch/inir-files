import QtQuick
import qs.services
import qs.kit

// A name being changed where it stands: the name without its type is chosen, Enter or a click away keeps it, Esc
// leaves it as it was.
Inset {
    id: root
    required property string name
    property bool centered: false
    signal done(string name)
    signal cancelled()
    property bool finished: false

    color: Theme.light ? "#ffffff" : Theme.mix(Theme.surface, "#000000", 0.25)
    focused: true
    radius: Theme.round(7)
    implicitHeight: Math.max(Theme.dp(26), input.contentHeight + Theme.dp(8))

    function finish(keep: bool): void {
        if (root.finished) return
        root.finished = true
        if (keep && input.text.trim().length > 0 && input.text !== root.name) root.done(input.text)
        else root.cancelled()
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: Theme.dp(6)
        anchors.rightMargin: Theme.dp(6)
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: root.centered ? TextInput.AlignHCenter : TextInput.AlignLeft
        text: root.name
        color: Theme.ink
        selectionColor: Theme.alpha(Theme.accent, 0.45)
        selectedTextColor: Theme.ink
        font.family: Theme.sans
        font.pixelSize: Theme.body
        renderType: TextInput.NativeRendering
        font.hintingPreference: Font.PreferDefaultHinting
        selectByMouse: true
        clip: true
        Component.onCompleted: {
            forceActiveFocus()
            select(0, Fmt.stem(root.name))
        }
        onAccepted: root.finish(true)
        onActiveFocusChanged: if (!activeFocus) root.finish(true)
        Keys.onEscapePressed: event => { root.finish(false); event.accepted = true }
        Keys.onPressed: event => {
            // F2 again walks the choice: the name, the whole, the type.
            if (event.key === Qt.Key_F2) {
                const stem = Fmt.stem(text)
                if (selectionStart === 0 && selectionEnd === stem && stem < text.length) selectAll()
                else if (selectionStart === 0 && selectionEnd === text.length && stem < text.length) select(stem + 1, text.length)
                else select(0, stem)
                event.accepted = true
            }
        }
    }
}
