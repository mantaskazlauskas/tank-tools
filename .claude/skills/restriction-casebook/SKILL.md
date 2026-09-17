---
name: restriction-casebook
description: Diagnosis method and solved-case log for WoW client restrictions in Tank Tools — a call that throws only inside an instance, a widget that renders nothing, an event that never arrives, a panel blank in a raid but fine at a target dummy, state that a /reload fixes. Read BEFORE debugging any "it shows nothing" or "works outdoors, not in an instance" symptom, and use it to record a new case once one is actually solved.
---

# Restriction casebook

The addon's hard bugs are almost all the same bug wearing different clothes: **the
client refused something, and the refusal was misdiagnosed.** Every one of them
cost days, and none of them looked like a refusal from the chair — they looked
like a filter matching nothing, an empty group, a feature that "just doesn't
work in raids."

Full entries are in [cases.md](cases.md). Read the method below first; it is what
generalises to the next one.

## The method

**1. Work out which shape of refusal you have.** There are four. The first
three look identical downstream, and each has a different fix. Getting this wrong is the
single most expensive mistake in this codebase.

| Shape | What you observe | Fix |
|---|---|---|
| **A secret value** | the call returns, the value throws when compared/formatted/keyed | launder it — `ns.Clean`, or pass it unread into a setter |
| **A throw** | the call itself does not return | never make the call; find the widget that does it for you |
| **A silent no-op** | the call returns as if it worked, and nothing happens | verify afterwards with an independent witness |

`pcall` only catches the second. It reports success for the third, which is how
the debuff journal spent sessions certain the combat log was feeding it.

There is a fourth that the table above will lead you away from: **a refusal
scoped to combat rather than to place.** Secure frames raise like a throw, but
the trigger is `InCombatLockdown()`, so no amount of testing in a delve will
reproduce it and none of the `WORLD.*` restriction flags model it. Ask what the
*tick* does to a protected call, not what an instance does to it — see
[combat is a fourth kind of refusal](cases.md#combat-is-a-fourth-kind-of-refusal-and-it-is-scoped-to-time).

**2. Distinguish three outcomes, never two.** Nearly every case below is a check
written as a boolean where the third state — *the client will not say* — silently
takes the wrong branch. "Not shown" and "unreadable" are different answers, and
counting the second as the first prints "showing none" exactly where the engine
is working. This applies hardest to diagnostics: **never gate a diagnostic field
behind a value that can itself be secret.**

**3. Predicates fail open.** `ns.IsTrue`/`ns.IsFalse` are both false for an
unreadable value, so the unit passes the gate. Failing closed blinds the addon
in precisely the content it exists for.

**4. If `/reload` fixes it, the reads were fine and the cached answer was old.**
That is a state-lifetime bug, not a restriction. See the delve case.

**5. Reach for the diagnostic commands before the debugger.** `/tt status`,
`/tt debug`, `/tt cotanks` exist because every link in these chains fails
silently and they all look the same from outside. If one of them cannot answer
the question you have, extending it is usually the actual fix.

## Index

| If you see | Case |
|---|---|
| no debuff icons in a boss fight, fine at a dummy | [auras throw, they do not go secret](cases.md#auras-throw-they-do-not-go-secret) |
| icons "built, positioned, shown" and nothing on screen | [AuraButtons are 0×0 unless you size them](cases.md#aurabuttons-are-00-unless-you-size-them) |
| a size slider that does nothing to existing icons | [engine-owned buttons cannot be resized](cases.md#engine-owned-buttons-cannot-be-resized) |
| a diagnostic command that itself throws | [client-owned widget getters are secret](cases.md#client-owned-widget-getters-are-secret) |
| an event that never fires, no error | [a protected event registers "successfully"](cases.md#a-protected-event-registers-successfully) |
| panel missing in a delve, stuck on after leaving; `/reload` fixes both | [zone state cached at the first PEW is stale](cases.md#zone-state-cached-at-the-first-pew-is-stale) |
| a nameplate scan that sees nothing at all | [namePlateUnitToken reads nil](cases.md#nameplateunittoken-reads-nil) |
| threat values unreadable inside instances | [the two threat APIs are not equally restricted](cases.md#the-two-threat-apis-are-not-equally-restricted) |
| an aura group that registers for no events | [the aura container has a required call order](cases.md#the-aura-container-has-a-required-call-order) |
| a fallback that is empty in the content it exists for | [both doors can shut at the same time](cases.md#both-doors-can-shut-at-the-same-time) |
| markers missing after a zone change, never recovering | [a blind wipe drops plates whose ADDED already fired](cases.md#a-blind-wipe-drops-plates-whose-added-already-fired) |
| "action blocked" only after a pull starts; fine at a dummy | [combat is a fourth kind of refusal](cases.md#combat-is-a-fourth-kind-of-refusal-and-it-is-scoped-to-time) |

## Adding a case

Do it when the fix lands, not while still fighting it — a case written mid-fight
records the theory, and the theory is usually the wrong diagnosis you are about
to discard.

Append to [cases.md](cases.md) in this shape:

```markdown
## <what is true, stated as a fact>

**Symptom:** how it presented, in the words it presented itself in — "no debuff
icons across two boss fights", not "aura enumeration failure".
**Wrong diagnosis:** the plausible explanation that cost the time. This is the
most valuable line in the entry; the fix is often obvious once it is ruled out.
**Cause:** the mechanism.
**Fix:** what to do instead, and where it lives.
**Pinned by:** the suite/scenario that fails if this regresses.
```

Two rules that keep it worth reading:

- **A case needs a test.** If nothing in `tests/` fails when the fix is reverted,
  the entry is a story, not a guard — write the scenario first (see the
  `WORLD.*` restriction flags in `CLAUDE.md`), then the entry. `Pinned by: nothing
  yet` is allowed, but it is a visible debt, not a resting state.
- **Do not restate the README.** The README says how the addon works. This says
  what went wrong on the way there and how it was recognised.

If a case turns out to be about *how the addon is built* rather than *how the
client refused something*, it belongs in `CLAUDE.md` or a source comment instead.
This file is specifically the refusals.
