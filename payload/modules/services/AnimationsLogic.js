.pragma library

// Animation Studio
//
// Everything here is deterministic so it can be unit-tested outside
// Quickshell. The service (AnimationsService.qml) owns state and side
// effects; the panel (AnimationsPanel.qml) owns presentation.
//
// Target: Hyprland's Lua configuration API (>= 0.55, tuned for 0.56):
//   hl.curve(NAME, { type = "bezier", points = { {x1, y1}, {x2, y2} } })
//   hl.curve(NAME, { type = "spring", mass = M, stiffness = K, dampening = D })
//   hl.animation({ leaf = L, enabled = B, speed = S, bezier|spring = NAME, style = STR })
// The spring key is spelled "dampening" (sic) by Hyprland.

var SCHEMA_VERSION = 1;

// Names Hyprland already owns. Redefining them would silently change every
// animation that relies on them.
var RESERVED_CURVES = ["default"];

// Curves that can be referenced without being defined here.
var BUILTIN_CURVES = [{ name: "default", type: "bezier", builtin: true }];

var LIMITS = {
    bezierX: [0, 1],
    bezierY: [-3, 3],
    mass: [0.01, 100],
    stiffness: [0.1, 5000],
    dampening: [0, 1000],
    speed: [0.01, 1000]
};

// ---------------------------------------------------------------------------
// Animation tree (Hyprland wiki, "Animation tree"). `since` marks leaves that
// only exist on newer builds; the panel labels them, and Hyprland itself will
// reject them on builds that lack them (reported per statement).
// styleKind selects the style suggestions shown in the panel.
// ---------------------------------------------------------------------------
var STYLE_SUGGESTIONS = {
    window: ["slide", "popin 80%", "gnomed"],
    layer: ["slide", "popin 80%", "fade"],
    workspace: ["auto", "slide", "slidevert", "fade", "slidefade 20%", "slidefadevert 20%"],
    angle: ["once", "loop"],
    none: []
};

var LEAVES = [
    { leaf: "global", parent: "", label: "Global", styleKind: "none", desc: "Fallback for every animation that is not set explicitly" },
    { leaf: "windows", parent: "global", label: "Windows", styleKind: "window", desc: "All window animations" },
    { leaf: "windowsIn", parent: "windows", label: "Window open", styleKind: "window", desc: "A window appears" },
    { leaf: "windowsOut", parent: "windows", label: "Window close", styleKind: "window", desc: "A window closes" },
    { leaf: "windowsMove", parent: "windows", label: "Window move / resize", styleKind: "none", desc: "Moving, dragging and resizing" },
    { leaf: "layers", parent: "global", label: "Layers", styleKind: "layer", desc: "Layer surfaces (bars, launchers, notifications)" },
    { leaf: "layersIn", parent: "layers", label: "Layer open", styleKind: "layer", desc: "A layer surface appears" },
    { leaf: "layersOut", parent: "layers", label: "Layer close", styleKind: "layer", desc: "A layer surface closes" },
    { leaf: "fade", parent: "global", label: "Fade", styleKind: "none", desc: "All fades" },
    { leaf: "fadeIn", parent: "fade", label: "Fade in", styleKind: "none", desc: "Window open fade" },
    { leaf: "fadeOut", parent: "fade", label: "Fade out", styleKind: "none", desc: "Window close fade" },
    { leaf: "fadeSwitch", parent: "fade", label: "Fade on focus", styleKind: "none", desc: "Active window / opacity change" },
    { leaf: "fadeShadow", parent: "fade", label: "Fade shadow", styleKind: "none", desc: "Shadow change on focus" },
    { leaf: "fadeGlow", parent: "fade", label: "Fade glow", styleKind: "none", desc: "Glow change on focus", since: "newer builds" },
    { leaf: "fadeDim", parent: "fade", label: "Fade dim", styleKind: "none", desc: "Dimming of inactive windows" },
    { leaf: "fadeLayers", parent: "fade", label: "Fade layers", styleKind: "none", desc: "Fade on layers" },
    { leaf: "fadeLayersIn", parent: "fadeLayers", label: "Fade layer in", styleKind: "none", desc: "Layer open fade" },
    { leaf: "fadeLayersOut", parent: "fadeLayers", label: "Fade layer out", styleKind: "none", desc: "Layer close fade" },
    { leaf: "fadePopups", parent: "fade", label: "Fade popups", styleKind: "none", desc: "Wayland popups" },
    { leaf: "fadePopupsIn", parent: "fadePopups", label: "Fade popup in", styleKind: "none", desc: "Popup open fade" },
    { leaf: "fadePopupsOut", parent: "fadePopups", label: "Fade popup out", styleKind: "none", desc: "Popup close fade" },
    { leaf: "fadeDpms", parent: "fade", label: "Fade on DPMS", styleKind: "none", desc: "Fade when the screen sleeps or wakes" },
    { leaf: "border", parent: "global", label: "Border", styleKind: "none", desc: "Border colour change" },
    { leaf: "borderangle", parent: "global", label: "Border angle", styleKind: "angle", desc: "Border gradient angle (loop keeps the GPU busy)" },
    { leaf: "shadowangle", parent: "global", label: "Shadow angle", styleKind: "angle", desc: "Shadow gradient angle", since: "newer builds" },
    { leaf: "glowangle", parent: "global", label: "Glow angle", styleKind: "angle", desc: "Glow gradient angle", since: "newer builds" },
    { leaf: "workspaces", parent: "global", label: "Workspaces", styleKind: "workspace", desc: "Workspace switching" },
    { leaf: "workspacesIn", parent: "workspaces", label: "Workspace in", styleKind: "workspace", desc: "Incoming workspace" },
    { leaf: "workspacesOut", parent: "workspaces", label: "Workspace out", styleKind: "workspace", desc: "Outgoing workspace" },
    { leaf: "specialWorkspace", parent: "workspaces", label: "Special workspace", styleKind: "workspace", desc: "Scratchpad workspaces" },
    { leaf: "specialWorkspaceIn", parent: "specialWorkspace", label: "Special in", styleKind: "workspace", desc: "Scratchpad opens" },
    { leaf: "specialWorkspaceOut", parent: "specialWorkspace", label: "Special out", styleKind: "workspace", desc: "Scratchpad closes" },
    { leaf: "zoomFactor", parent: "global", label: "Zoom", styleKind: "none", desc: "Screen zoom" },
    { leaf: "monitorAdded", parent: "global", label: "Monitor added", styleKind: "none", desc: "Monitor hot-plug zoom" }
];

