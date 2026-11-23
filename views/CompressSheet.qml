import QtQuick
import qs.services
import qs.kit

// Files into one archive: its name and its format, each format with what it is good for.
Sheet {
    id: root
    required property var ops
    property var paths: []
    property string dir: ""
    property string suggested: ""
    property string format: Prefs.recall("archiveFormat", "zip")
    title: I18n.tr("Compress")
    subtitle: Fmt.items(root.paths.length)
    readonly property var formats: [
        { value: "zip", text: "zip", hint: I18n.tr("Opens on every system.") },
        { value: "7z", text: "7z", hint: I18n.tr("The smallest archive, and it can hold a password.") },
        { value: "tar.zst", text: "tar.zst", hint: I18n.tr("Fast and small; keeps Linux permissions.") },
        { value: "tar.xz", text: "tar.xz", hint: I18n.tr("Very small, slower to make.") },
        { value: "tar.gz", text: "tar.gz", hint: I18n.tr("The classic Linux archive.") }
    ]

    function make(): void {
        const n = name.text.trim()
        if (n.length === 0 || n.indexOf("/") >= 0) return
        const file = n + "." + root.format
        Prefs.remember("archiveFormat", root.format)
        root.ops.job("compress", { paths: root.paths, dest: Fmt.join(root.dir, file) }, I18n.tr("“%1” made", file))
        root.close()
    }

    Field {
        id: name
        width: parent.width
        glyph: "folder_zip"
        text: root.suggested
        onAccepted: root.make()
        onEscaped: root.close()
        Component.onCompleted: Qt.callLater(focusAll)
    }
    Segments {
        options: root.formats
        value: root.format
        onChosen: value => root.format = value
    }
    Txt {
        width: parent.width
        text: (root.formats.find(f => f.value === root.format)?.hint ?? "") + "  " + Fmt.pretty(Fmt.join(root.dir, name.text.trim() + "." + root.format))
        color: Theme.ink3
        size: Theme.small
        wrapMode: Text.Wrap
        elide: Text.ElideNone
    }
    actions: [
        Pill { text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        Pill { text: I18n.tr("Compress"); kind: "solid"; enabled: name.text.trim().length > 0; onClicked: root.make() }
    ]
}
