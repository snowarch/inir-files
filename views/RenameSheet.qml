import QtQuick
import qs.services
import qs.kit

// Many names at once: replace a part, number them, or change their case. Each new name shows before anything moves.
Sheet {
    id: root
    property var entries: []
    property var pane: null
    property string mode: "replace"
    property string casing: "lower"
    cardWidth: Theme.dp(540)
    title: I18n.n("Rename %1 item", "Rename %1 items", root.entries.length)

    function stemOf(e: var): string { return e.dir ? e.name : e.name.slice(0, Fmt.stem(e.name)) }
    function newName(e: var, i: int): string {
        const stem = root.stemOf(e)
        const ext = e.name.slice(stem.length)
        if (root.mode === "replace") return find.text.length > 0 ? e.name.split(find.text).join(replace.text) : e.name
        if (root.mode === "number") {
            const first = Math.max(0, parseInt(start.text) || 0)
            const num = String(first + i).padStart(String(first + root.entries.length - 1).length, "0")
            const p = pattern.text.length > 0 ? pattern.text : "* #"
            return (p.indexOf("#") >= 0 ? p.split("#").join(num) : p + " " + num).split("*").join(stem) + ext
        }
        if (root.casing === "upper") return stem.toUpperCase() + ext
        if (root.casing === "title") return stem.toLowerCase().replace(/(^|[\s_\-.])(\p{L})/gu, (m, a, b) => a + b.toUpperCase()) + ext
        return stem.toLowerCase() + ext
    }
    readonly property var names: { void find.text; void replace.text; void pattern.text; void start.text; void root.casing; return root.entries.map((e, i) => root.newName(e, i)) }
    readonly property var bad: {
        const seen = {}
        const out = root.names.map(n => n.length === 0 || n.indexOf("/") >= 0 || n === "." || n === "..")
        root.names.forEach((n, i) => {
            const key = Fmt.parent(root.entries[i].path) + "/" + n
            if (seen[key] !== undefined) { out[i] = true; out[seen[key]] = true }
            seen[key] = i
        })
        return out
    }
    readonly property int changed: root.names.filter((n, i) => n !== root.entries[i].name).length
    readonly property bool valid: root.changed > 0 && !root.bad.some(b => b)

    function apply(): void {
        if (!root.valid) return
        const items = root.entries.map((e, i) => ({ path: e.path, name: root.names[i] })).filter((it, i) => it.name !== root.entries[i].name)
        const pane = root.pane
        Core.call("batch_rename", { items: items }, r => {
            if (!r.ok) {
                Toast.fail(r.error.startsWith("exists:") ? I18n.tr("“%1” is already there", r.error.slice(7)) : Errors.text(r.error))
                return
            }
            Undo.push({ job: true, what: "rename", op: "movepairs", args: { pairs: r.pairs.map(p => [p[1], p[0]]) } })
            Toast.show(I18n.n("%1 item renamed", "%1 items renamed", r.pairs.length), I18n.tr("Undo"), () => Undo.undo(pane ? pane.browser : null))
            if (pane) { pane.folder.reload(); pane.forceActiveFocus() }
        })
        root.close()
    }
    Keys.onReturnPressed: root.apply()
    Keys.onEnterPressed: root.apply()

    Segments {
        options: [
            { value: "replace", glyph: "find_replace", text: I18n.tr("Replace") },
            { value: "number", glyph: "format_list_numbered", text: I18n.tr("Number") },
            { value: "case", glyph: "match_case", text: I18n.tr("Case") }
        ]
        value: root.mode
        onChosen: value => root.mode = value
    }
    Row {
        visible: root.mode === "replace"
        width: parent.width
        spacing: Theme.dp(8)
        Field { id: find; width: (parent.width - Theme.dp(8)) / 2; placeholder: I18n.tr("Find"); onAccepted: root.apply(); onEscaped: root.close(); Component.onCompleted: Qt.callLater(focusAll) }
        Field { id: replace; width: (parent.width - Theme.dp(8)) / 2; placeholder: I18n.tr("Replace with"); onAccepted: root.apply(); onEscaped: root.close() }
    }
    Row {
        visible: root.mode === "number"
        width: parent.width
        spacing: Theme.dp(8)
        Field { id: pattern; width: parent.width - start.width - Theme.dp(8); placeholder: I18n.tr("* is the old name, # the number"); text: "* #"; onAccepted: root.apply(); onEscaped: root.close() }
        Field { id: start; width: Theme.dp(90); text: "1"; glyph: "tag"; clearable: false; input.inputMethodHints: Qt.ImhDigitsOnly; onAccepted: root.apply(); onEscaped: root.close() }
    }
    Segments {
        visible: root.mode === "case"
        options: [
            { value: "lower", text: I18n.tr("lower case") },
            { value: "upper", text: I18n.tr("UPPER CASE") },
            { value: "title", text: I18n.tr("Title Case") }
        ]
        value: root.casing
        onChosen: value => root.casing = value
    }

    Inset {
        width: parent.width
        height: Math.min(Theme.dp(28) * root.entries.length + Theme.dp(12), Theme.dp(252))
        radius: Theme.radius
        ListView {
            anchors.fill: parent
            anchors.margins: Theme.dp(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.entries
            delegate: Item {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: Theme.dp(28)
                readonly property string next: root.names[index] ?? ""
                readonly property bool same: next === modelData.name
                Txt { x: Theme.dp(6); width: parent.width / 2 - Theme.dp(22); height: parent.height; text: modelData.name; size: Theme.small; color: Theme.ink2; elide: Text.ElideMiddle }
                Glyph { anchors.centerIn: parent; name: "arrow_forward"; size: Theme.dp(14); color: Theme.ink3 }
                Txt {
                    x: parent.width / 2 + Theme.dp(16)
                    width: parent.width / 2 - Theme.dp(22)
                    height: parent.height
                    text: parent.next
                    size: Theme.small
                    elide: Text.ElideMiddle
                    strong: !parent.same
                    color: root.bad[index] ? Theme.danger : parent.same ? Theme.ink3 : Theme.accentInk
                }
            }
        }
    }
    actions: [
        Pill { text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        Pill { text: root.changed > 0 ? I18n.n("Rename %1", "Rename %1", root.changed) : I18n.tr("Rename"); kind: "solid"; enabled: root.valid; onClicked: root.apply() }
    ]
}