function leafInfo(name) {
    for (var i = 0; i < LEAVES.length; i++)
        if (LEAVES[i].leaf === name) return LEAVES[i];
    return null;
}

function leafDepth(name) {
    var d = 0, info = leafInfo(name), guard = 0;
    while (info && info.parent && guard++ < 16) {
        d++;
        info = leafInfo(info.parent);
    }
    return d;
}

function leafOrder(name) {
    for (var i = 0; i < LEAVES.length; i++)
        if (LEAVES[i].leaf === name) return i;
    return LEAVES.length; // unknown (custom) leaves sort last
}

// axctl's own hard-coded animation block (axctl/pkg/ipc/hyprland/generator_lua.go).
// Used to emulate "restore defaults" without a compositor reload.
var AXCTL_DEFAULTS = {
    curve: { name: "myBezier", type: "bezier", x1: 0.4, y1: 0.0, x2: 0.2, y2: 1.0 },
    leaves: {
        windows: { speed: 2.5, style: "popin 80%" },
        border: { speed: 2.5, style: "" },
        fade: { speed: 2.5, style: "" },
        workspaces: { speed: 2.5, style: "auto" }
    },
    // What Hyprland uses when nothing above it is set.
    global: { speed: 10, curve: "default", style: "" }
};

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------
function fmt(n) {
    n = Number(n);
    if (!isFinite(n)) return "0";
    var s = n.toFixed(6);
    if (s.indexOf(".") >= 0) s = s.replace(/0+$/, "").replace(/\.$/, "");
    if (s === "-0" || s === "") s = "0";
    return s;
}

function luaString(s) {
    // Inputs are validated to a safe character set, but escape anyway.
    return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n").replace(/\r/g, "\\r") + "\"";
}

function num(v, fallback) {
    var n = (typeof v === "number") ? v : parseFloat(v);
    return isFinite(n) ? n : fallback;
}

// ---------------------------------------------------------------------------
// Config model
// ---------------------------------------------------------------------------
function emptyConfig() {
    return {
        version: SCHEMA_VERSION,
        enabled: false,
        autoApply: true,
        curves: [],
        animations: []
    };
}

function findCurve(cfg, name) {
    for (var i = 0; i < cfg.curves.length; i++)
        if (cfg.curves[i].name === name) return cfg.curves[i];
    for (var j = 0; j < BUILTIN_CURVES.length; j++)
        if (BUILTIN_CURVES[j].name === name) return BUILTIN_CURVES[j];
    return null;
}

