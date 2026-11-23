import QtQuick
import qs.services

// A line of text to type into, pressed into the surface.
Inset {
    id: root
    property alias text: input.text
    property alias input: input
    property string placeholder: ""
    property string glyph: ""
    property bool clearable: true
    signal accepted()
    signal escaped()
    signal edited()

    implicitHeight: Theme.dp(34)
    implicitWidth: Theme.dp(220)
    focused: input.activeFocus

    function focusAll(): void {
        input.forceActiveFocus()
        input.selectAll()
    }

    Glyph {
        id: icon
        visible: root.glyph.length > 0
        x: Theme.dp(10)
        anchors.verticalCenter: parent.verticalCenter
        name: root.glyph
        size: Theme.dp(17)
        color: Theme.ink3
    }
    TextInput {
        id: input
        anchors.left: icon.visible ? icon.right : parent.left
        anchors.leftMargin: icon.visible ? Theme.dp(7) : Theme.dp(12)
        anchors.right: clear.visible ? clear.left : parent.right
        anchors.rightMargin: Theme.dp(8)
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.ink
        selectionColor: Theme.alpha(Theme.accent, 0.4)
        selectedTextColor: Theme.ink
        font.family: Theme.sans
        font.pixelSize: Theme.body
        renderType: TextInput.NativeRendering
        font.hintingPreference: Font.PreferDefaultHinting
        clip: true
        selectByMouse: true
        onAccepted: root.accepted()
        onTextEdited: root.edited()
        Keys.onEscapePressed: event => { root.escaped(); event.accepted = true }
        Txt {
            anchors.fill: parent
            visible: input.text.length === 0
            text: root.placeholder
            color: Theme.ink3
        }
    }
    Act {
        id: clear
        visible: root.clearable && input.text.length > 0
        anchors.right: parent.right
        anchors.rightMargin: Theme.dp(4)
        anchors.verticalCenter: parent.verticalCenter
        size: Theme.dp(24)
        glyphSize: Theme.dp(15)
        glyph: "close"
        onClicked: { input.clear(); root.edited(); input.forceActiveFocus() }
    }
}
