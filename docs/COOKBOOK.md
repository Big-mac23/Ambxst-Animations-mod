# Cookbook

Task-oriented. Find the thing closest to what you want, follow it exactly
once, then adapt.

Every recipe that changes `AnimationsLogic.js` ends the same way: run
`./tests/run_all.sh` from the package root. That single script runs the
JS unit tests *and* feeds the resulting Lua through real Lua 5.4 against a
strict mock of Hyprland's API — it's the fastest way to know you didn't
break curve math or generate malformed Lua, and it needs nothing but
`node` and `lua5.4` installed.

```
cd animation-studio
./tests/run_all.sh
```

If `lua5.4` isn't installed: `sudo apt install lua5.4` (Debian/Ubuntu) or
your distro's equivalent. If it's missing, `run_all.sh` will fail loudly
on that step specifically — the Node tests still run fine without it.

---

## Add a new Hyprland leaf (e.g. Hyprland ships a new one)

1. Open `payload/modules/services/AnimationsLogic.js`, find the `LEAVES`
   array.
2. Add an entry in the right spot in the tree (order matters — it's the
   display and apply order):
   ```js
   { leaf: "newLeafName", parent: "windows", label: "Human name", styleKind: "window", desc: "One line explaining it" },
   ```
   - `parent` must be another leaf already in the table (or `""` for a
     root — only `global` should have this).
   - `styleKind` picks which style suggestion chips show in the UI. Use
     an existing kind (`window`, `layer`, `workspace`, `angle`) if it
     behaves like those, or add a new key to `STYLE_SUGGESTIONS` just
     above the table if it needs its own suggestion set.
   - If this leaf doesn't exist on older Hyprland builds, add
     `since: "..."` — this only affects a label suffix in the UI; it
     doesn't gate anything functionally (Hyprland itself rejects it on
     older builds, and the mod reports that per-statement).
3. That's it — the Panel renders `LEAVES` directly (see
   `AnimationsPanel.qml`'s Animations tab `Repeater`), so no UI change is
   needed.
4. Run `./tests/run_all.sh`. The "leaf table is consistent" test in
   `logic.test.js` checks your new entry's `parent` exists and sorts
   after it — if you got the tree position wrong, it'll tell you exactly.

## Add a new preset

Presets live in `Logic.PRESETS` (`AnimationsLogic.js`). Copy the shape of
an existing one:

```js
{
  id: "my-preset",                 // unique, lowercase, used nowhere but internally
  name: "My Preset",               // shown in the UI
  description: "One sentence.",    // shown under the name
  config: {
    curves: [bez("name", x1, y1, x2, y2), spr("name", mass, stiffness, dampening)],
    animations: [an("leaf", speed, "curveName", "style")]
  }
}
```

`bez`, `spr`, `an` are tiny helper functions defined right above
`PRESETS` — use them, don't hand-write the object shape, it's easy to
transpose a field.

Add your preset object to the `PRESETS` array, then
`./tests/run_all.sh`. Two tests exercise every preset automatically —
`"every preset validates and generates Lua"` and `"round trip: generated
Lua re-imports to the same config"` — so a typo (like a curve name an
animation references but never defines) fails immediately with the
preset's id in the message, without you needing to write a new test.

## Change a validation limit (e.g. allow a wider stiffness range)

Edit `LIMITS` near the top of `AnimationsLogic.js`:

```js
var LIMITS = {
    bezierX: [0, 1],
    bezierY: [-3, 3],
    mass: [0.01, 100],
    stiffness: [0.1, 5000],   // ← e.g. change the upper bound here
    dampening: [0, 1000],
    speed: [0.01, 1000]
};
```

These bounds are also what `ParamSlider` in `AnimationsPanel.qml` uses for
its `from`/`to` on the mass/stiffness/dampening sliders — you don't need
to touch the Panel separately, it reads the same values through the
`Logic.LIMITS` import (search the Panel for where `ParamSlider` blocks
set `from:`/`to:` if you want to double check, but they're wired to
sensible slider ranges within these limits already, not to `LIMITS`
directly — if you widen a limit a lot, sanity-check the slider's `from`/
`to` still makes sense for dragging by hand, e.g. a slider from 0.1 to
50000 is unusable; you may want the slider narrower than the hard
validation limit).

Run `./tests/run_all.sh` — the `"validate rejects each class of bad
input"` test hard-codes some out-of-range values; if you loosen a limit
past what that test assumes, you'll get a clear failure telling you which
assertion now needs updating.

## Add a new field to curves (e.g. Hyprland adds a third curve type)

