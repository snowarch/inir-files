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

    ListModel { id: entries }

    function load(): void {
        if (root.path.length === 0) { entries.clear(); return }
        const s = ++root.serial
        root.loading = true
        Core.call("list", { path: root.path, hidden: Prefs.get("hidden"), sort: Prefs.get("sort"), desc: Prefs.get("desc"), dirsFirst: Prefs.get("dirsFirst"), counts: false }, r => {
            if (s !== root.serial) return
            root.loading = false
            root.error = r.ok ? "" : r.error
            const list = r.ok ? (r.entries ?? []) : []
            // Same rows in the same order: only what changed is touched.
            if (list.length === entries.count && list.every((e, i) => entries.get(i).path === e.path)) {
                for (let i = 0; i < list.length; i++) for (const k of ["name", "size", "mtime", "thumb", "icon"]) if (entries.get(i)[k] !== list[i][k]) entries.setProperty(i, k, list[i][k])
                return
            }
            entries.clear()
            entries.append(list.map(e => ({ name: e.name, path: e.path, dir: e.dir, link: e.link ?? false, broken: e.broken ?? false, size: e.size, mtime: e.mtime,
                mime: e.mime, kind: e.kind, icon: e.icon, generic: e.generic, hidden: e.hidden, mode: e.mode, thumb: e.thumb, role: e.role ?? "", items: -1 })))
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
