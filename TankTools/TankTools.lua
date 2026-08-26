--------------------------------------------------------------------------------
-- Tank Tools
--
-- A tank's answer to one question: "which enemy is on someone else, so I can
-- taunt it off?"
--
-- The whole addon is one glyph next to a nameplate. There is no threat meter,
-- no list, no percentages -- inside an instance the client restricts every
-- value those would need (names come back unreadable, threat numbers come back
-- secret), and none of them is what a tank acts on anyway. What you act on is
-- "that one is not mine", and that survives every restriction.
--
-- Nameplate addons commonly color plates by threat. This does not touch the
-- plate or fight with them: the marker is a child frame of Blizzard's base
-- plate container, so the two compose.
--------------------------------------------------------------------------------

local ADDON, ns = ...

-- Hot-path upvalues. The scan runs 5x/sec across every visible nameplate, so
-- every global lookup here is one we do not pay for.
local UnitThreatSituation    = UnitThreatSituation
local issecretvalue          = issecretvalue
local UnitExists             = UnitExists
local UnitName               = UnitName
local UnitCanAttack          = UnitCanAttack
local UnitIsDead             = UnitIsDead
local UnitIsPlayer           = UnitIsPlayer
local UnitIsUnit             = UnitIsUnit
local UnitPlayerOrPetInParty = UnitPlayerOrPetInParty
local UnitPlayerOrPetInRaid  = UnitPlayerOrPetInRaid
local UnitAffectingCombat    = UnitAffectingCombat
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitInRaid             = UnitInRaid
local IsInInstance           = IsInInstance
local GetTime                = GetTime
local twipe                  = wipe
local floor                  = math.floor

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

local defaults = {
    onlyTankSpec    = true,   -- do nothing at all unless the player is a tank
    sound           = true,   -- audible alert when a mob stops being yours

    -- Accessibility-first: the signal is a *glyph appearing*, not a hue change,
    -- so it carries no color information at all -- absence means "mine",
    -- presence means "not mine". Color is decoration on top.
    npMarker        = true,          -- mark mobs you do NOT have aggro on
    npMarkerWarn    = false,         -- also mark mobs you are about to lose
    npMarkerSecure  = false,         -- mark mobs you DO have aggro on
    npGlyph         = "!",           -- glyph for "you do not have this one"
    npWarnGlyph     = "?",           -- glyph for "about to lose this one"
    npSecureGlyph   = "o",           -- glyph for "this one is yours"
    npSize          = 28,
    npAnchor        = "LEFT",        -- LEFT | RIGHT | TOP | BOTTOM
    npPulse         = true,          -- motion, a channel independent of color
    npColor         = { 1, 0.92, 0.15 },

    -- The aggro marker is the "nothing is wrong" state, so it gets its own,
    -- deliberately quiet color -- a grey that recedes and lets the alert
    -- glyphs keep the loud one. It never pulses, whatever npPulse says.
    npSecureColor   = { 0.62, 0.62, 0.62 },
}

local db  -- resolved at ADDON_LOADED

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local groupUnits = {}     -- cached "party1".. / "raid1".. tokens (no per-call concat)
local wasTanking = {}     -- unit token -> bool, drives the "you just lost it" alert

local isTankRole  = false
local inCombat    = false
local inInstance  = false
local lastAlert   = 0
local elapsed     = 0

local UPDATE_INTERVAL = 0.2
local ALERT_COOLDOWN  = 1.5

-- Threat states. The numbers are shared with the nameplate module, which uses
-- them to index its per-kind settings table.
local STATE_LOST   = 1   -- something else is tanking it
local STATE_WARN   = 2   -- you have it, but you are holding it insecurely
local STATE_SECURE = 3   -- yours, comfortably

ns.STATE_LOST   = STATE_LOST
ns.STATE_WARN   = STATE_WARN
ns.STATE_SECURE = STATE_SECURE

