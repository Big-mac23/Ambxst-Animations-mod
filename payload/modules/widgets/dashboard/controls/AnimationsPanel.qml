pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.theme
import qs.modules.components
import qs.modules.services
import qs.config
import "../../../services/AnimationsLogic.js" as Logic

// Settings page: edit Hyprland curves (bezier + spring) and per-leaf
// animations. All state lives in AnimationsService; this file is view only,
// and must stay free of side effects on load (the settings indexer
// instantiates every panel headlessly to build the search index).
Item {
    id: root

    // SettingsTab assigns maxContentWidth (480) after load. This page needs
    // room for the curve editor, so it deliberately ignores it.
    property int maxContentWidth: 480
    readonly property int contentWidth: Math.min(width, 760)
    readonly property real sideMargin: (width - contentWidth) / 2

    readonly property var cfg: AnimationsService.config
    readonly property bool on: cfg.enabled

    property int tab: 0
    property int selectedCurve: 0
    property string importText: ""
    property string importMessage: ""
    property bool showLua: false

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    readonly property var curveNames: {
        const out = ["default"];
        for (let i = 0; i < cfg.curves.length; i++) out.push(cfg.curves[i].name);
        return out;
    }

    function curveAt(i) { return (i >= 0 && i < cfg.curves.length) ? cfg.curves[i] : null; }

    function animFor(leaf) {
        for (let i = 0; i < cfg.animations.length; i++)
            if (cfg.animations[i].leaf === leaf) return cfg.animations[i];
        return null;
    }

    function errFor(scope, id, field) {
        const errs = AnimationsService.errors;
        for (let i = 0; i < errs.length; i++)
            if (errs[i].scope === scope && errs[i].id === id && (field === "" || errs[i].field === field)) return errs[i].message;
        return "";
    }

    function usedBy(curveName) {
        const out = [];
        for (let i = 0; i < cfg.animations.length; i++)
            if (cfg.animations[i].enabled && cfg.animations[i].curve === curveName) out.push(cfg.animations[i].leaf);
        return out;
    }

    // leaves that are in the config but not in the built-in tree (imported)
    readonly property var extraLeaves: {
        const known = {};
        for (let i = 0; i < Logic.LEAVES.length; i++) known[Logic.LEAVES[i].leaf] = true;
        const out = [];
        for (let j = 0; j < cfg.animations.length; j++)
            if (!known[cfg.animations[j].leaf]) out.push({ leaf: cfg.animations[j].leaf, parent: "", label: cfg.animations[j].leaf, styleKind: "none", desc: "Custom leaf" });
        return out;
    }

    function addCurve(template) {
        AnimationsService.update(c => {
            const copy = Logic.clone(template);
            copy.name = Logic.uniqueCurveName(c, template.name);
            c.curves.push(copy);
        });
        root.selectedCurve = cfg.curves.length - 1;
    }

    function duplicateCurve(i) {
        const src = curveAt(i);
        if (src) addCurve(src);
    }

    function deleteCurve(i) {
        AnimationsService.update(c => { c.curves.splice(i, 1); });
        root.selectedCurve = Math.max(0, Math.min(root.selectedCurve, cfg.curves.length - 1));
    }

    function setCurve(i, field, value) {
        AnimationsService.update(c => { if (c.curves[i]) c.curves[i][field] = value; });
    }

    function renameCurve(i, name) {
        AnimationsService.update(c => {
            const old = c.curves[i].name;
            c.curves[i].name = name;
            for (let k = 0; k < c.animations.length; k++)
                if (c.animations[k].curve === old) c.animations[k].curve = name;   // keep references intact
        });
    }

    function setBezier(i, x1, y1, x2, y2) {
        AnimationsService.update(c => {
            const cv = c.curves[i];
            if (!cv) return;
            cv.x1 = x1; cv.y1 = y1; cv.x2 = x2; cv.y2 = y2;
        });
    }

    function toggleLeaf(leaf, custom) {
        AnimationsService.update(c => {
            const at = c.animations.findIndex(a => a.leaf === leaf);
            if (custom && at < 0) {
                c.animations.push({ leaf: leaf, enabled: true, speed: 4, curve: c.curves.length > 0 ? c.curves[0].name : "default", style: "" });
            } else if (!custom && at >= 0) {
                c.animations.splice(at, 1);
            }
        });
    }

    function setAnim(leaf, field, value) {
        AnimationsService.update(c => {
            const a = c.animations.find(x => x.leaf === leaf);
            if (a) a[field] = value;
        });
    }

    function fmtMs(seconds) { return Math.round(seconds * 1000) + " ms"; }

    // ------------------------------------------------------------------
    // small building blocks
    // ------------------------------------------------------------------
    component Label: Text {
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(0)
        color: Colors.overBackground
        wrapMode: Text.WordWrap
    }

    component Muted: Label {
        font.pixelSize: Styling.fontSize(-1)
        color: Colors.overSurfaceVariant
    }

    component Card: StyledRect {
        id: card
        default property alias content: inner.data
        property string title: ""
        variant: "pane"
        radius: Styling.radius(0)
        Layout.fillWidth: true
        implicitHeight: inner.implicitHeight + 24

        ColumnLayout {
            id: inner
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            Label {
                visible: card.title !== ""
                text: card.title
                font.bold: true
                Layout.fillWidth: true
            }
        }
    }

    component Btn: StyledRect {
        id: btn
        property string text: ""
        property string icon: ""
        property string kind: "normal"            // normal | primary | danger
        property bool hovered: false
        signal clicked

        variant: !enabled ? "common" : (kind === "primary" ? (hovered ? "primaryfocus" : "primary")
            : kind === "danger" ? (hovered ? "errorfocus" : "error") : (hovered ? "focus" : "common"))
        radius: Styling.radius(-2)
        implicitHeight: 32
        implicitWidth: row.implicitWidth + 24
        opacity: enabled ? 1 : 0.5

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 6

            Text {
                visible: btn.icon !== ""
                text: btn.icon
                font.family: Icons.font
                font.pixelSize: 16
                color: btn.kind === "primary" ? Styling.srItem("primary") : btn.kind === "danger" ? Styling.srItem("error") : Colors.overBackground
            }
            Text {
                visible: btn.text !== ""
                text: btn.text
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: btn.kind === "primary" ? Styling.srItem("primary") : btn.kind === "danger" ? Styling.srItem("error") : Colors.overBackground
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            enabled: btn.enabled
            cursorShape: Qt.PointingHandCursor
            onEntered: btn.hovered = true
            onExited: btn.hovered = false
            onClicked: btn.clicked()
        }
    }

    component Chip: StyledRect {
        id: chip
        property string text: ""
        property bool active: false
        property bool hovered: false
        signal clicked

        variant: active ? "primary" : (hovered ? "focus" : "common")
        radius: Styling.radius(-4)
        implicitHeight: 26
        implicitWidth: chipText.implicitWidth + 18

        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.text
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-1)
            color: chip.active ? Styling.srItem("primary") : Colors.overBackground
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: chip.hovered = true
            onExited: chip.hovered = false
            onClicked: chip.clicked()
        }
    }

    component Toggle: RowLayout {
        id: tg
        property string caption: ""
        property bool checked: false
        signal toggled(bool value)

        Layout.fillWidth: true
        spacing: 8
        opacity: enabled ? 1 : 0.5

        Label {
            text: tg.caption
            Layout.fillWidth: true
        }

        Rectangle {
            id: track
            implicitWidth: 40
            implicitHeight: 22
            radius: 11
            color: tg.checked ? Styling.srItem("overprimary") : Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.22)

            Rectangle {
                width: 16
                height: 16
                radius: 8
                y: 3
                x: tg.checked ? parent.width - width - 3 : 3
                color: tg.checked ? Colors.background : Colors.overBackground

                Behavior on x {
                    enabled: Config.animDuration > 0
                    NumberAnimation {
                        duration: Config.animDuration / 2
                        easing.type: Easing.OutCubic
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: tg.enabled
                cursorShape: Qt.PointingHandCursor
                onClicked: tg.toggled(!tg.checked)
            }
        }
    }

    component NumField: ColumnLayout {
        id: nf
        property string caption: ""
        property real value: 0
        property real from: 0
        property real to: 100
        property int decimals: 2
        property string error: ""
        signal edited(real v)

        spacing: 2
        Layout.fillWidth: true

        Muted {
            visible: nf.caption !== ""
            text: nf.caption
        }

        StyledRect {
            variant: nf.error !== "" ? "error" : "common"
            radius: Styling.radius(-2)
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            Layout.minimumWidth: 56

            TextInput {
                id: input
                anchors.fill: parent
                anchors.margins: 8
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: nf.error !== "" ? Styling.srItem("error") : Colors.overBackground
                selectByMouse: true
                clip: true
                horizontalAlignment: TextInput.AlignHCenter
                verticalAlignment: TextInput.AlignVCenter
                inputMethodHints: Qt.ImhFormattedNumbersOnly

                function show() { text = Logic.fmt(nf.value); }
                readonly property real bound: nf.value
                onBoundChanged: if (!activeFocus) show()
                Component.onCompleted: show()

                onEditingFinished: {
                    const v = parseFloat(text.replace(",", "."));
                    if (isFinite(v)) nf.edited(Math.max(nf.from, Math.min(nf.to, v)));
                    show();
                }
            }
        }
    }

    component TextBox: ColumnLayout {
        id: tb
        property string caption: ""
        property string text: ""
        property string placeholder: ""
        property string error: ""
        property bool mono: false
        signal committed(string value)

        spacing: 2
        Layout.fillWidth: true

        Muted {
            visible: tb.caption !== ""
            text: tb.caption
        }

        StyledRect {
            variant: tb.error !== "" ? "error" : "common"
            radius: Styling.radius(-2)
            Layout.fillWidth: true
            Layout.preferredHeight: 32

            TextInput {
                id: field
                anchors.fill: parent
                anchors.margins: 8
                font.family: tb.mono ? "monospace" : Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: tb.error !== "" ? Styling.srItem("error") : Colors.overBackground
                selectByMouse: true
                clip: true
                verticalAlignment: TextInput.AlignVCenter

                readonly property string bound: tb.text
                onBoundChanged: if (!activeFocus && text !== bound) text = bound
                Component.onCompleted: text = tb.text
                onEditingFinished: tb.committed(text)

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: field.text === "" && !field.activeFocus
                    text: tb.placeholder
                    font: field.font
                    color: Colors.overSurfaceVariant
                }
            }
        }
    }

    // Slider with optional logarithmic scale (stiffness spans decades).
    component ParamSlider: ColumnLayout {
        id: ps
        property string caption: ""
        property real value: 1
        property real from: 0
        property real to: 100
        property bool log: false
        property int decimals: 2
        property string error: ""
        signal edited(real v)

        spacing: 2
        Layout.fillWidth: true

        RowLayout {
            Layout.fillWidth: true
            Muted {
                text: ps.caption
                Layout.fillWidth: true
            }
            NumField {
                Layout.preferredWidth: 84
                Layout.fillWidth: false
                value: ps.value
                from: ps.from
                to: ps.to
                error: ps.error
                onEdited: v => ps.edited(v)
            }
        }

        Item {
            id: rail
            Layout.fillWidth: true
            Layout.preferredHeight: 20

            readonly property real ratio: {
                const v = Math.max(ps.from, Math.min(ps.to, ps.value));
                if (ps.log) return (Math.log(v) - Math.log(ps.from)) / (Math.log(ps.to) - Math.log(ps.from));
                return (v - ps.from) / (ps.to - ps.from);
            }

            function valueAt(x) {
                const r = Math.max(0, Math.min(1, x / width));
                const v = ps.log ? Math.exp(Math.log(ps.from) + r * (Math.log(ps.to) - Math.log(ps.from))) : ps.from + r * (ps.to - ps.from);
                const p = Math.pow(10, ps.decimals);
                return Math.round(v * p) / p;
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.18)

                Rectangle {
                    width: parent.width * rail.ratio
                    height: parent.height
                    radius: 2
                    color: Styling.srItem("overprimary")
                }
            }
            Rectangle {
                width: 14
                height: 14
                radius: 7
                anchors.verticalCenter: parent.verticalCenter
                x: rail.ratio * (rail.width - width)
                color: Styling.srItem("overprimary")
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onPressed: mouse => ps.edited(rail.valueAt(mouse.x))
                onPositionChanged: mouse => { if (pressed) ps.edited(rail.valueAt(mouse.x)); }
            }
        }
    }

    // ------------------------------------------------------------------
    // layout
    // ------------------------------------------------------------------
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: column.implicitHeight + 24
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column
            x: root.sideMargin
            width: root.contentWidth
            spacing: 8

            // ---------------- header ----------------
            Label {
                text: "Animations"
                font.pixelSize: Styling.fontSize(2)
                font.weight: Font.Medium
                Layout.fillWidth: true
            }

            Card {
                Toggle {
                    caption: "Use custom animations"
                    checked: root.on
                    onToggled: v => AnimationsService.setEnabled(v)
                }
                Muted {
                    Layout.fillWidth: true
                    text: root.on
                        ? "Your curves and animations are pushed into Hyprland on top of Ambxst's defaults."
                        : "Off: Ambxst's built-in animation block stays in charge. Turning it off restores it immediately."
                }
                Toggle {
                    visible: root.on
                    caption: "Apply changes as I edit"
                    checked: root.cfg.autoApply
                    onToggled: v => AnimationsService.update(c => { c.autoApply = v; })
                }

                RowLayout {
                    visible: root.on
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: AnimationsService.applyState === "error" || AnimationsService.applyState === "blocked" ? Colors.error
                            : AnimationsService.applyState === "ok" ? Styling.srItem("overprimary") : Colors.overSurfaceVariant
                    }
                    Muted {
                        Layout.fillWidth: true
                        text: AnimationsService.applySummary !== "" ? AnimationsService.applySummary
                            : (AnimationsService.unapplied ? "Changes not applied yet." : "Waiting for the first apply.")
                    }
                    Btn {
                        text: "Apply"
                        kind: "primary"
                        visible: AnimationsService.unapplied || AnimationsService.applyState === "error"
                        enabled: !AnimationsService.hasErrors && AnimationsService.applyState !== "applying"
                        onClicked: AnimationsService.applyNow()
                    }
                }
            }

            Card {
                id: problems
                visible: AnimationsService.hasErrors
                title: "Fix before applying"
                Repeater {
                    model: AnimationsService.errors.slice(0, 5)
                    delegate: Label {
                        required property var modelData
                        Layout.fillWidth: true
                        color: Colors.error
                        font.pixelSize: Styling.fontSize(-1)
                        text: modelData.scope + " “" + modelData.id + "”: " + modelData.message
                    }
                }
                Muted {
                    visible: AnimationsService.errors.length > 5
                    text: "…and " + (AnimationsService.errors.length - 5) + " more."
                }
            }

            Card {
                visible: AnimationsService.applyState === "error"
                title: "Hyprland rejected some statements"
                Repeater {
                    model: AnimationsService.applyResults.filter(r => !r.ok).slice(0, 5)
                    delegate: Label {
                        required property var modelData
                        Layout.fillWidth: true
                        color: Colors.error
                        font.pixelSize: Styling.fontSize(-1)
                        text: modelData.label + " — " + (modelData.message || "rejected")
                    }
                }
                Muted {
                    Layout.fillWidth: true
                    text: "Leaves marked “newer builds” do not exist on every Hyprland version. Remove or disable them to clear this."
                }
            }

            // ---------------- empty state ----------------
            Card {
                visible: root.cfg.curves.length === 0 && root.cfg.animations.length === 0
                title: "Start from a preset"
                Muted {
                    Layout.fillWidth: true
                    text: "Load a starting point, then tune it. You can also paste your existing hl.curve / hl.animation (or bezier / animation) lines under Presets & tools."
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: Logic.PRESETS
                        delegate: Btn {
                            required property var modelData
                            text: modelData.name
                            kind: "primary"
                            onClicked: AnimationsService.loadPreset(modelData.id)
                        }
                    }
                }
            }

            SegmentedSwitch {
                Layout.alignment: Qt.AlignHCenter
                options: ["Curves", "Animations", "Presets & tools"]
                currentIndex: root.tab
                onIndexChanged: index => root.tab = index
            }

            // =====================================================
            // TAB 0: CURVES
            // =====================================================
            ColumnLayout {
                visible: root.tab === 0
                Layout.fillWidth: true
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Btn {
                        text: "Bezier"
                        icon: Icons.plus
                        onClicked: root.addCurve(Logic.newBezier("bezier"))
                    }
                    Btn {
                        text: "Spring"
                        icon: Icons.plus
                        onClicked: root.addCurve(Logic.newSpring("spring"))
                    }
                    Item { Layout.fillWidth: true }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Muted { text: "Bezier presets"; height: 26; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: Logic.BEZIER_PRESETS
                        delegate: Chip {
                            required property var modelData
                            text: modelData.name
                            onClicked: root.addCurve(modelData)
                        }
                    }
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Muted { text: "Spring presets"; height: 26; verticalAlignment: Text.AlignVCenter }
                    Repeater {
                        model: Logic.SPRING_PRESETS
                        delegate: Chip {
                            required property var modelData
                            text: modelData.name
                            onClicked: root.addCurve(modelData)
                        }
                    }
                }

                Muted {
                    visible: root.cfg.curves.length === 0
                    Layout.fillWidth: true
                    text: "No curves yet. Add one above; Hyprland's built-in “default” curve is always available."
                }

                RowLayout {
                    visible: root.cfg.curves.length > 0
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    // curve list
                    ColumnLayout {
                        Layout.preferredWidth: root.contentWidth > 600 ? 190 : 140
                        Layout.maximumWidth: root.contentWidth > 600 ? 190 : 140
                        Layout.alignment: Qt.AlignTop
                        spacing: 4

                        Repeater {
                            model: root.cfg.curves
                            delegate: StyledRect {
                                id: row
                                required property var modelData
                                required property int index
                                property bool hovered: false
                                readonly property bool selected: index === root.selectedCurve

                                Layout.fillWidth: true
                                implicitHeight: 44
                                radius: Styling.radius(-2)
                                variant: selected ? "focus" : (hovered ? "pane" : "common")

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 8

                                    CurvePreview {
                                        curve: row.modelData
                                        Layout.preferredWidth: 30
                                        Layout.preferredHeight: 28
                                        padding: 3
                                        lineColor: row.selected ? Styling.srItem("overprimary") : Colors.overSurfaceVariant
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Label {
                                            text: row.modelData.name
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                            font.weight: row.selected ? Font.Bold : Font.Normal
                                            color: root.errFor("curve", row.modelData.name, "") !== "" ? Colors.error : Colors.overBackground
                                        }
                                        Muted {
                                            text: row.modelData.type
                                            font.pixelSize: Styling.fontSize(-2)
                                        }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: row.hovered = true
                                    onExited: row.hovered = false
                                    onClicked: root.selectedCurve = row.index
                                }
                            }
                        }
                    }

                    // editor
                    Card {
                        id: editor
                        readonly property var c: root.curveAt(root.selectedCurve)
                        readonly property int i: root.selectedCurve
                        visible: c !== null
                        Layout.alignment: Qt.AlignTop

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            TextBox {
                                caption: "Name"
                                text: editor.c ? editor.c.name : ""
                                error: editor.c ? root.errFor("curve", editor.c.name, "name") : ""
                                onCommitted: v => { if (editor.c && v !== editor.c.name) root.renameCurve(editor.i, v); }
                            }
                            Btn {
                                Layout.alignment: Qt.AlignBottom
                                icon: Icons.copy
                                onClicked: root.duplicateCurve(editor.i)
                            }
                            Btn {
                                Layout.alignment: Qt.AlignBottom
                                icon: Icons.trash
                                kind: "danger"
                                onClicked: root.deleteCurve(editor.i)
                            }
                        }

                        Muted {
                            visible: editor.c && root.errFor("curve", editor.c.name, "name") !== ""
                            Layout.fillWidth: true
                            color: Colors.error
                            text: editor.c ? root.errFor("curve", editor.c.name, "name") : ""
                        }

                        CurvePreview {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 220
                            curve: editor.c
                            editable: !!editor.c && editor.c.type === "bezier"
                            onBezierEdited: (x1, y1, x2, y2) => root.setBezier(editor.i, x1, y1, x2, y2)
                        }

                        MotionPreview {
                            Layout.fillWidth: true
                            curve: editor.c
                        }

                        // bezier fields
                        RowLayout {
                            visible: !!editor.c && editor.c.type === "bezier"
                            Layout.fillWidth: true
                            spacing: 6
                            NumField {
                                caption: "x1"
                                value: editor.c && editor.c.type === "bezier" ? editor.c.x1 : 0
                                from: 0
                                to: 1
                                error: editor.c ? root.errFor("curve", editor.c.name, "x1") : ""
                                onEdited: v => root.setCurve(editor.i, "x1", v)
                            }
                            NumField {
                                caption: "y1"
                                value: editor.c && editor.c.type === "bezier" ? editor.c.y1 : 0
                                from: -3
                                to: 3
                                error: editor.c ? root.errFor("curve", editor.c.name, "y1") : ""
                                onEdited: v => root.setCurve(editor.i, "y1", v)
                            }
                            NumField {
                                caption: "x2"
                                value: editor.c && editor.c.type === "bezier" ? editor.c.x2 : 0
                                from: 0
                                to: 1
                                error: editor.c ? root.errFor("curve", editor.c.name, "x2") : ""
                                onEdited: v => root.setCurve(editor.i, "x2", v)
                            }
                            NumField {
                                caption: "y2"
                                value: editor.c && editor.c.type === "bezier" ? editor.c.y2 : 0
                                from: -3
                                to: 3
                                error: editor.c ? root.errFor("curve", editor.c.name, "y2") : ""
                                onEdited: v => root.setCurve(editor.i, "y2", v)
                            }
                        }
                        Muted {
                            visible: !!editor.c && editor.c.type === "bezier"
                            Layout.fillWidth: true
                            text: "Drag the two dots. y may go outside 0–1 to overshoot."
                        }

                        // spring fields
                        ColumnLayout {
                            visible: !!editor.c && editor.c.type === "spring"
                            Layout.fillWidth: true
                            spacing: 6

                            ParamSlider {
                                caption: "Mass (keep near 1)"
                                value: editor.c && editor.c.type === "spring" ? editor.c.mass : 1
                                from: 0.1
                                to: 10
                                log: true
                                error: editor.c ? root.errFor("curve", editor.c.name, "mass") : ""
                                onEdited: v => root.setCurve(editor.i, "mass", v)
                            }
                            ParamSlider {
                                caption: "Stiffness (higher = faster)"
                                value: editor.c && editor.c.type === "spring" ? editor.c.stiffness : 200
                                from: 1
                                to: 2000
                                log: true
                                decimals: 1
                                error: editor.c ? root.errFor("curve", editor.c.name, "stiffness") : ""
                                onEdited: v => root.setCurve(editor.i, "stiffness", v)
                            }
                            ParamSlider {
                                caption: "Dampening (higher = less bounce)"
                                value: editor.c && editor.c.type === "spring" ? editor.c.dampening : 20
                                from: 0.5
                                to: 200
                                log: true
                                decimals: 1
                                error: editor.c ? root.errFor("curve", editor.c.name, "dampening") : ""
                                onEdited: v => root.setCurve(editor.i, "dampening", v)
                            }

                            Label {
                                id: springStats
                                readonly property var st: editor.c && editor.c.type === "spring"
                                    ? Logic.springStats(editor.c.mass, editor.c.stiffness, editor.c.dampening)
                                    : ({ settle: 0, overshoot: 0, zeta: 1 })
                                Layout.fillWidth: true
                                font.pixelSize: Styling.fontSize(-1)
                                color: Styling.srItem("overprimary")
                                text: (st.zeta < 0.9999 ? "Bouncy" : st.zeta <= 1.0001 ? "Critically damped" : "Overdamped")
                                    + " · settles in ≈ " + root.fmtMs(st.settle)
                                    + " · overshoot " + (st.overshoot * 100).toFixed(1) + "%"
                                    + " · ζ " + st.zeta.toFixed(2)
                            }
                            Muted {
                                Layout.fillWidth: true
                                text: "Ideal spring response. Hyprland also scales an animation's time by its speed, so use the Animations tab to judge real duration."
                            }
                        }

                        Muted {
                            readonly property var used: editor.c ? root.usedBy(editor.c.name) : []
                            Layout.fillWidth: true
                            text: used.length > 0 ? "Used by: " + used.join(", ") : "Not used by any animation yet."
                        }
                    }
                }
            }

            // =====================================================
            // TAB 1: ANIMATIONS
            // =====================================================
            ColumnLayout {
                visible: root.tab === 1
                Layout.fillWidth: true
                spacing: 6

                Muted {
                    Layout.fillWidth: true
                    text: "Hyprland animations form a tree: a leaf you do not customise inherits from its parent. Tick a leaf to give it its own curve, speed and style. Speed is in deciseconds (1 = 100 ms)."
                }

                Repeater {
                    model: Logic.LEAVES.concat(root.extraLeaves)
                    delegate: StyledRect {
                        id: leafRow
                        required property var modelData
                        readonly property var a: root.animFor(modelData.leaf)
                        readonly property bool custom: a !== null
                        readonly property var suggestions: Logic.STYLE_SUGGESTIONS[modelData.styleKind] || []

                        Layout.fillWidth: true
                        Layout.leftMargin: Math.min(3, Logic.leafDepth(modelData.leaf)) * 14
                        variant: custom ? "pane" : "common"
                        radius: Styling.radius(-2)
                        implicitHeight: leafCol.implicitHeight + 16
                        opacity: custom && !a.enabled ? 0.7 : 1

                        ColumnLayout {
                            id: leafCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Rectangle {
                                    width: 18
                                    height: 18
                                    radius: 4
                                    color: leafRow.custom ? Styling.srItem("overprimary") : "transparent"
                                    border.width: 2
                                    border.color: leafRow.custom ? Styling.srItem("overprimary") : Colors.overSurfaceVariant
                                    Text {
                                        anchors.centerIn: parent
                                        visible: leafRow.custom
                                        text: Icons.accept
                                        font.family: Icons.font
                                        font.pixelSize: 12
                                        color: Colors.background
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.toggleLeaf(leafRow.modelData.leaf, !leafRow.custom)
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Label {
                                        Layout.fillWidth: true
                                        text: leafRow.modelData.label + (leafRow.modelData.since ? "  ·  " + leafRow.modelData.since : "")
                                        font.weight: leafRow.custom ? Font.Bold : Font.Normal
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }
                                    Muted {
                                        Layout.fillWidth: true
                                        text: leafRow.modelData.leaf + " — " + leafRow.modelData.desc
                                        font.pixelSize: Styling.fontSize(-2)
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }
                                }

                                Toggle {
                                    visible: leafRow.custom
                                    Layout.fillWidth: false
                                    caption: ""
                                    checked: leafRow.custom && leafRow.a.enabled
                                    onToggled: v => root.setAnim(leafRow.modelData.leaf, "enabled", v)
                                }
                            }

                            // curve chooser
                            Flow {
                                visible: leafRow.custom && leafRow.a.enabled
                                Layout.fillWidth: true
                                spacing: 6
                                Repeater {
                                    model: root.curveNames
                                    delegate: Chip {
                                        required property string modelData
                                        text: modelData
                                        active: leafRow.custom && leafRow.a.curve === modelData
                                        onClicked: root.setAnim(leafRow.modelData.leaf, "curve", modelData)
                                    }
                                }
                            }
                            Muted {
                                visible: leafRow.custom && leafRow.a.enabled && root.errFor("animation", leafRow.modelData.leaf, "curve") !== ""
                                color: Colors.error
                                Layout.fillWidth: true
                                text: root.errFor("animation", leafRow.modelData.leaf, "curve")
                            }

                            RowLayout {
                                visible: leafRow.custom && leafRow.a.enabled
                                Layout.fillWidth: true
                                spacing: 8
                                NumField {
                                    caption: "Speed"
                                    Layout.preferredWidth: 90
                                    Layout.fillWidth: false
                                    value: leafRow.custom ? leafRow.a.speed : 0
                                    from: 0.01
                                    to: 1000
                                    error: root.errFor("animation", leafRow.modelData.leaf, "speed")
                                    onEdited: v => root.setAnim(leafRow.modelData.leaf, "speed", v)
                                }
                                TextBox {
                                    visible: leafRow.modelData.styleKind !== "none"
                                    caption: "Style"
                                    placeholder: "default"
                                    text: leafRow.custom ? leafRow.a.style : ""
                                    error: root.errFor("animation", leafRow.modelData.leaf, "style")
                                    onCommitted: v => root.setAnim(leafRow.modelData.leaf, "style", v.trim())
                                }
                            }

                            Flow {
                                visible: leafRow.custom && leafRow.a.enabled && leafRow.suggestions.length > 0
                                Layout.fillWidth: true
                                spacing: 6
                                Repeater {
                                    model: leafRow.suggestions
                                    delegate: Chip {
                                        required property string modelData
                                        text: modelData
                                        active: leafRow.custom && leafRow.a.style === modelData
                                        onClicked: root.setAnim(leafRow.modelData.leaf, "style", modelData)
                                    }
                                }
                            }
                            Muted {
                                visible: leafRow.custom && leafRow.a.enabled && leafRow.a.style === "auto"
                                Layout.fillWidth: true
                                text: "auto follows your bar: slidefade for top/bottom, slidefadevert for left/right."
                            }
                        }
                    }
                }
            }

            // =====================================================
            // TAB 2: PRESETS & TOOLS
            // =====================================================
            ColumnLayout {
                visible: root.tab === 2
                Layout.fillWidth: true
                spacing: 8

                Card {
                    title: "Presets"
                    Muted {
                        Layout.fillWidth: true
                        text: "Loading a preset replaces your current curves and animations."
                    }
                    Repeater {
                        model: Logic.PRESETS
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Label { text: modelData.name; font.weight: Font.Medium; Layout.fillWidth: true }
                                Muted { text: modelData.description; Layout.fillWidth: true }
                            }
                            Btn {
                                text: "Load"
                                onClicked: AnimationsService.loadPreset(modelData.id)
                            }
                        }
                    }
                }

                Card {
                    title: "Import"
                    Muted {
                        Layout.fillWidth: true
                        text: "Paste hl.curve() / hl.animation() lines, or hyprlang bezier = / animation = lines. Matching names and leaves are replaced, everything else is kept."
                    }
                    StyledRect {
                        variant: "common"
                        radius: Styling.radius(-2)
                        Layout.fillWidth: true
                        Layout.preferredHeight: 110

                        Flickable {
                            anchors.fill: parent
                            anchors.margins: 8
                            clip: true
                            contentHeight: importArea.implicitHeight
                            TextArea.flickable: TextArea {
                                id: importArea
                                font.family: "monospace"
                                font.pixelSize: Styling.fontSize(-1)
                                color: Colors.overBackground
                                wrapMode: TextEdit.NoWrap
                                selectByMouse: true
                                background: null
                                placeholderText: "hl.curve(\"snap\", { type = \"bezier\", points = { {0.05, 0.9}, {0.1, 1.05} } })"
                                placeholderTextColor: Colors.overSurfaceVariant
                                text: root.importText
                                onTextChanged: root.importText = text
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Btn {
                            text: "Import"
                            kind: "primary"
                            enabled: root.importText.trim() !== ""
                            onClicked: {
                                const r = AnimationsService.importFromText(root.importText);
                                const n = r.curves.length + r.animations.length;
                                root.importMessage = n === 0
                                    ? "Nothing recognised in that text."
                                    : "Imported " + r.curves.length + " curve(s) and " + r.animations.length + " animation(s)"
                                        + (r.skipped.length > 0 ? "; skipped " + r.skipped.length + " line(s) it could not read." : ".");
                                if (n > 0) { importArea.text = ""; root.importText = ""; }
                            }
                        }
                        Muted {
                            Layout.fillWidth: true
                            text: root.importMessage
                        }
                    }
                }

                Card {
                    title: "Keep it across Hyprland reloads"
                    Muted {
                        Layout.fillWidth: true
                        text: "Ambxst applies your animations live and re-applies them when its config regenerates. To make them part of Hyprland's own config load (survives a manual reload or a restart before Ambxst starts), add a small loader to the OVERRIDES section of your hyprland.lua."
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            color: AnimationsService.loaderState === "installed" ? Styling.srItem("overprimary") : Colors.overSurfaceVariant
                        }
                        Muted {
                            Layout.fillWidth: true
                            text: AnimationsService.loaderState === "installed" ? "Loader is in hyprland.lua."
                                : AnimationsService.loaderState === "absent" ? "Loader not installed."
                                : AnimationsService.loaderState === "managed" ? "hyprland.lua is managed by Nix; add the snippet by hand."
                                : AnimationsService.loaderState === "missing" ? "No Lua config found at ~/.config/hypr/hyprland.lua."
                                : "Checking…"
                        }
                        Btn {
                            visible: AnimationsService.loaderState === "absent"
                            text: "Add loader"
                            onClicked: AnimationsService.installLoader()
                        }
                        Btn {
                            visible: AnimationsService.loaderState === "installed"
                            text: "Remove"
                            onClicked: AnimationsService.removeLoader()
                        }
                    }
                    Muted {
                        visible: AnimationsService.loaderMessage !== ""
                        Layout.fillWidth: true
                        text: AnimationsService.loaderMessage
                    }
                    Muted {
                        Layout.fillWidth: true
                        text: "A backup is written to hyprland.lua.animation-studio.bak before any change."
                    }
                }

                Card {
                    title: "Generated Lua"
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Btn {
                            text: root.showLua ? "Hide" : "Show"
                            onClicked: root.showLua = !root.showLua
                        }
                        Btn {
                            text: "Copy"
                            icon: Icons.copy
                            onClicked: AnimationsService.copyLuaToClipboard()
                        }
                        Item { Layout.fillWidth: true }
                    }
                    Muted {
                        Layout.fillWidth: true
                        text: AnimationsService.luaPath
                    }
                    StyledRect {
                        visible: root.showLua
                        variant: "common"
                        radius: Styling.radius(-2)
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(260, luaText.implicitHeight + 16)
                        Flickable {
                            anchors.fill: parent
                            anchors.margins: 8
                            clip: true
                            contentWidth: luaText.implicitWidth
                            contentHeight: luaText.implicitHeight
                            Text {
                                id: luaText
                                text: AnimationsService.luaPreview
                                font.family: "monospace"
                                font.pixelSize: Styling.fontSize(-2)
                                color: Colors.overBackground
                            }
                        }
                    }
                }

                Card {
                    title: "Restore Ambxst defaults"
                    Muted {
                        Layout.fillWidth: true
                        text: "Puts Ambxst's own animation block back live and switches custom animations off. Your curves and animations stay saved. A Hyprland reload restores the original tree exactly."
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Btn {
                            text: "Restore defaults"
                            icon: Icons.arrowCounterClockwise
                            kind: "danger"
                            enabled: root.on
                            onClicked: AnimationsService.restoreDefaults()
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }
        }
    }
}
