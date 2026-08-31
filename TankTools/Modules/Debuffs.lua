--------------------------------------------------------------------------------
-- Tank Tools -- the debuff journal
--
-- Every debuff that lands on you, written down once with whatever the client
-- was willing to say about it: the spell id, the icon, whether it can be
-- dispelled, whether the encounter flagged it as a raid, boss or tank-role
-- aura, and where you were standing the first time you caught it.
--
-- It exists because the co-tank panel's row cannot be told what to show. The
-- aura engine takes a list of spell ids to exclude and reports nothing back,
-- so "hide this one, always show that one" needs a list of ids -- and nobody
-- has one. This is how the list gets built: play, then read back what actually
-- happened to you.
--
-- TWO DOORS, BECAUSE ONE OF THEM IS SHUT WHERE IT MATTERS
--
-- The obvious source is the aura data itself: UNIT_AURA hands over an AuraData
-- table per added aura, with every flag on it. That is the rich door, and it
-- is the one that closes. Inside an encounter or a Mythic+ the client refuses
-- aura reads -- exactly the content whose debuffs are worth cataloguing. See
-- ns.AurasRestricted in Core/Secret.lua.
--
-- So the combat log is read too. SPELL_AURA_APPLIED carries a spell id and the
-- word DEBUFF, and it is a log line rather than a unit read: a different
-- permission, and one that is still open where the first is not. It says far
-- less -- an id and a name, no flags at all. That is enough to key a record
-- on, and the spell database fills in the name and the icon for nothing,
-- because asking what spell 12345 is called is not a question about a unit.
--
-- The two doors are not interchangeable, so a record says which one it came
-- through. A journal that quietly filed half a raid's debuffs as "not
-- dispellable, not a raid aura" because it never got to look would be worse
-- than one that admits it does not know.
--
-- NOTHING HERE IS READ RAW
--
-- Every value off an aura table or a log line goes through Clean() before it
-- is compared, formatted or used as a table key. A flag that comes back
-- unreadable leaves the record's field alone rather than writing false into
-- it, so a fact learned in a delve survives a raid where it could not be
-- checked.
--------------------------------------------------------------------------------

local _, ns = ...

local Clean, IsSecret = ns.Clean, ns.IsSecret
local Print   = ns.Print
local format  = string.format
local tsort   = table.sort
local strlower = string.lower

local MAX_AURA_SCAN = 40    -- the client's own per-unit aura cap
local SCAN_GAP      = 1.0   -- seconds between full re-reads of our own auras
local FLUSH         = 0.3   -- how often a change reaches the open window

-- How many debuffs the journal remembers. It is a saved variable, so it is a
-- file that grows every time you play; four hundred entries is more distinct
-- debuffs than a season of content puts on one tank, and what gets dropped is
-- always what you have not seen for longest.
local MAX_RECORDS   = 400

--------------------------------------------------------------------------------

ns.RegisterFeature{
    name    = "debuffs",
    title   = "Debuff journal",
    default = false,
    desc    = "Records every debuff that lands on you, and lists them in\n"
              .. "/tt debuffs. Recording and the window work; marking one\n"
              .. "tracked or ignored in the co-tank row is not built yet.",
}

local M = ns.NewModule("debuffs", {
    feature  = "debuffs",
    defaults = {
        djRecord  = true,
        djFromLog = true,
        -- The journal itself, spell id -> record.
        --
        -- An empty table is a legal default here for the reason Core/DB.lua
        -- gives: CopyDefault copies the array part, so an empty one comes back
        -- as a fresh empty table and cannot alias this declaration. It is the
        -- only table default in the addon that is not a colour triple, and the
        -- settings window never edits it -- the journal window does.
        djSeen    = {},
    },
})

local db      -- resolved in OnInit
local seen    -- db.djSeen

-- A record has changed since the window last drew. Batched onto a ticker
-- rather than redrawn per event: a fast-ticking debuff refreshes several times
-- a second and the list looks identical each time.
local dirty = false

local lastScan = 0

-- Our own GUID, laundered once per zone. nil means the combat log door is shut
-- for us -- we cannot tell our own log lines from anyone else's -- and the
-- status line says so rather than leaving the journal mysteriously thin.
local myGUID

-- Whether each door has actually produced anything this session. Between them
-- they explain every empty journal there is.
local sawAura, sawLog = false, false

