// Run: node --test tests/
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function loadLogic() {
    const file = path.join(__dirname, "..", "payload", "modules", "services", "AnimationsLogic.js");
    const src = fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*$/m, "");
    const sandbox = { module: { exports: {} }, Math, JSON, Object, Array, Number, String, RegExp, isFinite, parseFloat };
    vm.createContext(sandbox);
    vm.runInContext(src, sandbox, { filename: file });
    // Results come from another realm; JSON-roundtrip them so deepEqual compares plain data.
    const raw = sandbox.module.exports, out = {};
    for (const [k, v] of Object.entries(raw)) {
        out[k] = typeof v === "function"
            ? (...a) => { const r = v(...a); return r === undefined ? r : JSON.parse(JSON.stringify(r)); }
            : JSON.parse(JSON.stringify(v));
    }
    return out;
}
const L = loadLogic();

const cfgOf = (curves, animations, extra) => Object.assign(L.emptyConfig(), { enabled: true, curves, animations }, extra || {});
const bez = (name, x1, y1, x2, y2) => ({ name, type: "bezier", x1, y1, x2, y2 });
const spr = (name, mass, stiffness, dampening) => ({ name, type: "spring", mass, stiffness, dampening });
const an = (leaf, speed, curve, style = "", enabled = true) => ({ leaf, enabled, speed, curve, style });
const fields = (errs) => errs.map((e) => `${e.scope}:${e.id}:${e.field}`);

test("fmt trims zeros without eating integer digits", () => {
    assert.equal(L.fmt(10), "10");
    assert.equal(L.fmt(100), "100");
    assert.equal(L.fmt(0.5), "0.5");
    assert.equal(L.fmt(1.10), "1.1");
    assert.equal(L.fmt(-0), "0");
    assert.equal(L.fmt(238.1191), "238.1191");
    assert.equal(L.fmt(24.21279333), "24.212793");
    assert.equal(L.fmt(NaN), "0");
});

test("normalize is total and drops junk", () => {
    assert.deepEqual(L.normalize(null), L.emptyConfig());
    assert.deepEqual(L.normalize("x"), L.emptyConfig());
    const c = L.normalize({
        enabled: true,
        curves: [{ name: "a", type: "spring", mass: "2", stiffness: 100, damping: 7 }, { name: 5 }, { name: "b", type: "nope" }, null],
        animations: [{ leaf: "windows", speed: "3", curve: "a" }, { nope: 1 }, { leaf: 9 }]
    });
    assert.equal(c.curves.length, 1);
    assert.equal(c.curves[0].mass, 2);
    assert.equal(c.curves[0].dampening, 7, "accepts the misspelt alias 'damping' on read");
    assert.equal(c.animations.length, 1);
    assert.equal(c.animations[0].speed, 3);
    assert.equal(c.animations[0].enabled, true);
});

test("validate accepts a good config", () => {
    const cfg = cfgOf([bez("snap", 0.2, 0.9, 0.1, 1), spr("s", 1, 200, 20)], [an("windows", 4, "s"), an("fade", 2, "snap"), an("border", 1, "default")]);
    assert.deepEqual(L.validate(cfg), []);
});

test("validate rejects each class of bad input", () => {
    const bad = cfgOf(
        [bez("default", 0, 0, 1, 1), bez("bad name", 0, 0, 1, 1), bez("ok", 1.5, 0, 0.5, 9), bez("ok", 0, 0, 1, 1),
            spr("sp", 0, 10, 5), spr("sp2", 1, -1, 5), spr("sp3", 1, 10, -2), bez("semi;colon", 0, 0, 1, 1)],
        [an("windows", 0, "ok"), an("windows", 3, "ok"), an("fade", 3, "missing"), an("fadeIn", 3, ""),
            an("layers", 3, "ok", "popin; hl.exec()"), an("border", 3, "ok", "auto"), an("bad leaf!", 3, "ok")]
    );
    const f = fields(L.validate(bad));
    for (const expected of [
        "curve:default:name", "curve:bad name:name", "curve:ok:x1", "curve:ok:y2", "curve:ok:name",
        "curve:sp:mass", "curve:sp2:stiffness", "curve:sp3:dampening", "curve:semi;colon:name",
        "animation:windows:speed", "animation:windows:leaf", "animation:fade:curve", "animation:fadeIn:curve",
        "animation:layers:style", "animation:border:style", "animation:bad leaf!:leaf"
    ]) assert.ok(f.includes(expected), `missing error ${expected}\n${f.join("\n")}`);
});

