# TankWatch

A small threat tracker for tanks in retail WoW, built to sit alongside
EllesmereUI.

## What it does

One compact list of every enemy currently fighting your group, sorted so the
problems are always on top:

| Row color | Meaning | Right-hand text |
|---|---|---|
| 🔴 Red | **You are not tanking it.** | who currently has it |
| 🟠 Orange | You have it, but someone is closing in | that player's threat % |
| 🟢 Green | Yours, comfortably | top rival's threat % |

The bar behind each row is that percentage, so you can read the list at a
glance without parsing numbers mid-pull.

When a mob that *was* yours stops being yours, the frame flashes red and plays
a raid-warning sound.

## Nameplate marker (colorblind-friendly)

A bright **`!`** appears next to the nameplate of every enemy you do **not**
have aggro on. It is on by default.

This exists because threat UI across WoW — Blizzard's and EllesmereUI's alike —
leans almost entirely on **red vs. green**, which is precisely the pair that
protanopia and deuteranopia collapse into the same muddy tone. Roughly 1 in 12
men has some form of color vision deficiency.

So the marker deliberately carries **no color information at all**:

| Channel | How it signals |
|---|---|
| **Shape** | a glyph with a distinct silhouette (`!`) |
| **Presence** | it appears *only* on mobs you have lost — nothing on screen means everything is yours |
| **Motion** | an optional pulse, a channel completely independent of hue |
| **Contrast** | thick black outline, so it reads over any nameplate color |

Every one of those survives being rendered in pure grayscale. The color is
decoration applied last — turn the monitor monochrome and the marker still
works perfectly.

All of it is tunable in the **Nameplate marker** column of `/tw config`: size,
which side of the plate it sits on, the symbol itself, the color, and whether
it pulses (turn that off if motion is distracting).

### Seeing what you are adjusting

Click **Preview marker on all nameplates** (or `/tw nptest`). Every enemy
nameplate is marked immediately, whether or not you have aggro on it — so you
can walk up to a target dummy, or just stand in any outdoor zone, and tune the
size and position against real nameplates.

Preview ignores every other condition on purpose: it works out of combat, and
on any spec, because that is where you will actually be standing when you set
this up. If **Also mark mobs at risk** is enabled, your current target shows
the `?` symbol while everything else shows `!`, so you can compare the two.

It is intentionally temporary. Preview is never saved, and it switches itself
off the moment you change zone — so it can't follow you into a dungeon and
mark the whole pull.

All five color presets are bright, high-luminance choices that stay
distinguishable from one another under protanopia, deuteranopia *and*
tritanopia.

`/tw npwarn` adds a second, **differently shaped** glyph (`?`) for mobs still
yours but slipping — shape again, not a color change, so the two states never
rely on being told apart by hue.

## Why not just use nameplates?

EllesmereUI's nameplate module already colors plates by threat, and TankWatch
deliberately does not touch nameplates — it would only fight with it. This
covers what a nameplate physically cannot:

- Mobs **behind you**, off-screen, or buried in a 15-pack.
- Mobs you have **zero threat on** — the add that spawned onto the healer.
  There is no threat data to color that plate with, so it looks like any other
  enemy right up until someone dies.
- **Who** is about to pull, and how close they are, before it happens.

## Install

The folder is already in place at
`_retail_/Interface/AddOns/TankWatch`. Restart WoW, or `/reload` if it is
running, and enable **TankWatch** in the AddOns list.

## Setup

Type **`/tw config`** to open the settings window. Everything is in there —
you never need the slash commands.

You can also reach it through **ESC → Options → AddOns → TankWatch**.

The settings open in their own small movable window rather than as a page
inside Blizzard's Settings frame, because most of these options are ones you
judge by looking: scale, width, marker size and marker position all want the
live frame visible while you drag the slider, and the Settings frame covers
most of the screen.

To place the threat list: untick **Lock frame**, click **Preview layout** to
fill it with sample rows, drag it where you want it, then tick Lock again.
Locked also makes it click-through, so it never eats a mouse-turn mid-pull.

By default it only appears **in combat**, and only while you are in a **tank
spec** — so it stays out of the way completely on your other characters.

## Commands

The settings window covers everything below; these remain for people who
prefer typing, and for macros.