--------------------------------------------------------------------------------
-- Writing a record
--------------------------------------------------------------------------------

-- Wall clock, not GetTime(): a record outlives the session that made it, and
-- "1483.2 seconds after some login in October" is not a date.
local function Now()
    return time and time() or 0
end

-- Where we are, in words. Not a unit read and never restricted -- the zone
-- name is written on the map -- so this is one of the few facts the journal
-- can be sure of inside an instance.
local function Where()
    if IsInInstance and GetInstanceInfo then
        local inside = IsInInstance()
        if inside then
            local name = GetInstanceInfo()
            if type(name) == "string" and name ~= "" then return name end
        end
    end
    if GetRealZoneText then
        local z = GetRealZoneText()
        if type(z) == "string" and z ~= "" then return z end
    end
    return nil
end

-- The oldest records go when the journal is full. Counted and sorted only once
-- the cap is actually passed, which is a handful of times in the life of a
-- character rather than once per debuff.
local function Prune()
    local ids, n = {}, 0
    for id in pairs(seen) do
        n = n + 1
        ids[n] = id
    end
    if n <= MAX_RECORDS then return end

    tsort(ids, function(a, b)
        local ra, rb = seen[a], seen[b]
        if ra.last ~= rb.last then return ra.last < rb.last end
        return a < b
    end)
    for i = 1, n - MAX_RECORDS do seen[ids[i]] = nil end
end

-- Name and icon from the spell database rather than from the aura.
--
-- This is the half of a record the combat log cannot give us, and it does not
-- have to: what spell 12345 is called is a question about the game's data
-- files, not about a unit, and it is answerable in a boss fight like anywhere
-- else. It only ever fills gaps -- what we saw on the aura wins, because that
-- is what was actually on you.
local function FillFromSpellbook(r)
    if r.name and r.icon then return end
    if not (C_Spell and C_Spell.GetSpellInfo) then return end

    local ok, info = pcall(C_Spell.GetSpellInfo, r.id)
    if not ok or type(info) ~= "table" then return end

    if not r.name and type(info.name) == "string" and info.name ~= "" then
        r.name = info.name
    end
    if not r.icon and info.iconID then r.icon = info.iconID end
end

-- `via` is the door: "aura" when we got to read the aura table, "log" when all
-- we had was a combat log line. A record only ever moves up -- once a debuff
-- has been seen properly it stays marked that way, because the flags on it
-- were read properly too.
local function Touch(id, via)
    local r = seen[id]
    local fresh = false
    if not r then
        r = { id = id, n = 0, first = Now(), where = Where() }
        seen[id] = r
        fresh = true
    end

    r.n    = r.n + 1
    r.last = Now()
    if via == "aura" then
        r.via = "aura"
    elseif r.via == nil then
        r.via = "log"
    end

    -- After the record is filled in, not before: Prune sorts on `last`, and a
    -- record it found half built would take the comparison down. And only for
    -- a record that is actually new -- a debuff reapplying is the common case
    -- and must not cost a walk of the whole journal.
    if fresh then Prune() end

    dirty = true
    return r
end

-- A flag as the record stores it: true, false, or nil for "the client would
-- not say". Collapsing the last two is the mistake this function exists to
-- prevent -- an unreadable isRaid is not a debuff that raid frames ignore.
local function Flag(v)
    if v == nil or IsSecret(v) then return nil end
    return v and true or false
end

-- One AuraData table. `harmful` says the caller already knows this is a
-- debuff: true for a HARMFUL enumeration, false for the added-aura list, where
-- helpful and harmful arrive together and the flag has to be checked.
local function FromAura(a, harmful)
    if type(a) ~= "table" then return end

    local id = Clean(a.spellId)
    if type(id) ~= "number" then return end   -- nothing to key a record on

    -- Fails CLOSED, unlike almost everything else in this addon, and on
    -- purpose: an unreadable isHarmful on the shared added-aura list would let
    -- every proc and buff you own into a journal whose whole point is to be a
    -- shortlist of debuffs. The log door covers what is lost here.
    if not harmful and Flag(a.isHarmful) ~= true then return end

    local r = Touch(id, "aura")
    sawAura = true

    local name = Clean(a.name)
    if type(name) == "string" and name ~= "" then r.name = name end

    local icon = Clean(a.icon)
    if icon ~= nil then r.icon = icon end

    -- The dispel type is a string or nothing, and "nothing" is a real answer:
    -- it means the debuff cannot be dispelled at all. Stored as "none" so the
    -- window can tell that apart from a field we never got to read.
    local d = a.dispelName
    if not IsSecret(d) then
        r.dispel = (type(d) == "string" and d ~= "") and d or "none"
    end

    -- Each written only when readable, so a fact learned outside survives a
    -- fight where the same aura came back blank.
    local f
    f = Flag(a.isRaid);                  if f ~= nil then r.raid = f end
    f = Flag(a.isBossAura);              if f ~= nil then r.boss = f end
    f = Flag(a.isTankRoleAura);          if f ~= nil then r.tank = f end
    f = Flag(a.isFromPlayerOrPlayerPet); if f ~= nil then r.mine = f end

    FillFromSpellbook(r)