test("disabled animations skip curve/speed validation", () => {
    assert.deepEqual(L.validate(cfgOf([], [an("fade", 0, "", "", false)])), []);
});

test("statements: exact Lua for bezier, spring, disabled", () => {
    const cfg = cfgOf([bez("snap", 0.05, 0.9, 0.1, 1.05), spr("easy", 1, 238.1191, 24.21279333)],
        [an("windowsIn", 4.1, "easy", "popin 87%"), an("fade", 3.03, "snap"), an("fadeOut", 1, "snap", "", false)]);
    const s = L.buildStatements(cfg, {}).map((x) => x.lua);
    assert.deepEqual(s, [
        'hl.curve("snap", { type = "bezier", points = { {0.05, 0.9}, {0.1, 1.05} } })',
        'hl.curve("easy", { type = "spring", mass = 1, stiffness = 238.1191, dampening = 24.212793 })',
        'hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, spring = "easy", style = "popin 87%" })',
        'hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "snap" })',
        'hl.animation({ leaf = "fadeOut", enabled = false })'
    ]);
});

test("statements are ordered curves-first then tree order, and are single-statement one-liners", () => {
    const cfg = cfgOf([bez("a", 0, 0, 1, 1)], [an("workspaces", 1, "a"), an("zoomFactor", 1, "a"), an("windowsIn", 1, "a"), an("global", 1, "default"), an("custom", 1, "a")]);
    const st = L.buildStatements(cfg, {});
    assert.equal(st[0].id, "curve:a");
    assert.deepEqual(st.slice(1).map((x) => x.id), ["animation:global", "animation:windowsIn", "animation:workspaces", "animation:zoomFactor", "animation:custom"]);
    for (const x of st) {
        assert.ok(!x.lua.includes(";"), "no ';' (compositor.eval splits on it)");
        assert.ok(!/[\r\n]/.test(x.lua));
    }
});

test("auto style follows bar orientation", () => {
    const cfg = cfgOf([bez("a", 0, 0, 1, 1)], [an("workspaces", 2, "a", "auto")]);
    assert.match(L.buildStatements(cfg, { barPosition: "top" })[1].lua, /style = "slidefade 20%"/);
    assert.match(L.buildStatements(cfg, { barPosition: "bottom" })[1].lua, /style = "slidefade 20%"/);
    assert.match(L.buildStatements(cfg, { barPosition: "left" })[1].lua, /style = "slidefadevert 20%"/);
    assert.match(L.buildStatements(cfg, { barPosition: "right" })[1].lua, /style = "slidefadevert 20%"/);
    assert.match(L.buildStatements(cfg, undefined)[1].lua, /slidefade 20%/);
});

test("spring key used for spring curves, bezier key for bezier and builtin default", () => {
    const cfg = cfgOf([spr("s", 1, 100, 10)], [an("windows", 1, "s"), an("fade", 1, "default")]);
    const st = L.buildStatements(cfg, {}).map((x) => x.lua);
    assert.match(st[1], /spring = "s"/);
    assert.match(st[2], /bezier = "default"/);
});

