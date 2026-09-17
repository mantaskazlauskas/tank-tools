--------------------------------------------------------------------------------
-- The debuff journal: what gets recorded, through which door, and what the
-- window makes of it.
--
-- Scenarios:
--   fresh   aura reads are allowed, so both doors are open and a record can
--           carry every flag there is
--   secret  the client refuses aura enumeration, which is a boss fight or a
--           Mythic+. The rich door is shut: nothing may throw, the ticker must
--           not latch, and the combat log has to keep the journal filling.
--
-- The added-aura path is exercised in both, with unreadable fields in the
-- second: UNIT_AURA hands over tables rather than being asked for them, so it
-- is the one aura source that still arrives while enumeration is refused --
-- and what arrives on it may be secret field by field.
--------------------------------------------------------------------------------

local SECRET_AURAS = (SCENARIO == "secret")

WORLD.aurasSecret = SECRET_AURAS
WORLD.auraEngine  = SECRET_AURAS   -- a client in an encounter has the engine
WORLD.zone        = "Elwynn Forest"

WORLD.units["player"] = {
    name = "Tankadin", isPlayer = true, class = "WARRIOR",
    hp = 100, hpMax = 100, auras = {},
}

-- The journal is unfinished work, so it ships behind a flag and starts off.
-- Set before ADDON_LOADED, which is when the database resolves and the gate is
-- read -- exactly the window a saved flag is read in.
TankToolsDB = {
    dbVersion = 2,
    modules = { features = { debuffs = true } },
}

-- What the game's data files know. Not a unit read, so it answers in an
-- encounter like anywhere else, and it is the only reason a record caught in
-- the combat log can have an icon at all.
SPELLDB[100001] = { name = "Gushing Wound", icon = 111, desc = "You are bleeding." }
SPELLDB[300002] = { name = "Catalogued",    icon = 222, desc = "Known to the client." }

FireEvent("ADDON_LOADED", "TankTools")
FireEvent("PLAYER_LOGIN")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Find(id)
    local list = NS.DebuffRecords()
    for i = 1, #list do
        if list[i].id == id then return list[i] end
    end
end

local function Aura(id, o)
    o = o or {}
    return {
        spellId                 = id,
        name                    = o.name,
        icon                    = o.icon,
        isHarmful               = (o.harmful == nil) and true or o.harmful,
        dispelName              = o.dispel,
        isRaid                  = o.raid,
        isBossAura              = o.boss,
        isTankRoleAura          = o.tank,
        isFromPlayerOrPlayerPet = o.mine,
    }
end

local function Added(...)
    FireEvent("UNIT_AURA", "player", { addedAuras = { ... } })
end

local function TextMatching(list, want)
    for i = 1, #list do
        if tostring(list[i]):find(want, 1, true) then return list[i] end
    end
end

--------------------------------------------------------------------------------
section("the gate")
--------------------------------------------------------------------------------

ok(NS.GetFeature("debuffs") ~= nil, "the journal registers a feature flag")
eq(NS.FeatureEnabled("debuffs"), true, "which this suite turned on")
ok(NS.GetTicker("debuffs") ~= nil, "so its module started")
eq(TankToolsDB.modules.debuffs.djRecord, true, "recording is on out of the box")
ok(type(TankToolsDB.modules.debuffs.djSeen) == "table", "and the journal exists")

--------------------------------------------------------------------------------
section("recording -- the aura door")
--------------------------------------------------------------------------------

Added(Aura(100001, { name = "Gushing Wound", icon = 111, dispel = "Magic",
                     raid = true, boss = true, tank = false, mine = false }))

local r = Find(100001)
ok(r ~= nil, "a debuff on the added-aura list is recorded")
if r then
    eq(r.name,   "Gushing Wound", "with the name the aura carried")
    eq(r.icon,   111,             "and its icon")
    eq(r.dispel, "Magic",         "and its dispel type")
    eq(r.raid,   true,            "the raid flag")
    eq(r.boss,   true,            "the boss flag")
    -- The distinction the whole record shape exists for: a flag that is false
    -- is not a flag we never got to read.
    eq(r.tank,   false,           "a flag that is off is stored as off")
    eq(r.via,    "aura",          "and it says it came through the rich door")
    eq(r.n,      1,               "seen once")
    eq(r.where,  "Elwynn Forest", "and where we were standing")
