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
    // Rows already known for a path, shown at once while the disk is read again: (path) => rows, or null.
    property var seedOf: null
    // Something to show: rows, or a reading that found none.
    readonly property bool ready: root.rows.length > 0 || (!root.loading && root.serial > 0)
    signal loaded(var rows)

    ListModel { id: entries }

    function load(): void {
        if (root.path.length === 0) { root.rows = []; entries.clear(); return }
        const s = ++root.serial
        root.loading = true
        const seed = root.seedOf ? root.seedOf(root.path) : null
        if (seed) {
            root.rows = seed
            entries.clear()
            entries.append(seed)
        }
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
            } else {
                entries.clear()
                entries.append(list)
            }
            if (r.ok) root.loaded(list)
        })
    }
    // The folder is watched while it is shown, so what changes in it from anywhere shows in it.
    property string held: ""
    function hold(): void {
        if (root.held === root.path) return
        Core.dropWatch(root.held)
        root.held = root.path
        Core.holdWatch(root.held)
    }
    onPathChanged: { root.hold(); root.load() }
    Component.onCompleted: { root.hold(); root.load() }
    Component.onDestruction: Core.dropWatch(root.held)
    Connections {
        target: Prefs
        function onValuesChanged() { root.load() }
    }
    Connections {
        target: Core
        function onChanged(paths) { if (paths.indexOf(root.path) >= 0) root.load() }
    }
}