test("bezier math", () => {
    for (const t of [0, 0.1, 0.5, 0.9, 1]) assert.ok(Math.abs(L.bezierProgress(0, 0, 1, 1, t) - t) < 1e-5, "linear bezier is identity");
    let prev = -1;
    for (let i = 0; i <= 100; i++) {
        const v = L.bezierProgress(0.23, 1, 0.32, 1, i / 100);
        assert.ok(v >= prev - 1e-9, "easeOutQuint is monotonic");
        prev = v;
    }
    assert.ok(Math.abs(L.bezierProgress(0.23, 1, 0.32, 1, 1) - 1) < 1e-9);
    assert.ok(L.bezierProgress(0.34, 1.56, 0.64, 1, 0.5) > 1, "easeOutBack overshoots");
    assert.ok(Math.abs(L.bezierProgress(0.23, 1, 0.32, 1, 0.1) - 0.3981) < 1e-3, "easeOutQuint front-loads (reference value)");
    // independent brute-force reference
    const brute = (x1, y1, x2, y2, t) => { let best = 1e9, y = 0; for (let i = 0; i <= 50000; i++) { const s = i / 50000, u = 1 - s; const x = 3 * u * u * s * x1 + 3 * u * s * s * x2 + s ** 3; if (Math.abs(x - t) < best) { best = Math.abs(x - t); y = 3 * u * u * s * y1 + 3 * u * s * s * y2 + s ** 3; } } return y; };
    for (const c of [[0.65, 0.05, 0.36, 1], [0.34, 1.56, 0.64, 1], [0.5, 0.9, 0.1, 1.1]])
        for (let i = 1; i < 10; i++) assert.ok(Math.abs(L.bezierProgress(...c, i / 10) - brute(...c, i / 10)) < 1e-3);
});

test("spring math: analytic overshoot and regimes", () => {
    const zeta = 0.5;
    const k = 100, m = 1, c = 2 * zeta * Math.sqrt(k * m);
    const stats = L.springStats(m, k, c);
    const analytic = Math.exp(-Math.PI * zeta / Math.sqrt(1 - zeta * zeta));
    assert.ok(Math.abs(stats.overshoot - analytic) < 0.002, `overshoot ${stats.overshoot} vs ${analytic}`);
    assert.ok(Math.abs(stats.zeta - zeta) < 1e-9);

    const crit = L.springStats(1, 100, 20);
    assert.ok(crit.overshoot < 1e-6, "critically damped does not overshoot");
    const over = L.springStats(1, 100, 60);
    assert.ok(over.overshoot < 1e-6 && over.settle > crit.settle, "overdamped is slower");

    for (const [mm, kk, cc] of [[1, 100, 5], [1, 100, 20], [1, 100, 60], [2.5, 40, 10]]) {
        assert.equal(L.springStep(mm, kk, cc, 0), 0);
        assert.ok(Math.abs(L.springStep(mm, kk, cc, 30) - 1) < 1e-6, "converges to 1");
    }
    // continuity across regime boundary
    const a = L.springStep(1, 100, 19.9999, 0.3), b = L.springStep(1, 100, 20.0001, 0.3);
    assert.ok(Math.abs(a - b) < 1e-4);
});

test("spring: stiffer settles faster, default 'easy' is lightly underdamped", () => {
    const soft = L.springStats(1, 70, 10), stiff = L.springStats(1, 400, 30);
    assert.ok(stiff.settle < soft.settle);
    const easy = L.springStats(1, 238.1191, 24.21279333);
    assert.ok(easy.zeta > 0.7 && easy.zeta < 0.85);
    assert.ok(easy.overshoot > 0 && easy.overshoot < 0.05);
});

test("sampleCurve spans and endpoints", () => {
    const b = L.sampleCurve(bez("x", 0.25, 0.1, 0.25, 1), 50);
    assert.equal(b.points.length, 51);
    assert.equal(b.points[0].v, 0);
    assert.ok(Math.abs(b.points[50].v - 1) < 1e-9);
    const s = L.sampleCurve(spr("y", 1, 200, 10), 50);
    assert.ok(s.span >= 0.15 && s.span <= 3);
    assert.equal(s.points[0].v, 0);
});

