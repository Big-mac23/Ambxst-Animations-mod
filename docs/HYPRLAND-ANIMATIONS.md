# Hyprland animations, in plain terms

This has nothing to do with QML or this mod's code — it's what Hyprland
itself does, so the code makes sense when you read it.

## Curves: two kinds of "how motion feels"

An animation needs a function that maps "how far through the animation am
I" (0 to 1) to "how far along the change am I" (also roughly 0 to 1, but
can overshoot). That function is the **curve**.

### Bezier

A cubic bezier curve with fixed start `(0,0)` and end `(1,1)` points, and
two *control* points `(x1,y1)` and `(x2,y2)` you choose. Hyprland (and
this mod) constrain `x1`/`x2` to 0–1 but let `y1`/`y2` go up to ±3, which
is how you get overshoot ("ease out back" style bounces).

Intuition: the control points act like magnets pulling the curve's early
and late shape toward them. A control point near `(0, 1)` makes the
animation shoot up fast then coast — "ease out". Near `(1, 0)` does the
opposite. If you're picking numbers by hand rather than dragging,
[cubic-bezier.com](https://cubic-bezier.com) is a good place to feel this
out before typing values in — the math is identical to CSS's
`cubic-bezier()`.

In code: `Logic.bezierProgress(x1, y1, x2, y2, t)`. It solves for the
bezier's `x` parameter that corresponds to time `t` (Newton's method, with
bisection as a fallback if Newton doesn't converge — happens for very
sharp curves), then evaluates `y` at that same parameter. This is
standard "easing function from bezier control points" math; the four
numbers in a curve fully determine it.

### Spring (Hyprland 0.56+)

A **physical** curve: imagine a mass on a spring, pulled to a target and
released. Three numbers describe it:

- **mass** — how heavy the moving thing feels. Higher mass = slower to
  start moving, slower to stop. Hyprland's docs suggest keeping this near
  1 and doing your tuning with the other two.
- **stiffness** — how hard the spring pulls. Higher = faster, snappier.
- **dampening** (yes, spelled with the extra "en" in Hyprland's own
  config key — see the note below) — how much the motion is resisted, à
  la a shock absorber. Higher = less bounce, more "arrives and stops".

The three combine into one number physicists call **damping ratio (ζ)**:

- ζ < 1 → **underdamped**: overshoots, oscillates before settling. Bouncy.
- ζ = 1 → **critically damped**: fastest approach to the target with no
  overshoot at all.
- ζ > 1 → **overdamped**: no overshoot, but slower than critical.

This mod shows you ζ directly (under the spring sliders) along with
"settles in ≈ X ms" and "overshoot Y%", computed by
`Logic.springStats(mass, stiffness, dampening)`, so you don't have to do
the physics in your head — turn dampening up until "Bouncy" becomes
"Critically damped" if you want the spring feel without any overshoot.

**A spelling trap worth knowing about explicitly:** Hyprland's actual
config key is `dampening`, not the more common English `damping`. You'll
see `damping` used informally in some blog posts and even in some copied
example configs. This mod's importer (`Logic.importLua`) accepts both
spellings when reading pasted text, but always **writes** `dampening`,
because that's the only spelling Hyprland's Lua API (`hl.curve`) actually
accepts.

## The animation tree ("leaves")

Hyprland doesn't make you configure every single kind of animation
separately. Instead there's a tree: `global` is the root, `windows` is a
child of `global`, `windowsIn` (window opening) and `windowsOut` (window
closing) are children of `windows`, and so on. If you don't explicitly
configure `windowsIn`, it inherits whatever `windows` has. If `windows`
isn't configured either, it inherits from `global`.

This mod's `Logic.LEAVES` table is a transcription of that whole tree
(`leaf`, `parent`, a human label, and what kind of `style` string it
accepts, if any). The Animations tab in the Panel renders it with
indentation matching depth, computed by walking `parent` links
(`Logic.leafDepth`).

A few leaves are worth knowing by name because they come up in the docs
and tests:

- `windowsMove` — dragging/resizing. No `style`, just a speed and curve.
- `fadeLayersIn`/`fadeLayersOut` — fade for layer surfaces (bars, launcher
  popups, notifications), as opposed to `layersIn`/`layersOut` which
  handle their slide/pop.
- `borderangle`, `shadowangle`, `glowangle` — these use `style: "loop"` or
  `"once"` rather than a slide/pop string; they animate a gradient's
  rotation, not a position.
- `workspacesIn`/`workspacesOut`/`specialWorkspaceIn`/`specialWorkspaceOut`
  — the only leaves where `style: "auto"` is valid. Hyprland picks
  `slidefade` or `slidefadevert` for you based on your bar's position;
  this mod reproduces that choice in `Logic.workspaceAutoStyle()` so the
  generated Lua always has a concrete style baked in (Hyprland's `auto`
  keyword itself would also work, but resolving it ourselves means the
  live-apply path doesn't depend on Hyprland's bar-detection matching
  Ambxst's).

Leaves marked `since: "newer builds"` in the table (`fadeGlow`,
`shadowangle`, `glowangle` as of when this was written) may not exist on
every Hyprland install. Enabling one of these on an older Hyprland is not
a bug in this mod — Hyprland itself will reject the statement, which
you'll see reported per-leaf in the "Hyprland rejected some statements"
card rather than silently failing everything.

## Speed units

Hyprland's animation "speed" is in **deciseconds** — `4` means roughly
400ms, not 4 seconds and not 4ms. This trips people up constantly when
hand-writing configs; it's the reason the mod doesn't hide the raw number
behind a "milliseconds" label — deciseconds is genuinely what Hyprland's
API takes, and translating it would make imported/exported configs
inconsistent with what everyone else's Hyprland configs say.

## What `hl.curve()` / `hl.animation()` actually are

Hyprland 0.55+ can be configured with Lua instead of (or alongside) the
older `hyprland.conf` syntax. `hl.curve(name, spec)` defines a named curve;
`hl.animation({...})` assigns a curve, speed, and style to one leaf. This
mod always targets that Lua API, never the older `bezier = ` /
`animation = ` config-file syntax directly — though it can **read** that
older syntax when you paste it into Import (see `Logic.importHyprlang`),
since plenty of existing configs and tutorials are still written that
way.
