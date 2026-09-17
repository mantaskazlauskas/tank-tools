# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tank Tools is a standalone World of Warcraft (retail) addon written in Lua 5.1.
No dependencies, no embedded libraries, no custom media. `TankTools/` is the
folder that ships; everything else in the repo is tooling.

`README.md` is the real design document and is unusually complete — the rules
below are the parts that are easy to violate, not a summary of it. Read the
relevant README section before changing threat scanning, the co-tank panel, or
the debuff journal.

When something renders nothing, throws only inside an instance, or works
outdoors but not in a raid, read the `restriction-casebook` skill before
debugging — it holds the solved cases and the method for telling the three kinds
of refusal apart. Add a case to it when a new one is solved.

## Commands

```
pip install lupa                    # once; tests need a real Lua 5.1 interpreter
python tests/run.py                 # every suite, every scenario
python tests/run.py tankwatch       # one suite, all its scenarios
python tests/run.py core:migrate    # one scenario

python deploy.py                    # copy into a live WoW install (WOW_ROOT at top of script)
python release.py                   # dry run: print what a release would do
python release.py --create          # tag + GitHub release, version read from the .toc
python release.py --create --type beta
```

There is no build and no linter beyond the Lua language server driven by
`.luarc.json`. Any new WoW global a file references must be added to that file's
`diagnostics.globals` list or it reports as undefined.

Releases are driven by `## Version:` in `TankTools/TankTools.toc`; bump and
commit it before tagging. GitHub Actions attaches the built zip to the release.

## Tests

`tests/harness.lua` stubs `CreateFrame`, the `Unit*` calls, events and the
ticker, then loads every `.lua` line in `TankTools.toc`, **in `.toc` order**.
Nothing is mocked out — the shipping code runs. Suites are plain Lua using the
harness globals `ok`, `eq`, `section`, `WORLD`, `NS`, `FILES`, `Tick`,
`FireEvent`, `Slash`, `ChatSince`, `FireCombatLog`.

A suite's scenarios are declared in the `SUITES` dict in [tests/run.py](tests/run.py)
and read by the suite as the `SCENARIO` global; the world is set up *before* the
addon loads. Three restriction models, and they are not interchangeable:

| Flag | Models |
|---|---|
| `WORLD.secretMode` | every `Unit*` call returns a secret value — readable calls, unreadable answers |
| `WORLD.aurasSecret` | aura enumeration **throws**, as it does in an encounter or Mythic+ |
| `WORLD.forbiddenEvents` | the client silently refuses an event registration |

`tankwatch:engine` and `debuffs:secret` are the load-bearing ones: any code that
walks aura indices in a restricted context fails them outright, which is the
regression the aura display exists to prevent.

## Architecture

### The .toc is the dependency graph

`TankTools/TankTools.toc` is the only place load order is written down, and the
file carries comments explaining each position. Core before UI before Modules.
Event handlers for a given event run in registration order, which is file order,
which is why the database resolving before anything reads it works at all. A new
file goes in a considered position, and `suite_core.lua` asserts the ordering
contract.

### Core owns four things

A database, a ticker, an event dispatcher, a settings window. Modules declare
what they want from each and never reach into one another, so a broken or
removed module costs you that module only. Registration is declarative at load
time; nothing *runs* until `ADDON_LOADED` has resolved the database
(`ns.ready`).

```lua
local M = ns.NewModule("mymodule", { defaults = { enabled = true } })  -- TankToolsDB.modules.mymodule
function M:OnInit()   -- self.db exists, no event has fired yet
    ns.RegisterTicker("mymodule", "watch", 0.2, Tick)
    ns.RegisterEvent("GROUP_ROSTER_UPDATE", Rebuild)
end
```

Help text, `/tt status` and the settings window are all *generated* from
`ns.RegisterCommand`, `ns.RegisterStatusProvider` and `ns.RegisterOptionsSection`
— a feature that exists is a feature that is listed, so there is no second place
to update when adding one.

`Modules/Threat.lua` produces `ns.stateByUnit` and draws nothing; displays
attach via `ns.RegisterThreatConsumer{ wants = ..., updated = ... }`, and `wants`
also decides whether the scan runs this tick.

