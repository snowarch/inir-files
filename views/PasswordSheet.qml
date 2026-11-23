import QtQuick
import qs.services
import qs.kit

// An archive that is locked: the password, then the extraction again.
Sheet {
    id: root
    required property var ops
    property var paths: []
    property string dest: ""
    property bool retry: false
    title: I18n.tr("“%1” needs a password", Fmt.name(root.paths[0] ?? ""))
    subtitle: root.retry ? I18n.tr("That password did not open it. Try again.") : I18n.tr("Type the password to extract it.")

    function extract(): void {
        if (pw.text.length === 0) return
        root.ops.extractTo(root.paths, root.dest, pw.text)
        root.close()
    }
    Field {
        id: pw
        width: parent.width
        glyph: "key"
        placeholder: I18n.tr("Password")
        clearable: false
        onAccepted: root.extract()
        onEscaped: root.close()
        Component.onCompleted: { input.echoMode = TextInput.Password; Qt.callLater(focusAll) }
    }
    actions: [
        Pill { text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        Pill { text: I18n.tr("Extract"); kind: "solid"; enabled: pw.text.length > 0; onClicked: root.extract() }
    ]
}