This is the biggest kind of change — it touches all three layers. Follow
the existing `spring` type as the template throughout:

1. **Logic.js**:
   - `LIMITS` — add range(s) for the new fields.
   - `newBezier`/`newSpring` — add a `newYourType(name)` constructor with
     sensible defaults.
   - `normalize()` — teach it to read your type's fields from raw JSON
     (see the `else if (c.type === "bezier")` branch).
   - `validate()` — add an `else if (c.type === "yourtype")` branch
     checking your new fields against `LIMITS`.
   - `curveStatement()` — emit the right `hl.curve(name, { type = "...",
     ... })` shape.
   - `animationStatement()` — if your type uses a different key name than
     `bezier`/`spring` in `hl.animation({...})`, extend the `key`
     selection logic.
   - `sampleCurve()` / `curveValueAt()` — the math that drives the
     preview graph and the motion dot. Add a branch that computes
     progress-over-time for your type.
   - Add your type's presets to `PRESETS` (optional) and importer support
     in `importLua()` if you want paste-to-import to recognize it.
2. **AnimationsService.qml** — almost certainly nothing; it treats curves
   generically via `Logic.buildStatements`.
3. **AnimationsPanel.qml**:
   - Add a "+ YourType" button next to the existing "+ Bezier"/"+ Spring"
     buttons in the Curves tab, calling `root.addCurve(Logic.newYourType(...))`.
   - Add a fields section (copy the spring `ColumnLayout` block, gated on
     `editor.c.type === "yourtype"`) with `ParamSlider`s or `NumField`s
     for your new fields.
   - `CurvePreview.qml` should keep working unmodified as long as
     `Logic.sampleCurve()` handles your type — it just plots whatever
     `sampleCurve` returns.
4. Run `./tests/run_all.sh`, then add a handful of tests for the new type
   modeled on the existing spring tests (validate accepts/rejects it,
   `curveStatement` produces exact expected Lua, round-trips through
   import).

## Debug "Hyprland rejected some statements"

This means `AnimationsService.applyState === "error"` — some individual
`hl.curve`/`hl.animation` call the mod sent came back with an error from
the daemon.

1. Open Settings → Animations → the red card lists which leaf/curve
   failed and Hyprland's own error message.
2. Common causes:
   - **A leaf marked `since: "newer builds"`** and your Hyprland is older
     than that. Disable that leaf, or upgrade Hyprland.
   - **A curve name typo** — an animation references a curve that got
     renamed or deleted. The Panel's validation (yellow/red banner) should
     usually catch this *before* apply, but if you edited
     `animations.json` by hand outside the UI, it might not have been
     re-validated yet — reopen Settings to force a re-check.
   - **Hyprland version too old for the Lua API at all** (needs 0.55+).
     Check `hyprctl version`.
3. To see exactly what was sent, open the "Presets & tools" tab → "Show"
   under Generated Lua — that's the same statements, formatted as a file.
   You can also copy them and run them by hand via `hyprctl` to get
   Hyprland's raw error without going through this mod at all, which is
   useful for telling "my mod has a bug" apart from "Hyprland just doesn't
   like this input" — e.g. `hyprctl --batch "$(cat that-line)"` isn't
   quite right syntax for Lua statements; easiest is pasting the offending
   `hl.curve(...)`/`hl.animation(...)` line into a scratch `.lua` file and
   `hyprctl reload` a config that `dofile()`s it, or using the same
   loader mechanism this mod already installs (see ARCHITECTURE.md's
   loader section) temporarily pointed at a one-line test file.

## Verify a patch still composes (after editing SettingsTab.qml/etc.)