function newBezier(name) {
    return { name: name, type: "bezier", x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0 };
}

function newSpring(name) {
    return { name: name, type: "spring", mass: 1, stiffness: 238.1191, dampening: 24.21279333 };
}

function uniqueCurveName(cfg, base) {
    var stem = String(base || "curve").replace(/[^A-Za-z0-9_]/g, "");
    if (!/^[A-Za-z]/.test(stem)) stem = "c" + stem;
    stem = stem.substring(0, 28);
    var name = stem, i = 2;
    while (findCurve(cfg, name)) name = stem + (i++);
    return name;
}

// Coerce arbitrary parsed JSON into a well-formed config. Never throws.
// Invalid entries are dropped here; validate() reports semantic problems on
// what remains.
function normalize(raw) {
    var cfg = emptyConfig();
    if (!raw || typeof raw !== "object") return cfg;

    cfg.enabled = raw.enabled === true;
    cfg.autoApply = raw.autoApply !== false;

    var curves = Array.isArray(raw.curves) ? raw.curves : [];
    for (var i = 0; i < curves.length; i++) {
        var c = curves[i];
        if (!c || typeof c !== "object" || typeof c.name !== "string") continue;
        if (c.type === "spring") {
            cfg.curves.push({
                name: c.name, type: "spring",
                mass: num(c.mass, 1), stiffness: num(c.stiffness, 238.1191),
                dampening: num(c.dampening !== undefined ? c.dampening : c.damping, 24.21279333)
            });
        } else if (c.type === "bezier") {
            cfg.curves.push({
                name: c.name, type: "bezier",
                x1: num(c.x1, 0.25), y1: num(c.y1, 0.1), x2: num(c.x2, 0.25), y2: num(c.y2, 1)
            });
        }
    }

    var anims = Array.isArray(raw.animations) ? raw.animations : [];
    for (var j = 0; j < anims.length; j++) {
        var a = anims[j];
        if (!a || typeof a !== "object" || typeof a.leaf !== "string") continue;
        cfg.animations.push({
            leaf: a.leaf,
            enabled: a.enabled !== false,
            speed: num(a.speed, 5),
            curve: typeof a.curve === "string" ? a.curve : "",
            style: typeof a.style === "string" ? a.style : ""
        });
    }
    return cfg;
}

function clone(o) { return JSON.parse(JSON.stringify(o)); }

// ---------------------------------------------------------------------------
// Validation. Returns [{ scope, id, field, message }].
// scope: "curve" | "animation" | "config".
// ---------------------------------------------------------------------------
var NAME_RE = /^[A-Za-z][A-Za-z0-9_]{0,31}$/;
var LEAF_RE = /^[A-Za-z][A-Za-z0-9]{0,39}$/;
var STYLE_RE = /^[A-Za-z0-9 %._-]{0,40}$/;

function inRange(v, r) { return typeof v === "number" && isFinite(v) && v >= r[0] && v <= r[1]; }