### Restricted values are a Core concern

Since Midnight the client returns *secret values* for unit-identifying reads
inside instances. Every read goes through [TankTools/Core/Secret.lua](TankTools/Core/Secret.lua)
— `Clean`, `IsTrue`, `IsFalse`, `IsSecret`, `Show`. Do not copy those helpers
into a module; a copy drifts the next time the restricted set changes.

Rules that are load-bearing:

- **Identity predicates fail open.** `IsTrue`/`IsFalse` are both false for an
  unreadable value, so the unit passes the gate. Failing closed blinds the addon
  in exactly the content it exists for.
- **`UnitThreatSituation` is readable inside instances; `UnitDetailedThreatSituation`
  is not.** Only the plain one is used, and its 0–3 carries every state.
- **Never use a unit GUID, `UnitIsUnit`, or `namePlateUnitToken` as an identity.**
  Unit tokens (`nameplate1`…`nameplate40`, built once at load) and integer
  indices are what survive.
- **Auras are a different restriction.** The enumeration *throws*; there is no
  value to launder. [TankTools/UI/AuraRow.lua](TankTools/UI/AuraRow.lua) hands a
  unit and a filter to the client's own `AuraContainer` and lets it draw, so the
  addon never learns what the debuff is. Only fall back to reading auras where no
  aura widget exists. Values that are secret can still be passed unread into
  `SetText`/`SetValue`/`SetMinMaxValues`.
- **`AuraButton`s need an explicit size** — the engine never gives them a rect,
  and a 0×0 button looks exactly like a filter matching nothing.
- **Getters on client-owned widgets are themselves restricted.** `IsShown`,
  `GetWidth` and friends can throw; launder them, and never put a diagnostic
  behind one.

### Failure latches

Polling code fails five times a second, not once. Every ticker subscriber runs
under `pcall` and three consecutive errors stop *that subscriber*, loudly,
printing the actual error; `PLAYER_ENTERING_WORLD` clears the latch, because the
restrictions that trip it are instance-scoped. Event handlers latch the same way
at five failures. `ns.RegisterEvent` returns whether the client actually accepted
the registration — a *protected* event does not raise, it silently stays
unregistered, so the return value matters.

### Feature flags

Unfinished modules ship inert rather than half-visible. `ns.RegisterFeature{...}`
declares a flag; `feature = "name"` on a module, command, status provider or
options section gates it. With the flag off: `OnInit` never runs, commands are
unlisted and do not dispatch, the settings page and its tab disappear, status
lines are not printed — but the file stays in the `.toc`, so it still compiles
and its suites still run. **Unregistered names are enabled**: gating is opt-in.

Flags are per character, read once at load, and need a `/reload` to take effect
(enabling live would work; disabling cannot, since tickers and event handlers
cannot be taken back). `/tt features` is registered `hidden = true` and is the
one command the generated help omits.

Currently flagged: the co-tank panel and the debuff journal.

### Cross-module stubs

[TankTools/Core/Namespace.lua](TankTools/Core/Namespace.lua) stubs every
cross-file entry point (`ns.ShowDebuffs`, `ns.DebuffRecords`, `ns.FeatureEnabled`,
…) with a safe default, so a caller can invoke them unconditionally and deleting
a module's file leaves the rest running. Add a stub there when adding a new
cross-file function.

## Conventions

- `undefined-field` and `inject-field` are disabled in `.luarc.json` on purpose:
  the language server types every `CreateFrame()` as a generic frame, so real
  `Slider`/`EditBox`/`CheckButton` methods and fields stored on frames both
  report falsely. Do not re-enable them; genuine problems still report.
- Comments in this codebase explain *why*, at length, especially where a
  restriction or a past bug forced the shape. Match that when touching Core.
- Widgets with no settings, commands or lifecycle live in `UI/` (that is why
  `AuraRow.lua` is not a module). A module records and stores; its window in
  `UI/` only draws, and calls into the module at runtime, never at file scope.
- `deploy.py` and `release.py` are shared verbatim with the ChattyLittleNpc
  repos — fix them there too rather than diverging.