end

-- Everything harmful on us right now. Rate limited, and silent while aura
-- reads are refused: ns.AurasRestricted() is asked before the loop rather than
-- leaning on the pcall inside it, because a refusal there is the normal state
-- in an encounter and not an error worth swallowing five times a second.
local function FullScan()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    if ns.AurasRestricted() then return end

    local now = GetTime and GetTime() or 0
    if (now - lastScan) < SCAN_GAP then return end
    lastScan = now

    for i = 1, MAX_AURA_SCAN do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
        if not ok or not a then break end
        FromAura(a, true)
    end
end

--------------------------------------------------------------------------------
-- Reading it back
--------------------------------------------------------------------------------

-- The spell's own tooltip text, fetched live and never saved.
--
-- Four hundred descriptions in the saved variables file would be the largest
-- thing in it by an order of magnitude, they would be stale after every
-- balance patch, and they would be in the wrong language for anyone who
-- changed clients. This is a data-file read, so it is cheap and always
-- current.
--
-- It can legitimately answer nothing the first time -- spell data loads on
-- demand -- so the request is fired and SPELL_DATA_LOAD_RESULT redraws.
function ns.DebuffDescription(id)
    if not (C_Spell and C_Spell.GetSpellDescription) then return nil end

    local ok, d = pcall(C_Spell.GetSpellDescription, id)
    if ok and type(d) == "string" and d ~= "" then return d end

    if C_Spell.RequestLoadSpellData then
        pcall(C_Spell.RequestLoadSpellData, id)
    end
    return nil
end

local SORTS = {
    -- Most recent first: the debuff you are looking up is nearly always the
    -- one that just happened to you.
    recent = function(a, b)
        if a.last ~= b.last then return a.last > b.last end
        return a.id < b.id
    end,
    name = function(a, b)
        local na, nb = strlower(a.name or ""), strlower(b.name or "")
        if na ~= nb then return na < nb end
        return a.id < b.id
    end,
    count = function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.id < b.id
    end,
}

-- Every sort breaks its ties on the spell id rather than on the table address,
-- for the reason the aura row sorts the way it does: table.sort is not stable,
-- and rows that swap places on every redraw are worse than an arbitrary order
-- that at least holds still.

