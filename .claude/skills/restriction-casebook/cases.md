# Cases

Solved restrictions, oldest first. Each entry is a bug that has already cost
days once. The **Wrong diagnosis** line is the point of the entry.

---

## Auras throw, they do not go secret

**Symptom:** no debuff icons on the co-tank panel across two whole boss fights.
Everything else on the panel — health, names, the boss ring — kept working.
Fine at a target dummy, fine in the open world.

**Wrong diagnosis:** "restricted auras arrive as secret values, like every other
restricted read, so launder them the way health is laundered." The first version
walked the aura indices and handed each field to a setter unread, on exactly that
assumption.

**Cause:** auras are not that kind of restricted. Inside an encounter or a
Mythic+ the client refuses the *enumeration itself* — `C_UnitAuras.GetAuraDataByIndex`
throws rather than returning a secret. There is no value to launder, and no
amount of `Clean()` helps. Worse, the throw is not local: three throws in a row
tripped the ticker latch and took the **entire panel** down, which is why the
symptom looked like a dead feature rather than a missing row.

**Fix:** do not read auras at all. `UI/AuraRow.lua` hands a unit and a filter to
the client's own `AuraContainer` and lets it draw into regions the addon owns.
The stack count on screen is real and the addon never saw it. `ns.AurasRestricted()`
in `Core/Secret.lua` is the probe for the state. Fall back to reading auras only
where no aura engine exists.

**Pinned by:** `tankwatch:engine` and `debuffs:secret` — `WORLD.aurasSecret`
makes the aura calls *throw*, so any code that walks indices fails the suite
outright.

---

## AuraButtons are 0×0 unless you size them

**Symptom:** the engine reported everything healthy — group created, buttons
built, positioned, shown — and the screen was empty.

**Wrong diagnosis:** "the candidate filter is matching nothing." An unsized
button is completely indistinguishable from a filter that selected no auras, and
that is where the days went.

**Cause:** Blizzard's aura engine never gives an `AuraButton` a rect.
`CustomAuraButtonTemplate` has no `<Size>`, the frame provider sets none, and
`ApplyElementLayout` only clears points and sets one anchor. The group's
`layout.elementWidth`/`elementHeight` control the spacing the flow layout
reserves, **not** the frame's size — `GetElementSize` reads those *instead of*
asking the button.

**Fix:** size the button inside `initializeFrame`. That is the only window; the
engine owns it afterwards. Anything doing `SetAllPoints(button)` inherits 0×0.

**Pinned by:** `tests/suite_tankwatch.lua` — `_RawWidth()`/`_RawHeight()` on the
first engine button must equal `twIconSize`, labelled "engine buttons are sized
by us, or they are invisible".

---

## Engine-owned buttons cannot be resized

**Symptom:** the "Icon size" slider did nothing on screen. The row visibly
respaced itself and the icons in it stayed the size they were first built at.

**Wrong diagnosis:** "push the new size through `SetAuraGroupLayout` like any
other layout change."

**Cause:** the corollary of the case above. Size is baked in `initializeFrame`
and the engine owns the button after, so a live size change cannot reach buttons
that already exist — `SetAuraGroupLayout` with a new `elementWidth` only
respaces them.

**Fix:** the only route to icons at a new size is a container that has never
built any. Frames cannot be destroyed and a slider's `OnValueChanged` fires per
drag step, so retired containers are kept in a cache keyed by the size they were
built at and handed back out — bounded by the slider's range, and free when a
drag passes back over a size already used. A swapped-in container must be
rebound explicitly (`SetUnit`/`SetEnabled`/`UpdateAllAuras`): the unit did not
change, so nothing else will do it for you.

**Pinned by:** `tests/suite_tankwatch.lua`, section "the icon size slider reaches
the icons" — every icon up must report the new size, without a reload.

---

## Client-owned widget getters are secret

**Symptom:** `/tt twapi` — the diagnostic command written specifically to explain
a blank row — threw when run inside instanced content.

**Wrong diagnosis:** "a frame is a frame; reading a widget's own state is not a
unit read." It isn't a unit read, and it is restricted anyway.

**Cause:** an `AuraContainer` and its `AuraButton`s answer their *own* getters
with secret values inside instanced content — `IsShown()`, `GetWidth()`,
`GetHeight()`. `if b:IsShown()` throws. A frame the addon creates is safe to
read; a frame the client hands over is not.

