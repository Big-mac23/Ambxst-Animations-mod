# Architecture

## The three layers

```
┌─────────────────────────┐
│  AnimationsPanel.qml     │  presentation. Reads AnimationsService.config,
│  (+ CurvePreview,        │  calls AnimationsService.update(...) when you
│   MotionPreview)         │  interact with it. Has NO logic of its own
│                           │  beyond "what does this look like".
└───────────┬───────────────┘
            │ reads config / calls update(), setEnabled(), applyNow()...
            ▼
┌─────────────────────────┐
│  AnimationsService.qml   │  state + I/O. Owns the one true copy of the
│                           │  config. Persists it to disk. Sends it to
│                           │  Hyprland through the daemon. Knows about
│                           │  GameMode, the bar position, timers, retries.
└───────────┬───────────────┘
            │ calls into, for every actual computation
            ▼
┌─────────────────────────┐
│  AnimationsLogic.js       │  pure functions. validate(), buildStatements(),
│                           │  bezierProgress(), springStep(), importText()...
│                           │  No QML types, no Quickshell, no files. Could
│                           │  run in plain Node, and does (tests/logic.test.js
│                           │  runs it exactly that way).
└───────────────────────────┘
```

Why split it this way, rather than one big QML file (which is how a lot of
Ambxst's own panels are written)? Because the hard part of this mod isn't
the UI — it's getting the Lua right, and the only way to *know* it's right
is to test it outside a running compositor. QML objects can't run in `node
--test`. Plain JavaScript functions can. So everything that benefits from
being tested hard lives in `AnimationsLogic.js`, and everything that
*must* be QML (because it touches files, processes, or the daemon) is kept
as thin as possible around it.

If you're adding a feature and you're not sure which file it belongs in,
ask: "does this need to remember something, watch a file, or run a
process?" If no — it's a pure function, put it in Logic.js and write a
test for it in `tests/logic.test.js`. If yes — it belongs in the Service.
UI-only concerns (what color is the button, how many columns) belong in
the Panel and nowhere else.

## The config object

Everything in this mod hangs off one JS object, shaped like this:

```js
{
  version: 1,
  enabled: false,         // is the mod switched on?
  autoApply: true,        // push edits to Hyprland as you make them?
  curves: [
    { name: "snap", type: "bezier", x1: 0.05, y1: 0.9, x2: 0.1, y2: 1.05 },
    { name: "easy", type: "spring", mass: 1, stiffness: 238.1, dampening: 24.2 }
  ],
  animations: [
    { leaf: "windowsIn", enabled: true, speed: 4.1, curve: "easy", style: "popin 87%" }
  ]
}
```

`AnimationsLogic.emptyConfig()` builds the empty version.
`AnimationsLogic.normalize(raw)` takes *anything* — JSON.parse output,
user-pasted garbage, an old version of the schema — and turns it into a
well-formed config, dropping what it can't understand. Nothing else in the
codebase should read a raw config; everything goes through `normalize`
first (the Service's `FileView.onLoaded` and `importFromText` both do
this).

This is `AnimationsService.config`, the single property everything else
reads. The Panel treats it as read-only and never mutates it directly —
see "how a change happens" below.

## How a change happens, end to end

Walk through: you drag a bezier handle in the curve editor.

1. **CurvePreview.qml**'s `MouseArea` computes the new (x, y) under the
   cursor and emits `bezierEdited(x1, y1, x2, y2)`.
2. **AnimationsPanel.qml**'s `onBezierEdited` handler calls
   `root.setBezier(editor.i, x1, y1, x2, y2)`.
3. `setBezier` calls `AnimationsService.update(mutator)`, passing a
   function that mutates a curve in place.
4. **AnimationsService.update()**:
   - deep-clones the current config (`Logic.clone`, so the mutator can't
     accidentally alias state still on screen mid-edit),
   - runs your mutator on the clone,
   - calls `root._commit(next, true)`.
5. **`_commit`**:
   - sets `root.config = next` — every QML binding that reads
     `AnimationsService.config` re-evaluates. This is what makes the graph
     redraw instantly.
   - calls `_refreshDerived()`, which re-runs `Logic.validate(config)` and
     `Logic.buildLuaFile(config, context)` and stores the results in
     `root.errors` and `root.luaPreview`.
   - restarts `saveTimer` (400ms debounce) and, if the mod is on,
     autoApply is on, and there are no validation errors, restarts
     `applyTimer` (700ms debounce).
6. **saveTimer fires** → `root._flush()` writes `animations.json` and
   `animations.lua` to disk (through `FileView.setText`, which does an
   atomic write).
7. **applyTimer fires** → `root.applyNow()` → `Logic.buildStatements(config,
   context)` turns the config into an ordered list of one-line Lua
   statements (curves first, then animations in tree order) → `_runApply`
   queues them.
8. **`_sendNext()`** sends exactly one statement at a time to
   `BackendService.call("compositor.eval", { expression: stmt.lua }, cb)`,
   waits for the callback, records ok/error, then sends the next. This is
   deliberately serial, not `Promise.all` — a curve **must** exist before
   an animation statement that references it runs, and Hyprland processes
   `compositor.eval` calls independently, so firing them all at once could
   land them out of order.
9. When the queue drains, `_finishApply()` sets `applyState` to `"ok"` or
   `"error"` and, if any statement failed, keeps `unapplied = true` so the
   Panel's "Apply" button reappears.

Every step in 4–9 happens with no UI code involved — the Panel only ever
sees the *result* (`AnimationsService.config`, `.errors`, `.applyState`,
`.luaPreview`) through property bindings. If you're debugging "the UI
shows the wrong thing," check whether the *config* is wrong (bug in
Service/Logic) or the *rendering* is wrong (bug in Panel) by inspecting
`AnimationsService.config` directly — e.g. temporarily add
`onConfigChanged: console.log(JSON.stringify(config))`.

## Statement generation: why one line each

`Logic.buildStatements()` and `Logic.buildLuaFile()` never put more than
one `hl.curve(...)` or `hl.animation(...)` call per line, and never chain
statements with `;`. Two independent reasons:

- **Live apply** (`AnimationsService._sendNext`) sends the daemon's
  `compositor.eval` one statement per call, and the pipeline that carries
  it splits on `;` — so a statement containing one would corrupt whatever
  comes after it.
- **The generated file** (`animations.lua`) wraps every statement in
  `_try(function() ... end)` so one leaf that doesn't exist on your
  Hyprland build (see `since:` in the leaf table) can't take down every
  animation after it in the file. That isolation only works one statement
  per `_try`.

If you ever add a new kind of statement, keep this invariant: one
statement, one line, no semicolons inside it. `tests/lua_check.lua` will
catch a violation (it loads each line with Lua's `load()`, which fails on
anything but a single well-formed chunk).

## The leaf tree and "restore defaults"

Hyprland's animations form a tree (`global` → `windows` → `windowsIn`,
etc. — see `Logic.LEAVES`). A leaf you don't set explicitly inherits from
its nearest configured ancestor. This mod's UI mirrors that tree directly
in the Animations tab (indentation = depth, computed by
`Logic.leafDepth`).

"Restore defaults" is worth understanding because it's the one place this
mod pretends to know something about Ambxst's *own* animation code — see
`Logic.AXCTL_DEFAULTS`, a hand-transcribed copy of the hard-coded
animation block in axctl's Go source
(`backend/pkg/svc/compositor` → generated by
`axctl/pkg/ipc/hyprland/generator_lua.go`). `buildRestoreStatements()`
walks up the tree from each leaf you've touched until it finds one axctl
sets, and emits a statement putting that value back live — without
waiting for a full Hyprland reload. This is an **emulation**: if axctl's
own defaults ever change, `AXCTL_DEFAULTS` will drift from them, and
"Restore defaults" will restore the *old* values live (a real Hyprland
reload always restores the *actual* current defaults exactly, since it
re-runs axctl's generator from scratch). If you bump the Ambxst version
this mod targets, check whether that block changed — see COOKBOOK.md.

## Persistence and re-apply triggers

Two files, both under `AnimationsService`'s control:

- `~/.config/ambxst/config/animations.json` — the source of truth. What
  gets loaded on startup, what the Panel edits.
- `~/.local/share/ambxst/animations.lua` — a derived file, regenerated on
  every save. Only meaningful if you've installed the optional loader
  (below); the live-apply path doesn't read it at all.

Three things can make the service re-apply without you touching the
Panel:

1. **axctl regenerates its own config** (because you changed something
   elsewhere in Ambxst that touches Hyprland settings) — this triggers a
   Hyprland reload, which wipes any curves/animations we pushed live. The
   service watches `~/.local/share/ambxst/{axctl.toml,hyprland.lua}` with
   `FileView.watchChanges` and re-applies 1.5s after either changes.
2. **GameMode ends** — animations are typically suspended during GameMode;
   when `GameModeClient.toggled` goes false, re-apply.
3. **Ambxst itself starts up** — axctl's own startup sequence writes its
   config and reloads Hyprland shortly after the shell launches, which
   again wipes live curves. The service schedules two apply attempts,
   2.5s and 9s after `animations.json` loads with `enabled: true`, to
   survive that.

If you find yourself needing a fourth trigger, follow the same pattern:
watch the right file or property, debounce, call `_applyIfEnabled()` (not
`applyNow()` directly — it no-ops correctly when the mod is off or busy).

## The optional hyprland.lua loader

By default this mod's writes to `animations.lua` are inert — nothing
reads that file back. `installLoader()` appends a small, clearly marked
block to your `hyprland.lua` that makes Hyprland's *own* config load
execute it. This means your animations survive `hyprctl reload` or a
Hyprland restart that happens before Ambxst's shell has started —
scenarios where the live-apply path hasn't run yet.

The install/remove scripts (in `AnimationsService.qml`, `_installScript()`
and `removeProc`) are deliberately conservative:
- refuse to touch a `hyprland.lua` that's a symlink into `/nix/store`
  (a Nix-managed config — editing it would be pointless, it gets
  regenerated),
- back up to `hyprland.lua.animation-studio.bak` before any write,
- use a marker comment (`Logic.LOADER_MARKER`) to detect "already
  installed" and to find the exact block to remove later.

If you change the loader block's shape (`Logic.buildLoaderBlock()`), keep
`removeProc`'s `awk` matcher in sync — it looks for the marker line and
strips through the next line that's exactly `end)`.

## Mod composition: why the patches are additive-only

Ambxst's mod manager applies every enabled mod's patches, in order, on top
of each other and of Ambxst itself (see
`backend/pkg/mods/manager.go`). If two mods both want to touch
`SettingsTab.qml`, the second mod's patch has to apply against a file the
first mod already changed. Ambxst handles this by trying, in order:

1. the patch applies verbatim,
2. a git 3-way merge,
3. if the 3-way merge only conflicts on *added* lines from both sides
   (no one deleted or changed a line the other touched), it keeps both
   additions — see `resolveAddedBlocks` in the manager.

Case 3 only works if neither mod's patch **deletes or rewrites** a line
the other mod also touches. That's why `patches/settings-tab.patch` looks
the way it does:

- the sidebar entry and the panel registration are both **pure
  insertions** — new lines added, nothing existing removed,
- the one line that *used to* need changing —
  `contentArea.panelComponents[root.currentSection]` — looked up a panel
  by its *position* in the array. Two mods each inserting their own panel
  at the top of that array would silently open the wrong page for each
  other. The patch instead changes that one line to look panels up by
  `section` id (`.find(panel => panel.section === root.currentSection)`),
  which makes array order irrelevant. This is the only line in any of the
  three patches that isn't a pure addition — and it was checked against a
  simulated second mod during development for exactly this reason (see
  COOKBOOK.md's "verify a patch still composes" recipe if you ever add
  another line like it).

If you ever add a new patch to this mod, prefer insertion over
modification wherever the target file's structure allows it, for the same
reason.

### The section id isn't a small number, on purpose

Every panel in `SettingsTab.qml` — Ambxst's own and any mod's — is
identified by a `section` integer, and `root.currentSection` (the
property that drives which panel is shown) is declared as a plain `int`
in Ambxst's own source, not a namespaced string. Ambxst's built-ins use
`0`–`10`. The obvious choice for a mod adding one panel is `11`, "the next
number" — that's what this mod used at first.

That's a real bug waiting to happen, not just an aesthetic one: nothing
coordinates section numbers between independently-authored mods. Any
other mod author reaching for the same "next available number" logic
lands on `11` too, and since the lookup is `panelComponents.find(panel =>
panel.section === root.currentSection)`, the *first* entry in the
composed array with a matching section wins — the other mod's sidebar
entry silently opens this mod's panel instead of its own, with no error
and no warning. This is what "the panel hijacks other mods" (an actual
report, not a hypothetical) turned out to be.

The fix: this mod's `section` (`116923207` in the current patches) is a
32-bit value derived from an FNV-1a hash of the mod's own id string,
`"community.animation-studio"` — see the `AnimationsLogic.js`-adjacent
derivation, or just regenerate it:

```python
def fnv1a_32(s):
    h = 0x811c9dc5
    for b in s.encode():
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h

section = 100000 + (fnv1a_32("community.animation-studio") % 900000000)
```

This doesn't *guarantee* no collision — it's still a finite space of
32-bit ints, and the pigeonhole principle always wins eventually — but it
makes collision with any other mod astronomically less likely than
colliding on "the next integer after 10", which is a near-certainty the
moment a second panel-adding mod exists. If you fork this mod or change
its id, regenerate the section number from the new id the same way, and
update all four places it appears: the sidebar entry and the
`panelComponents` entry in `patches/settings-tab.patch`, and the three
search-index entries in `patches/settings-index.patch`. There's no
central registry for this — every mod author has to independently follow
this convention (or something like it) for it to actually work; it's a
mitigation for a real gap in Ambxst's own mod system, not a complete fix
for it. Worth raising upstream if you want a real fix rather than every
mod author quietly hashing their own id.