-- A fresh array of records, filtered and sorted. Fresh rather than a view into
-- the store, so the window cannot edit the journal by accident and an eviction
-- cannot happen underneath a redraw.
--
-- `query` matches the name or the spell id, case insensitively -- a number
-- typed into the box finds an id you half remember.
function ns.DebuffRecords(query, sort)
    local out = {}
    if not seen then return out end

    query = (type(query) == "string") and strlower(strtrim(query)) or ""

    for _, r in pairs(seen) do
        local keep = (query == "")
        if not keep then
            keep = strlower(r.name or ""):find(query, 1, true) ~= nil
                   or tostring(r.id):find(query, 1, true) ~= nil
        end
        if keep then out[#out + 1] = r end
    end

    tsort(out, SORTS[sort] or SORTS.recent)
    return out
end

-- What the journal knows about itself, for the window's footer and for
-- /tt status. Every field answers one version of "why is this empty".
function ns.DebuffStats()
    local n = 0
    if seen then for _ in pairs(seen) do n = n + 1 end end

    return {
        total      = n,
        recording  = db and db.djRecord and true or false,
        fromLog    = db and db.djFromLog and true or false,
        restricted = ns.AurasRestricted(),
        logOpen    = myGUID ~= nil,
        sawAura    = sawAura,
        sawLog     = sawLog,
        cap        = MAX_RECORDS,
    }
end

function ns.ForgetDebuffs()
    local n = 0
    if seen then
        for id in pairs(seen) do
            seen[id] = nil
            n = n + 1
        end
    end
    dirty = true
    return n
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

local LOG_EVENTS = {
    SPELL_AURA_APPLIED      = true,
    SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REFRESH      = true,
}

-- The combat log handler, and the one hot path in this file: it runs on every
-- line of the log, which in a raid is thousands a second.
--
-- So it is ordered by how cheaply each test rejects. The subevent is looked at
-- first and throws out almost everything; the destination GUID is compared
-- only for the handful of lines that survive that.
--
-- Nothing is used as a table key before it has been laundered and type
-- checked. A secret used as a key throws, and a handler that throws on every
-- log line is one the event dispatcher stops within five of them.
local function OnCombatLog()
    if not (db.djRecord and db.djFromLog) then return end
    if not myGUID or not CombatLogGetCurrentEventInfo then return end

    local _, sub, _, _, _, _, _, destGUID, _, _, _,
          spellId, spellName, _, auraType = CombatLogGetCurrentEventInfo()

    sub = Clean(sub)
    if type(sub) ~= "string" or not LOG_EVENTS[sub] then return end

    if Clean(auraType) ~= "DEBUFF" then return end

    local dest = Clean(destGUID)
    if type(dest) ~= "string" or dest ~= myGUID then return end

    local id = Clean(spellId)
    if type(id) ~= "number" then return end

    local r = Touch(id, "log")
    sawLog = true

    local name = Clean(spellName)
    if not r.name and type(name) == "string" and name ~= "" then r.name = name end
    FillFromSpellbook(r)
end

--------------------------------------------------------------------------------
-- Module lifecycle
--------------------------------------------------------------------------------

function M:OnInit()
    db = self.db
    -- A database saved before this module existed has the settings but not the
    -- table, and a journal that nils out on the first debuff is worse than one
    -- that starts empty.
    if type(db.djSeen) ~= "table" then db.djSeen = {} end
    seen = db.djSeen

    -- The added-aura list is the rich door, and the one that arrives without
    -- being asked for. An update carrying no list -- an older client, or a
    -- full refresh -- falls through to reading our own auras, which works
    -- wherever it is allowed and quietly does nothing where it is not.
    ns.RegisterEvent("UNIT_AURA", function(_, unit, updateInfo)
        if unit ~= "player" or not db.djRecord then return end

        if type(updateInfo) == "table" then
            local added = updateInfo.addedAuras
            if type(added) == "table" then
                for i = 1, #added do FromAura(added[i], false) end
            end
            if added and not updateInfo.isFullUpdate then return end
        end

        FullScan()
    end)

    ns.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)

    -- Catches what is already on you: a debuff applied while the addon was
    -- loading, or across a zone in, never produces an added-aura event we see.
    ns.RegisterEvents({ "PLAYER_ENTERING_WORLD", "PLAYER_LOGIN" }, function()
        myGUID = UnitGUID and Clean(UnitGUID("player")) or nil
        if db.djRecord then FullScan() end
    end)

    -- Spell data loads on demand, so a description asked for a moment ago
    -- arrives now. Only the window cares, and only while it is open.
    ns.RegisterEvent("SPELL_DATA_LOAD_RESULT", function()
        dirty = true
    end)

    -- The redraw runs on the shared ticker like everything else, so the whole
    -- feature sits behind one failure latch and a debuff refreshing ten times
    -- a second still costs one redraw.
    ns.RegisterTicker("debuffs", "debuff journal", FLUSH, function()
        if not dirty then return end
        dirty = false
        ns.RefreshDebuffs()
    end)
end

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

ns.RegisterStatusProvider(40, function(yn)
    local s = ns.DebuffStats()
    Print(format("debuff journal: recording=%s  recorded=%d/%d",
                 yn(s.recording), s.total, s.cap))
    Print(format("  aura reads here=%s  combat log=%s",
                 s.restricted and "|cffff8000refused|r" or "|cff00ff00allowed|r",
                 s.logOpen and (s.fromLog and "|cff00ff00on|r" or "off")
                     or "|cffff4040cannot tell our own lines apart|r"))
end, "debuffs")