end

Added(Aura(200001, { harmful = false, name = "Power Word: Shield" }))
ok(Find(200001) == nil, "a buff on the same list is not a debuff")

-- The one place in this addon that fails closed, and on purpose: the added
-- aura list carries helpful and harmful together, so an unreadable isHarmful
-- would let every proc you own into a list of debuffs.
Added({ spellId = 200002, isHarmful = SECRETV })
ok(Find(200002) == nil, "an unreadable isHarmful is not recorded as a debuff")

Added(Aura(100002, { name = "Crushing Blow" }))
eq(Find(100002) and Find(100002).dispel, "none",
   "an aura with no dispel type reads as one that cannot be dispelled")

Added({ spellId = 100003, isHarmful = true, dispelName = SECRETV })
eq(Find(100003) and Find(100003).dispel, nil,
   "...which is not what a dispel type we were refused reads as")

-- THE AURA THE PANEL CAN DRAW AND THE JOURNAL CANNOT NAME
--
-- The case that looks like a broken feature from the chair: UNIT_AURA still
-- pushes a table during an encounter -- it is not an enumeration, so it is not
-- refused -- but the id on it can be a secret. The panel renders that aura
-- perfectly, because a display hands a value on unread, and the journal cannot
-- touch it, because a record is keyed by spell id and a secret used as a table
-- key throws.
--
-- So it is dropped, and it is COUNTED. The count is the whole difference
-- between "this addon is broken" and "the client refused to answer", and those
-- want opposite reactions from whoever is reading the status line.
local unnamedBefore = NS.DebuffStats().unnamed
local recordsBefore = NS.DebuffStats().total

Added({ spellId = SECRETV, isHarmful = true })
eq(NS.DebuffStats().unnamed, unnamedBefore + 1,
   "an aura the client will not name is counted, not silently dropped")
eq(NS.DebuffStats().total, recordsBefore,
   "and no record is filed under a key we could not read")

-- A readable `false` is a buff, not a refusal, and must not inflate the count
-- that exists to mean "we were denied".
local harmfulBefore = NS.DebuffStats().unreadableHarmful
Added({ spellId = 200003, isHarmful = false })
eq(NS.DebuffStats().unreadableHarmful, harmfulBefore,
   "a buff is not counted as an aura we were refused")

Added({ spellId = 200004, isHarmful = SECRETV })
eq(NS.DebuffStats().unreadableHarmful, harmfulBefore + 1,
   "but an unreadable isHarmful is")

--------------------------------------------------------------------------------
section("a fact learned is not unlearned")
--------------------------------------------------------------------------------

-- The same debuff again, this time with the flags unreadable. What we already
-- know has to survive it, or a raid would blank every record a delve filled in.
Added({ spellId = 100001, isHarmful = true,
        isRaid = SECRETV, isBossAura = SECRETV, dispelName = SECRETV })

r = Find(100001)
eq(r.raid,   true,    "a flag read earlier survives a read we were refused")
eq(r.boss,   true,    "...for each flag separately")
eq(r.dispel, "Magic", "and so does the dispel type")
eq(r.n,      2,       "the sighting is still counted")

--------------------------------------------------------------------------------
section("recording -- the combat log")
--------------------------------------------------------------------------------

FireCombatLog("SPELL_AURA_APPLIED", 300001, "Log Only", "DEBUFF")

r = Find(300001)
ok(r ~= nil, "a debuff seen only in the combat log is still recorded")
if r then
    eq(r.via,    "log",      "and says so")
    eq(r.name,   "Log Only", "the log carries a name")
    eq(r.dispel, nil,        "but no dispel type")
    eq(r.raid,   nil,        "and no raid flag")
    eq(r.boss,   nil,        "and no boss flag")
end

-- The half of a log-only record the spell database can fill in. The log gives
-- an id and nothing else useful; asking what that id is called is not a
-- question about a unit, so it is answerable here.
FireCombatLog("SPELL_AURA_APPLIED", 300002, nil, "DEBUFF")
r = Find(300002)
eq(r and r.name, "Catalogued", "the spell database names a record the log did not")
eq(r and r.icon, 222,          "and gives it an icon, which no log line carries")

