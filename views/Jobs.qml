import QtQuick
import qs.services
import qs.kit

// The changes at work, as one pill in the status line: a ring of the whole progress and what the first job does. A
// click lists every job with its speed, its time left and a way to stop it. Finished jobs leave after a moment; failed
// ones stay until read.
Item {
    id: root
    required property var browser
    readonly property var list: {
        const out = []
        for (const id in Core.jobs) out.push(Core.jobs[id])
        return out.sort((a, b) => a.job - b.job)
    }
    readonly property var running: root.list.filter(j => j.state === "scan" || j.state === "running" || j.state === "waiting")
    readonly property real progress: {
        const r = root.running
        if (r.length === 0) return 0
        const total = r.reduce((a, j) => a + (j.totalBytes || 0), 0)
        const done = r.reduce((a, j) => a + (j.bytes || 0), 0)
        return total > 0 ? done / total : -1
    }
    property bool open: false
    visible: root.list.length > 0
    implicitWidth: root.list.length > 0 ? pill.width : 0
    implicitHeight: Theme.dp(26)

    function verb(j: var): string {
        switch (j.kind) {
        case "copy": return I18n.tr("Copying")
        case "move": case "movepairs": return I18n.tr("Moving")
        case "duplicate": return I18n.tr("Duplicating")
        case "link": return I18n.tr("Linking")
        case "trash": return I18n.tr("Moving to the trash")
        case "delete": case "purge": case "emptytrash": return I18n.tr("Deleting")
        case "restore": case "untrash": return I18n.tr("Restoring")
        case "extract": return I18n.tr("Extracting")
        case "compress": return I18n.tr("Compressing")
        }
        return I18n.tr("Working")
    }
    function line(j: var): string {
        if (j.state === "failed") return I18n.tr("%1 failed", root.verb(j))
        if (j.state === "done") return I18n.tr("Done")
        if (j.state === "cancelled") return I18n.tr("Stopped")
        if (j.state === "waiting") return I18n.tr("Waiting for an answer")
        if (j.state === "scan") return I18n.tr("Counting %1", Fmt.items(j.totalFiles || 0))
        const parts = [I18n.tr("%1 of %2", Fmt.size(j.bytes || 0), Fmt.size(j.totalBytes || 0))]
        if (j.rate > 0) parts.push(Fmt.rate(j.rate))
        if (j.eta > 0) parts.push(Fmt.eta(j.eta))
        return parts.join(" · ")
    }

    // Finished jobs leave on their own; failed ones wait to be read.
    Connections {
        target: Core
        function onJobEvent(j) {
            if (j.state === "done" || j.state === "cancelled") forget.createObject(root, { job: j.job })
        }
    }
    Component {
        id: forget
        Timer {
            property int job
            interval: 3500
            running: true
            onTriggered: { if (Core.jobs[job] && Core.jobs[job].state !== "failed") Core.forgetJob(job); destroy() }
        }
    }
    onListChanged: if (root.list.length === 0) root.open = false

    Rectangle {
        id: pill
        anchors.verticalCenter: parent.verticalCenter
        height: Theme.dp(26)
        width: pillRow.width + Theme.dp(18)
        radius: height / 2
        color: pillMouse.containsMouse || root.open ? Theme.fillHover : Theme.fill
        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: Theme.dp(7)
            Ring {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.running.length > 0
                width: Theme.dp(14)
                height: width
                value: root.progress
            }
            Glyph {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.running.length === 0
                readonly property bool failed: root.list.some(j => j.state === "failed")
                name: failed ? "error" : "check_circle"
                fill: 1
                size: Theme.dp(15)
                color: failed ? Theme.danger : Theme.success
            }
            Txt {
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.small
                color: Theme.ink
                text: root.running.length > 1 ? I18n.tr("%1 jobs", root.running.length) + (root.progress >= 0 ? " · " + Math.round(root.progress * 100) + "%" : "")
                    : root.running.length === 1 ? root.verb(root.running[0]) + (root.progress >= 0 ? " · " + Math.round(root.progress * 100) + "%" : "")
                    : root.list.length > 0 ? root.line(root.list[root.list.length - 1]) : ""
            }
        }
        MouseArea {
            id: pillMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.open = !root.open
        }
    }

    // ---- the list of jobs, over the panes
    Item {
        parent: root.browser.stage
        anchors.fill: parent
        visible: root.open
        z: 700
        MouseArea { anchors.fill: parent; onClicked: root.open = false }
        Card {
            id: card
            readonly property point at: root.open ? pill.mapToItem(root.browser.stage, pill.width, 0) : Qt.point(0, 0)
            x: Math.max(Theme.dp(8), at.x - width)
            y: at.y - height - Theme.dp(8)
            width: Theme.dp(380)
            height: Math.min(col.implicitHeight + Theme.dp(20), root.browser.stage.height * 0.6)
            radius: Theme.cardRadius
            color: Theme.light ? "#ffffff" : Theme.raised
            MouseArea { anchors.fill: parent }
            Flickable {
                anchors.fill: parent
                anchors.margins: Theme.dp(10)
                contentHeight: col.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: col
                    width: parent.width
                    spacing: Theme.dp(6)
                    Repeater {
                        model: root.list
                        delegate: Item {
                            id: jobRow
                            required property var modelData
                            readonly property var j: modelData
                            readonly property bool live: j.state === "scan" || j.state === "running" || j.state === "waiting"
                            width: col.width
                            height: inner.implicitHeight + Theme.dp(16)
                            Rectangle { anchors.fill: parent; radius: Theme.dp(12); color: Theme.fill }
                            Column {
                                id: inner
                                x: Theme.dp(12)
                                y: Theme.dp(8)
                                width: parent.width - Theme.dp(24) - stop.width
                                spacing: Theme.dp(5)
                                Txt {
                                    width: parent.width
                                    strong: true
                                    text: root.verb(jobRow.j) + (jobRow.j.current ? " · " + Fmt.name(jobRow.j.current) : "")
                                    elide: Text.ElideMiddle
                                }
                                Meter {
                                    visible: jobRow.live
                                    width: parent.width
                                    value: jobRow.j.totalBytes > 0 ? jobRow.j.bytes / jobRow.j.totalBytes : (jobRow.j.progress ?? 0)
                                }
                                Caption {
                                    width: parent.width
                                    text: root.line(jobRow.j) + (jobRow.j.dest ? " · " + I18n.tr("to %1", Fmt.pretty(jobRow.j.dest)) : "")
                                    elide: Text.ElideMiddle
                                }
                                Repeater {
                                    model: (jobRow.j.errors ?? []).slice(0, 4)
                                    delegate: Txt {
                                        required property var modelData
                                        width: inner.width
                                        size: Theme.small
                                        color: Theme.danger
                                        text: Fmt.name(modelData.path) + ": " + Errors.text(modelData.error)
                                        elide: Text.ElideMiddle
                                    }
                                }
                            }
                            Act {
                                id: stop
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.dp(6)
                                anchors.verticalCenter: parent.verticalCenter
                                glyph: jobRow.live ? "stop_circle" : "close"
                                tip: jobRow.live ? I18n.tr("Stop") : I18n.tr("Dismiss")
                                onClicked: jobRow.live ? Core.cancelJob(jobRow.j.job) : Core.forgetJob(jobRow.j.job)
                            }
                        }
                    }
                }
            }
        }
    }
}