function validate(cfg) {
    var errs = [];
    function err(scope, id, field, message) { errs.push({ scope: scope, id: id, field: field, message: message }); }

    var seen = {};
    for (var i = 0; i < cfg.curves.length; i++) {
        var c = cfg.curves[i];
        if (!NAME_RE.test(c.name)) err("curve", c.name, "name", "Use letters, digits and _ (start with a letter, max 32).");
        else if (RESERVED_CURVES.indexOf(c.name) >= 0) err("curve", c.name, "name", "\"" + c.name + "\" is reserved by Hyprland.");
        else if (seen[c.name]) err("curve", c.name, "name", "Duplicate curve name.");
        seen[c.name] = true;

        if (c.type === "bezier") {
            if (!inRange(c.x1, LIMITS.bezierX)) err("curve", c.name, "x1", "x1 must be between 0 and 1.");
            if (!inRange(c.x2, LIMITS.bezierX)) err("curve", c.name, "x2", "x2 must be between 0 and 1.");
            if (!inRange(c.y1, LIMITS.bezierY)) err("curve", c.name, "y1", "y1 must be between -3 and 3.");
            if (!inRange(c.y2, LIMITS.bezierY)) err("curve", c.name, "y2", "y2 must be between -3 and 3.");
        } else if (c.type === "spring") {
            if (!inRange(c.mass, LIMITS.mass)) err("curve", c.name, "mass", "Mass must be between 0.01 and 100.");
            if (!inRange(c.stiffness, LIMITS.stiffness)) err("curve", c.name, "stiffness", "Stiffness must be between 0.1 and 5000.");
            if (!inRange(c.dampening, LIMITS.dampening)) err("curve", c.name, "dampening", "Dampening must be between 0 and 1000.");
        }
    }

    var seenLeaf = {};
    for (var j = 0; j < cfg.animations.length; j++) {
        var a = cfg.animations[j];
        if (!LEAF_RE.test(a.leaf)) { err("animation", a.leaf, "leaf", "Invalid leaf name."); continue; }
        if (seenLeaf[a.leaf]) err("animation", a.leaf, "leaf", "Leaf is defined more than once.");
        seenLeaf[a.leaf] = true;
        if (!a.enabled) continue;
        if (!inRange(a.speed, LIMITS.speed)) err("animation", a.leaf, "speed", "Speed must be between 0.01 and 1000.");
        if (!a.curve) err("animation", a.leaf, "curve", "Choose a curve.");
        else if (!findCurve(cfg, a.curve)) err("animation", a.leaf, "curve", "Curve \"" + a.curve + "\" is not defined.");
        if (!STYLE_RE.test(a.style)) err("animation", a.leaf, "style", "Style may only contain letters, digits, spaces, %, ., _ and -.");
        else if (a.style === "auto" && ["workspaces", "workspacesIn", "workspacesOut"].indexOf(a.leaf) < 0)
            err("animation", a.leaf, "style", "\"auto\" is only available for the workspaces leaves.");
    }
    return errs;
}

// ---------------------------------------------------------------------------
// Lua generation. Every statement is a single line and a single Lua call:
// compositor.eval splits on ';' so nothing may ride along on the same line.
// ---------------------------------------------------------------------------
function workspaceAutoStyle(barPosition) {
    return (barPosition === "left" || barPosition === "right") ? "slidefadevert 20%" : "slidefade 20%";
}

function resolveStyle(style, ctx) {
    if (style === "auto") return workspaceAutoStyle(ctx && ctx.barPosition);
    return style;
}

function curveStatement(c) {
    if (c.type === "spring") {
        return "hl.curve(" + luaString(c.name) + ", { type = \"spring\", mass = " + fmt(c.mass) +
            ", stiffness = " + fmt(c.stiffness) + ", dampening = " + fmt(c.dampening) + " })";
    }
    return "hl.curve(" + luaString(c.name) + ", { type = \"bezier\", points = { {" + fmt(c.x1) + ", " + fmt(c.y1) +
        "}, {" + fmt(c.x2) + ", " + fmt(c.y2) + "} } })";
}

function animationStatement(a, curveType, ctx) {
    if (!a.enabled) return "hl.animation({ leaf = " + luaString(a.leaf) + ", enabled = false })";
    var key = curveType === "spring" ? "spring" : "bezier";
    var s = "hl.animation({ leaf = " + luaString(a.leaf) + ", enabled = true, speed = " + fmt(a.speed) +
        ", " + key + " = " + luaString(a.curve);
    var style = resolveStyle(a.style, ctx);
    if (style) s += ", style = " + luaString(style);
    return s + " })";
}

function sortedAnimations(cfg) {
    return cfg.animations.slice().sort(function (p, q) { return leafOrder(p.leaf) - leafOrder(q.leaf); });
}

// Ordered statements that realise `cfg`. Curves first, then animations in
// tree order. Each item: { id, label, lua }.
function buildStatements(cfg, ctx) {
    var out = [];
    for (var i = 0; i < cfg.curves.length; i++)
        out.push({ id: "curve:" + cfg.curves[i].name, label: "curve " + cfg.curves[i].name, lua: curveStatement(cfg.curves[i]) });
    var anims = sortedAnimations(cfg);
    for (var j = 0; j < anims.length; j++) {
        var a = anims[j];
        var curve = a.enabled ? findCurve(cfg, a.curve) : null;
        out.push({ id: "animation:" + a.leaf, label: "animation " + a.leaf, lua: animationStatement(a, curve ? curve.type : "bezier", ctx) });
    }
    return out;
}

