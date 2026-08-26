<img src="assets/logo.png" alt="Tank Tools" width="128" align="left">

# Tank Tools

Marks enemy nameplates by threat, for tanks in retail WoW. Standalone: no
dependencies, no embedded libraries, works on the default UI.

<br clear="left">

## What it does

One question, answered as fast as possible: **which enemy is on someone else,
so I can taunt it off?**

A bright **`!`** appears next to the nameplate of every enemy you do **not**
have aggro on. Nothing on screen means everything is yours.

That is the whole addon. There is no threat meter, no list, no percentages —
see [Secret values](#secret-values-midnight-and-later) for why those cannot
work inside an instance, and why none of them is what a tank acts on anyway.

## The three markers

Three independent markers, one per threat state, each with its own symbol:

| Marker | State | Default symbol | On by default |
|---|---|---|---|
| **Not mine** | you do **not** have aggro | `!` | yes |
| **At risk** | yours, but you are holding it insecurely | `?` | no |
| **Mine** | you **do** have aggro | `o` | no |

**Not mine** is the taunt list. **At risk** warns you before a mob becomes one.
**Mine** inverts the usual signal: instead of "something appeared, go get it",
it is a running confirmation that a plate is yours. Turn it on if you would
rather read a positive mark than an absence — some people find "nothing there"
hard to trust mid-pull. It gets its own quieter color (grey by default) and it
**never pulses**, so motion stays reserved for the two states that need you.

When a mob that *was* yours stops being yours, a raid-warning sound plays. That
is the one non-visual channel, and it fires in the moment you are looking at
health bars rather than nameplates.

## Why a glyph and not a color

Threat UI across WoW — Blizzard's and most addons' alike — leans almost
entirely on **red vs. green**, which is precisely the pair protanopia and
deuteranopia collapse into the same muddy tone. Roughly 1 in 12 men has some
form of color vision deficiency.

So the marker carries **no color information at all**:

| Channel | How it signals |
|---|---|
| **Shape** | a glyph with a distinct silhouette (`!`) |
| **Presence** | it appears *only* on mobs you have lost — nothing on screen means everything is yours |
| **Motion** | an optional pulse, a channel completely independent of hue |
| **Contrast** | thick black outline, so it reads over any nameplate color |

Every one of those survives being rendered in pure grayscale. Color is
decoration applied last — turn the monitor monochrome and the marker still
works perfectly. Every state is a differently *shaped* glyph, never a recolored
one, so no two ever rely on being told apart by hue.

## Setup

Type **`/tt config`**, or go through **ESC → Options → AddOns → Tank Tools**.
Size, which side of the plate it sits on, the symbols, the colors, and whether
it pulses are all in there.

### Seeing what you are adjusting

Click **Preview marker on all nameplates** (or `/tt nptest`). Every enemy
nameplate is marked immediately, whether or not you have aggro on it — so you
can walk up to a target dummy, or stand in any outdoor zone, and tune size and
position against real nameplates.

Preview ignores every other condition on purpose: it works out of combat and on
any spec, because that is where you will be standing when you set it up. Each
enabled symbol is spread across the mobs on screen, and each nameplate keeps
the same one rather than flickering, so with all three on you can see `!`, `?`
and `o` side by side and check the silhouettes really are distinct at the size
you picked.

It is intentionally temporary. Preview is never saved, and it switches itself
off the moment you change zone — so it cannot follow you into a dungeon and
mark the whole pull.

## When things mark

A marker needs all of: you are in a tank spec, that marker's checkbox is on,
and the mob is in the matching threat state.

Markers deliberately ignore combat state. The moment you most need one is a
pull you did not start — and when someone else grabs a mob, you are by
definition not yet in combat yourself.

**Nothing is tracked** unless an enemy is actually fighting your group: it has
a threat entry for you or for a group member, or (outside an instance only) it
is swinging at one of you. Idle mobs in the room ahead never mark.

If nothing marks when you think it should, run **`/tt status`** — it prints
your spec, combat and instance state, every gate above, and how many mobs are
marked. For the per-mob answer, run **`/tt debug`** in the fight: it dumps
every nameplate the scan sees, every value it read, and the exact check that
rejected each one.

## Secret values (Midnight and later)

Since Midnight, the client returns **secret values** for anything that
identifies a unit while you are inside an instance. `UnitGUID` comes back a
secret string; `UnitIsUnit`, `UnitCanAttack` and `UnitName` can come back
secret too. A secret can be handed to a frame setter, but comparing it,
formatting it, or using it as a table key throws immediately.

That is why this addon is only a marker. A list needs names to print and
percentages to sort by, and inside a dungeon it fills with `Unknown`.

### The two threat APIs are not equally restricted

The single most important fact here, and easy to get wrong:

| Call | Inside an instance |
|---|---|
| `UnitThreatSituation(unit, mob)` | returns a plain, readable **0–3** |
| `UnitDetailedThreatSituation(unit, mob)` | returns **secret values** for nameplate pairings |

Tank Tools uses only the plain one, whose single number carries all three states:

| Status | Means | Marker |
|---|---|---|
| `nil` | no threat entry — not our fight yet | *none* |
| `0` / `1` | someone else holds it | **not mine** |
| `2` | ours, but insecurely | **at risk** |
| `3` | ours, securely | **mine** |

Status `2` *is* the at-risk warning, stated by the client itself — which is why
no threat-percentage threshold is needed to produce it, and why it keeps
working inside an instance.

### No unit identity at all

| Instead of | It uses |
|---|---|
| `UnitGUID` as a mob key | the unit token (`nameplate3`) |
| `UnitIsUnit` to drop our own raid token | `UnitInRaid("player")`, an integer index |
| `UnitIsUnit(unit, "player")` for the personal plate | `unit == "player"`, a plain string compare |
| `C_NamePlate.GetNamePlates()` + `namePlateUnitToken` | the `nameplate1`…`nameplate40` tokens |

That last one matters: plate frames no longer carry a `namePlateUnitToken`
field. It reads `nil`, and a scan built on it sees nothing at all — silently,
because a `nil` token merely fails an `if`.

Every remaining unit read goes through a `Clean()` helper built on
`issecretvalue`, which turns a restricted value into `nil` rather than letting
it reach a comparison. Identity predicates then **fail open**: an unreadable
`UnitCanAttack` lets the mob through rather than dropping it, because the
threat data does the real gating and you cannot hold threat on a friendly unit.
Failing closed is what blinds the addon in exactly the content it exists for.

### What this costs inside instances

One thing genuinely cannot be done there: asking a mob **who it is currently
hitting**. That question is `UnitIsUnit(mobTarget, groupMember)`, and it is
restricted.

Outdoors, that check catches a mob nobody has threat on yet — a freshly spawned
add that landed on the healer, or one a pet is holding. Inside an instance,
group threat entries are the only signal, so such a mob stays unmarked until
*someone* generates threat on it. In practice that is a global cooldown or
less, and once anyone has touched it the mob marks normally.

### The scan latch

The set of values the client treats as secret has grown across patches and can
grow again. Rather than throw an error five times a second forever if it does,
the scan runs under a latch: three consecutive errors and it stops, once,
printing the error to chat. Changing zone clears it and retries.

## Commands

The settings window covers everything below; these remain for people who prefer
typing, and for macros.

| Command | Effect |
|---|---|
| `/tt config` | **open the settings window** |
| `/tt` | list all commands |
| `/tt nptest` | preview the symbols on every enemy nameplate |
| `/tt status` | why is nothing marking? |
| `/tt debug` | dump every nameplate the scan sees, and why each was skipped |
| `/tt np` | toggle the "not mine" marker |
| `/tt npwarn` | toggle the "at risk" marker |
| `/tt npsecure` | toggle the "mine" marker |
| `/tt nppulse` | toggle the pulse |
| `/tt npsize <10-72>` | marker size |
| `/tt npanchor <pos>` | left / right / top / bottom |
| `/tt npglyph <text>` | "not mine" symbol (default `!`) |
| `/tt npwarnglyph <text>` | "at risk" symbol (default `?`) |
| `/tt npsecglyph <text>` | "mine" symbol (default `o`) |
| `/tt npcolor <name>` | alert color — white / yellow / cyan / magenta / orange / green / grey |
| `/tt npseccolor <name>` | aggro marker color, same presets |
| `/tt sound` | toggle the lost-mob sound |
| `/tt tankonly` | toggle tank-spec-only |

## Compatibility

Tank Tools is self-contained. It has no required dependencies, embeds no
libraries, ships no custom media, and uses only documented Blizzard APIs
(`C_NamePlate`, the `nameplate1`…`nameplate40` unit tokens, and
`UnitThreatSituation`). It works as-is on the default UI.

It also composes with nameplate addons rather than competing with them. The
marker is a child frame of Blizzard's base nameplate container and never
touches the plate's own frames, so whatever is drawing your nameplates keeps
full ownership of them. Where those addons color plates by threat, this adds
the channel a hue cannot carry.

The settings window is built from core widget types and long-lived Blizzard
templates, so it renders correctly with or without a UI replacement loaded. If
your UI exposes a public skinning API, Tank Tools will use it to match your
theme; otherwise the window uses its own dark backdrop. Either way it needs no
setup.

## Performance notes

- Polls at 5 Hz, and only while something is eligible to mark. On a non-tank
  spec, or with every marker off, each tick is a few comparisons and nothing
  else.
- Group unit tokens (`party1`, `raid1`, …) are cached on roster change, and the
  `nameplate1`…`nameplate40` tokens are built once at load, so the scan does no
  string building at all.
- A hostile unit that is not fighting anybody is rejected before the roster
  walk, so a city full of nameplates costs one threat lookup each.
- One marker frame is allocated per *plate frame*, not per mob. Blizzard
  recycles a small fixed pool of plates, so a whole session allocates ~40.
- Markers only touch a frame on an actual state transition. In a big pull the
  steady state is a couple of comparisons per plate per tick.

## Development

```
tank-watch/
  TankTools/                  the addon itself -- this folder is what ships
    TankTools.toc
    TankTools.lua             threat scan, alerts, slash commands, diagnostics
    TankTools_Nameplates.lua  the markers themselves
    TankTools_Options.lua     settings window
  assets/                     logo + the script that renders it (not shipped)
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
then replaces that install's `Interface/AddOns/TankTools`. Change `WOW_ROOT` at
the top of the script if your install lives elsewhere.

### Cutting a release

Bump `## Version:` in `TankTools/TankTools.toc`, commit, then:

```
python release.py                 # dry run -- prints what it would do
python release.py --create        # tag + GitHub release
python release.py --create --type beta
```

The tag drives everything downstream: GitHub Actions attaches
`TankTools-<tag>.zip` to the release, and once the CurseForge webhook is set up
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