FireCombatLog("SPELL_AURA_APPLIED", 300003, "A Buff", "BUFF")
ok(Find(300003) == nil, "a buff in the log is not a debuff")

FireCombatLog("SPELL_AURA_APPLIED", 300004, "Not Mine", "DEBUFF",
              "Player-1-SOMEBODYELSE")
ok(Find(300004) == nil, "a debuff applied to somebody else is not ours")

FireCombatLog("SPELL_DAMAGE", 300005, "A Hit", "DEBUFF")
ok(Find(300005) == nil, "a damage line is not an aura application")

--------------------------------------------------------------------------------
section("the doors are ranked")
--------------------------------------------------------------------------------

FireCombatLog("SPELL_AURA_APPLIED", 400001, "Upgraded", "DEBUFF")
eq(Find(400001).via, "log", "a debuff first met in the log is a log record")

Added(Aura(400001, { name = "Upgraded", dispel = "Curse", boss = true }))
r = Find(400001)
eq(r.via,    "aura",  "and is upgraded the first time the aura door opens")
eq(r.dispel, "Curse", "gaining the flags a log line could never have carried")

FireCombatLog("SPELL_AURA_REFRESH", 400001, "Upgraded", "DEBUFF")
eq(Find(400001).via, "aura", "and never falls back to the poorer door")

--------------------------------------------------------------------------------
section("reading our own auras")
--------------------------------------------------------------------------------

WORLD.units["player"].auras = {
    { spellId = 500001, name = "Already On You", icon = 333,
      dispel = "Poison", boss = true, applications = 3 },
}

-- The scan is rate limited, so the clock has to move before it will run again.
Tick(2)
FireEvent("PLAYER_ENTERING_WORLD")

if SECRET_AURAS then
    ok(Find(500001) == nil,
       "nothing is read while the client refuses aura enumeration")
    eq(FAILED_TICKS(), 0, "...and nothing latched a ticker trying")
else
    r = Find(500001)
    ok(r ~= nil, "a debuff already on us when we zone in is picked up")
    eq(r and r.dispel, "Poison", "with its dispel type")
    eq(r and r.boss,   true,     "and its boss flag")
end

--------------------------------------------------------------------------------
section("recording can be turned off")
--------------------------------------------------------------------------------

local store = TankToolsDB.modules.debuffs

store.djRecord = false
Added(Aura(600001, { name = "Not Wanted" }))
FireCombatLog("SPELL_AURA_APPLIED", 600002, "Also Not Wanted", "DEBUFF")
ok(Find(600001) == nil and Find(600002) == nil, "neither door records while off")

store.djRecord = true
store.djFromLog = false
FireCombatLog("SPELL_AURA_APPLIED", 600003, "Log Off", "DEBUFF")
ok(Find(600003) == nil, "the log door closes on its own")
Added(Aura(600004, { name = "Aura Still On" }))
ok(Find(600004) ~= nil, "without shutting the other one")
store.djFromLog = true

--------------------------------------------------------------------------------
section("reading it back")
--------------------------------------------------------------------------------

-- Sorting by recency needs the clock to have moved between records, which is
-- what makes this the last one written.
WALL = WALL + 100
Added(Aura(900001, { name = "Zebra Last" }))

eq(NS.DebuffRecords(nil, "recent")[1].id, 900001, "the newest record sorts first")

local byName = NS.DebuffRecords(nil, "name")
local sorted = true
for i = 2, #byName do
    if (byName[i - 1].name or ""):lower() > (byName[i].name or ""):lower() then
        sorted = false
    end
end
ok(sorted, "and by name when asked, ascending")

