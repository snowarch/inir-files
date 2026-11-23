import QtQuick
import Quickshell
import qs.services
import qs.kit

// Every app that can open the file, the suggested ones first; it can become the usual one for the kind.
Sheet {
    id: root
    property var paths: []
    property var entry: null
    property var apps: []
    property var suggested: []
    property string usual: ""
    property string chosen: ""
    property bool always: false
    cardWidth: Theme.dp(460)
    title: I18n.tr("Open with")
    subtitle: root.entry ? (root.paths.length === 1 ? root.entry.name : Fmt.items(root.paths.length)) : ""

    Component.onCompleted: {
        Core.call("stat", { paths: [root.paths[0]] }, r => {
            if (!r.ok || r.entries.length === 0) return
            root.entry = r.entries[0]
            Core.call("apps", { mime: root.entry.mime }, a => {
                if (!a.ok) return
                root.suggested = a.apps.map(x => x.id)
                root.usual = a.default ?? ""
                if (root.chosen.length === 0) root.chosen = root.usual || (root.suggested[0] ?? "")
            })
        })
        Core.call("all_apps", {}, r => { if (r.ok) root.apps = r.apps.filter(a => !a.hidden) })
    }
    readonly property var shown: {
        const q = search.text.trim().toLowerCase()
        const rank = id => { const i = root.suggested.indexOf(id); return i < 0 ? 1000 : i }
        return root.apps
            .filter(a => q.length === 0 || a.name.toLowerCase().indexOf(q) >= 0 || (a.generic ?? "").toLowerCase().indexOf(q) >= 0 || a.id.toLowerCase().indexOf(q) >= 0)
            .sort((a, b) => rank(a.id) - rank(b.id) || a.name.localeCompare(b.name))
    }
    function open(): void {
        if (root.chosen.length === 0) return
        if (root.always && root.entry) Core.call("set_default", { mime: root.entry.mime, app: root.chosen })
        Core.call("open", { paths: root.paths, app: root.chosen, terminal: Prefs.get("terminal") ?? "" }, r => { if (!r.ok) Toast.fail(Errors.text(r.error)) })
        root.close()
    }
    Keys.onReturnPressed: root.open()
    Keys.onEnterPressed: root.open()

    Field {
        id: search
        width: parent.width
        glyph: "search"
        placeholder: I18n.tr("Find an app")
        onAccepted: { if (root.shown.length > 0 && search.text.length > 0) root.chosen = root.shown[0].id; root.open() }
        onEscaped: root.close()
        Component.onCompleted: Qt.callLater(focusAll)
    }
    Inset {
        width: parent.width
        height: Theme.dp(300)
        radius: Theme.radius
        ListView {
            id: list
            anchors.fill: parent
            anchors.margins: Theme.dp(5)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.shown
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool on: root.chosen === modelData.id
                readonly property bool suggested: root.suggested.indexOf(modelData.id) >= 0
                readonly property string iconUrl: modelData.icon ? (modelData.icon.startsWith("/") ? Fmt.url(modelData.icon) : Quickshell.iconPath(modelData.icon, true)) : ""
                width: ListView.view.width
                height: Theme.dp(42)
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius
                    color: row.on ? Theme.accentPlate : rowMouse.containsMouse ? Theme.fill : "transparent"
                }
                Image {
                    id: icon
                    x: Theme.dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.dp(26)
                    height: width
                    sourceSize: Qt.size(width * 2, height * 2)
                    source: row.iconUrl
                    visible: status === Image.Ready
                    asynchronous: true
                }
                Glyph { anchors.centerIn: icon; visible: !icon.visible; name: "apps"; size: Theme.dp(20); color: Theme.ink3 }
                Column {
                    anchors.left: icon.right
                    anchors.leftMargin: Theme.dp(10)
                    anchors.right: tag.left
                    anchors.rightMargin: Theme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    Txt { width: parent.width; text: row.modelData.name; strong: row.on; color: row.on ? Theme.accentInk : Theme.ink }
                    Txt { width: parent.width; visible: text.length > 0; text: row.modelData.generic ?? ""; size: Theme.caption; color: Theme.ink3 }
                }
                Txt {
                    id: tag
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.dp(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.id === root.usual ? I18n.tr("Usual") : row.suggested ? I18n.tr("Suggested") : ""
                    size: Theme.caption
                    color: Theme.ink3
                }
                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.chosen = row.modelData.id
                    onDoubleClicked: { root.chosen = row.modelData.id; root.open() }
                }
            }
        }
    }
    Check {
        visible: !!root.entry
        text: root.entry ? I18n.tr("Always open %1 with it", root.entry.comment || root.entry.mime) : ""
        checked: root.always
        onToggled: value => root.always = value
    }
    actions: [
        Pill { text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        Pill { text: I18n.tr("Open"); kind: "solid"; enabled: root.chosen.length > 0; onClicked: root.open() }
    ]
}
