import QtQuick
import qs.services
import qs.kit

// A name taken where a file is going: the two side by side, which is newer and larger, and what to do.
Sheet {
    id: root
    property var question: ({})
    property bool all: false
    readonly property string srcPath: typeof root.question.src === "string" ? root.question.src : (root.question.src?.path ?? "")
    readonly property string dstPath: typeof root.question.dst === "string" ? root.question.dst : (root.question.dst?.path ?? "")
    property var src: typeof root.question.src === "object" ? root.question.src : null
    property var dst: typeof root.question.dst === "object" ? root.question.dst : null
    dismissable: false
    cardWidth: Theme.dp(520)
    title: root.question.dirs ? I18n.tr("A folder named “%1” is already there", Fmt.name(root.dstPath)) : I18n.tr("“%1” is already there", Fmt.name(root.dstPath))
    subtitle: I18n.tr("In %1", Fmt.pretty(Fmt.parent(root.dstPath || "/")))

    Component.onCompleted: {
        if (root.src && root.dst) return
        const paths = [root.srcPath, root.dstPath].filter(p => p.length > 0)
        if (paths.length === 0) return
        Core.call("stat", { paths: paths }, r => {
            if (!root || !r.ok) return
            root.src = r.entries.find(e => e.path === root.srcPath) ?? root.src
            root.dst = r.entries.find(e => e.path === root.dstPath) ?? root.dst
        })
    }
    function answer(action: string): void {
        Core.answer(root.question.job, action, root.all)
        root.close()
    }
    Keys.onEscapePressed: root.answer("cancel")

    component Side: Inset {
        id: side
        property var entry: null
        property var other: null
        property string label: ""
        width: (parent.width - Theme.dp(10)) / 2
        height: Theme.dp(176)
        radius: Theme.cardRadius
        readonly property bool newer: !!side.entry && !!side.other && side.entry.mtime > side.other.mtime + 1000
        readonly property bool larger: !!side.entry && !!side.other && !side.entry.dir && side.entry.size > side.other.size
        Column {
            anchors.centerIn: parent
            width: parent.width - Theme.dp(24)
            spacing: Theme.dp(6)
            Caption { anchors.horizontalCenter: parent.horizontalCenter; text: side.label }
            FileIcon { anchors.horizontalCenter: parent.horizontalCenter; size: Theme.dp(64); entry: side.entry }
            Txt {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                size: Theme.small
                text: side.entry ? (side.entry.dir ? Fmt.items(side.entry.items ?? 0) : Fmt.size(side.entry.size)) : ""
                color: side.larger ? Theme.accentInk : Theme.ink
                strong: side.larger
            }
            Txt {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                size: Theme.small
                text: side.entry ? Fmt.when(side.entry.mtime) + (side.newer ? " · " + I18n.tr("newer") : "") : ""
                color: side.newer ? Theme.accentInk : Theme.ink2
            }
        }
    }

    Row {
        width: parent.width
        spacing: Theme.dp(10)
        Side { label: I18n.tr("Already there"); entry: root.dst; other: root.src }
        Side { label: I18n.tr("Arriving"); entry: root.src; other: root.dst }
    }
    Check {
        text: I18n.tr("Do the same for every name taken")
        checked: root.all
        onToggled: value => root.all = value
    }

    actions: [
        Pill { text: I18n.tr("Stop"); kind: "plain"; onClicked: root.answer("cancel") },
        Pill { text: I18n.tr("Skip"); onClicked: root.answer("skip") },
        Pill { text: I18n.tr("Keep both"); onClicked: root.answer("keep") },
        Pill { text: root.question.dirs ? I18n.tr("Merge") : I18n.tr("Replace"); kind: "solid"; onClicked: root.answer(root.question.dirs ? "merge" : "replace") }
    ]
}
