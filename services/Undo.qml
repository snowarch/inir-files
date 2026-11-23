pragma Singleton
import QtQuick
import Quickshell

// What can be taken back and put again: each finished change leaves the step that reverses it. A copy goes to the
// trash, a move goes back, a trash comes back, a rename takes its old name. An undone step leaves its own reverse to
// redo, and a redone one leaves its reverse to undo; a new change forgets what could be redone.
Singleton {
    id: root

    property var stack: []
    property var redos: []
    readonly property bool can: root.stack.length > 0
    readonly property bool canRedo: root.redos.length > 0
    readonly property string label: root.can ? root.say(root.stack[root.stack.length - 1].what, false) : ""
    readonly property string redoLabel: root.canRedo ? root.say(root.redos[root.redos.length - 1].what, true) : ""

    function say(what: string, redo: bool): string {
        switch (what) {
        case "copy": return redo ? I18n.tr("Redo copy") : I18n.tr("Undo copy")
        case "move": return redo ? I18n.tr("Redo move") : I18n.tr("Undo move")
        case "trash": return redo ? I18n.tr("Redo trash") : I18n.tr("Undo trash")
        case "restore": return redo ? I18n.tr("Redo put back") : I18n.tr("Undo put back")
        case "rename": return redo ? I18n.tr("Redo rename") : I18n.tr("Undo rename")
        case "new": return redo ? I18n.tr("Redo new item") : I18n.tr("Undo new item")
        }
        return redo ? I18n.tr("Redo") : I18n.tr("Undo")
    }

    // A change the person made: what could be redone no longer follows from it.
    function push(step: var): void {
        root.stack = root.stack.concat([step]).slice(-60)
        root.redos = []
    }
    function file(redo: bool, step: var): void {
        if (redo) root.redos = root.redos.concat([step]).slice(-60)
        else root.stack = root.stack.concat([step]).slice(-60)
    }
    // A rename's reply gives the step that names it back.
    function renamed(r: var): var { return { what: "rename", op: "rename", args: { path: r.to, name: Fmt.name(r.from) } } }

    // The owner is the window that asked: it answers the step's own questions.
    function undo(owner: var): void { root.run(false, owner) }
    function redo(owner: var): void { root.run(true, owner) }
    function run(redo: bool, owner: var): void {
        const from = redo ? root.redos : root.stack
        if (from.length === 0) return
        const step = from[from.length - 1]
        if (redo) root.redos = from.slice(0, -1)
        else root.stack = from.slice(0, -1)
        // The reverse of an undo is filed to redo, and the reverse of a redo to undo.
        if (step.job) Core.job(step.op, step.args, { undoable: false, then: redo ? "undo" : "redo", what: step.what, owner: owner ?? null })
        else Core.call(step.op, step.args, r => {
            if (!r.ok) { Toast.fail(redo ? I18n.tr("Could not redo: %1", Errors.text(r.error)) : I18n.tr("Could not undo: %1", Errors.text(r.error))); return }
            if (step.op === "rename") root.file(!redo, root.renamed(r))
        })
    }

    // What reverses a finished job; `what` names the change the person made, for the menu's words.
    function reverse(j: var, what: var): var {
        const created = j.created ?? [], moved = j.moved ?? [], trashed = j.trashed ?? []
        switch (j.kind) {
        case "copy": case "duplicate": case "link": case "extract": case "compress":
            return created.length > 0 ? { job: true, what: what ?? "copy", op: "trash", args: { paths: created } } : null
        case "restore": case "untrash":
            return created.length > 0 ? { job: true, what: what ?? "restore", op: "trash", args: { paths: created } } : null
        case "move": case "movepairs":
            return moved.length > 0 ? { job: true, what: what ?? "move", op: "movepairs", args: { pairs: moved.map(p => [p[1], p[0]]) } } : null
        case "trash":
            return trashed.length > 0 ? { job: true, what: what ?? "trash", op: "untrash", args: { paths: trashed } } : null
        }
        return null
    }

    Connections {
        target: Core
        function onJobEvent(j) {
            if (j.state !== "done" && j.state !== "cancelled") return
            const note = Core.jobNotes[j.job]
            if (!note || !(note.undoable || note.then)) return
            const step = root.reverse(j, note.what)
            if (!step) return
            if (note.then) root.file(note.then === "redo", step)
            else root.push(step)
        }
    }
}
