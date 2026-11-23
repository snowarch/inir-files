import QtQuick
import qs.services

// The fill under a control: none at rest, a step on hover, another pressed, the accent's plate when on.
Rectangle {
    property bool hovered: false
    property bool pressed: false
    property bool on: false
    radius: Theme.radius
    color: on ? Theme.accentPlate : pressed ? Theme.fillPress : hovered ? Theme.fillHover : "transparent"
    Behavior on color { ColorAnimation { duration: Theme.fast; easing.type: Easing.OutCubic } }
}
