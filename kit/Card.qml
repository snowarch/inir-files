import QtQuick
import qs.services

// A card: its fill sets it off, an edge of light along the top, no outline.
Rectangle {
    id: root
    property bool lit: true
    radius: Theme.cardRadius
    color: Theme.card
    Rectangle {
        visible: root.lit
        x: root.radius * 0.8
        width: parent.width - root.radius * 1.6
        height: 1
        color: Theme.edge
    }
}