// Statements that put the axctl defaults back for every leaf `cfg` touches.
// It is an emulation: each touched leaf gets the values it would inherit from
// the nearest ancestor axctl configures, falling back to Hyprland's global
// default. A compositor reload restores the exact original tree.
function buildRestoreStatements(cfg, ctx) {
    var out = [];
    var d = AXCTL_DEFAULTS;
    out.push({ id: "curve:" + d.curve.name, label: "curve " + d.curve.name, lua: curveStatement(d.curve) });

    var leaves = {};
    for (var i = 0; i < cfg.animations.length; i++) leaves[cfg.animations[i].leaf] = true;
    // axctl's own leaves are always restored, even if the user never touched them.
    for (var k in d.leaves) leaves[k] = true;

    var names = Object.keys(leaves).sort(function (p, q) { return leafOrder(p) - leafOrder(q); });
    for (var n = 0; n < names.length; n++) {
        var leaf = names[n];
        var src = null, cur = leaf, guard = 0;
        while (cur && guard++ < 16) {
            if (d.leaves[cur]) { src = { speed: d.leaves[cur].speed, curve: d.curve.name, style: d.leaves[cur].style, type: "bezier" }; break; }
            var info = leafInfo(cur);
            cur = info ? info.parent : "";
        }
        if (!src) src = { speed: d.global.speed, curve: d.global.curve, style: d.global.style, type: "bezier" };
        var a = { leaf: leaf, enabled: true, speed: src.speed, curve: src.curve, style: src.style };
        // An "auto" style only makes sense on workspaces leaves; inherited
        // values for others are already concrete.
        out.push({ id: "animation:" + leaf, label: "animation " + leaf, lua: animationStatement(a, src.type, ctx) });
    }
    return out;
}

// The file Hyprland loads. Each statement is wrapped so one rejected leaf
// (e.g. a leaf that does not exist on this build) cannot abort the rest.
function buildLuaFile(cfg, ctx) {
    var lines = [];
    lines.push("-- Generated by Ambxst Animation Studio. Do not edit: changes are overwritten.");
    lines.push("-- Source of truth: ~/.config/ambxst/config/animations.json");
    lines.push("");
    if (!cfg.enabled) {
        lines.push("-- Animation Studio is switched off; nothing to apply.");
        return lines.join("\n") + "\n";
    }
    var stmts = buildStatements(cfg, ctx);
    if (stmts.length === 0) {
        lines.push("-- No curves or animations defined.");
        return lines.join("\n") + "\n";
    }
    lines.push("local function _try(fn)");
    lines.push("    local ok, err = pcall(fn)");
    lines.push("    if not ok then print(\"[animation-studio] \" .. tostring(err)) end");
    lines.push("end");
    lines.push("");
    for (var i = 0; i < stmts.length; i++)
        lines.push("_try(function() " + stmts[i].lua + " end)");
    return lines.join("\n") + "\n";
}

var LOADER_MARKER = "-- Ambxst Animation Studio";

function buildLoaderBlock() {
    return LOADER_MARKER + "\n" +
        "pcall(function()\n" +
        "    local base = os.getenv(\"XDG_DATA_HOME\") or (os.getenv(\"HOME\") .. \"/.local/share\")\n" +
        "    local f = loadfile(base .. \"/ambxst/animations.lua\")\n" +
        "    if f then f() end\n" +
        "end)\n";
}

// ---------------------------------------------------------------------------
// Curve maths (used by the preview, never by Hyprland)
// ---------------------------------------------------------------------------

// Cubic bezier easing, P0=(0,0) P3=(1,1): progress y at time fraction t.
function bezierProgress(x1, y1, x2, y2, t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    function bx(s) { var u = 1 - s; return 3 * u * u * s * x1 + 3 * u * s * s * x2 + s * s * s; }
    function by(s) { var u = 1 - s; return 3 * u * u * s * y1 + 3 * u * s * s * y2 + s * s * s; }
    function dbx(s) { var u = 1 - s; return 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2); }
    var s = t;
    for (var i = 0; i < 8; i++) {           // Newton
        var e = bx(s) - t;
        if (Math.abs(e) < 1e-7) return by(s);
        var d = dbx(s);
        if (Math.abs(d) < 1e-6) break;
        s -= e / d;
    }
    var lo = 0, hi = 1;                     // bisection fallback
    s = t;
    for (var k = 0; k < 40; k++) {
        var v = bx(s);
        if (Math.abs(v - t) < 1e-7) break;
        if (v < t) lo = s; else hi = s;
        s = (lo + hi) / 2;
    }
    return by(s);
}

function springDampingRatio(m, k, c) { return c / (2 * Math.sqrt(k * m)); }

