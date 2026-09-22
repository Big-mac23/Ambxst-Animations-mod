# Animation Studio — docs

This is a mod for [Ambxst](https://github.com/Axenide/Ambxst) that adds a
Settings page for Hyprland's animation system: bezier curves, spring curves
(Hyprland 0.56+), and per-leaf timings/styles, applied live.

You don't need to read all of this to use the mod — it just works from
Settings → Animations. These docs are for when you want to **change** it:
add a leaf Hyprland introduces later, tweak a preset, fix a bug, add a
field. Read them in this order:

1. **This file** — the shape of the package, what each piece does, where
   to look for something.
2. **[ARCHITECTURE.md](ARCHITECTURE.md)** — how the three layers fit
   together and what happens, step by step, when you drag a curve handle.
   Read this once, fully, before changing anything. Everything else in the
   codebase follows from it.
3. **[COOKBOOK.md](COOKBOOK.md)** — task-oriented. "I want to do X" →
   here's exactly where to edit and how to verify it didn't break.
4. **[HYPRLAND-ANIMATIONS.md](HYPRLAND-ANIMATIONS.md)** — a primer on the
   domain this mod is modeling: what a "leaf" is, how the animation tree
   inherits, the bezier and spring math, in plain terms. Read this if the
   *Hyprland* side is unfamiliar, separately from the *code* side.

## Package layout

```
ambxst.mod.json              — the manifest. Tells Ambxst's mod manager
                                what to overlay and what to patch.
patches/                     — unified diffs against three existing Ambxst
                                files (adds a sidebar entry, a search
                                index, a shell.qml startup line).
payload/modules/
  services/
    AnimationsLogic.js       — all the math and rules. No QML, no I/O.
                                (688 lines)
    AnimationsService.qml    — the mod's brain: owns the config, saves it,
                                talks to the Hyprland daemon. (442 lines)
  widgets/dashboard/controls/
    AnimationsPanel.qml      — the Settings page you actually look at.
                                (1262 lines)
    CurvePreview.qml         — the draggable curve graph.
    MotionPreview.qml        — the little dot that demonstrates motion.
tests/
  logic.test.js              — Node unit tests for AnimationsLogic.js.
  lua_harness.lua            — a strict mock of Hyprland's hl.curve /
                                hl.animation API, in real Lua.
  lua_check.lua              — runs the *actual generated Lua* against
                                that mock.
  gen_lua_fixtures.js        — produces the Lua files lua_check.lua tests.
  run_all.sh                 — runs everything above. Start here after any
                                change to AnimationsLogic.js.
```

There's a fourth layer of tests (a headless QML/Qt test suite that drives
the real panel and service) that isn't shipped in the package because it
needs a stubbed-out Quickshell environment to run outside Ambxst itself.
COOKBOOK.md explains how to rebuild that harness if you want it.

## The one idea to hold onto

**AnimationsLogic.js has no side effects.** It takes a config object in,
returns a new config, a list of errors, or a string of Lua — always the
same output for the same input, never touches a file or the network.
Every other file exists to move data into and out of that one file.

This means: if something computes the wrong Lua, the bug is in Logic.js,
and you can find it with `node --test` in about ten seconds, without ever
touching Hyprland, Quickshell, or the UI. If something doesn't *save* or
*apply* correctly, the bug is in AnimationsService.qml. If something looks
wrong on screen but the underlying config is right, the bug is in
AnimationsPanel.qml. Keeping that boundary intact is the single most
valuable thing to preserve when you edit this.
