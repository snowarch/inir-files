pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The bridge to inir-files-core, the process that does the file work: one JSON line per request, one per reply,
// events for what streams. A request made before the core is up waits in line; a core that dies is started again and
// the callers still waiting hear "core".
Singleton {
    id: root

    readonly property string binary: Quickshell.env("INIR_FILES_CORE") || Quickshell.shellPath("core/target/release/inir-files-core")
    readonly property string home: Quickshell.env("HOME") ?? "/"
    property bool ready: false
    property var places: ({ home: root.home, xdg: [], bookmarks: [], devices: [], network: [], trash: 0 })
    // Jobs at work and just finished, by id: the last event of each.
    property var jobs: ({})
    property var jobNotes: ({})

    property int nextId: 1
    property var waiting: ({})
    property var queue: []
    property int crashes: 0

    signal counts(string path, var counts)
    signal changed(var paths)
    signal jobEvent(var job)
    signal conflict(var question)
    signal searchBatch(var batch)
    signal sizeEvent(var data)
    signal checksumEvent(var data)
    signal failed(string op, string error)
    // A server being connected wants an answer (a password, a choice): { token, kind, message, fields, choices }.
    signal asked(var ask)

    function call(op: string, args: var, done: var): int {
        const id = root.nextId++
        const msg = Object.assign({ id: id, op: op }, args ?? {})
        if (done) {
            const w = Object.assign({}, root.waiting)
            w[id] = done
            root.waiting = w
        }
        const line = JSON.stringify(msg) + "\n"
        if (root.ready) proc.write(line)
        else root.queue = root.queue.concat([line])
        return id
    }

    // A job with what the interface needs to say about it and undo it.
    function job(op: string, args: var, note: var): void {
        root.call(op, args, reply => {
            if (!reply.ok) { root.failed(op, reply.error); return }
            const notes = Object.assign({}, root.jobNotes)
            notes[reply.job] = Object.assign({ op: op, args: args, undoable: true }, note ?? {})
            root.jobNotes = notes
        })
    }
    function cancelJob(id: int): void { root.call("job_cancel", { job: id }) }
    function answer(id: int, action: string, all: bool): void { root.call("job_answer", { job: id, action: action, all: all }) }
    function forgetJob(id: int): void {
        const j = Object.assign({}, root.jobs)
        delete j[id]
        root.jobs = j
    }
    // Folders on screen in any window, counted: the core watches each while one pane still shows it.
    property var watchCount: ({})
    function holdWatch(path: string): void {
        if (path.length === 0) return
        const m = Object.assign({}, root.watchCount)
        m[path] = (m[path] ?? 0) + 1
        root.watchCount = m
        watchSync.restart()
    }
    function dropWatch(path: string): void {
        if (path.length === 0 || root.watchCount[path] === undefined) return
        const m = Object.assign({}, root.watchCount)
        if (--m[path] <= 0) delete m[path]
        root.watchCount = m
        watchSync.restart()
    }
    Timer { id: watchSync; interval: 50; onTriggered: root.call("watch", { paths: Object.keys(root.watchCount) }) }

    // Files cut in any window wait here for the next paste, which moves them.
    property var cutPaths: ({})
    property int clipRev: 0
    function setCut(paths: var): void {
        const m = {}
        for (const p of paths) m[p] = true
        root.cutPaths = m
        root.clipRev++
    }

    // The bookmarks a bookmark op sends back, put in place with no new look at the disks.
    function takeBookmarks(r: var): void { if (r?.ok && r.bookmarks) root.places = Object.assign({}, root.places, { bookmarks: r.bookmarks }) }
    function refreshPlaces(): void { root.call("places", {}, r => { if (r.ok) root.places = r }) }

    // ---- thumbnails: asked for by what is on screen, answered to the item that asked
    property var thumbs: ({})
    property var thumbWaiters: ({})
    property var thumbAsk: ({})
    function thumbKey(path: string, size: string, mtime: real): string { return path + "|" + size + "|" + mtime }
    function thumb(path: string, size: string, mtime: real, item: var): string {
        const key = root.thumbKey(path, size, mtime)
        if (root.thumbs[key] !== undefined) return root.thumbs[key]
        const list = root.thumbWaiters[key] ?? []
        if (list.indexOf(item) < 0) list.push(item)
        root.thumbWaiters[key] = list
        if (!root.thumbAsk[size]) root.thumbAsk[size] = []
        if (list.length === 1) root.thumbAsk[size].push(path + "\n" + mtime)
        thumbFlush.restart()
        return ""
    }
    function unthumb(path: string, size: string, mtime: real, item: var): void {
        const key = root.thumbKey(path, size, mtime)
        const list = root.thumbWaiters[key]
        if (!list) return
        const at = list.indexOf(item)
        if (at >= 0) list.splice(at, 1)
        if (list.length === 0) delete root.thumbWaiters[key]
    }
    property var thumbMtimes: ({})
    Timer {
        id: thumbFlush
        interval: 24
        onTriggered: {
            for (const size in root.thumbAsk) {
                const asks = root.thumbAsk[size]
                if (asks.length === 0) continue
                const paths = []
                for (let i = asks.length - 1; i >= 0; i--) {
                    const [p, m] = asks[i].split("\n")
                    root.thumbMtimes[p + "|" + size] = Number(m)
                    // The core works newest first: the top of the screen is asked for last.
                    paths.push(p)
                }
                root.call("thumb", { paths: paths, size: size })
            }
            root.thumbAsk = ({})
        }
    }
    function gotThumb(m: var): void {
        const mtime = root.thumbMtimes[m.path + "|" + m.size] ?? 0
        const key = root.thumbKey(m.path, m.size, mtime)
        root.thumbs[key] = m.file
        const list = root.thumbWaiters[key]
        if (!list) return
        delete root.thumbWaiters[key]
        for (const item of list) {
            try { if (item && item.path === m.path) item.thumbFile = m.file } catch (e) {}
        }
    }

    function line(data: string): void {
        let m
        try { m = JSON.parse(data) } catch (e) { return }
        if (m.id !== undefined) {
            const done = root.waiting[m.id]
            if (done) {
                delete root.waiting[m.id]
                done(m)
            }
            return
        }
        switch (m.event) {
        case "ready":
            root.ready = true
            for (const l of root.queue) proc.write(l)
            root.queue = []
            root.refreshPlaces()
            watchSync.restart()
            break
        case "thumb": root.gotThumb(m); break
        case "counts": root.counts(m.path, m.counts); break
        case "changed": root.changed(m.paths); break
        case "job": {
            const j = Object.assign({}, root.jobs)
            j[m.job] = m
            root.jobs = j
            root.jobEvent(m)
            break
        }
        case "conflict": root.conflict(m); break
        case "search": root.searchBatch(m); break
        case "dirsize": root.sizeEvent(m); break
        case "checksum": root.checksumEvent(m); break
        case "places": root.places = m; break
        case "ask": root.asked(m); break
        }
    }

    Process {
        id: proc
        command: [root.binary]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => root.line(data)
        }
        onExited: (code, status) => {
            root.ready = false
            const w = root.waiting
            root.waiting = ({})
            for (const id in w) w[id]({ id: Number(id), ok: false, error: "core" })
            root.crashes++
            if (root.crashes < 6) restart.start()
            else console.warn("[inir-files] the core keeps stopping: " + root.binary)
        }
    }
    Timer { id: restart; interval: 400; onTriggered: proc.running = true }
    Timer { interval: 60000; running: root.crashes > 0; repeat: true; onTriggered: root.crashes = 0 }
}
