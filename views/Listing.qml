import QtQuick
import qs.services

// A folder read for a side column: its entries, kept in step with the disk, without choice or history.
Item {
    id: root
    visible: false
    property string path: ""
    property alias model: entries
    property bool loading: false
    property string error: ""
    property int serial: 0
    // The rows as the model holds them, read in place of the model.
    property var rows: []

    ListModel { id: entries }

    function load(): void {
        if (root.path.length === 0) { root.rows = []; entries.clear(); return }
        const s = ++root.serial
        root.loading = true
        Core.call("list", { path: root.path, hidden: Prefs.get("hidden"), sort: Prefs.get("sort"), desc: Prefs.get("desc"), dirsFirst: Prefs.get("dirsFirst"), counts: false }, r => {
            if (s !== root.serial) return
            root.loading = false
            root.error = r.ok ? "" : r.error
            // The keys only some entries carry, so every row has every role.
            const b = { link: false, target: "", broken: false, role: "", appIcon: "", remote: false }
            const list = (r.ok ? (r.entries ?? []) : []).map(e => Object.assign({}, b, e))
            const old = root.rows
            root.rows = list
            // Same rows in the same order: only what changed is touched.
            if (list.length === old.length && list.every((e, i) => old[i].path === e.path)) {
                for (let i = 0; i < list.length; i++) for (const k in list[i]) if (old[i][k] !== list[i][k]) entries.setProperty(i, k, list[i][k])
                return
            }
            entries.clear()
            entries.append(list)
        })
    }
    onPathChanged: root.load()
    Component.onCompleted: root.load()
    Connections {
        target: Prefs
        function onValuesChanged() { root.load() }
    }
    Connections {
        target: Core
        function onChanged(paths) { if (paths.indexOf(root.path) >= 0) root.load() }
    }
}
