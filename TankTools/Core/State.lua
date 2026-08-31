--------------------------------------------------------------------------------
-- Tank Tools -- shared world state
--
-- The facts about "where am I, who is with me, and what am I" that more than
-- one module needs. Written only here; read everywhere via `ns.state` and
-- `ns.groupUnits`.
--
-- All of it is cached rather than asked for on demand, because the consumers
-- are hot paths: the threat scan reads `inInstance` once per nameplate, five
-- times a second, and walks the group list once per unmarked mob. None of
-- these values can change without an event, so an event is what updates them.
--------------------------------------------------------------------------------

local _, ns = ...

local UnitAffectingCombat    = UnitAffectingCombat
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitInRaid             = UnitInRaid
local IsInInstance           = IsInInstance
local IsInRaid               = IsInRaid
local GetNumGroupMembers     = GetNumGroupMembers
local GetRaidRosterInfo      = GetRaidRosterInfo
local UnitExists             = UnitExists
local UnitName               = UnitName
local GetTime                = GetTime
local twipe                  = wipe
local strmatch               = string.match
local tonumber               = tonumber
local tremove                = table.remove
local tinsert                = table.insert

local Clean = ns.Clean

local state = ns.state

-- Cached "party1".. / "raid1".. tokens for everyone except us, so no consumer
-- ever concatenates in a loop. Wiped in place, never replaced, so a module may
-- hold it as a local for the whole session.
local groupUnits = {}
ns.groupUnits = groupUnits

--------------------------------------------------------------------------------

-- Which token in the raid is us, or nil when the client will not say.
--
-- UnitInRaid gives our own 0-based slot, and an integer compare is always
-- safe; asking UnitIsUnit instead would be the obvious way and is exactly what
-- breaks in an instance.
--
-- Cleaned and type-checked rather than trusted, for two separate reasons. A
-- secret would throw on the `+ 1` -- arithmetic is one of the things a secret
-- refuses. And a nil is not hypothetical: it is what produced the duplicate
-- co-tank block, because every caller here used to treat "I do not know which
-- one is me" as "none of them is me".
local function SelfRaidToken()
    local me = Clean(UnitInRaid("player"))
    if type(me) ~= "number" then return nil end
    return "raid" .. (me + 1)
end

-- A second, weaker way to find our own slot: match on name.
--
-- Deliberately kept apart from SelfRaidToken and used only for presentation --
-- which bar sits first, and which bar "show my own" hides. Two people in a
-- raid can share a name across realms, and a wrong guess here costs you a
-- misplaced bar. Letting the same guess decide who counts as a tank would let
-- it judge a stranger's slot by *our* spec, which costs you the wrong person
-- on screen. One of those is worth risking and the other is not.
local function GuessSelfToken()
    local me = SelfRaidToken()
    if me then return me end

    local myName = Clean(UnitName("player"))
    if type(myName) ~= "string" then return nil end

    local n = GetNumGroupMembers() or 0
    for i = 1, n do
        local u = "raid" .. i
        -- Both sides laundered, and both required to be readable: two nils
        -- must not read as a match.
        local name = Clean(UnitName(u))
        if type(name) == "string" and name == myName then return u end
    end
    return nil
end

ns.SelfRaidToken  = SelfRaidToken
ns.GuessSelfToken = GuessSelfToken

-- The token we are being displayed under: our raid slot when we are in a raid
-- and the client will name it, "player" otherwise. Never nil, so a comparison
-- against it is always meaningful -- but in a raid where our slot is unknown
-- it will match nothing, and a caller that wants to single us out has to cope
-- with not being able to.
ns.selfUnit = "player"