If you change `patches/settings-tab.patch` or `patches/settings-index.patch`,
re-verify two things: the patch still applies to a clean Ambxst checkout,
and it still composes if another hypothetical mod also touches the same
file. The check below reproduces what Ambxst's mod manager does
internally (`git apply` → 3-way merge → added-blocks fallback — see
ARCHITECTURE.md's "why the patches are additive-only").

```bash
# 1. Regenerate the patch after editing the target file directly:
cd /path/to/a/clean/Ambxst/checkout
git checkout c62a7acc443dbb1c9045e83466402528cc522af2   # the commit this mod targets
# ... make your edit to modules/widgets/dashboard/controls/SettingsTab.qml ...
git diff -- modules/widgets/dashboard/controls/SettingsTab.qml > /path/to/animation-studio/patches/settings-tab.patch

# 2. Verify it still applies verbatim to a fresh checkout:
cd /tmp && rm -rf check && git clone /path/to/a/clean/Ambxst check && cd check
git checkout c62a7acc443dbb1c9045e83466402528cc522af2
git apply --check --whitespace=error-all /path/to/animation-studio/patches/settings-tab.patch && echo OK
```

For the composition check (does it survive a second mod editing the same
file?), simulate a second mod that does something plausible to the same
anchor points (e.g. also inserts a sidebar entry, also inserts a panel
registration) and confirm `git apply --3way` on your patch afterward
produces no `<<<<<<<` conflict markers in the result. If you're not
changing the *shape* of `patches/settings-tab.patch` (still pure
insertions, still using the section-id lookup rather than positional
indexing), you generally don't need to re-run this — it's the section-id
lookup line specifically that was worth this level of paranoia, because
it's the one line in the whole mod that isn't a pure addition.

## Change the mod's id (and its section number along with it)

If you fork this mod under a new id, the section number the settings
panel uses is derived from the old id and needs to change too — see
ARCHITECTURE.md's "The section id isn't a small number, on purpose" for
why a plain incrementing number isn't safe here.

1. Pick your new id, e.g. `"yourname.animation-studio"`.
2. Derive the new section number:
   ```bash
   python3 -c '
   def fnv1a_32(s):
       h = 0x811c9dc5
       for b in s.encode():
           h ^= b
           h = (h * 0x01000193) & 0xFFFFFFFF
       return h
   print(100000 + (fnv1a_32("yourname.animation-studio") % 900000000))
   '
   ```
3. Regenerate `patches/settings-tab.patch` and `patches/settings-index.patch`
   against a clean checkout (see "Verify a patch still composes" above for
   the exact clone/checkout/diff steps), replacing every `section:
   116923207` with your new number — there are four occurrences total (two
   in settings-tab.patch, three in settings-index.patch).
4. Update `"id"` in `ambxst.mod.json` to match.
5. Re-run the composition check below to confirm you didn't reintroduce a
   collision, then `./tests/run_all.sh`.

## Rebuild the tar.gz for installing

```bash
cd animation-studio   # the package root, containing ambxst.mod.json
tar -czf ../animation-studio-mod.tar.gz .
```

## Rebuild the headless QML test harness (optional, deeper verification)

The Node + Lua tests in `tests/` cover the logic layer thoroughly and
don't need anything beyond `node` and `lua5.4`. If you're changing
`AnimationsService.qml` or `AnimationsPanel.qml` themselves — not just
`AnimationsLogic.js` — and want to verify the *QML* wiring (does dragging
a handle actually call the right function, does the apply queue actually
serialize, does GameMode actually defer), you need Qt's `qmltestrunner`
and a stub Quickshell environment, since the real Quickshell types
(`FileView`, `Process`, the Quickshell singleton) don't exist outside a
running Ambxst shell.

This wasn't shipped in the package because it's a fair amount of stub code
tied to the exact Quickshell API surface this mod uses, and it'll drift
as Ambxst's own Quickshell version changes. Recreating it is
straightforward but is its own task — the short version:

1. Install Qt6 QML tooling: `sudo apt install qt6-declarative-dev-tools qml6-module-qtquick-controls qml6-module-qttest` (Debian/Ubuntu; adjust for your distro).
2. Build a minimal `qmldir`-based stub tree providing fake `Quickshell`,
   `Quickshell.Io` (`FileView`, `Process`, `StdioCollector`), and stand-ins
   for `qs.config`/`qs.modules.theme`/`qs.modules.components` — enough for
   `AnimationsService.qml` and `AnimationsPanel.qml` to load and run, with
   the fakes recording what they were asked to do (files written,
   processes run, daemon calls made) instead of actually doing it.
3. Write a `TestCase { }` in a `.qml` file that loads the real
   `AnimationsPanel.qml`/`AnimationsService.qml` against those stubs,
   drives them through `TestCase` methods (`mouseClick`, calling exposed
   functions directly, `tryVerify` for async timers), and asserts on the
   stub's recorded state.
4. Run with:
   ```bash
   QT_QPA_PLATFORM=offscreen qmltestrunner -import /path/to/your/stub/tree -input your_test.qml
   ```

If in doubt, the Node/Lua suite (`run_all.sh`) is the one to lean on day
to day — it's what actually caught real bugs during development (an
off-by-one in statement ordering, a lost in-flight "restore" request, the
`damping`/`dampening` spelling mismatch). The QML harness is worth
rebuilding mainly if you're restructuring how the Service and Panel talk
to each other, not for ordinary content changes.
