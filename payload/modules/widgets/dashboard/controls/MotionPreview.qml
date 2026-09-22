import QtQuick
import qs.modules.theme
import qs.config
import "../../../services/AnimationsLogic.js" as Logic

// A dot travelling along a track using the curve's own progress function.
// Beziers run over `bezierDuration`; springs run over their settle time.
// This shows the *shape* of the motion. Hyprland scales time by the
// animation's speed, so absolute durations there differ.
Item {
    id: root

    property var curve: null
    property int bezierDuration: 900
    property bool autoPlay: true

    implicitHeight: 34

    property real f: 0                       // 0..1 position within the run
    property real span: 1                    // seconds a spring's plot covers

    readonly property real dotSize: 16
    readonly property real usable: track.width * 0.85 - dotSize   // leave room for overshoot

    function restart() {
        if (!curve) return;
        anim.stop();
        if (curve.type === "spring") {
            span = Logic.sampleCurve(curve, 8).span;
            anim.duration = Math.round(span * 1000);
        } else {
            anim.duration = bezierDuration;
        }
        f = 0;
        anim.start();
    }

    onCurveChanged: if (autoPlay) restartTimer.restart()
    Component.onCompleted: if (autoPlay) restartTimer.restart()

    // Debounce so dragging a handle does not restart the run every frame.
    Timer {
        id: restartTimer
        interval: 250
        onTriggered: root.restart()
    }

    NumberAnimation {
        id: anim
        target: root
        property: "f"
        from: 0
        to: 1
        easing.type: Easing.Linear
    }

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: playButton.left
        anchors.rightMargin: 10
        height: 6
        radius: 3
        color: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.14)

        // where progress = 1
        Rectangle {
            x: root.dotSize / 2 + root.usable
            anchors.verticalCenter: parent.verticalCenter
            width: 2
            height: 14
            color: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.4)
        }

        Rectangle {
            id: dot
            width: root.dotSize
            height: root.dotSize
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: Styling.srItem("overprimary")
            x: root.curve ? Logic.curveValueAt(root.curve, root.f, root.span) * root.usable : 0
        }
    }

    Rectangle {
        id: playButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 30
        height: 30
        radius: 15
        color: playArea.containsMouse ? Qt.rgba(Colors.primary.r, Colors.primary.g, Colors.primary.b, 0.25) : "transparent"

        Text {
            anchors.centerIn: parent
            text: Icons.play
            font.family: Icons.font
            font.pixelSize: 16
            color: Colors.overBackground
        }

        MouseArea {
            id: playArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.restart()
        }
    }
}
