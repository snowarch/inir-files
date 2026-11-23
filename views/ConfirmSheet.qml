import QtQuick
import qs.services
import qs.kit

// A question before a change: its words, a name to type when one is needed, and the ways to answer. The last choice is
// the main one, and Enter takes it. Cancel is always there.
Sheet {
    id: root
    property var choices: []          // [{ text, kind, run(text) }]
    property bool field: false
    property string fieldText: ""
    property string placeholder: ""
    readonly property var main: root.choices.length > 0 ? root.choices[root.choices.length - 1] : null

    function choose(c: var): void {
        const text = input.item ? input.item.text.trim() : ""
        if (root.field && text.length === 0) return
        root.close()
        if (c && c.run) c.run(text)
    }
    Keys.onReturnPressed: root.choose(root.main)
    Keys.onEnterPressed: root.choose(root.main)

    Loader {
        id: input
        active: root.field
        width: parent.width
        sourceComponent: Field {
            text: root.fieldText
            placeholder: root.placeholder
            onAccepted: root.choose(root.main)
            onEscaped: root.close()
            Component.onCompleted: Qt.callLater(focusAll)
        }
    }

    actions: [
        Pill { text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        Repeater {
            model: root.choices
            Pill {
                required property var modelData
                text: modelData.text
                kind: modelData.kind ?? "quiet"
                onClicked: root.choose(modelData)
            }
        }
    ]
}
