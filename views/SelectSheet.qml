import QtQuick
import qs.services
import qs.kit

// Choose by name in the place shown: a pattern with * and ?, or a piece of text a name holds; commas join patterns.
// What matches is counted while it is typed. The choice replaces the one before.
Sheet {
    id: root
    required property var pane
    title: I18n.tr("Select by name")
    subtitle: I18n.tr("* stands for any text and ? for one character. Separate patterns with commas.")

    readonly property var matches: {
        const tests = field.text.split(",").map(t => t.trim()).filter(t => t.length > 0).map(t => root.test(t))
        if (tests.length === 0) return []
        const all = root.pane.folder.all
        const out = []
        for (let i = 0; i < all.length; i++) if (tests.some(rx => rx.test(all[i].name))) out.push(all[i].path)
        return out
    }
    // A pattern with * or ? covers the whole name; plain text matches anywhere in it. Case never counts.
    function test(t: string): var {
        const wild = t.includes("*") || t.includes("?")
        const body = t.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".")
        return new RegExp(wild ? "^" + body + "$" : body, "i")
    }
    function choose(): void {
        if (root.matches.length === 0) return
        root.pane.folder.selectByPaths(root.matches)
        root.close()
    }
    Field {
        id: field
        width: parent.width
        glyph: "checklist"
        placeholder: I18n.tr("For example *.jpg, report")
        onAccepted: root.choose()
        onEscaped: root.close()
        Component.onCompleted: Qt.callLater(focusAll)
    }
    Txt {
        width: parent.width
        height: Theme.dp(30)
        verticalAlignment: Text.AlignBottom
        text: field.text.trim().length === 0 ? "" : root.matches.length === 0 ? I18n.tr("Nothing matches") : I18n.n("%1 item matches", "%1 items match", root.matches.length)
        color: root.matches.length === 0 ? Theme.ink3 : Theme.ink2
        size: Theme.small
    }
    actions: [
        Pill { text: I18n.tr("Cancel"); kind: "plain"; onClicked: root.close() },
        Pill { text: I18n.tr("Select"); kind: "solid"; enabled: root.matches.length > 0; onClicked: root.choose() }
    ]
}
