import QtQuick
import qs.modules.theme
import qs.config
import "../../../services/AnimationsLogic.js" as Logic

// Plots an animation curve (progress over time) and, for beziers, lets the
// two control points be dragged. Purely presentational: edits are reported
// through bezierEdited(); the owner decides what to do with them.
Item {
    id: root

    property var curve: null                 // { type: "bezier"|"spring", ... }
    property bool editable: false            // draggable bezier handles
    property color lineColor: Styling.srItem("overprimary")
    property color gridColor: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.14)
    property color guideColor: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.35)
    property color handleColor: Colors.primary
    property int padding: 14

    // Visible progress range. Editable beziers use a fixed window so the
    // plot does not rescale under the cursor while dragging.
    readonly property bool isBezier: !!curve && curve.type === "bezier"
    property real yMin: -0.6
    property real yMax: 1.6

    signal bezierEdited(real x1, real y1, real x2, real y2)

    implicitHeight: 220

    readonly property real plotW: width - 2 * padding
    readonly property real plotH: height - 2 * padding

    function px(x) { return padding + x * plotW; }
    function py(y) { return padding + (yMax - y) / (yMax - yMin) * plotH; }

    // Recompute the vertical window for non-editable plots (springs overshoot).
    function fitRange() {
        if (!curve) return;
        if (isBezier && editable) {
            yMin = -0.6;
            yMax = 1.6;
            return;
        }
        const s = Logic.sampleCurve(curve, 80);
        let lo = 0, hi = 1;
        for (let i = 0; i < s.points.length; i++) {
            lo = Math.min(lo, s.points[i].v);
            hi = Math.max(hi, s.points[i].v);
        }
        if (isBezier) {
            lo = Math.min(lo, curve.y1, curve.y2);
            hi = Math.max(hi, curve.y1, curve.y2);
        }
        yMin = lo - 0.12;
        yMax = hi + 0.12;
    }

    onCurveChanged: { fitRange(); canvas.requestPaint(); }
    onEditableChanged: { fitRange(); canvas.requestPaint(); }
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    Component.onCompleted: fitRange()

    Connections {
        target: Colors
        function onPrimaryChanged() { canvas.requestPaint(); }
        function onOverBackgroundChanged() { canvas.requestPaint(); }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            if (!root.curve || root.plotW <= 0 || root.plotH <= 0) return;

            // grid
            ctx.lineWidth = 1;
            ctx.strokeStyle = root.gridColor;
            ctx.beginPath();
            for (let i = 0; i <= 4; i++) {
                const gx = root.px(i / 4);
                ctx.moveTo(gx, root.py(root.yMax));
                ctx.lineTo(gx, root.py(root.yMin));
            }
            ctx.stroke();

            // y = 0 and y = 1 guides
            ctx.strokeStyle = root.guideColor;
            ctx.setLineDash([4, 4]);
            ctx.beginPath();
            ctx.moveTo(root.px(0), root.py(0));
            ctx.lineTo(root.px(1), root.py(0));
            ctx.moveTo(root.px(0), root.py(1));
            ctx.lineTo(root.px(1), root.py(1));
            ctx.stroke();
            ctx.setLineDash([]);

            const sampled = Logic.sampleCurve(root.curve, 96);

            // spring: mark where it settles
            if (root.curve.type === "spring") {
                const st = Logic.springStats(root.curve.mass, root.curve.stiffness, root.curve.dampening);
                const sx = root.px(Math.min(1, st.settle / sampled.span));
                ctx.strokeStyle = root.guideColor;
                ctx.setLineDash([2, 4]);
                ctx.beginPath();
                ctx.moveTo(sx, root.py(root.yMax));
                ctx.lineTo(sx, root.py(root.yMin));
                ctx.stroke();
                ctx.setLineDash([]);
            }

            // bezier handles' stems, under the curve
            if (root.isBezier && root.editable) {
                ctx.strokeStyle = root.guideColor;
                ctx.lineWidth = 1.5;
                ctx.beginPath();
                ctx.moveTo(root.px(0), root.py(0));
                ctx.lineTo(root.px(root.curve.x1), root.py(root.clampY(root.curve.y1)));
                ctx.moveTo(root.px(1), root.py(1));
                ctx.lineTo(root.px(root.curve.x2), root.py(root.clampY(root.curve.y2)));
                ctx.stroke();
            }

            // the curve
            ctx.strokeStyle = root.lineColor;
            ctx.lineWidth = 2.5;
            ctx.lineJoin = "round";
            ctx.beginPath();
            for (let i = 0; i < sampled.points.length; i++) {
                const p = sampled.points[i];
                const x = root.px(p.t), y = root.py(p.v);
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
            }
            ctx.stroke();

            // handles
            if (root.isBezier && root.editable) {
                ctx.fillStyle = root.handleColor;
                const pts = [[root.curve.x1, root.curve.y1], [root.curve.x2, root.curve.y2]];
                for (let k = 0; k < 2; k++) {
                    ctx.beginPath();
                    ctx.arc(root.px(pts[k][0]), root.py(root.clampY(pts[k][1])), 7, 0, Math.PI * 2);
                    ctx.fill();
                }
            }
        }
    }

    function clampY(y) { return Math.max(yMin, Math.min(yMax, y)); }

    property int _drag: -1   // 0 = first control point, 1 = second

    MouseArea {
        anchors.fill: parent
        enabled: root.isBezier && root.editable
        hoverEnabled: true
        cursorShape: root._drag >= 0 ? Qt.ClosedHandCursor : Qt.ArrowCursor

        function nearest(mx, my) {
            const d0 = Math.hypot(mx - root.px(root.curve.x1), my - root.py(root.clampY(root.curve.y1)));
            const d1 = Math.hypot(mx - root.px(root.curve.x2), my - root.py(root.clampY(root.curve.y2)));
            const best = d0 <= d1 ? 0 : 1;
            return Math.min(d0, d1) <= 18 ? best : -1;
        }

        onPressed: mouse => {
            root._drag = nearest(mouse.x, mouse.y);
        }
        onReleased: root._drag = -1
        onCanceled: root._drag = -1

        onPositionChanged: mouse => {
            if (root._drag < 0) return;
            const nx = Math.max(0, Math.min(1, (mouse.x - root.padding) / root.plotW));
            const ny = root.yMax - (mouse.y - root.padding) / root.plotH * (root.yMax - root.yMin);
            const rx = Math.round(nx * 100) / 100;
            const ry = Math.round(Math.max(root.yMin, Math.min(root.yMax, ny)) * 100) / 100;
            if (root._drag === 0) root.bezierEdited(rx, ry, root.curve.x2, root.curve.y2);
            else root.bezierEdited(root.curve.x1, root.curve.y1, rx, ry);
        }
    }
}