| Command | Effect |
|---|---|
| `/tw config` | **open the settings window** |
| `/tw` | list all commands |
| `/tw unlock` / `/tw lock` | move the frame / lock it (locked = click-through) |
| `/tw test` | toggle fake rows for positioning |
| `/tw scale <0.5-2.0>` | frame scale |
| `/tw width <120-600>` | frame width |
| `/tw rows <1-40>` | max rows shown |
| `/tw warn <1-100>` | rival % at which a held mob turns orange (default 80) |
| `/tw sound` | toggle the lost-mob sound |
| `/tw tankonly` | toggle tank-spec-only |
| `/tw ooc` | toggle combat-only |
| `/tw clean` | toggle hiding while everything is securely tanked |
| `/tw reset` | reset position and scale |
| `/tw np` | toggle the nameplate marker |
| `/tw nptest` | preview the marker on every enemy nameplate |
| `/tw npwarn` | also mark mobs you may lose |
| `/tw nppulse` | toggle the marker pulse |
| `/tw npsize <10-72>` | marker size |
| `/tw npanchor <pos>` | left / right / top / bottom |
| `/tw npglyph <text>` | symbol to show (default `!`) |
| `/tw npcolor <name>` | white / yellow / cyan / magenta / orange |

`/tw clean` is worth knowing about: with it on, the frame is invisible unless
something is actually wrong. Pure alarm, zero clutter.

## EllesmereUI integration

TankWatch registers through EllesmereUI's public skinning API
(`EllesmereUI.RegisterSkin`, documented in `EllesmereUI/SKINNING_API.md`), so
the threat list *and* every widget in the settings window — checkboxes,
buttons, the text field, the window frame itself — are painted in your current
EUI theme and font, and follow live accent/theme changes.

This is entirely automatic and needs no setup. If EllesmereUI is missing or
disabled, TankWatch falls back to its own dark backdrop. You can turn the
skinning off per-addon in **EllesmereUI options → Blizz UI Enhanced → Blizzard
Window Skins → Third-Party Addons**.

## Performance notes

- Polls at 5 Hz, and only while it is actually eligible to show. Out of combat
  or on a non-tank spec, each tick is a single comparison.
- Group unit tokens (`party1`, `raid1`, …) are cached on roster change, so the
  scan does no string building.
- Row frames and mob entry tables are pooled; a steady state allocates nothing.


## Development

```
tank-watch/
  TankWatch/                  the addon itself -- this folder is what ships
    TankWatch.toc
    TankWatch.lua             threat scan, list frame, slash commands
    TankWatch_Nameplates.lua  colorblind-friendly nameplate marker
    TankWatch_Options.lua     settings window
  deploy.py                   copy into a live WoW install for testing
  release.py                  tag + GitHub release from the .toc version
  pkgmeta.yaml                tells CurseForge how to package the zip
  .github/workflows/          attaches the built zip to the GitHub release
```

Tooling is shared with the ChattyLittleNpc repos, so it behaves identically.

### Deploying to a live WoW install

```
python deploy.py
```

Lists every WoW version found under the configured root, asks which to use,
then replaces that install's `Interface/AddOns/TankWatch`. Change `WOW_ROOT` at
the top of the script if your install lives elsewhere.

`deploy.py` finds the addon folder by looking for a subdirectory containing a
matching `.toc`, so it needs no per-repo edits -- the same as `release.py`,
which is copied verbatim from ChattyLittleNpc.

### Cutting a release

Bump `## Version:` in `TankWatch/TankWatch.toc`, commit, then:

```
python release.py                 # dry run -- prints what it would do
python release.py --create        # tag + GitHub release
python release.py --create --type beta
```

The tag drives everything downstream: GitHub Actions attaches
`TankWatch-<tag>.zip` to the release, and once the CurseForge webhook is set up
(see `../curseforge-packaging-setup.md`) the tagged commit is packaged there
too. `v1.0.0` publishes as Release, `v1.0.0-beta` as Beta, `v1.0.0-alpha` as
Alpha.

**Not yet done:** this repo still needs its CurseForge webhook. Follow Step 3
of `../curseforge-packaging-setup.md` with this repo's project ID.

### A note on `.luarc.json`

`undefined-field` and `inject-field` are switched off deliberately. The Lua
language server types `CreateFrame()` as a generic frame regardless of the
type string passed to it, so every genuine `Slider`, `EditBox` and
`CheckButton` method (`SetMinMaxValues`, `SetAutoFocus`, `SetChecked`, ...)
reports as undefined, and every field stored on a frame reports as an illegal
injection. Both are unavoidable in addon code. Real problems -- undefined
globals, syntax errors, arity mismatches -- are still reported.