test("every preset validates and generates Lua", () => {
    for (const p of L.PRESETS) {
        const cfg = L.presetConfig(p.id);
        assert.ok(cfg.enabled);
        assert.deepEqual(L.validate(cfg), [], `preset ${p.id}`);
        assert.ok(L.buildLuaFile(cfg, {}).includes("hl.animation"), p.id);
    }
    for (const c of [...L.BEZIER_PRESETS, ...L.SPRING_PRESETS]) assert.deepEqual(L.validate(cfgOf([c], [])), [], c.name);
});

test("leaf table is consistent", () => {
    const names = new Set(L.LEAVES.map((x) => x.leaf));
    assert.equal(names.size, L.LEAVES.length, "unique leaves");
    for (const x of L.LEAVES) {
        assert.ok(x.parent === "" || names.has(x.parent), `${x.leaf} parent`);
        if (x.parent) assert.ok(L.leafOrder(x.parent) < L.leafOrder(x.leaf), `${x.leaf} sorts after its parent`);
    }
    assert.equal(L.leafDepth("global"), 0);
    assert.equal(L.leafDepth("fadeLayersIn"), 3);
});

test("Lua file: off, empty, and populated", () => {
    assert.match(L.buildLuaFile(L.emptyConfig(), {}), /switched off/);
    assert.match(L.buildLuaFile(cfgOf([], []), {}), /No curves/);
    const lua = L.buildLuaFile(cfgOf([bez("a", 0, 0, 1, 1)], [an("fade", 1, "a")]), {});
    assert.match(lua, /_try\(function\(\) hl\.curve\("a"/);
    assert.match(lua, /_try\(function\(\) hl\.animation\(/);
});

test("import: hl.* lua, both damping spellings, comments", () => {
    const src = `
        -- my curves
        hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
        hl.curve("rubber", { type = "spring", mass = 0.8, stiffness = 60, dampening = 9 })
        hl.curve("typo", { type = "spring", mass = 1, stiffness = 238.1191, damping = 24.21279333 })
        hl.animation({ leaf = "windows", enabled = true, speed = 10, spring = "rubber", style = "slide" })
        hl.animation({ leaf = "fade", enabled = 0 })
        hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
        hl.curve("broken", { type = "bezier" })
    `;
    const r = L.importText(src);
    assert.equal(r.curves.length, 3);
    assert.deepEqual(r.curves[0], bez("easeOutQuint", 0.23, 1, 0.32, 1));
    assert.deepEqual(r.curves[1], spr("rubber", 0.8, 60, 9));
    assert.equal(r.curves[2].dampening, 24.21279333);
    assert.deepEqual(r.animations[0], an("windows", 10, "rubber", "slide"));
    assert.equal(r.animations[1].enabled, false);
    assert.equal(r.animations[2].curve, "easeOutQuint");
    assert.equal(r.skipped.length, 1);
});

test("import: hyprlang lines", () => {
    const src = `
        animations {
            enabled = yes
            bezier = myBezier, 0.05, 0.9, 0.1, 1.05   # comment
            animation = windows, 1, 7, myBezier
            animation = windowsOut, 1, 7, default, popin 80%
            animation = fade, 0
            animation = borderangle, 1, 8, default, loop
            animation = broken
        }`;
    const r = L.importText(src);
    assert.deepEqual(r.curves, [bez("myBezier", 0.05, 0.9, 0.1, 1.05)]);
    assert.deepEqual(r.animations.map((a) => [a.leaf, a.enabled, a.speed, a.curve, a.style]), [
        ["windows", true, 7, "myBezier", ""],
        ["windowsOut", true, 7, "default", "popin 80%"],
        ["fade", false, 5, "", ""],
        ["borderangle", true, 8, "default", "loop"]
    ]);
    assert.equal(r.skipped.length, 1);
});

test("import: garbage in, nothing out", () => {
    const r = L.importText("hello world\n{{{ ((( hl.curve( \"x\"");
    assert.equal(r.curves.length + r.animations.length, 0);
    assert.ok(Array.isArray(r.skipped));
    assert.deepEqual(L.importText(null).curves, []);
});

test("mergeImport: later wins by name/leaf, others kept", () => {
    const base = cfgOf([bez("a", 0, 0, 1, 1), bez("b", 0, 0, 1, 1)], [an("fade", 1, "a"), an("windows", 1, "b")]);
    const merged = L.mergeImport(base, { curves: [bez("a", 0.5, 0, 0.5, 1), bez("c", 0, 0, 1, 1)], animations: [an("fade", 9, "c")], skipped: [] });
    assert.equal(merged.curves.length, 3);
    assert.equal(merged.curves[0].x1, 0.5);
    assert.equal(merged.animations.find((a) => a.leaf === "fade").speed, 9);
    assert.equal(merged.animations.length, 2);
    assert.equal(base.curves[0].x1, 0, "does not mutate input");
});

test("round trip: generated Lua re-imports to the same config", () => {
    for (const p of L.PRESETS) {
        const cfg = L.presetConfig(p.id);
        const lua = L.buildStatements(cfg, {}).map((x) => x.lua).join("\n");
        const back = L.importText(lua);
        const norm = L.normalize({ enabled: true, curves: back.curves, animations: back.animations });
        const expectCurves = cfg.curves.map((c) => (c.type === "spring"
            ? { ...c, mass: +L.fmt(c.mass), stiffness: +L.fmt(c.stiffness), dampening: +L.fmt(c.dampening) } : c));
        assert.deepEqual(norm.curves, expectCurves, `${p.id} curves`);
        const expectAnims = L.buildStatements(cfg, {}).filter((s) => s.id.startsWith("animation:")).length;
        assert.equal(norm.animations.length, expectAnims, `${p.id} anims`);
        for (const a of norm.animations) {
            const orig = cfg.animations.find((x) => x.leaf === a.leaf);
            assert.equal(a.speed, +L.fmt(orig.speed));
            assert.equal(a.curve, orig.curve);
            assert.equal(a.style, orig.style === "auto" ? L.workspaceAutoStyle("top") : orig.style);
        }
    }
});

test("restore: inherits axctl values down the tree", () => {
    const cfg = cfgOf([], [an("windowsIn", 4, "x"), an("fadeLayersIn", 4, "x"), an("borderangle", 4, "x"), an("workspacesOut", 4, "x", "auto")]);
    const st = L.buildRestoreStatements(cfg, { barPosition: "left" });
    const by = Object.fromEntries(st.map((s) => [s.id, s.lua]));
    assert.match(by["curve:myBezier"], /points = \{ \{0.4, 0\}, \{0.2, 1\} \}/);
    assert.equal(by["animation:windowsIn"], 'hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "myBezier", style = "popin 80%" })');
    assert.equal(by["animation:fadeLayersIn"], 'hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 2.5, bezier = "myBezier" })');
    assert.equal(by["animation:borderangle"], 'hl.animation({ leaf = "borderangle", enabled = true, speed = 10, bezier = "default" })', "not under an axctl leaf: Hyprland global default");
    assert.match(by["animation:workspacesOut"], /style = "slidefadevert 20%"/);
    for (const leaf of ["windows", "border", "fade", "workspaces"]) assert.ok(by["animation:" + leaf], "axctl's own leaves always restored: " + leaf);
    for (const s of st) assert.ok(!s.lua.includes(";"));
});

test("loader block is idempotent-marked and never errors when the file is missing", () => {
    const b = L.buildLoaderBlock();
    assert.ok(b.startsWith(L.LOADER_MARKER));
    assert.match(b, /pcall\(function\(\)/);
    assert.match(b, /if f then f\(\) end/);
});