// Unit step response of a mass-spring-damper released from rest.
function springStep(m, k, c, t) {
    if (t <= 0) return 0;
    var w0 = Math.sqrt(k / m);
    var z = springDampingRatio(m, k, c);
    if (z < 0.9999) {
        var wd = w0 * Math.sqrt(1 - z * z);
        return 1 - Math.exp(-z * w0 * t) * (Math.cos(wd * t) + (z * w0 / wd) * Math.sin(wd * t));
    }
    if (z <= 1.0001) return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
    var r = w0 * Math.sqrt(z * z - 1);
    var s1 = -z * w0 + r, s2 = -z * w0 - r;
    return 1 - (s2 * Math.exp(s1 * t) - s1 * Math.exp(s2 * t)) / (s2 - s1);
}

// { settle (s, within 2% and staying there), overshoot (fraction above 1), zeta }
function springStats(m, k, c) {
    var dt = 0.001, tmax = 10, peak = 0, settle = tmax;
    var last = -1;
    var n = Math.round(tmax / dt);
    for (var i = 1; i <= n; i++) {
        var v = springStep(m, k, c, i * dt);
        if (v > peak) peak = v;
        if (Math.abs(v - 1) > 0.02) last = i;
    }
    if (last >= 0) settle = Math.min(tmax, (last + 1) * dt);
    else settle = 0;
    return { settle: settle, overshoot: Math.max(0, peak - 1), zeta: springDampingRatio(m, k, c) };
}

// Sample a curve definition into [{ t, v }] (t in 0..1 of the preview span).
// Springs are sampled over their settle time (at least 0.15 s, at most 3 s).
function sampleCurve(curve, count) {
    var pts = [], span = 1, i;
    if (curve.type === "spring") {
        var st = springStats(curve.mass, curve.stiffness, curve.dampening);
        span = Math.min(3, Math.max(0.15, st.settle * 1.15));
        for (i = 0; i <= count; i++) {
            var t = span * i / count;
            pts.push({ t: i / count, v: springStep(curve.mass, curve.stiffness, curve.dampening, t) });
        }
    } else {
        for (i = 0; i <= count; i++) {
            var f = i / count;
            pts.push({ t: f, v: bezierProgress(curve.x1, curve.y1, curve.x2, curve.y2, f) });
        }
    }
    return { points: pts, span: span };
}

// Progress (0..1+) of `curve` at preview fraction f (0..1) over its span.
function curveValueAt(curve, f, span) {
    if (curve.type === "spring") return springStep(curve.mass, curve.stiffness, curve.dampening, span * f);
    return bezierProgress(curve.x1, curve.y1, curve.x2, curve.y2, f);
}

// ---------------------------------------------------------------------------
// Presets
// ---------------------------------------------------------------------------
function bez(name, x1, y1, x2, y2) { return { name: name, type: "bezier", x1: x1, y1: y1, x2: x2, y2: y2 }; }
function spr(name, m, k, c) { return { name: name, type: "spring", mass: m, stiffness: k, dampening: c }; }
function an(leaf, speed, curve, style) { return { leaf: leaf, enabled: true, speed: speed, curve: curve, style: style || "" }; }

var BEZIER_PRESETS = [
    bez("easeOutQuint", 0.23, 1, 0.32, 1),
    bez("easeInOutCubic", 0.65, 0.05, 0.36, 1),
    bez("easeOutBack", 0.34, 1.56, 0.64, 1),
    bez("overshoot", 0.5, 0.9, 0.1, 1.1),
    bez("linear", 0, 0, 1, 1),
    bez("quick", 0.15, 0, 0.1, 1)
];

var SPRING_PRESETS = [
    spr("easy", 1, 238.1191, 24.21279333),
    spr("snappy", 1, 400, 30),
    spr("bouncy", 1, 250, 14),
    spr("rubber", 1, 70, 10),
    spr("heavy", 2.5, 40, 10)
];

