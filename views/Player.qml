import QtQuick
import QtMultimedia
import qs.services
import qs.kit

// Sound and moving pictures, played where they are shown: a bar to play, pause, seek and mute. A click on the picture
// plays or pauses it.
Item {
    id: root
    property string source: ""
    property bool video: true
    property bool autoplay: false
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property real barHeight: Theme.dp(40)
    // A film shows its bar while the pointer moves over it, and lets the picture be once the pointer rests.
    property bool awake: false
    HoverHandler {
        onPointChanged: { root.awake = true; rest.restart() }
        onHoveredChanged: if (!hovered) { rest.stop(); root.awake = false }
    }
    Timer { id: rest; interval: 1800; onTriggered: root.awake = false }

    function toggle(): void { root.playing ? player.pause() : player.play() }
    function clock(ms: real): string {
        const s = Math.max(0, Math.floor(ms / 1000))
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
        return (h > 0 ? h + ":" + String(m).padStart(2, "0") : String(m)) + ":" + String(sec).padStart(2, "0")
    }

    MediaPlayer {
        id: player
        source: root.source.length > 0 ? Fmt.url(root.source) : ""
        audioOutput: AudioOutput {
            id: audio
            volume: 0.85
        }
        videoOutput: root.video ? screen : null
        onSourceChanged: if (root.autoplay) Qt.callLater(() => player.play())
    }
    Component.onCompleted: if (root.autoplay) player.play()
    Component.onDestruction: player.stop()

    VideoOutput {
        id: screen
        visible: root.video
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
        MouseArea { anchors.fill: parent; onClicked: root.toggle() }
    }

    Rectangle {
        id: bar
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.video ? Theme.dp(12) : 0
        width: root.video ? Math.min(parent.width - Theme.dp(24), Theme.dp(620)) : parent.width
        height: root.barHeight
        radius: height / 2
        color: root.video ? Qt.rgba(0.05, 0.05, 0.07, 0.72) : Theme.fill
        opacity: !root.video || !root.playing || root.awake || barHover.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
        HoverHandler { id: barHover }
        readonly property color ink: root.video ? "#f4f5f7" : Theme.ink
        readonly property color ink2: root.video ? Qt.rgba(1, 1, 1, 0.7) : Theme.ink2

        Act {
            id: playAct
            x: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            round: true
            glyph: root.playing ? "pause" : "play_arrow"
            tint: bar.ink
            onClicked: root.toggle()
        }
        Txt {
            id: now
            anchors.left: playAct.right
            anchors.leftMargin: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.clock(player.position)
            size: Theme.small
            color: bar.ink2
            font.features: { "tnum": 1 }
        }
        Item {
            id: track
            anchors.left: now.right
            anchors.leftMargin: Theme.dp(10)
            anchors.right: total.left
            anchors.rightMargin: Theme.dp(10)
            anchors.verticalCenter: parent.verticalCenter
            height: Theme.dp(20)
            readonly property real frac: player.duration > 0 ? player.position / player.duration : 0
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: Theme.dp(4); radius: height / 2; color: root.video ? Qt.rgba(1, 1, 1, 0.22) : Theme.fillPress }
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * track.frac; height: Theme.dp(4); radius: height / 2; color: root.video ? "#ffffff" : Theme.accent }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: parent.width * track.frac - width / 2
                width: seek.containsMouse || seek.pressed ? Theme.dp(12) : 0
                height: width
                radius: width / 2
                color: root.video ? "#ffffff" : Theme.accent
                Behavior on width { NumberAnimation { duration: Theme.fast } }
            }
            MouseArea {
                id: seek
                anchors.fill: parent
                hoverEnabled: true
                enabled: player.seekable
                function at(x: real): void { player.position = Math.max(0, Math.min(1, x / width)) * player.duration }
                onPressed: mouse => at(mouse.x)
                onPositionChanged: mouse => { if (pressed) at(mouse.x) }
            }
        }
        Txt {
            id: total
            anchors.right: muteAct.left
            anchors.rightMargin: Theme.dp(2)
            anchors.verticalCenter: parent.verticalCenter
            text: root.clock(player.duration)
            size: Theme.small
            color: bar.ink2
            font.features: { "tnum": 1 }
        }
        Act {
            id: muteAct
            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            round: true
            glyph: audio.muted ? "volume_off" : "volume_up"
            tint: bar.ink
            onClicked: audio.muted = !audio.muted
        }
    }
}