-- The scan's only output, and the nameplate module's only input.
--
-- Keyed by *unit token*, not GUID, and that is not a stylistic choice. Inside
-- an instance the client returns "secret values" for anything identifying a
-- unit -- UnitGUID comes back a secret string -- and a secret cannot be used
-- as a table key: the attempt throws. A unit token is always a plain string.
ns.stateByUnit  = {}
local stateByUnit = ns.stateByUnit

-- Unit tokens are recycled: `nameplate3` is a different mob a moment later.
-- The nameplate module calls this as each plate is released so the incoming
-- occupant cannot inherit the outgoing one's flag and fire a false alarm.
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

-- The client decides what counts as a secret value, and that set has grown
-- across patches. Rather than throw five times a second forever the next time
-- it grows, the scan runs under a latch: three consecutive failures and it
-- stops, once, printing the error. A zone change clears it.
local scanFailures = 0
local scanDisabled = false
local scanError    = nil

-- Replaced by TankTools_Nameplates.lua. Stubbed here so the hot path can call
-- them unconditionally, and so the core still runs if that file is removed.
function ns.RefreshMarkers() end
function ns.MarkersLooksChanged() end
function ns.SetMarkerPreview(_) return false end
function ns.GetMarkerPreview() return false end

-- Replaced by TankTools_Options.lua.
function ns.ToggleOptions() end
function ns.RefreshOptions() end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Tank Tools|r: " .. msg)
end

--------------------------------------------------------------------------------
-- Reading restricted values
--------------------------------------------------------------------------------