local function RebuildGroupUnits()
    twipe(groupUnits)
    local n = GetNumGroupMembers() or 0

    if IsInRaid() then
        local me = SelfRaidToken()
        for i = 1, n do
            -- Failing open: if we cannot be identified, our own token stays in
            -- the list. The only consumer is the threat scan's "is anyone in
            -- the group on this mob", which it asks solely about mobs we have
            -- no threat entry on -- so our own entry is nil there anyway.
            if not me or ("raid" .. i) ~= me then
                groupUnits[#groupUnits + 1] = "raid" .. i
            end
        end
    elseif n > 0 then
        -- party1..partyN-1 never include us to begin with.
        for i = 1, n - 1 do groupUnits[#groupUnits + 1] = "party" .. i end
    end
end

local function UpdateRole()
    -- The player's own spec is authoritative: someone can queue as tank and
    -- then swap spec, and UnitGroupRolesAssigned still answers TANK for the
    -- old one.
    local C = C_SpecializationInfo
    local spec = (C and C.GetSpecialization and C.GetSpecialization())
              or (GetSpecialization and GetSpecialization())
    local role
    if spec then
        role = (C and C.GetSpecializationRole and C.GetSpecializationRole(spec))
             or (GetSpecializationRole and GetSpecializationRole(spec))
    end
    state.isTankRole = (role or UnitGroupRolesAssigned("player")) == "TANK"
end

--------------------------------------------------------------------------------
-- Tanks
--
-- Lives here rather than in the module that draws them, for the same reason
-- `isTankRole` does: "what role is this person" is a roster fact, and the
-- roster is what this file owns. It is the plural of a question Core already
-- answers about the player.
--------------------------------------------------------------------------------

local tankUnits = {}
ns.tankUnits = tankUnits   -- player first when the player tanks, then the rest

local VALID_ROLE = { TANK = true, HEALER = true, DAMAGER = true }

-- UnitGroupRolesAssigned answers with the role someone *queued* as, which goes
-- stale the moment they change spec -- the same trap UpdateRole avoids for the
-- player by reading the spec directly. We cannot read another player's spec,
-- but the raid roster carries a spec-derived combat role, so prefer that.
--
-- The field is read by position and validated rather than trusted, because a
-- return-value list is exactly the kind of thing that shifts between patches:
-- an unexpected value falls back instead of quietly labelling the raid.
local function RoleFor(unit)
    local idx = tonumber(strmatch(unit, "^raid(%d+)$") or "")
    if idx and GetRaidRosterInfo then
        local combatRole = Clean(select(12, GetRaidRosterInfo(idx)))
        if VALID_ROLE[combatRole] then return combatRole end
    end
    return Clean(UnitGroupRolesAssigned(unit))
end

-- Built from the whole roster rather than from groupUnits plus "player".
--
-- In a raid our own slot is a raid token like any other, and every read the
-- co-tank panel makes -- health, name, auras, threat -- answers identically
-- for "raid3" and for "player". Adding "player" separately and relying on
-- groupUnits having dropped our own token is what put two copies of us on
-- screen whenever the client would not say which slot we were.
local function RebuildTankUnits()
    twipe(tankUnits)
    local n = GetNumGroupMembers() or 0

    if IsInRaid() then
        -- Authoritative, for the tank decision.
        local me = SelfRaidToken()
        -- Best effort, for ordering and for "show my own bar".
        ns.selfUnit = GuessSelfToken() or "player"

        for i = 1, n do
            local u = "raid" .. i
            if UnitExists(u) then
                -- For our own slot the spec is authoritative, for the same
                -- reason UpdateRole reads it: someone can queue as tank and
                -- then swap, and the roster's role lags. For everyone else the
                -- roster is the best we can see.
                local isTank
                if u == me then
                    isTank = state.isTankRole
                else
                    isTank = (RoleFor(u) == "TANK")
                end
                if isTank then tankUnits[#tankUnits + 1] = u end
            end
        end

        -- Ordering only. A panel of co-tanks reads better with you at the near
        -- end, since you are the one you already know -- but if the client
        -- will not name our slot, roster order is a worse read, not a broken
        -- one.
        local shown = ns.selfUnit
        for i = 2, #tankUnits do
            if tankUnits[i] == shown then
                tremove(tankUnits, i)
                tinsert(tankUnits, 1, shown)
                break
            end
        end
    else
        ns.selfUnit = "player"
        if state.isTankRole then tankUnits[1] = "player" end
        for i = 1, n - 1 do
            local u = "party" .. i
            if UnitExists(u) and RoleFor(u) == "TANK" then
                tankUnits[#tankUnits + 1] = u
            end
        end
    end
end

ns.RebuildGroupUnits = RebuildGroupUnits
ns.RebuildTankUnits  = RebuildTankUnits
ns.UpdateRole        = UpdateRole

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local INSTANCE_TYPE = {
    none = true, party = true, raid = true,
    pvp  = true, arena = true, scenario = true,
}

-- Where we are, read fresh. Returns whether the answer changed.
--
-- Validated rather than trusted, the same way RoleFor treats the roster's
-- combat role: this is a string from a return-value list, and a consumer that
-- compares it to "party" should read "no" from an unexpected value rather than
-- from a nil it forgot to guard.
--
-- The raw string is kept beside it because that fallback is silent, and the
-- consumer it matters to is the co-tank panel's "show me solo in instanced
-- content" gate. Blizzard adds content types -- delves arrived reporting as
-- "scenario", and the next one may not -- and "the panel did not appear here"
-- is impossible to tell from "the type it reported is not one we list" unless
-- something remembers what was actually said.
local function ReadWorld()
    local inInstance, instanceType = IsInInstance()

    local nowIn   = inInstance and true or false
    local nowType = INSTANCE_TYPE[instanceType] and instanceType or "none"
    local changed = (state.inInstance ~= nowIn)
                    or (state.instanceType ~= nowType)

    state.inInstance      = nowIn
    state.instanceType    = nowType
    state.instanceTypeRaw = type(instanceType) == "string" and instanceType or "?"

    return changed
end

-- THIS USED TO BE READ ONCE PER ZONE, AND THAT WAS WRONG
--
-- The old comment here said it could not change without PLAYER_ENTERING_WORLD,
-- so reading it on that event was enough. It cannot change without one, which
-- is not the same claim: at the *first* PEW after a transition the client will
-- happily still describe the zone you just left. Cache that and you are wrong
-- for the whole visit, because nothing asks again.
--
-- What that looked like: walk into a delve and the co-tank panel never
-- appears, because the gate still believes you are outdoors; walk out and it
-- stays on screen, because the gate still believes you are in a delve. A
-- /reload fixed both, which is the tell -- the reads were fine, the cached
-- answer was old.
--
-- The same window covers the other thing that is not ready when a loading
-- screen ends: the specialization API can answer nil for a moment, and solo
-- there is no roster event coming along later to correct it. That would leave
-- state.isTankRole false with nothing to trigger a rebuild -- an empty tank
-- list, and the panel hidden for exactly the same reason.
local WORLD_SETTLE = 10    -- seconds of re-checking after a zone change
local WORLD_EVERY  = 0.5
local settleUntil  = 0

local function RefreshAll()
    UpdateRole()
    RebuildGroupUnits()
    RebuildTankUnits()
end

ns.RegisterEvents({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD" }, function()
    RefreshAll()
    state.inCombat = UnitAffectingCombat("player") and true or false
    ReadWorld()
    settleUntil = (GetTime and GetTime() or 0) + WORLD_SETTLE
end)

-- Registered here rather than at file scope because Core/Ticker.lua loads
-- after this file; by PLAYER_LOGIN everything exists.
ns.RegisterEvent("PLAYER_LOGIN", function()
    ns.RegisterTicker("world", "world state", WORLD_EVERY, function()
        local changed  = ReadWorld()
        local settling = (GetTime and GetTime() or 0) < settleUntil
        if changed or settling then RefreshAll() end
    end)
end)

ns.RegisterEvent("PLAYER_REGEN_DISABLED", function() state.inCombat = true  end)
ns.RegisterEvent("PLAYER_REGEN_ENABLED",  function() state.inCombat = false end)

ns.RegisterEvent("GROUP_ROSTER_UPDATE", function()
    RebuildGroupUnits()
    UpdateRole()
    RebuildTankUnits()
end)

-- Our own spec change moves us in or out of the tank list; PLAYER_ROLES_ASSIGNED
-- covers everyone else's, and fires when the group's role assignments settle.
ns.RegisterEvents({ "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_ROLES_ASSIGNED" },
    function()
        UpdateRole()
        RebuildTankUnits()
    end)
