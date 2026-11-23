import QtQuick
import QtQuick.Shapes
import qs.services

// Progress round a point; an unknown amount turns.
Item {
    id: root
    property real value: -1
    property real stroke: Theme.dp(2.5)
    property color tint: Theme.accent
    implicitWidth: Theme.dp(18)
    implicitHeight: Theme.dp(18)

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: Theme.fillPress
            strokeWidth: root.stroke
            PathAngleArc { centerX: root.width / 2; centerY: root.height / 2; radiusX: root.width / 2 - root.stroke; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
        }
    }
    Shape {
        id: arc
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.tint
            strokeWidth: root.stroke
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.width / 2; centerY: root.height / 2
                radiusX: root.width / 2 - root.stroke; radiusY: radiusX
                startAngle: -90
                sweepAngle: root.value < 0 ? 90 : 360 * Math.min(1, root.value)
            }
        }
        RotationAnimator on rotation {
            running: root.value < 0 && root.visible
            from: 0; to: 360; duration: 900; loops: Animation.Infinite
        }
    }
}