-- Every value that comes out of a unit API goes through here.
--
-- Inside an instance the client hands back secret values for anything that
-- could identify a unit. A secret can be passed straight to a frame setter,
-- but comparing it, formatting it, or using it as a table key throws -- and
-- that is all this addon ever does with one. So rather than reason about which
-- call is restricted where, every read is laundered: a secret comes back as
-- nil, meaning "unavailable", and every consumer handles nil already.
--
-- Guarded call because issecretvalue does not exist on older clients.
local function Clean(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- The two ways to read a restricted boolean, and the distinction matters.
-- Clean() collapses "secret" and "nil" into the same unreadable answer, so
-- these say which side an unreadable answer must NOT fall on:
--
--   IsTrue(v)   only when the answer is readable and yes
--   IsFalse(v)  only when the answer is readable and no
--
-- Both are false for an unreadable value, so a check written either way fails
-- OPEN -- the mob carries on through the scan instead of being dropped.
--
-- That direction is deliberate. UnitCanAttack, UnitIsDead and UnitIsPlayer can
-- all come back secret inside an instance, and dropping the mob when the
-- answer is unreadable would blind the addon in exactly the content it exists
-- for. Letting it through costs nothing: the threat data does the real gating
-- a few lines later, you cannot hold threat on a friendly unit, and a dead one
-- loses its nameplate within a tick.
local function IsTrue(v)
    local c = Clean(v)
    return c ~= nil and c ~= false
end

local function IsFalse(v)
    return Clean(v) == false
end

--------------------------------------------------------------------------------
-- Roster cache
--------------------------------------------------------------------------------

local function RebuildGroupUnits()
    twipe(groupUnits)
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        -- Drop our own token by index. UnitInRaid gives our own 0-based slot,
        -- and an integer compare is always safe; asking UnitIsUnit instead
        -- would be the obvious way and is exactly what breaks in an instance.
        local me = UnitInRaid("player")
        for i = 1, n do
            if not me or i ~= me + 1 then
                groupUnits[#groupUnits + 1] = "raid" .. i
            end
        end
    elseif n > 0 then
        -- party1..partyN-1 never include us to begin with.
        for i = 1, n - 1 do groupUnits[#groupUnits + 1] = "party" .. i end
    end
end

local function UpdateRole()
    -- The player's own spec is authoritative: someone can queue as tank and then
    -- swap spec, and UnitGroupRolesAssigned still answers TANK for the old one.
    local C = C_SpecializationInfo
    local spec = (C and C.GetSpecialization and C.GetSpecialization())
              or (GetSpecialization and GetSpecialization())
    local role
    if spec then
        role = (C and C.GetSpecializationRole and C.GetSpecializationRole(spec))
             or (GetSpecializationRole and GetSpecializationRole(spec))
    end
    isTankRole = (role or UnitGroupRolesAssigned("player")) == "TANK"
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
        -- No UnitIsUnit here: RebuildGroupUnits already left our own token out,
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
    -- through on purpose -- see IsTrue.
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
        if inInstance then return end

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

    for unit, state in pairs(stateByUnit) do
        local tanking = (state ~= STATE_LOST)
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
-- Main loop
--------------------------------------------------------------------------------

local function MarkersWanted()
    return db.npMarker or db.npMarkerWarn or db.npMarkerSecure
end

local function Refresh()
    Scan()
    -- Skipped out of combat: the scan keeps running there so a pull you did
    -- not start is marked before you are dragged into it, and "you lost it" is
    -- not a thing that can meaningfully happen when you are not fighting.
    if inCombat then CheckAlerts() end
    ns.RefreshMarkers()
end

local function RunScan()
    local ok, err = pcall(Refresh)
    if ok then
        scanFailures = 0
        return
    end

    scanFailures = scanFailures + 1
    scanError    = err
    if scanFailures >= 3 then
        scanDisabled = true
        -- Print the error itself, not a pointer to it. A silent addon plus a
        -- "run /tt status" nudge is how the last one of these stayed invisible.
        Print("|cffff4040scan stopped|r -- the game is restricting something "
              .. "this addon reads:")
        Print("  " .. tostring(err))
        Print("Changing zone retries. Please report that line.")
    end
end

-- The ticker lives on a bare, always-shown frame so it keeps firing no matter
-- what else is hidden.
local function OnTick(_, e)
    elapsed = elapsed + e
    if elapsed < UPDATE_INTERVAL then return end
    elapsed = 0

    if scanDisabled then return end

    -- Idle fast path. Note what is NOT a condition here: being in combat. The
    -- single most useful moment for a marker is a pull you did not start, and
    -- when someone else grabs a mob you are by definition not yet in combat.
    if not ns.GetMarkerPreview()
       and ((db.onlyTankSpec and not isTankRole) or not MarkersWanted()) then
        if next(stateByUnit) then
            twipe(stateByUnit)
            ns.RefreshMarkers()
        end
        return
    end

    RunScan()
end

--------------------------------------------------------------------------------
-- Diagnostics
--
-- /tt debug. Deliberately a separate copy of ScanUnit's gate order rather than
-- instrumentation inside it: the scan runs 5x/sec across every plate on screen
-- and must not carry a debug branch, and a diagnostic that shares code with
-- the thing it is diagnosing hides the bugs that matter most.
--------------------------------------------------------------------------------

-- Renders a value the way the scan sees it. The whole point is telling apart
-- the three cases a plain tostring() flattens: absent, restricted, and real.
local function Show(v)
    if v == nil then return "|cff888888nil|r" end
    if issecretvalue and issecretvalue(v) then return "|cffff8000SECRET|r" end
    if v == true  then return "|cff00ff00true|r" end
    if v == false then return "|cffff4040false|r" end
    return "|cff00ff00" .. tostring(v) .. "|r"
end

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
        if inInstance then
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
                 Show(inInstance), Show(inCombat), Show(isTankRole), #groupUnits))

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
-- Events
--------------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        TankToolsDB = TankToolsDB or {}
        for k, v in pairs(defaults) do
            if TankToolsDB[k] == nil then
                -- Copy table defaults rather than aliasing them, so a saved
                -- value can never write back into `defaults`.
                if type(v) == "table" then
                    local t = {}
                    for i = 1, #v do t[i] = v[i] end
                    TankToolsDB[k] = t
                else
                    TankToolsDB[k] = v
                end
            end
        end
        db = TankToolsDB
        ns.db = db
        -- Started only now, so the ticker never runs against a nil db.
        ev:SetScript("OnUpdate", OnTick)

    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        UpdateRole()
        RebuildGroupUnits()
        inCombat = UnitAffectingCombat("player") and true or false

        -- Drives the one unit-identity fallback left in the scan. Read once
        -- per zone rather than per tick: it cannot change without this event.
        inInstance = IsInInstance() and true or false

        -- A zone change is also the natural retry point for the latch: the
        -- restrictions that trip it are instance-scoped, so what failed inside
        -- may well work outside.
        scanFailures = 0
        scanDisabled = false

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        twipe(wasTanking)

    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildGroupUnits()
        UpdateRole()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        UpdateRole()
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

SLASH_TANKTOOLS1 = "/tanktools"
SLASH_TANKTOOLS2 = "/tt"

SlashCmdList.TANKTOOLS = function(input)
    -- Case is folded for the command and for keyword arguments, but `arg` is
    -- kept verbatim so /tt npglyph can take an uppercase glyph.
    local cmd, arg = strsplit(" ", strtrim(input or ""), 2)
    cmd = strlower(cmd or "")
    arg = arg and strtrim(arg) or nil
    local larg = arg and strlower(arg) or nil
    local n = tonumber(arg)

    if cmd == "config" or cmd == "options" or cmd == "opt" then
        ns.ToggleOptions()

    elseif cmd == "np" then
        db.npMarker = not db.npMarker
        ns.MarkersLooksChanged()
        Print("\"not mine\" marker " .. (db.npMarker and "enabled." or "disabled."))

    elseif cmd == "npwarn" then
        db.npMarkerWarn = not db.npMarkerWarn
        ns.MarkersLooksChanged()
        Print("at-risk marker " .. (db.npMarkerWarn and "enabled." or "disabled."))

    elseif cmd == "npsecure" or cmd == "npmine" then
        db.npMarkerSecure = not db.npMarkerSecure
        ns.MarkersLooksChanged()
        Print("aggro marker " .. (db.npMarkerSecure and "enabled." or "disabled."))

    elseif cmd == "nptest" or cmd == "nppreview" then
        local on = ns.SetMarkerPreview(not ns.GetMarkerPreview())
        if on then
            Print("marker preview |cff00ff00on|r -- every enemy nameplate is "
                  .. "marked so you can see the symbols. It ends on zone change, "
                  .. "or run |cffffff00/tt nptest|r again.")
        else
            Print("marker preview |cffff0000off|r.")
        end

    elseif cmd == "nppulse" then
        db.npPulse = not db.npPulse
        ns.MarkersLooksChanged()
        Print("marker pulse " .. (db.npPulse and "enabled." or "disabled."))

    elseif cmd == "npsize" then
        if n and n >= 10 and n <= 72 then
            db.npSize = floor(n)
            ns.MarkersLooksChanged()
            Print("marker size set to " .. db.npSize .. ".")
        else
            Print("usage: /tt npsize 10 - 72")
        end

    elseif cmd == "npanchor" then
        local a = larg and strupper(larg) or ""
        if a == "LEFT" or a == "RIGHT" or a == "TOP" or a == "BOTTOM" then
            db.npAnchor = a
            ns.MarkersLooksChanged()
            Print("marker anchored to the " .. strlower(a) .. " of the nameplate.")
        else
            Print("usage: /tt npanchor left | right | top | bottom")
        end

    elseif cmd == "npglyph" or cmd == "npwarnglyph" or cmd == "npsecglyph" then
        local key = (cmd == "npwarnglyph" and "npWarnGlyph")
                 or (cmd == "npsecglyph" and "npSecureGlyph")
                 or "npGlyph"
        if arg and arg ~= "" then
            db[key] = arg
            ns.MarkersLooksChanged()
            Print("symbol set to \"" .. arg .. "\".")
        else
            Print("usage: /tt " .. cmd .. " <text>")
        end

    elseif cmd == "npcolor" or cmd == "npseccolor" then
        local preset = larg and ns.COLOR_PRESETS and ns.COLOR_PRESETS[larg]
        if preset then
            local key = (cmd == "npseccolor") and "npSecureColor" or "npColor"
            db[key] = { preset[1], preset[2], preset[3] }
            ns.MarkersLooksChanged()
            Print((key == "npSecureColor" and "aggro marker" or "alert marker")
                  .. " color set to " .. arg .. ".")
        else
            Print("usage: /tt " .. cmd
                  .. " white | yellow | cyan | magenta | orange | green | grey")
        end

    elseif cmd == "sound" then
        db.sound = not db.sound
        Print("lost-mob sound " .. (db.sound and "enabled." or "disabled."))

    elseif cmd == "tankonly" then
        db.onlyTankSpec = not db.onlyTankSpec
        Print("tank-spec-only " .. (db.onlyTankSpec and "enabled." or "disabled."))

    elseif cmd == "debug" then
        DumpScan()

    elseif cmd == "status" then
        -- Every reason the addon can legitimately mark nothing, in one place,
        -- so "it did not appear" is answerable without guessing.
        local function yn(v) return v and "|cff00ff00yes|r" or "|cffff4040no|r" end
        local lost, warn, secure = 0, 0, 0
        for _, st in pairs(stateByUnit) do
            if st == STATE_LOST then lost = lost + 1
            elseif st == STATE_WARN then warn = warn + 1
            else secure = secure + 1 end
        end
        Print("tank spec: " .. yn(isTankRole)
              .. "  |  in combat: " .. yn(inCombat)
              .. "  |  instance: " .. yn(inInstance)
              .. "  |  group size: " .. (GetNumGroupMembers() or 0))
        Print("markers -- not mine: " .. yn(db.npMarker)
              .. ", at-risk: " .. yn(db.npMarkerWarn)
              .. ", mine: " .. yn(db.npMarkerSecure)
              .. ", preview: " .. yn(ns.GetMarkerPreview()))
        Print(format("marked right now: %d not mine, %d at risk, %d mine",
                     lost, warn, secure))
        if scanDisabled then
            Print("|cffff4040Scan stopped.|r Last error: " .. tostring(scanError))
            Print("Change zone to retry. Please report this error.")
        elseif db.onlyTankSpec and not isTankRole then
            Print("|cffff8000Nothing will mark:|r you are not in a tank spec and "
                  .. "|cffffff00/tt tankonly|r is on.")
        elseif lost + warn + secure == 0 then
            Print("|cffff8000Nothing marked.|r Only enemies actually fighting "
                  .. "your group count -- run |cffffff00/tt debug|r in a fight "
                  .. "to see why each one was skipped.")
        end

    else
        Print("commands:")
        Print("  |cffffff00/tt config|r          -- open the settings window")
        Print("  |cffffff00/tt nptest|r          -- preview the symbols on every nameplate")
        Print("  |cffffff00/tt status|r          -- why is nothing marking?")
        Print("  |cffffff00/tt debug|r           -- dump every nameplate the scan sees")
        Print("markers:")
        Print("  |cffffff00/tt np|r              -- mobs you do NOT have aggro on")
        Print("  |cffffff00/tt npwarn|r          -- mobs at risk of being pulled")
        Print("  |cffffff00/tt npsecure|r        -- mobs you DO have aggro on")
        Print("  |cffffff00/tt nppulse|r         -- toggle the pulse")
        Print("  |cffffff00/tt npsize|r <n>      -- 10 to 72")
        Print("  |cffffff00/tt npanchor|r <p>    -- left | right | top | bottom")
        Print("  |cffffff00/tt npglyph|r <t>     -- \"not mine\" symbol (default !)")
        Print("  |cffffff00/tt npwarnglyph|r <t> -- \"at risk\" symbol (default ?)")
        Print("  |cffffff00/tt npsecglyph|r <t>  -- \"mine\" symbol (default o)")
        Print("  |cffffff00/tt npcolor|r <c>     -- alert color")
        Print("  |cffffff00/tt npseccolor|r <c>  -- aggro color")
        Print("other:")
        Print("  |cffffff00/tt sound|r           -- toggle the lost-mob sound")
        Print("  |cffffff00/tt tankonly|r        -- toggle tank-spec-only")
    end

    -- Slash commands and the settings window edit the same table, so pull the
    -- window back into sync rather than letting it show stale values.
    ns.RefreshOptions()
end