**Fix:** launder through `ns.Clean`/`ns.IsSecret`/`ns.Show`. Report three
outcomes, never two — shown, hidden, and "the client will not say"; counting
unreadable as hidden prints "showing none" precisely where the engine is
working. **Never gate a diagnostic field behind a value that can be secret.**

This one bit twice: as well as crashing the command, gating the first-button
rect behind `IsShown()` hid the one number that would have revealed the 0×0
case above.

**Pinned by:** `tankwatch:secret`.

---

## A protected event registers "successfully"

**Symptom:** the debuff journal stayed thin in exactly the content worth
cataloguing, while reporting that the combat log was feeding it. Every login it
also handed the player an error report.

**Wrong diagnosis:** "the registration is fine — `pcall` wrapped it and it
returned clean — so the log must just be quiet." It was never registered.

**Cause:** on a client that protects `COMBAT_LOG_EVENT_UNFILTERED` the
registration is refused *in the worst way available*: nothing raises, the client
fires `ADDON_ACTION_FORBIDDEN` (which the player's error display shows), leaves
the event unregistered, and returns as though it had worked. A `pcall` catches
nothing and reports success.

**Fix:** `ns.RegisterEvent` calls `IsEventRegistered` afterwards — the only
witness there is — and returns whether the client actually accepted it. Callers
must check the return value. Two refinements that matter:

- Register before the handler list exists, so a refusal leaves nothing behind.
  An empty list would be worse than no list: the next attempt would find it,
  skip the call, and quietly never receive the event.
- Only a definite `false` counts as refusal. A client that will not answer the
  question leaves us assuming it worked, rather than discarding a live event.
- Remember the refusal across sessions. The *attempt* is what the client reports
  as forbidden, so the only way to stop handing the player an error report every
  login is to stop attempting. `logAllowed` and `logRemembered` are kept apart so
  the status line can say "it said no" versus "we took its word for it".

**Pinned by:** `debuffs_log:refused` and `debuffs_log:remembered` —
`WORLD.forbiddenEvents` models the silent refusal, and `EVENT_ATTEMPTS` proves
the second session does not ask again.

---

## Zone state cached at the first PEW is stale

**Symptom:** walk into a delve and the co-tank panel never appears. Walk out and
it stays on screen. **A `/reload` fixed both** — which is the tell.

**Wrong diagnosis:** the old comment in the file said the zone cannot change
without `PLAYER_ENTERING_WORLD`, so reading it on that event is enough. That is
true and it is not the same claim as "the value is correct when PEW fires."

**Cause:** at the *first* PEW after a transition the client will happily still
describe the zone you just left. Cache that and you are wrong for the entire
visit, because nothing asks again. The same window catches a second thing: the
specialization API can answer `nil` for a moment after a loading screen, and
solo there is no roster event coming later to correct it — leaving
`state.isTankRole` false with nothing to trigger a rebuild.

**Fix:** a settle window. `Core/State.lua` re-checks every 0.5s for 10s after a
zone change rather than reading once.

**Pinned by:** `tests/suite_tankwatch.lua` — instance type is asserted across
party, none, pvp and scenario transitions (a delve reports as a `scenario`).

**Generalisation:** if `/reload` fixes it, the reads were fine and the cached
answer was old. That is a state-lifetime bug, and no amount of laundering
touches it.

---

## namePlateUnitToken reads nil

**Symptom:** a nameplate scan that saw nothing at all, anywhere — no error, no
partial results.

**Wrong diagnosis:** anything about threat or filtering. The scan never got as
far as a unit.

**Cause:** plate frames no longer carry a `namePlateUnitToken` field. It reads
`nil`, and a scan built on `C_NamePlate.GetNamePlates()` plus that field sees
nothing **silently**, because a `nil` token merely fails an `if`.

**Fix:** use the `nameplate1`…`nameplate40` unit tokens, built once at load. The
addon uses no unit identity at all — the token *is* the key, `UnitInRaid("player")`
(an integer index) replaces `UnitIsUnit` for dropping our own raid token, and the
personal plate is found with `unit == "player"`, a plain string compare.

**Pinned by:** `core:fresh` — the scan populates `NS.stateByUnit` from the
tokens.

---

## The two threat APIs are not equally restricted

**Symptom:** threat values unreadable inside instances, which reads as "threat
UI cannot work in instances at all."

**Wrong diagnosis:** treating both threat calls as one restricted family. Most
threat UI does, which is why most of it stops working inside instances.

**Cause:** they differ, and the difference is the addon's whole premise:

| Call | Inside an instance |
|---|---|
| `UnitThreatSituation(unit, mob)` | plain, readable **0–3** |
| `UnitDetailedThreatSituation(unit, mob)` | **secret values** for nameplate pairings |

**Fix:** use only the plain one. Its single number carries every state, and
status `2` *is* the at-risk warning stated by the client itself — so no threat
percentage threshold is needed to produce it, which is exactly why it keeps
working where a percentage cannot.

**Pinned by:** `core:fresh` and `tankwatch:secret`.

---

## The aura container has a required call order

**Symptom:** an aura group that registered for no events and drew nothing. No
error.

**Wrong diagnosis:** treating container setup as order-independent property
assignment.

**Cause:** two ordering constraints, both silent when violated.

- **Anchor and size before declaring the group.** The engine drains its parse and
  layout passes from an update armed the moment a group exists, so the container
  needs a real rect from the first one — a 1×1 container lays its buttons out
  inside 1×1.
- **Groups first, unit last.** Assigning the unit is what makes the container
  work out which events to register for, and it decides that against the groups
  it has *at the time*. Set the unit first and it registers for nothing.

**Fix:** `ApplyEngineLayout` → `AddAuraGroup` → `SetUnit`, and keep the
`AddAuraGroup` error message. The engine builds its buttons through
`initializeFrame` during that call, so an error in our own decoration lands
there and takes the whole group with it — keeping the message is the difference
between a diagnosable bug and a blank row.

**Pinned by:** `tankwatch:engine`.

---

## A blind wipe drops plates whose ADDED already fired

**Symptom:** walk into a delve and nothing is marked; walk back out and the
markers stay on screen. `/reload` fixed both.

**Wrong diagnosis:** the same signature as the stale-zone-state case above, and
initially blamed on it. It is a second, independent bug with an identical tell.

**Cause:** plates are torn down and rebuilt *around* `PLAYER_ENTERING_WORLD`,
not inside it. A blind wipe on that event threw away markers for plates whose
`NAME_PLATE_UNIT_ADDED` had already fired — and nothing was going to fire again
for them.

**Fix:** reconcile rather than wipe: once immediately for the plates that already
exist, then again over a short window as the rest arrive.

**Pinned by:** `core:fresh`, asserted on the *marker* rather than on
`NS.stateByUnit` — the threat scan walks the tokens itself and fills that map
whether or not a marker exists, so asserting on the map would pass while the
screen stayed blank.

---

## Both doors can shut at the same time

**Symptom:** the debuff journal stayed nearly empty in raids and Mythic+ — the
exact content it was built to catalogue — while filling normally in the open
world. `/tt status` said the combat log was registered and allowed.

**Wrong diagnosis:** "the aura door is shut in an encounter, which is expected,
and the combat log covers it." The log door was shut too, for an unrelated
reason, and the two failures looked like one.

**Cause:** the log handler attributed a line by comparing `destGUID` against
`myGUID = Clean(UnitGUID("player"))`. Inside an instance that read comes back
secret, so `myGUID` was `nil` and the handler returned at its first guard —
every line somebody's, none provably ours. The fallback for a shut door was
shut by a *different* restriction than the one it was covering.

**Fix:** attribute by `destFlags` instead — position 10 of the log line, an
affiliation bitmask rather than an answer about a unit, so the `MINE` bit works
where identity does not. The GUID compare stays as a secondary route and is the
only way to recognise a *co-tank*, since the mask has no notion of role.

**Generalisation:** when a fallback exists because door A closes in situation X,
check that door B does not also close in X for its own reasons. Two independent
restrictions with the same trigger present as one bug, and the fallback is
never exercised in the place it was designed for.

**Pinned by:** `debuffs:fresh` / `debuffs:secret`, section "our own lines
survive a secret GUID" — `WORLD.guidSecret` now covers every unit, not just the
player, because a harness that left the rest of the raid readable would let a
co-tank feature pass a suite it cannot pass in a raid.

---

## Combat is a fourth kind of refusal, and it is scoped to time

**Anticipated, not debugged.** Every other entry here cost days first. This one
is written up because its *shape* is new and the three in the method table do
not cover it — recorded when hover-casting landed, before it had a chance to
cost anything.

**Symptom it would have presented as:** a panel that works perfectly at a target
dummy and throws "Interface action failed because of an AddOn" the moment a
pull starts. Or worse and quieter: a bar that heals the wrong tank, once, in a
fight where two tanks swapped and nobody could say afterwards what happened.

**Wrong diagnosis:** the one the rest of this file trains you into — that it is
instance-scoped, that `WORLD.secretMode` or `aurasSecret` will reproduce it, and
that a delve run will find it. It will not. The panel is clean in a delve, clean
in a raid, and only wrong in the seconds after a roster change during combat.

**Cause:** secure frames. Creating one, pointing it, showing it and writing its
attributes are all protected, and the client refuses them **while the player is
in combat** — not inside an instance, not for restricted units. The co-tank
panel redraws five times a second and reassigns blocks on any roster event, so
the naive shape (write the unit attribute alongside the health bar) is blocked
on the first pull.

Against the method's table it is a *fourth* shape: it raises, like a throw, but
the trigger is `InCombatLockdown()` rather than where you are standing, and the
same call is fine a second later.

**Fix:** split the panel into the half that can change per tick and the half
that cannot, in `Modules/TankWatch.lua`.

- The secure button is created once per block, `SetAllPoints` on the bar so a
  relayout never re-points it, and `Show()`n once — visibility stays the plain
  parent's job, because hiding an unprotected parent hides a protected child
  without an API call on the protected frame.
- Only the `unit` attribute ever changes, and only when the occupant does.
- `AssignBlocks` pins a bar to the unit its *button* names while in combat, not
  to whoever is drawn. The attribute is the half that cannot move, so it is the
  half that decides; roster order returns when the fight ends.
- What is left — a tank who genuinely arrives mid-pull — is drawn at half alpha
  rather than guessed at. The addon says "I could not wire this one" instead of
  presenting a bar that casts somewhere else.

**Generalisation:** `ns.Clean` has no analogue here. There is no value to
launder and no widget to hand the job to — the only fix is to arrange for the
protected call not to be needed at the moment it is refused. When adding
anything secure, ask what the tick does to it, not what an instance does to it.

**Pinned by:** `tankwatch:fresh` / `:secret` / `:engine`, sections "a pull
cannot rewire a bar, so the panel stops trying" and "in combat a tank keeps the
bar they are already in". The harness makes `SetAttribute` throw while
`WORLD.inCombat` is set, so the suite fails loudly if the addon ever asks.

## A fail-closed check on a secret boolean switches the feature off where it matters

**Symptom:** "I pulled a mob with an important cast in a dungeon and it did not
get marked or make a sound." Fine outdoors; the `importantcasts:secret` suite
passed throughout.

**Wrong diagnosis:** that the important-cast answer was only *sometimes* secret,
so failing closed on it — no marker, no sound — was the safe side for a
decorative alert. The harness agreed, because it modelled the answer as secret
but left the cast's name and spell ID readable ("a cast bar has to work in a
dungeon"). Neither was checked against the generated docs.

**Cause:** `UnitCastingInfo`/`UnitChannelInfo` are `SecretWhenUnitSpellCastRestricted`
— for any unit but you or your pet, the spell ID is secret — and
`C_Spell.IsSpellImportant` accepts it (`AllowedWhenTainted`) and returns a
secret boolean. `IsTrue(secret)` is false, so every cast in every instance took
the "not important" branch. Failing closed on a value that is secret *everywhere
the feature is used* is not a safe default; it is the feature turned off.

**Fix:** never read the answer. In `Modules/ImportantCasts.lua` the marker is
armed for any cast (casting-at-all comes from `isTradeskill`, declared
`NeverSecret`), and the secret goes into `SetAlphaFromBoolean(imp, 1, 0)` on a
gate frame, so the client decides whether it is seen — the way EllesmereUI's
nameplates do it. The pulse lives one frame below the gate, because an Alpha
animation on the gate would drive the alpha the gate exists to set. The
*sound* has no equivalent: every sound call refuses a secret argument from
addon code, a frame's `OnShow` fires for the invisible markers too, and no
event fires on an alpha change. A sound that could only ever work outdoors
was removed rather than kept as a setting that is silent where it matters.

**Generalisation:** a secret boolean can drive what is *drawn* (`SetAlphaFromBoolean`,
`EvaluateColorValueFromBoolean`) but never what the addon *does*. Before choosing
a fail direction, ask whether the value is ever readable in the content the
feature is for — if not, both directions are wrong and the answer has to go to
the client unread. Truth-testing or comparing a secret *boolean* throws;
truthiness on a secret string or number is allowed.

**Pinned by:** `importantcasts:secret`. The harness now returns the cast's name
and spell ID secret, and its secrets carry a payload only `SetAlphaFromBoolean`
resolves, so the suite asserts what the player *sees* — an important cast
visible, an ordinary one transparent — without the addon being able to read
either.
