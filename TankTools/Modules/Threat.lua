--------------------------------------------------------------------------------
-- Tank Tools -- threat scan
--
-- A tank's answer to one question: "which enemy is on someone else, so I can
-- taunt it off?"
--
-- This module produces one thing: `ns.stateByUnit`, a map from nameplate unit
-- token to one of three threat states. It draws nothing. Whoever wants to show
-- that information registers as a consumer, and the scan does not know or care
-- who they are -- which is what lets the nameplate marker be deleted, or a
-- second display be added, without touching a line of this file.
--
-- There is no threat meter, no list, no percentages -- inside an instance the
-- client restricts every value those would need (names come back unreadable,
-- threat numbers come back secret), and none of them is what a tank acts on
-- anyway. What you act on is "that one is not mine", and that survives every
-- restriction.
--------------------------------------------------------------------------------

local _, ns = ...

-- Hot-path upvalues. The scan runs 5x/sec across every visible nameplate, so
-- every global lookup here is one we do not pay for.
local UnitThreatSituation    = UnitThreatSituation
local UnitExists             = UnitExists
local UnitName               = UnitName
local UnitCanAttack          = UnitCanAttack
local UnitIsDead             = UnitIsDead
local UnitIsPlayer           = UnitIsPlayer
local UnitIsUnit             = UnitIsUnit
local UnitPlayerOrPetInParty = UnitPlayerOrPetInParty
local UnitPlayerOrPetInRaid  = UnitPlayerOrPetInRaid
local UnitAffectingCombat    = UnitAffectingCombat
local GetNumGroupMembers     = GetNumGroupMembers
local GetTime                = GetTime
local twipe                  = wipe
local format                 = string.format

local Clean, IsTrue, IsFalse, Show = ns.Clean, ns.IsTrue, ns.IsFalse, ns.Show
local Print      = ns.Print
local state      = ns.state
local groupUnits = ns.groupUnits

local M = ns.NewModule("threat", {
    defaults = {
        onlyTankSpec = true,   -- do nothing at all unless the player is a tank
        sound        = true,   -- audible alert when a mob stops being yours
    },
})

local db   -- resolved in OnInit

local UPDATE_INTERVAL = 0.2
local ALERT_COOLDOWN  = 1.5

--------------------------------------------------------------------------------
-- Threat states
--
-- The numbers are shared with any display module, which uses them to index its
-- per-kind settings table.
--------------------------------------------------------------------------------

local STATE_LOST   = 1   -- something else is tanking it
local STATE_WARN   = 2   -- you have it, but you are holding it insecurely
local STATE_SECURE = 3   -- yours, comfortably

ns.STATE_LOST   = STATE_LOST
ns.STATE_WARN   = STATE_WARN
ns.STATE_SECURE = STATE_SECURE

-- The scan's only output, and a display module's only input.
--
-- Keyed by *unit token*, not GUID, and that is not a stylistic choice. Inside
-- an instance the client returns secret values for anything identifying a unit
-- -- UnitGUID comes back a secret string -- and a secret cannot be used as a
-- table key: the attempt throws. A unit token is always a plain string.
ns.stateByUnit = {}
local stateByUnit = ns.stateByUnit

local wasTanking = {}   -- unit token -> bool, drives the "you just lost it" alert
local lastAlert  = 0

-- Unit tokens are recycled: `nameplate3` is a different mob a moment later. A
-- display module calls this as each plate is released so the incoming occupant
-- cannot inherit the outgoing one's flag and fire a false alarm.
function ns.ForgetUnit(unit)
    wasTanking[unit] = nil
end

-- Nameplate unit tokens, built once so the scan never concatenates.
--
-- Not C_NamePlate.GetNamePlates(): the plate frames it returns no longer carry
-- a namePlateUnitToken field -- it reads nil -- and a scan built on that sees
-- nothing at all, silently, because a nil token merely fails an `if`. These
-- tokens are the documented interface and touch no frame field. 40 is the size
-- of Blizzard's plate pool.
local PLATE_UNITS = {}
for i = 1, 40 do PLATE_UNITS[i] = "nameplate" .. i end

