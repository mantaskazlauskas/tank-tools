--------------------------------------------------------------------------------
-- The journal on a client that protects the combat log.
--
-- This is a field bug, twice over, and both halves are asserted here.
--
-- First: registering for COMBAT_LOG_EVENT_UNFILTERED is refused by *raising*,
-- and a module's OnInit is a single pcall in Core/DB.lua -- so the refusal took
-- the zone-in scan, the redraw ticker and every later registration down with
-- it, and left the module marked failed. The journal did not fill and its
-- window never redrew, which reads as "the addon is broken", not "one door is
-- shut".
--
-- Second: guarding the call stopped the damage but not the noise. The client
-- fires ADDON_ACTION_FORBIDDEN on the *attempt*, caught or not, so asking every
-- login hands the player an error report every login about a door already known
-- to be shut. The refusal is dated with the interface version instead.
--
-- Scenarios:
--   refused     the client says no, and this is the first time we have asked
--   remembered  a previous session was refused on this same build, so we must
--               not ask again -- EVENT_ATTEMPTS is how that is proved
--------------------------------------------------------------------------------

local REMEMBERED = (SCENARIO == "remembered")
local BUILD      = 120000

WORLD.tocVersion = BUILD
WORLD.zone       = "Elwynn Forest"
WORLD.forbiddenEvents = { COMBAT_LOG_EVENT_UNFILTERED = true }

WORLD.units["player"] = {
    name = "Tankadin", isPlayer = true, class = "WARRIOR",
    hp = 100, hpMax = 100, auras = {},
}

TankToolsDB = {
    dbVersion = 2,
    modules = {
        features = { debuffs = true },
        -- The scenario's whole point: a refusal this client already gave us.
        debuffs  = REMEMBERED and { djLogRefusedOn = BUILD } or nil,
    },
}

SPELLDB[100001] = { name = "Gushing Wound", icon = 111, desc = "You are bleeding." }

FireEvent("ADDON_LOADED", "TankTools")
FireEvent("PLAYER_LOGIN")

local function Find(id)
    local list = NS.DebuffRecords()
    for i = 1, #list do
        if list[i].id == id then return list[i] end
    end
end

--------------------------------------------------------------------------------
section("the module survives a door it is not allowed to open")
--------------------------------------------------------------------------------

local m = NS.GetModule("debuffs")
ok(m ~= nil, "the module exists")
ok(not m.failed, "and did not fail to start on the refused registration")

-- Everything declared *after* the combat log in OnInit. These are what the
-- unguarded raise silently cost, and the reason the window looked dead.
ok(NS.GetTicker("debuffs") ~= nil, "the redraw ticker was still registered")
eq(NS.DebuffStats().logOpen, true,
   "and the zone-in handler ran, so we know our own GUID")

--------------------------------------------------------------------------------
section("what it says about the door")
--------------------------------------------------------------------------------

local s = NS.DebuffStats()
eq(s.logAllowed, false, "the journal reports the combat log as not available")
eq(s.logRemembered, REMEMBERED,
   REMEMBERED and "and that it did not ask, because it was told before"
              or  "and that it asked this session and was refused")

--------------------------------------------------------------------------------
section("asking, or not asking")
--------------------------------------------------------------------------------

if REMEMBERED then
    -- The entire fix for the error-per-login: the attempt is what the client
    -- reports, so the only way to stop the report is not to attempt.
    eq(EVENT_ATTEMPTS.COMBAT_LOG_EVENT_UNFILTERED, nil,
       "a remembered refusal is not asked again, so nothing is forbidden")
else
    eq(EVENT_ATTEMPTS.COMBAT_LOG_EVENT_UNFILTERED, 1,
       "a first refusal is asked exactly once")
    eq(TankToolsDB.modules.debuffs.djLogRefusedOn, BUILD,
       "and remembered against the build that refused it")
end

--------------------------------------------------------------------------------
section("the aura door still works")
--------------------------------------------------------------------------------

-- The journal is poorer on this client, not broken: what lands on us outside an
-- encounter is still recorded, with every flag the aura carried.
FireEvent("UNIT_AURA", "player", { addedAuras = { {
    spellId = 100001, isHarmful = true, name = "Gushing Wound", icon = 111,
    dispelName = "Magic", isRaid = true,
} } })

local r = Find(100001)
ok(r ~= nil, "a debuff still reaches the journal through the aura door")
eq(r and r.via, "aura", "through the rich door, which is the only one left")
eq(r and r.dispel, "Magic", "with the flags the combat log could never carry")

FireCombatLog("SPELL_AURA_APPLIED", 300001, "Never Arrives", "DEBUFF")
ok(Find(300001) == nil,
   "and nothing arrives from a log we were never registered for")

--------------------------------------------------------------------------------
section("asking again by hand")
--------------------------------------------------------------------------------

-- The escape hatch, for a refusal that was situational or a patch that
-- relented. It must actually re-ask, which for the remembered scenario means
-- the count goes up from nothing.
local asked = EVENT_ATTEMPTS.COMBAT_LOG_EVENT_UNFILTERED or 0

eq(NS.RetryDebuffLog(), false, "asking again while still refused says so")
eq(EVENT_ATTEMPTS.COMBAT_LOG_EVENT_UNFILTERED, asked + 1,
   "and it really did ask, rather than repeating the remembered answer")
eq(TankToolsDB.modules.debuffs.djLogRefusedOn, BUILD,
   "the refusal is re-dated, so the next login is quiet again")

-- And when the client relents, the door opens and the memory is dropped.
WORLD.forbiddenEvents = nil
eq(NS.RetryDebuffLog(), true, "once the client allows it, the door opens")
eq(TankToolsDB.modules.debuffs.djLogRefusedOn, nil,
   "and nothing is remembered against a client that said yes")

FireCombatLog("SPELL_AURA_APPLIED", 300002, "Arrives Now", "DEBUFF")
ok(Find(300002) ~= nil, "log lines are recorded from then on")

-- Asked once more with the door already open, nothing is registered twice: a
-- second handler would count every log line as two sightings.
local before = Find(300002).n
eq(NS.RetryDebuffLog(), true, "asking again with the door open is harmless")
FireCombatLog("SPELL_AURA_APPLIED", 300002, "Arrives Now", "DEBUFF")
eq(Find(300002).n, before + 1, "and the handler is not registered twice")

--------------------------------------------------------------------------------
section("the command")
--------------------------------------------------------------------------------

local before = #CHAT
Slash("debuffs log")
local said = ""
for _, line in ipairs(ChatSince(before)) do said = said .. Strip(line) .. "\n" end
ok(said:find("combat log door is open") ~= nil,
   "/tt debuffs log reports the door it found: " .. said)

--------------------------------------------------------------------------------
section("nothing latched")
--------------------------------------------------------------------------------

Tick(1)
eq(FAILED_TICKS(), 0, "no ticker failed anywhere in this suite")

report()