var PRESETS = [
    {
        id: "hyprland",
        name: "Hyprland defaults",
        description: "The stock 0.56 example configuration, with its spring on windows.",
        config: {
            curves: [bez("easeOutQuint", 0.23, 1, 0.32, 1), bez("linear", 0, 0, 1, 1), bez("almostLinear", 0.5, 0.5, 0.75, 1),
                bez("quick", 0.15, 0, 0.1, 1), spr("easy", 1, 238.1191, 24.21279333)],
            animations: [an("global", 10, "default"), an("border", 5.39, "easeOutQuint"), an("windows", 4.79, "easy"),
                an("windowsIn", 4.1, "easy", "popin 87%"), an("windowsOut", 1.49, "linear", "popin 87%"),
                an("fadeIn", 1.73, "almostLinear"), an("fadeOut", 1.46, "almostLinear"), an("fade", 3.03, "quick"),
                an("layers", 3.81, "easeOutQuint"), an("layersIn", 4, "easeOutQuint", "fade"), an("layersOut", 1.5, "linear", "fade"),
                an("fadeLayersIn", 1.79, "almostLinear"), an("fadeLayersOut", 1.39, "almostLinear"),
                an("workspaces", 1.94, "almostLinear", "fade"), an("workspacesIn", 1.21, "almostLinear", "fade"),
                an("workspacesOut", 1.94, "almostLinear", "fade"), an("zoomFactor", 7, "quick")]
        }
    },
    {
        id: "snappy",
        name: "Snappy",
        description: "Short bezier animations. Fast, no overshoot.",
        config: {
            curves: [bez("crisp", 0.2, 0.9, 0.1, 1), bez("out", 0.05, 0.7, 0.1, 1)],
            animations: [an("windows", 2.6, "crisp", "popin 88%"), an("layers", 2.4, "out", "popin 92%"),
                an("fade", 2.2, "out"), an("border", 3, "out"), an("workspaces", 2.6, "crisp", "auto")]
        }
    },
    {
        id: "springy",
        name: "Springy",
        description: "Spring physics on windows, layers and workspaces, with a little bounce.",
        config: {
            curves: [spr("pop", 1, 320, 22), spr("glide", 1, 260, 30), bez("quick", 0.15, 0, 0.1, 1)],
            animations: [an("windows", 4, "pop", "popin 85%"), an("windowsOut", 2, "quick", "popin 85%"),
                an("layers", 4, "pop", "popin 90%"), an("fade", 3, "quick"), an("workspaces", 4, "glide", "auto")]
        }
    }
];

