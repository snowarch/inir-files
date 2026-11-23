pragma Singleton
import QtQuick
import Quickshell

// Sizes, dates and durations as people read them, in their locale.
Singleton {
    id: root

    readonly property var loc: Qt.locale()
    // The locale's long date without the weekday: "November 23, 2026", "23 de noviembre de 2026".
    readonly property string longDate: root.loc.dateFormat(Locale.LongFormat).replace(/d{4}[,.]?\s*/, "").trim()

    function num(value: real, decimals: int): string { return Number(value).toLocaleString(root.loc, "f", decimals) }

    function size(bytes: real): string {
        if (bytes === undefined || bytes === null || bytes < 0) return ""
        if (bytes < 1000) return I18n.n("%1 byte", "%1 bytes", Math.round(bytes))
        const units = ["kB", "MB", "GB", "TB", "PB"]
        let v = bytes / 1000
        let u = 0
        while (v >= 1000 && u < units.length - 1) { v /= 1000; u++ }
        return root.num(v, v < 10 ? 1 : 0) + " " + units[u]
    }

    function items(count: int): string { return I18n.n("%1 item", "%1 items", count) }

    function sameDay(a: date, b: date): bool {
        return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
    }
    // Today shows the time, yesterday says so, this year the day and month, before that the year too.
    function when(ms: real): string {
        if (!ms || ms <= 0) return ""
        const d = new Date(ms)
        const now = new Date()
        const time = d.toLocaleTimeString(root.loc, Locale.ShortFormat)
        if (root.sameDay(d, now)) return I18n.tr("Today, %1", time)
        const y = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
        if (root.sameDay(d, y)) return I18n.tr("Yesterday, %1", time)
        if (d.getFullYear() === now.getFullYear()) return d.toLocaleDateString(root.loc, "d MMM") + ", " + time
        return d.toLocaleDateString(root.loc, "d MMM yyyy")
    }
    function full(ms: real): string {
        if (!ms || ms <= 0) return ""
        const d = new Date(ms)
        return d.toLocaleDateString(root.loc, root.longDate) + ", " + d.toLocaleTimeString(root.loc, Locale.ShortFormat)
    }
    function duration(seconds: real): string {
        if (!(seconds >= 0)) return ""
        const s = Math.floor(seconds % 60), m = Math.floor(seconds / 60) % 60, h = Math.floor(seconds / 3600)
        const two = v => (v < 10 ? "0" : "") + v
        return h > 0 ? h + ":" + two(m) + ":" + two(s) : m + ":" + two(s)
    }
    function rate(bytesPerSecond: real): string { return bytesPerSecond > 0 ? I18n.tr("%1/s", root.size(bytesPerSecond)) : "" }
    function eta(seconds: real): string {
        if (!(seconds > 0)) return ""
        if (seconds < 60) return I18n.n("%1 second left", "%1 seconds left", Math.ceil(seconds))
        if (seconds < 3600) return I18n.n("%1 minute left", "%1 minutes left", Math.ceil(seconds / 60))
        return I18n.n("%1 hour left", "%1 hours left", Math.round(seconds / 3600))
    }
    function name(path: string): string {
        if (path === "/") return "/"
        const p = path.endsWith("/") ? path.slice(0, -1) : path
        return p.slice(p.lastIndexOf("/") + 1)
    }
    function parent(path: string): string {
        const p = path.endsWith("/") && path.length > 1 ? path.slice(0, -1) : path
        const at = p.lastIndexOf("/")
        return at <= 0 ? "/" : p.slice(0, at)
    }
    function join(dir: string, name: string): string { return (dir.endsWith("/") ? dir : dir + "/") + name }
    // A path with the home folder as ~.
    function pretty(path: string): string {
        const home = Theme.home
        if (path === home) return "~"
        return path.startsWith(home + "/") ? "~" + path.slice(home.length) : path
    }
    function url(path: string): string {
        return "file://" + path.split("/").map(s => encodeURIComponent(s)).join("/")
    }
    // The name without its extension, for a rename that keeps the type (.tar.gz and the like count as one).
    function stem(name: string): int {
        if (name.startsWith(".") && name.indexOf(".", 1) < 0) return name.length
        const m = name.match(/\.(tar\.(gz|xz|bz2|zst|lz|lzma|lz4)|[^.]+)$/i)
        return m && m.index > 0 ? m.index : name.length
    }
}