--------------------------------------------------------------------------------
-- Consumers
--
-- Anything that displays threat state registers here. Two questions are asked
-- of each:
--
--   wants()    -> wants, ignoreRoleGate
--                 Whether the scan is worth running at all this tick. A second
--                 truthy return means "run it even if the player is not in a
--                 tank spec" -- which is what a preview mode needs, since the
--                 whole point of a preview is seeing the display before you
--                 are in the situation it exists for.
--   updated()  Called after each scan, and after the state map is emptied on
--                 going idle, so a display can clear itself.
--
-- The scan does not call ns.RefreshMarkers() directly any more. It has no
-- business knowing that a nameplate module exists.
--------------------------------------------------------------------------------

local consumers = {}

function ns.RegisterThreatConsumer(def)
    consumers[#consumers + 1] = def
end

local function ScanWanted()
    local wants, force = false, false
    for i = 1, #consumers do
        local w, f = consumers[i].wants()
        if w then wants = true end
        if f then force = true end
    end
    if force then return true end
    if not wants then return false end
    if db.onlyTankSpec and not state.isTankRole then return false end
    return true
end

local function NotifyUpdated()
    for i = 1, #consumers do
        local fn = consumers[i].updated
        if fn then fn() end
    end
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

-- Is anyone in the group on this mob's threat table? That is what makes it
-- *our* fight, and it is the only way to see an add that has landed on someone
-- before we have touched it ourselves.
local function GroupEngaged(mobUnit)
    for i = 1, #groupUnits do
        local u = groupUnits[i]
        -- No UnitIsUnit here: the roster cache already left our own token out,
        -- and the comparison would be a secret boolean inside an instance.
        if UnitExists(u) and not IsTrue(UnitIsDead(u))
           and Clean(UnitThreatSituation(u, mobUnit)) then
            return true
        end
    end
    return false
end

local function ScanUnit(unit)
    if not UnitExists(unit) then return end
    -- Each of these rejects only on a readable answer; an unreadable one falls
    -- through on purpose -- see Core/Secret.lua.
    if IsTrue(UnitIsPlayer(unit)) then return end     -- threat is a PvE concept
    if IsFalse(UnitCanAttack("player", unit)) then return end
    if IsTrue(UnitIsDead(unit)) then return end

    -- UnitThreatSituation, not UnitDetailedThreatSituation. The two diverge
    -- sharply inside an instance: the plain one keeps returning a readable
    -- 0-3, while the detailed one hands back secret values for nameplate
    -- pairings. One number carries all three states, which is the whole reason
    -- this addon can work in a dungeon at all:
    --
    --   nil  no threat entry -- not our fight (yet)
    --   0/1  someone else holds it   -> LOST
    --   2    ours, but insecurely    -> WARN
    --   3    ours, securely          -> SECURE
    local status = Clean(UnitThreatSituation("player", unit))

    -- Cheapest rejection first, and the one that fires most often: a mob we
    -- have no threat on that is not fighting anybody cannot be our problem.
    if not status and IsFalse(UnitAffectingCombat(unit)) then return end

    if not status and not GroupEngaged(unit) then
        -- Neither we nor anyone in the group has a threat entry on it, so as
        -- far as the threat API is concerned this is not our fight.
        --
        -- Out in the world we can double-check by asking the mob who it is
        -- hitting, which catches what threat data misses: a pet or guardian
        -- holding it, or a brand-new add that landed on the healer before
        -- anyone generated threat. The same check stops the scan from marking
        -- every unrelated fight happening nearby.
        --
        -- Inside an instance that question cannot be asked at all -- comparing
        -- the mob's target to a group member is a secret boolean, and testing
        -- it throws. Group threat entries are the only signal there, so we
        -- take the miss: an add nobody has any threat on yet stays unmarked
        -- until someone touches it, usually within a global cooldown.
        if state.inInstance then return end

        local t = unit .. "target"
        if not (UnitExists(t) and (UnitIsUnit(t, "player")
                or UnitPlayerOrPetInParty(t) or UnitPlayerOrPetInRaid(t))) then
            return
        end
    end

    if status == nil or status <= 1 then
        stateByUnit[unit] = STATE_LOST
    elseif status == 2 then
        stateByUnit[unit] = STATE_WARN
    else
        stateByUnit[unit] = STATE_SECURE
    end
end

local function Scan()
    twipe(stateByUnit)
    -- ScanUnit's own UnitExists check retires the dead tokens, so the whole
    -- pool can be walked unconditionally.
    for i = 1, #PLATE_UNITS do ScanUnit(PLATE_UNITS[i]) end
end

--------------------------------------------------------------------------------
-- Alert
--
-- The one non-visual channel: a mob that *was* yours stopping being yours.
-- Deliberately kept when the list went -- it fires in the moment you are
-- looking at your own health bars rather than at nameplates.
--------------------------------------------------------------------------------

local function CheckAlerts()
    local now, fire = GetTime(), false

    for unit, st in pairs(stateByUnit) do
        local tanking = (st ~= STATE_LOST)
        -- Alert only on a real transition (it was ours, now it is not), so
        -- fresh pulls and wandering patrols stay quiet.
        if wasTanking[unit] and not tanking then fire = true end
        wasTanking[unit] = tanking
    end

    if fire and now - lastAlert > ALERT_COOLDOWN then
        lastAlert = now
        if db.sound then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
    end
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

local function Tick()
    -- Idle fast path. Note what is NOT a condition here: being in combat. The
    -- single most useful moment for a marker is a pull you did not start, and
    -- when someone else grabs a mob you are by definition not yet in combat.
    if not ScanWanted() then
        if next(stateByUnit) then
            twipe(stateByUnit)
            NotifyUpdated()
        end
        return
    end

    Scan()
    -- Skipped out of combat: the scan keeps running there so a pull you did
    -- not start is marked before you are dragged into it, and "you lost it" is
    -- not a thing that can meaningfully happen when you are not fighting.
    if state.inCombat then CheckAlerts() end
    NotifyUpdated()
end

--------------------------------------------------------------------------------
-- Diagnostics
--
-- /tt debug. Deliberately a separate copy of ScanUnit's gate order rather than
-- instrumentation inside it: the scan runs 5x/sec across every plate on screen
-- and must not carry a debug branch, and a diagnostic that shares code with
-- the thing it is diagnosing hides the bugs that matter most.
--------------------------------------------------------------------------------

-- Mirrors ScanUnit, returning the gate that rejected the unit, or nil when it
-- would have been marked.
local function RejectReason(unit)
    if not UnitExists(unit) then return "unit does not exist" end
    if IsTrue(UnitIsPlayer(unit)) then return "it is a player" end
    if IsFalse(UnitCanAttack("player", unit)) then return "not attackable" end
    if IsTrue(UnitIsDead(unit)) then return "dead" end

    local status = Clean(UnitThreatSituation("player", unit))
    if not status and IsFalse(UnitAffectingCombat(unit)) then
        return "no threat entry for you, and it is not in combat"
    end

    if not status and not GroupEngaged(unit) then
        if state.inInstance then
            return "no threat entry for you or the group (in an instance, so "
                   .. "its target cannot be checked)"
        end
        local t = unit .. "target"
        if not (UnitExists(t) and (UnitIsUnit(t, "player")
                or UnitPlayerOrPetInParty(t) or UnitPlayerOrPetInRaid(t))) then
            return "no threat entry, and it is not swinging at you or your group"
        end
    end
    return nil
end

local function DumpUnit(unit)
    Print(format("|cffffff00%s|r  %s", unit, Clean(UnitName(unit)) or "|cff888888?|r"))
    Print(format("    canAttack=%s  isPlayer=%s  isDead=%s  mobInCombat=%s",
                 Show(UnitCanAttack("player", unit)),
                 Show(UnitIsPlayer(unit)),
                 Show(UnitIsDead(unit)),
                 Show(UnitAffectingCombat(unit))))
    Print(format("    UnitThreatSituation(player,unit)=%s",
                 Show(UnitThreatSituation("player", unit))))

    -- The group-side read. Everything about "which add is on a teammate" rests
    -- on it being a plain number for a member/plate pairing the way it is for a
    -- player/plate one -- if it comes back SECRET, Clean() nils it, and a mob
    -- nobody has touched never gets marked.
    for i = 1, #groupUnits do
        local u = groupUnits[i]
        if UnitExists(u) then
            Print(format("    UnitThreatSituation(%s,unit)=%s   [%s]",
                         u, Show(UnitThreatSituation(u, unit)),
                         Clean(UnitName(u)) or "?"))
        end
    end

    local reason = RejectReason(unit)
    if reason then
        Print("    |cffff4040NOT MARKED:|r " .. reason)
    else
        Print(format("    |cff00ff00marked|r -- state %s", tostring(stateByUnit[unit])))
    end
end

local function DumpScan()
    Print("|cffffff00---- scan dump ----|r")
    Print(format("instance=%s  inCombat=%s  tankRole=%s  groupUnits=%d",
                 Show(state.inInstance), Show(state.inCombat),
                 Show(state.isTankRole), #groupUnits))

    local live = 0
    for i = 1, #PLATE_UNITS do
        if UnitExists(PLATE_UNITS[i]) then live = live + 1 end
    end
    Print(format("live nameplate units: |cffffff00%d|r", live))

    for i = 1, #PLATE_UNITS do
        local u = PLATE_UNITS[i]
        if UnitExists(u) then DumpUnit(u) end
    end
end

--------------------------------------------------------------------------------
-- Module lifecycle
--------------------------------------------------------------------------------

function M:OnInit()
    db = self.db

    ns.RegisterTicker("threat", "scan", UPDATE_INTERVAL, Tick)

    -- Combat ending invalidates the whole "it was mine a moment ago" ledger.
    ns.RegisterEvent("PLAYER_REGEN_ENABLED", function() twipe(wasTanking) end)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommand{
    name    = "sound",
    section = "other:",
    order   = 10,
    desc    = "toggle the lost-mob sound",
    handler = function()
        db.sound = not db.sound
        Print("lost-mob sound " .. (db.sound and "enabled." or "disabled."))
    end,
}

ns.RegisterCommand{
    name    = "tankonly",
    section = "other:",
    order   = 20,
    desc    = "toggle tank-spec-only",
    handler = function()
        db.onlyTankSpec = not db.onlyTankSpec
        Print("tank-spec-only " .. (db.onlyTankSpec and "enabled." or "disabled."))
    end,
}

ns.RegisterCommand{
    name    = "debug",
    section = "commands:",
    order   = 40,
    desc    = "dump every nameplate the scan sees",
    handler = DumpScan,
}

--------------------------------------------------------------------------------
-- Status
--
-- Every reason the scan can legitimately mark nothing, in one place, so "it
-- did not appear" is answerable without guessing.
--------------------------------------------------------------------------------

ns.RegisterStatusProvider(10, function(yn)
    Print("tank spec: " .. yn(state.isTankRole)
          .. "  |  in combat: " .. yn(state.inCombat)
          .. "  |  instance: " .. yn(state.inInstance)
          .. "  |  group size: " .. (GetNumGroupMembers() or 0))

    local lost, warn, secure = 0, 0, 0
    for _, st in pairs(stateByUnit) do
        if st == STATE_LOST then lost = lost + 1
        elseif st == STATE_WARN then warn = warn + 1
        else secure = secure + 1 end
    end
    Print(format("marked right now: %d not mine, %d at risk, %d mine",
                 lost, warn, secure))

    local ticker = ns.GetTicker("threat")
    if ticker and ticker.disabled then
        Print("|cffff4040Scan stopped.|r Last error: " .. tostring(ticker.err))
        Print("Change zone to retry. Please report this error.")
    elseif db.onlyTankSpec and not state.isTankRole then
        Print("|cffff8000Nothing will mark:|r you are not in a tank spec and "
              .. "|cffffff00/tt tankonly|r is on.")
    elseif lost + warn + secure == 0 then
        Print("|cffff8000Nothing marked.|r Only enemies actually fighting "
              .. "your group count -- run |cffffff00/tt debug|r in a fight "
              .. "to see why each one was skipped.")
    end
end)

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

ns.RegisterOptionsSection{
    page      = "Threat",
    pageOrder = 10,
    column    = "left",
    order     = 20,
    build = function(f, x, y)
        y = y - 10
        y = ns.ui.Header(f, "General", x, y)
        y = ns.ui.Check(f, x, y, "Only in a tank spec", M.db, "onlyTankSpec")
        y = ns.ui.Check(f, x, y, "Sound when a mob stops being yours", M.db, "sound")
        return y
    end,
}