function presetConfig(id) {
    for (var i = 0; i < PRESETS.length; i++) {
        if (PRESETS[i].id === id) {
            var cfg = normalize(clone(PRESETS[i].config));
            cfg.enabled = true;
            return cfg;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Import: accepts hl.curve()/hl.animation() (Lua) and bezier=/animation=
// (hyprlang) lines, so people can paste what they already have.
// Returns { curves, animations, skipped }. Never throws.
// ---------------------------------------------------------------------------
var NUM = "(-?\\d*\\.?\\d+(?:[eE][-+]?\\d+)?)";

function matchCall(text, start) {
    // text[start] is "(" ; return the substring inside the matching ")".
    var depth = 0, inStr = false, q = "";
    for (var i = start; i < text.length; i++) {
        var ch = text[i];
        if (inStr) {
            if (ch === "\\") { i++; continue; }
            if (ch === q) inStr = false;
            continue;
        }
        if (ch === "\"" || ch === "'") { inStr = true; q = ch; continue; }
        if (ch === "(") depth++;
        else if (ch === ")") { depth--; if (depth === 0) return { inner: text.substring(start + 1, i), end: i }; }
    }
    return null;
}

function field(body, name) {
    var m = new RegExp("\\b" + name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|[^,}\\s]+)").exec(body);
    if (!m) return null;
    if (m[2] !== undefined) return m[2];
    if (m[3] !== undefined) return m[3];
    return m[1];
}

function importLua(text, result) {
    var re = /hl\.(curve|animation)\s*\(/g, m;
    while ((m = re.exec(text)) !== null) {
        var call = matchCall(text, m.index + m[0].length - 1);
        if (!call) { result.skipped.push(text.substr(m.index, 60)); continue; }
        re.lastIndex = call.end;
        var inner = call.inner;
        if (m[1] === "curve") {
            var nm = /^\s*["']([^"']+)["']\s*,\s*([\s\S]*)$/.exec(inner);
            if (!nm) { result.skipped.push("hl.curve(" + inner.substring(0, 50)); continue; }
            var body = nm[2], type = field(body, "type");
            if (type === "spring") {
                var dv = field(body, "dampening");
                if (dv === null) dv = field(body, "damping");
                result.curves.push({ name: nm[1], type: "spring", mass: num(field(body, "mass"), 1),
                    stiffness: num(field(body, "stiffness"), 238.1191), dampening: num(dv, 24.21279333) });
            } else {
                var pm = new RegExp("points\\s*=\\s*\\{\\s*\\{\\s*" + NUM + "\\s*,\\s*" + NUM + "\\s*\\}\\s*,\\s*\\{\\s*" + NUM + "\\s*,\\s*" + NUM + "\\s*\\}").exec(body);
                if (!pm) { result.skipped.push("hl.curve(\"" + nm[1] + "\" ..."); continue; }
                result.curves.push({ name: nm[1], type: "bezier", x1: parseFloat(pm[1]), y1: parseFloat(pm[2]), x2: parseFloat(pm[3]), y2: parseFloat(pm[4]) });
            }
        } else {
            var leaf = field(inner, "leaf");
            if (!leaf) { result.skipped.push("hl.animation(" + inner.substring(0, 50)); continue; }
            var en = field(inner, "enabled");
            var enabled = !(en === "false" || en === "0");
            var curve = field(inner, "bezier") || field(inner, "spring") || field(inner, "curve") || "";
            result.animations.push({ leaf: leaf, enabled: enabled, speed: num(field(inner, "speed"), 5), curve: curve, style: field(inner, "style") || "" });
        }
    }
}

function importHyprlang(text, result) {
    var lines = text.split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/#.*$/, "").trim();
        if (!line || /hl\./.test(line)) continue;
        var m = /^bezier\s*=\s*([A-Za-z0-9_]+)\s*,\s*(.+)$/.exec(line);
        if (m) {
            var p = m[2].split(",").map(function (s) { return parseFloat(s); });
            if (p.length === 4 && p.every(isFinite))
                result.curves.push({ name: m[1], type: "bezier", x1: p[0], y1: p[1], x2: p[2], y2: p[3] });
            else result.skipped.push(line);
            continue;
        }
        m = /^animation\s*=\s*(.+)$/.exec(line);
        if (m) {
            var parts = m[1].split(",").map(function (s) { return s.trim(); });
            if (parts.length < 2) { result.skipped.push(line); continue; }
            var on = parts[1] !== "0";
            var a = { leaf: parts[0], enabled: on, speed: 5, curve: "", style: "" };
            if (on) {
                if (parts.length < 4) { result.skipped.push(line); continue; }
                a.speed = num(parts[2], 5);
                a.curve = parts[3];
                a.style = parts.slice(4).join(", ");
            }
            result.animations.push(a);
        }
    }
}

function importText(text) {
    var result = { curves: [], animations: [], skipped: [] };
    text = String(text || "").replace(/--[^\n]*$/gm, function (c) { return c; });
    importLua(text, result);
    importHyprlang(text, result);
    return result;
}

// Merge imported entries into cfg (later wins on a name/leaf clash).
function mergeImport(cfg, imported) {
    var out = clone(cfg), i, j;
    for (i = 0; i < imported.curves.length; i++) {
        var c = imported.curves[i], hit = -1;
        for (j = 0; j < out.curves.length; j++) if (out.curves[j].name === c.name) hit = j;
        if (hit >= 0) out.curves[hit] = c; else out.curves.push(c);
    }
    for (i = 0; i < imported.animations.length; i++) {
        var a = imported.animations[i], at = -1;
        for (j = 0; j < out.animations.length; j++) if (out.animations[j].leaf === a.leaf) at = j;
        if (at >= 0) out.animations[at] = a; else out.animations.push(a);
    }
    return out;
}

if (typeof module !== "undefined") {
    module.exports = {
        LEAVES: LEAVES, PRESETS: PRESETS, BEZIER_PRESETS: BEZIER_PRESETS, SPRING_PRESETS: SPRING_PRESETS,
        STYLE_SUGGESTIONS: STYLE_SUGGESTIONS, LIMITS: LIMITS, AXCTL_DEFAULTS: AXCTL_DEFAULTS,
        emptyConfig: emptyConfig, normalize: normalize, validate: validate, clone: clone, findCurve: findCurve,
        newBezier: newBezier, newSpring: newSpring, uniqueCurveName: uniqueCurveName,
        buildStatements: buildStatements, buildRestoreStatements: buildRestoreStatements,
        buildLuaFile: buildLuaFile, buildLoaderBlock: buildLoaderBlock, LOADER_MARKER: LOADER_MARKER,
        curveStatement: curveStatement, animationStatement: animationStatement, workspaceAutoStyle: workspaceAutoStyle,
        bezierProgress: bezierProgress, springStep: springStep, springStats: springStats, springDampingRatio: springDampingRatio,
        sampleCurve: sampleCurve, curveValueAt: curveValueAt, presetConfig: presetConfig,
        importText: importText, mergeImport: mergeImport, leafInfo: leafInfo, leafDepth: leafDepth, leafOrder: leafOrder, fmt: fmt
    };
}
