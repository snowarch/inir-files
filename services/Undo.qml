pragma Singleton
import QtQuick
import Quickshell

// What can be taken back: each finished change leaves the step that reverses it. A copy goes to the trash, a move
// goes back, a trash comes back, a rename takes its old name. An undo is not itself undone.
Singleton {
    id: root

    property var stack: []
    readonly property bool can: root.stack.length > 0
    readonly property string label: root.can ? root.stack[root.stack.length - 1].label : ""

    function push(step: var): void { root.stack = root.stack.concat([step]).slice(-60) }

    // The owner is the window that asked: it answers the undo's own questions.
    function undo(owner: var): void {
        if (!root.can) return
        const step = root.stack[root.stack.length - 1]
        root.stack = root.stack.slice(0, -1)
        if (step.job) Core.job(step.op, step.args, { undoable: false, undo: true, owner: owner ?? null })
        else Core.call(step.op, step.args, r => { if (!r.ok) Toast.fail(I18n.tr("Could not undo: %1", Errors.text(r.error))) })
    }

    // A finished job leaves its reverse.
    Connections {
        target: Core
        function onJobEvent(j) {
            if (j.state !== "done" && j.state !== "cancelled") return
            const note = Core.jobNotes[j.job]
            if (!note || !note.undoable) return
            let step = null
            const n = (j.created ?? []).length + (j.moved ?? []).length + (j.trashed ?? []).length
            if (n === 0) return
            switch (j.kind) {
            case "copy": case "duplicate": case "link": case "extract": case "compress":
                step = { job: true, op: "trash", args: { paths: j.created }, label: I18n.tr("Undo copy") }
                break
            case "move": case "movepairs":
                step = { job: true, op: "movepairs", args: { pairs: j.moved.map(p => [p[1], p[0]]) }, label: I18n.tr("Undo move") }
                break
            case "trash":
                step = { job: true, op: "untrash", args: { paths: j.trashed }, label: I18n.tr("Undo trash") }
                break
            }
            if (step) root.push(step)
        }
    }
}