eq(#NS.DebuffRecords("gushing"), 1, "the filter matches a name, case-insensitively")
eq(#NS.DebuffRecords("300001"),  1, "and matches a spell id")
eq(#NS.DebuffRecords("  gushing  "), 1, "and does not care about stray spaces")
eq(#NS.DebuffRecords("no such debuff"), 0, "and matches nothing when nothing does")

local stats = NS.DebuffStats()
ok(stats.total > 0, "the stats count the journal")
eq(stats.recording, true, "and report that recording is on")
eq(stats.restricted, SECRET_AURAS, "and whether aura reads are allowed here")
eq(stats.logOpen, true, "and that we can pick our own lines out of the log")

-- The list handed out is a fresh array, so a caller cannot edit the journal by
-- holding on to it -- and an eviction cannot happen underneath a redraw that
-- is walking one.
local copy = NS.DebuffRecords()
local size = #copy
table.remove(copy)
ok(copy ~= NS.DebuffRecords(), "each call hands back a different array")
eq(#NS.DebuffRecords(), size, "and editing one does not shorten the journal")

--------------------------------------------------------------------------------
section("our own lines survive a secret GUID")
--------------------------------------------------------------------------------

-- This is the regression that made the journal thinnest in exactly the content
-- worth cataloguing. Inside an instance UnitGUID("player") is a secret, so the
-- GUID compare could never match and the log door shut itself in the one place
-- the aura door was already shut -- both doors closed at once, and the feature
-- looked broken rather than restricted.
--
-- destFlags is the way out: an affiliation bitmask on the log line, needing
-- nobody's identity, so a line aimed at us is recognisably ours in a raid.
WORLD.guidSecret = true
FireEvent("PLAYER_ENTERING_WORLD")

FireCombatLog("SPELL_AURA_APPLIED", 650001, "Ours Anyway", "DEBUFF")
ok(Find(650001) ~= nil, "a line flagged MINE is recorded without a readable GUID")
eq(NS.DebuffStats().logOpen, true, "and the journal reports the door open")
eq(NS.DebuffStats().selfByFlag, true, "attributed by the affiliation mask")

-- Both routes gone at once: no GUID to compare, and a mask the client will not
-- let us read either. Nothing is recorded, and nothing throws.
FireCombatLog("SPELL_AURA_APPLIED", 650002, "Unattributable", "DEBUFF",
              nil, SECRETV)
ok(Find(650002) == nil, "nothing is recorded when neither route can attribute it")

WORLD.guidSecret = false
FireEvent("PLAYER_ENTERING_WORLD")

--------------------------------------------------------------------------------
section("co-tank debuffs")
--------------------------------------------------------------------------------

-- The point of recording anybody but ourselves: the co-tank row draws auras on
-- the OTHER tank, so a journal that only ever saw our own debuffs could never
-- offer us the one we actually watched all night and wanted to mark.
WORLD.inRaid, WORLD.groupSize = true, 3
WORLD.units["raid1"] = { name = "Tankadin", guid = WORLD.guid,
                         combatRole = "TANK",   hp = 100, hpMax = 100, auras = {} }
WORLD.units["raid2"] = { name = "Bearbutt", guid = "Player-2-BEARBUTT",
                         combatRole = "TANK",   hp = 100, hpMax = 100, auras = {} }
WORLD.units["raid3"] = { name = "Healbot",  guid = "Player-3-HEALBOT",
                         combatRole = "HEALER", hp = 100, hpMax = 100, auras = {} }
FireEvent("GROUP_ROSTER_UPDATE")

ok(#NS.tankUnits >= 2, "the roster produced co-tanks")
eq(NS.DebuffStats().tanksBlind, 0, "whose GUIDs are readable out here")

FireCombatLog("SPELL_AURA_APPLIED", 660001, "Tank Smash", "DEBUFF",
              "Player-2-BEARBUTT")
ok(Find(660001) ~= nil, "a co-tank's debuff is recorded from the log")

-- The scope is tanks, and a scope that quietly took everybody would fill the
-- journal with other people's problems.
FireCombatLog("SPELL_AURA_APPLIED", 660002, "Healer Problem", "DEBUFF",
              "Player-3-HEALBOT")
ok(Find(660002) == nil, "a healer's is not")

if not SECRET_AURAS then
    -- The rich door, pointed at somebody else. SCAN_GAP has to pass first: the
    -- zone-in above already scanned, and a second walk inside the same second
    -- is the throttle doing its job.
    WORLD.units["raid2"].auras = { Aura(660003, { name = "On The Other Tank",
                                                  boss = true }) }
    Tick(1.5)
    FireEvent("UNIT_AURA", "raid2")
    local r = Find(660003)
    ok(r ~= nil, "a co-tank's aura is read where the client allows it")
    if r then eq(r.via, "aura", "and recorded through the rich door") end
end

-- WHAT THIS CANNOT DO, STATED RATHER THAN HIDDEN
--
-- Attributing a log line to a co-tank *specifically* needs a GUID, and an
-- encounter takes GUIDs away. destFlags cannot stand in: its affiliation bits
-- distinguish mine / party / raid and have no notion of role, so "this line is
-- about a tank" is exactly the question the mask cannot answer.
--
-- So co-tank recording degrades to nothing inside an encounter, and the status
-- command says so. That is the honest shape of it -- the alternative is a
-- journal that silently stops learning about the other tank on the one night
-- it matters.
WORLD.guidSecret = true
FireEvent("GROUP_ROSTER_UPDATE")

eq(NS.DebuffStats().tanksKnown, 0, "no co-tank can be recognised")
ok(NS.DebuffStats().tanksBlind > 0, "and the journal counts how many it lost")

FireCombatLog("SPELL_AURA_APPLIED", 660004, "Unattributable Tank Hit", "DEBUFF",
              "Player-2-BEARBUTT")
ok(Find(660004) == nil, "a co-tank's line cannot be attributed in an encounter")

WORLD.guidSecret = false
WORLD.inRaid, WORLD.groupSize = false, 0
WORLD.units["raid1"], WORLD.units["raid2"], WORLD.units["raid3"] = nil, nil, nil
FireEvent("GROUP_ROSTER_UPDATE")

--------------------------------------------------------------------------------
section("the third door -- the Encounter Journal")
--------------------------------------------------------------------------------

-- The door that does not care who the debuff lands on, and the only one that
-- can answer before anybody has been hit. It is content data, so it works
-- identically in both scenarios -- that is the whole point of it, and asserting
-- it under `secret` is asserting exactly that.
WORLD.journal = {
    instance   = 1200,
    encounters = {
        { name = "Trash Boss", journalID = 2001, dungeonID = 3001, root = 10 },
        { name = "The Boss",   journalID = 2002, dungeonID = 3002, root = 20 },
    },
    sections = {
        -- The other boss, which must not be walked.
        [10] = { title = "Wrong Boss Ability", spellID = 710001 },
        -- A heading with no spell of its own, holding two abilities.
        [20] = { title = "Abilities", firstChildSectionID = 21 },
        [21] = { title = "Tank Buster", spellID = 700001, abilityIcon = 77,
                 siblingSectionID = 22 },
        [22] = { title = "Raid Wide",   spellID = 700002, siblingSectionID = 23 },
        -- A child of a sibling: the walk has to go down as well as across.
        [23] = { title = "Phase Two", firstChildSectionID = 24 },
        [24] = { title = "Enrage", spellID = 700003 },
    },
}

FireEvent("ENCOUNTER_START", 3002, "The Boss", 16, 20)

ok(Find(700001) ~= nil, "a boss ability is learned before it ever lands")
ok(Find(700002) ~= nil, "...including one on a sibling section")
ok(Find(700003) ~= nil, "...and one nested under a sibling")
ok(Find(710001) == nil, "another boss's abilities are not swept in")

local jr = Find(700001)
eq(jr.via,  "journal", "and it is marked as coming from the journal")
eq(jr.n,    0,         "with no sightings, because nothing was seen")
eq(jr.name, "Tank Buster", "the journal's own title is kept")

-- The mapping that is easy to get wrong: ENCOUNTER_START carries the dungeon
-- id, and looking the journal up by it directly finds nothing.
eq(EJ_SELECTED, nil,
   "the player's open Dungeon Journal was not repointed to do the lookup")

eq(NS.DebuffStats().journalIDs, 3, "the status line counts what it learned")
eq(NS.DebuffStats().journalErr, nil, "and reports no problem")

-- A sighting upgrades a candidate rather than duplicating it: same spell id,
-- so the same record, now with a real count on it.
Added(Aura(700001, { name = "Tank Buster", boss = true }))
jr = Find(700001)
eq(jr.via, "aura", "meeting it for real upgrades the record")
eq(jr.n,   1,      "and starts counting sightings from the first real one")

-- A boss that is not in the journal says so rather than going quiet.
FireEvent("ENCOUNTER_START", 9999, "Unknown Boss", 16, 20)
ok(NS.DebuffStats().journalErr ~= nil, "an unlistable boss is reported")

-- A client whose API needs the instance selected first. The addon prefers not
-- to touch the selection, but a client that leaves it no choice must still
-- work rather than silently learning nothing.
WORLD.journal.needsSelect = true
FireEvent("ENCOUNTER_START", 3001, "Trash Boss", 16, 20)
ok(Find(710001) ~= nil, "it falls back to selecting when the client requires it")
eq(EJ_SELECTED, 1200, "and says which instance it selected")

WORLD.journal, EJ_SELECTED = nil, nil

--------------------------------------------------------------------------------
section("the window")
--------------------------------------------------------------------------------

NS.ShowDebuffs()
local panel = _G.TankToolsDebuffsFrame

ok(panel ~= nil and panel:IsShown(), "the window opens")

local rowFrames = FramesParentedTo(panel.list)
eq(#rowFrames, 12, "twelve row frames, however long the journal gets")

local texts = TextsIn(panel)
ok(TextMatching(texts, "Gushing Wound") ~= nil, "it lists a debuff by name")
ok(TextMatching(texts, "#100001") ~= nil,       "and by spell id")
ok(TextMatching(texts, "Magic") ~= nil,         "and shows the dispel type")
ok(TextMatching(texts, "log only") ~= nil,
   "and marks the records that only ever came through the log")
ok(TextMatching(texts, "recorded of") ~= nil,   "and says how full the journal is")

-- Typing in the filter box narrows the list as you go, without a keypress to
-- commit -- which is why the script is driven directly rather than the text
-- simply being set.
panel.filter:SetText("gushing")
panel.filter._scripts.OnTextChanged(panel.filter)

ok(rowFrames[1]:IsShown(), "filtering to one debuff leaves one row drawn")
ok(not rowFrames[2]:IsShown(), "...and hides the rest")

panel.filter:SetText("no such debuff")
panel.filter._scripts.OnTextChanged(panel.filter)
ok(panel.empty:IsShown(), "a filter matching nothing says so rather than going blank")
ok(not rowFrames[1]:IsShown(), "with no rows left drawn")

panel.filter:SetText("")
panel.filter._scripts.OnTextChanged(panel.filter)
ok(rowFrames[1]:IsShown(), "and clearing it brings the list back")

--------------------------------------------------------------------------------
section("hovering a row")
--------------------------------------------------------------------------------

panel.filter:SetText("gushing")
panel.filter._scripts.OnTextChanged(panel.filter)

rowFrames[1]._scripts.OnEnter(rowFrames[1])
ok(GameTooltip:IsShown(), "a row shows a tooltip")
eq(GameTooltip._content and GameTooltip._content.how, "spell",
   "the game's own spell tooltip, description and all, where it has one")
ok(TextMatching(GameTooltip._lines, "spell id 100001") ~= nil,
   "with our own lines underneath it")

rowFrames[1]._scripts.OnLeave(rowFrames[1])
ok(not GameTooltip:IsShown(), "and takes it away again")

-- A spell the client has never heard of: SetSpellByID errors rather than
-- returning nothing, and the row has to survive that with a tooltip of its own.
panel.filter:SetText("Log Only")
panel.filter._scripts.OnTextChanged(panel.filter)

rowFrames[1]._scripts.OnEnter(rowFrames[1])
ok(GameTooltip:IsShown(), "a spell the client does not know still gets a tooltip")
eq(GameTooltip._content and GameTooltip._content.how, "text",
   "...built by us, because the game refused to build one")
rowFrames[1]._scripts.OnLeave(rowFrames[1])

panel.filter:SetText("")
panel.filter._scripts.OnTextChanged(panel.filter)

--------------------------------------------------------------------------------
section("scrolling")
--------------------------------------------------------------------------------

for i = 1, 20 do
    WALL = WALL + 1
    FireCombatLog("SPELL_AURA_APPLIED", 800000 + i, "Filler " .. i, "DEBUFF")
end

-- A record changing only marks the journal dirty; the redraw is on the shared
-- ticker, which is what stops a debuff refreshing ten times a second costing
-- ten redraws.
Tick(1)

ok(panel.scroll:IsShown(), "the scrollbar appears once the list overflows")

local top = rowFrames[1]._rec
panel.list._scripts.OnMouseWheel(panel.list, -1)
ok(rowFrames[1]._rec ~= top, "the wheel scrolls the list")

panel.list._scripts.OnMouseWheel(panel.list, 1)
eq(rowFrames[1]._rec, top, "and back")

-- Scrolling up from the top must not run off the end of the array.
for _ = 1, 20 do panel.list._scripts.OnMouseWheel(panel.list, 1) end
eq(rowFrames[1]._rec, top, "and stops at the top")

for _ = 1, 100 do panel.list._scripts.OnMouseWheel(panel.list, -1) end
ok(rowFrames[1]._rec ~= nil, "and at the bottom, with the last page still full")

--------------------------------------------------------------------------------
section("the cap")
--------------------------------------------------------------------------------

for i = 1, 420 do
    WALL = WALL + 1
    FireCombatLog("SPELL_AURA_APPLIED", 1000000 + i, "Bulk " .. i, "DEBUFF")
end

eq(#NS.DebuffRecords(), 400, "the journal is capped, and the oldest go first")
ok(Find(1000420) ~= nil, "the newest is kept")
ok(Find(100001) == nil,  "and something not seen for longest is not")

--------------------------------------------------------------------------------
section("forgetting")
--------------------------------------------------------------------------------

local n = NS.ForgetDebuffs()
eq(n, 400, "forgetting says how many went")
eq(#NS.DebuffRecords(), 0, "and the journal is empty")

Tick(1)
ok(panel.empty:IsShown(), "the open window says so rather than showing stale rows")
ok(not rowFrames[1]:IsShown(), "with every row hidden")

FireCombatLog("SPELL_AURA_APPLIED", 111111, "After The Wipe", "DEBUFF")
ok(Find(111111) ~= nil, "and recording carries straight on")

--------------------------------------------------------------------------------
section("commands")
--------------------------------------------------------------------------------

NS.ToggleDebuffs()
ok(not panel:IsShown(), "toggle hides the window")

Slash("debuffs")
ok(panel:IsShown(), "/tt debuffs opens it")
Slash("debuffs")
ok(not panel:IsShown(), "and closes it again")

Slash("dj")
ok(panel:IsShown(), "the short form works too")

Slash("debuffs clear")
eq(#NS.DebuffRecords(), 0, "/tt debuffs clear empties the journal")

local before = #CHAT
Slash("status")
local said = ""
for _, line in ipairs(ChatSince(before)) do said = said .. Strip(line) .. "\n" end
ok(said:find("debuff journal") ~= nil, "and /tt status reports on it")

before = #CHAT
Slash("")
local help = ""
for _, line in ipairs(ChatSince(before)) do help = help .. Strip(line) .. "\n" end
ok(help:find("/tt debuffs") ~= nil, "the command is listed in the help")

--------------------------------------------------------------------------------
section("marking")
--------------------------------------------------------------------------------

-- The last command cleared the journal, so this is a fresh record for a mark
-- to land on.
FireCombatLog("SPELL_AURA_APPLIED", 700001, "Trash Nuisance", "DEBUFF")

local important, ignored = NS.DebuffMarkedIDs()
eq(important[700001], nil, "unmarked to start")

NS.SetDebuffMark(700001, "important")
important, ignored = NS.DebuffMarkedIDs()
eq(important[700001], true, "marking important puts the id in that set")
eq(ignored[700001], nil,    "and not in the other")
eq(NS.DebuffMarkCounts(), 1, "and the counts agree")

NS.SetDebuffMark(700001, "bogus")
eq(Find(700001).mark, "important",
   "an unrecognised mark is refused rather than overwriting the real one")

NS.SetDebuffMark(700001, "ignored")
important, ignored = NS.DebuffMarkedIDs()
eq(important[700001], nil,  "switching to ignored clears it from the important set")
eq(ignored[700001], true,   "and sets it in the other one")

NS.SetDebuffMark(700001, nil)
important, ignored = NS.DebuffMarkedIDs()
eq(important[700001], nil, "and nil clears the mark entirely")
eq(ignored[700001], nil,   "from both sets")

NS.SetDebuffMark(999999, "important")
eq(NS.DebuffMarkCounts(), 0,
   "marking an id the journal never recorded is a no-op")

--------------------------------------------------------------------------------
section("marks and pruning")
--------------------------------------------------------------------------------

FireCombatLog("SPELL_AURA_APPLIED", 700002, "Kept Forever", "DEBUFF")
NS.SetDebuffMark(700002, "important")

-- Four hundred fresh records, all newer than the marked one, is well past
-- what it would take to prune an ordinary record on recency alone.
for i = 1, 400 do
    WALL = WALL + 1
    FireCombatLog("SPELL_AURA_APPLIED", 710000 + i, "Padding " .. i, "DEBUFF")
end

ok(Find(700002) ~= nil,
   "a marked record is not evicted even when the cap is long since passed")
eq(#NS.DebuffRecords(), 401,
   "and does not count against the four hundred unmarked slots")

local forgotten = NS.ForgetDebuffs()
eq(forgotten, 400, "forgetting only clears the unmarked four hundred")
eq(#NS.DebuffRecords(), 1, "leaving the marked one behind")
ok(Find(700002) ~= nil and Find(700002).mark == "important",
   "record and mark both survive a forget")

NS.SetDebuffMark(700002, nil)
NS.ForgetDebuffs()
eq(#NS.DebuffRecords(), 0, "clearing the mark lets the last one go too")

--------------------------------------------------------------------------------
section("marking from the row")
--------------------------------------------------------------------------------

FireCombatLog("SPELL_AURA_APPLIED", 700003, "Click Me", "DEBUFF")
Tick(1)   -- the window is still open; flush the redraw

panel.filter:SetText("Click Me")
panel.filter._scripts.OnTextChanged(panel.filter)

ok(rowFrames[1]._rec and rowFrames[1]._rec.id == 700003,
   "the filtered row is bound to the new record")

rowFrames[1]._scripts.OnMouseUp(rowFrames[1], "LeftButton")
eq(Find(700003).mark, "important", "left-click marks the row important")
ok(TextMatching(TextsIn(panel), "important") ~= nil,
   "and the row grows an \"important\" chip")

rowFrames[1]._scripts.OnMouseUp(rowFrames[1], "LeftButton")
eq(Find(700003).mark, nil, "clicking the same mark again clears it")

rowFrames[1]._scripts.OnMouseUp(rowFrames[1], "RightButton")
eq(Find(700003).mark, "ignored", "right-click marks it ignored instead")
eq(rowFrames[1]:GetAlpha(), 0.45, "and the row dims to say so")

rowFrames[1]._scripts.OnMouseUp(rowFrames[1], "RightButton")
eq(Find(700003).mark, nil, "clicking ignored again clears it")
eq(rowFrames[1]:GetAlpha(), 1, "back at full opacity")

panel.filter:SetText("")
panel.filter._scripts.OnTextChanged(panel.filter)
NS.ForgetDebuffs()

--------------------------------------------------------------------------------
section("an event the client will not register")
--------------------------------------------------------------------------------

-- The bug this guards, and it is nastier than it looks: a protected event does
-- not raise. The client fires ADDON_ACTION_FORBIDDEN at the player's error
-- display, leaves the event unregistered, and returns as though it worked -- so
-- pcall reports success and the caller believes it is subscribed. The debuff
-- journal believed exactly that, recorded nothing from the log, never learned
-- why, and asked again every login, earning the player an error report each
-- time. Only IsEventRegistered can tell.
WORLD.forbiddenEvents = { TT_TEST_PROTECTED = true }

eq(NS.RegisterEvent("TT_TEST_PROTECTED", function() end), false,
   "a silently refused registration is reported as refused, not as success")
eq(NS.RegisterEvent("TT_TEST_ORDINARY", function() end), true,
   "and an ordinary one still registers")

-- The refusal must leave nothing behind. An empty handler list would make the
-- next attempt believe the event was already registered, skip the call, and
-- silently never deliver it.
WORLD.forbiddenEvents = nil
eq(NS.RegisterEvent("TT_TEST_PROTECTED", function() end), true,
   "and a later attempt is not poisoned by the earlier refusal")

eq(NS.DebuffStats().logAllowed, true,
   "the journal reports the combat log door it actually got")

--------------------------------------------------------------------------------
section("nothing latched")
--------------------------------------------------------------------------------

Tick(1)
eq(FAILED_TICKS(), 0, "no ticker failed anywhere in this suite")

report()
