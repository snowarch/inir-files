pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Words in the person's language: i18n/<lang>.json maps each English phrase to its translation; a phrase with no entry
// stays in English. %1, %2 … take the arguments in order.
Singleton {
    id: root

    readonly property string locale: (Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "en").split(".")[0]
    readonly property string language: root.locale.split("_")[0]
    // Spanish of every region reads the Latin American catalogue unless its own exists.
    readonly property var candidates: [root.locale, root.language === "es" ? "es_419" : root.language]
    property int tried: 0
    property var catalog: ({})

    FileView {
        path: Quickshell.shellPath("i18n/" + root.candidates[root.tried] + ".json")
        printErrors: false
        onLoaded: {
            try { root.catalog = JSON.parse(text()) } catch (e) { root.catalog = ({}) }
        }
        onLoadFailed: if (root.tried + 1 < root.candidates.length) root.tried++
    }

    // Untyped on purpose: a typed function drops the arguments its signature does not name.
    function tr(text, ...args) {
        let out = root.catalog[text] ?? text
        for (let i = 0; i < args.length; i++)
            out = out.split("%" + (i + 1)).join(String(args[i]))
        return out
    }
    // One form for a single thing, another for any other count.
    function n(one: string, many: string, count: int): string {
        return root.tr(count === 1 ? one : many, count.toLocaleString(Qt.locale(), "f", 0))
    }
}
