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
-- ...AND THE SECOND DOOR IS NOT GUARANTEED EITHER
--
-- The paragraph above was written when registering for the combat log was
-- something any addon could simply do. It is not: on a client that protects
-- COMBAT_LOG_EVENT_UNFILTERED the registration is refused, so the fallback for
-- a shut aura door can itself be shut.
--
-- And it is refused in the worst way available. Nothing raises. The client
-- fires ADDON_ACTION_FORBIDDEN -- which an error display will show the player
-- -- then leaves the event unregistered and returns as if it had worked. A
-- pcall around it catches nothing and reports success. That is why
-- ns.RegisterEvent checks IsEventRegistered afterwards rather than trusting
-- the call, and why this module records the refusal instead of rediscovering
-- it every login: the attempt is what the client reports, so the only way to
-- stop reporting it is to stop attempting.
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
local tremove = table.remove
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
    desc    = "Records every debuff that lands on you or on a co-tank, and\n"
              .. "lists them in /tt debuffs. Mark one important there to pin\n"
              .. "it into the co-tank row even past the boss/role filter, or\n"
              .. "ignored to drop it from that row for good.",
}

local M = ns.NewModule("debuffs", {
    feature  = "debuffs",
    defaults = {
        djRecord  = true,
        djFromLog = true,
        -- The Encounter Journal door. On by default because it is the only one
        -- that answers regardless of who the debuff lands on, and because it
        -- asks the client nothing it could refuse -- content data, not a unit
        -- read. Off is for someone who wants the journal to be a record of
        -- what actually happened to them and nothing else.
        djFromJournal = true,
        -- The journal itself, spell id -> record.
        --
        -- An empty table is a legal default here for the reason Core/DB.lua
        -- gives: CopyDefault copies the array part, so an empty one comes back
        -- as a fresh empty table and cannot alias this declaration. It is the
        -- only table default in the addon that is not a colour triple, and the
        -- settings window never edits it -- the journal window does.
        djSeen    = {},
        -- djLogRefusedOn is deliberately absent, like twPoint in TankWatch: it
        -- is written only if the client actually refuses the combat log, and
        -- its value is the interface version that refused. Absent means "never
        -- been told no", which is the right thing for a fresh database to
        -- believe.
    },
})

local db      -- resolved in OnInit
local seen    -- db.djSeen

-- A record has changed since the window last drew. Batched onto a ticker
-- rather than redrawn per event: a fast-ticking debuff refreshes several times
-- a second and the list looks identical each time.
local dirty = false

local lastScan = 0

-- Our own GUID, laundered once per zone. nil no longer shuts the combat log
-- door on its own -- destFlags attributes our own lines without any identity
-- at all, see Recordable() -- but it is still the only way to recognise a
-- co-tank's line, so the status command reports it.
local myGUID

-- Set once a log line has actually been attributed by its affiliation flags.
-- The status line says "not yet" rather than "no": the mask cannot be tested
-- until a line arrives, and calling the door shut before then would be a guess.
local sawMineFlag = false

-- Co-tank GUIDs, rebuilt with the roster. Only the readable ones go in, so an
-- entry here is a co-tank we can positively recognise; one whose GUID came
-- back secret is simply absent and counted in `blindTanks` instead. Two
-- numbers rather than one, because "no co-tanks" and "co-tanks we are not
-- allowed to identify" are different answers and only one of them is a reason
-- to stop expecting records.
local tankGUIDs  = {}
local blindTanks = 0

-- Auras that reached us and could not be identified. The whole point of
-- counting them is that they are invisible otherwise: an aura the client will
-- not name is dropped in silence, and a journal that stays empty through a
-- fight the co-tank panel drew perfectly looks like a broken feature rather
-- than a refused question.
--
-- Not saved. It is a fact about this session's content, and carrying last
-- week's number into tonight would make it a worse answer, not a longer one.
local unnamedAuras      = 0
local unreadableHarmful = 0

-- The Encounter Journal door, whose counters the status line reads and whose
-- walk lives further down the file. `journalTried` is kept apart from a zero
-- count because "no boss pulled yet" and "walked it and found nothing" are
-- different answers, and only the second one is a reason to look at the code.
local journalIDs   = 0
local journalTried = false
local journalErr

local function TankGUIDCount()
    local n = 0
    for _ in pairs(tankGUIDs) do n = n + 1 end
    return n
end

-- Whether each door has actually produced anything this session. Between them
-- they explain every empty journal there is.
local sawAura, sawLog = false, false

-- Whether the client let us register for the combat log at all. False is not
-- "we saw nothing on it" -- it is a door that was never opened, and the one
-- explanation for a thin journal that no amount of playing will change.
local logAllowed = false

-- True when we did not even ask, because a previous session was refused on
-- this same client build. Kept apart from logAllowed so the status line can
-- tell "it said no" from "we took its word for it".
local logRemembered = false

-- The interface version, which changes every patch. Used only to date a
-- remembered refusal: it is the soonest the answer could change, so it is the
-- soonest worth asking again.
local function ClientBuild()
    if not GetBuildInfo then return 0 end
    local ok, _, _, _, toc = pcall(GetBuildInfo)
    return (ok and type(toc) == "number") and toc or 0
end

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
--
-- A marked record is never counted here and never evicted. The whole point of
-- marking one is that it keeps mattering after you stop seeing it -- an
-- ignored trash debuff you have not met in three weeks should still be
-- ignored, and an important one should not silently start showing up in the
-- co-tank row again because the journal needed the slot.
local function Prune()
    local ids, n = {}, 0
    for id, r in pairs(seen) do
        if not r.mark then
            n = n + 1
            ids[n] = id
        end
    end
    if n <= MAX_RECORDS then return end

    -- Never-seen candidates go first, whatever their timestamps say.
    --
    -- A journal record is stamped at the pull, so on `last` alone a boss you
    -- have never fought would evict a debuff that landed on you last week --
    -- throwing away an observation to keep a guess. Something you actually
    -- took is the better record by definition, and it survives.
    tsort(ids, function(a, b)
        local ra, rb = seen[a], seen[b]
        local sa, sb = (ra.n or 0) > 0, (rb.n or 0) > 0
        if sa ~= sb then return sb end
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
    if type(id) ~= "number" then
        -- Counted, not just dropped, and only when the client actually refused
        -- to name it. A malformed table is a bug in us; a secret spellId is
        -- the client saying "you may display this and you may not identify
        -- it", and that is the single number that explains a journal which
        -- stays empty through a fight the panel drew perfectly.
        --
        -- The two are kept apart because they call for opposite responses:
        -- one is ours to fix, and the other is the answer.
        if IsSecret(a.spellId) then unnamedAuras = unnamedAuras + 1 end
        return
    end

    -- Fails CLOSED, unlike almost everything else in this addon, and on
    -- purpose: an unreadable isHarmful on the shared added-aura list would let
    -- every proc and buff you own into a journal whose whole point is to be a
    -- shortlist of debuffs. The log door covers what is lost here.
    if not harmful and Flag(a.isHarmful) ~= true then
        -- Only an *unreadable* answer is worth counting. A readable `false` is
        -- a buff, and every buff you own would otherwise inflate this into
        -- noise -- a diagnostic that cries wolf is one nobody reads on the
        -- night it is telling the truth.
        if IsSecret(a.isHarmful) then unreadableHarmful = unreadableHarmful + 1 end
        return
    end

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

-- Whether a UNIT_AURA update is about a unit this journal records.
--
-- The token is compared raw, as it is everywhere else an event hands one over:
-- a unit token in an event payload is a plain string, and it is the *answers*
-- about that unit -- its name, its GUID -- that come back secret.
local function Watched(unit)
    if unit == "player" then return true end
    local tanks = ns.tankUnits
    if not tanks then return false end
    for i = 1, #tanks do
        if tanks[i] == unit then return true end
    end
    return false
end

-- Everything harmful on one unit right now.
--
-- The pcall is not redundant with the AurasRestricted() check its caller makes.
-- That check answers the policy question for the frame; this one survives a
-- unit that goes away mid-walk, or a restricted set that has moved since the
-- probe. A break rather than a skip: the client packs auras from index 1, so
-- the first miss is the end of the list.
local function ScanUnit(unit)
    for i = 1, MAX_AURA_SCAN do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
        if not ok or not a then break end
        FromAura(a, true)
    end
end

-- Everything harmful on us and on the co-tanks right now. Rate limited, and
-- silent while aura reads are refused: ns.AurasRestricted() is asked before
-- the loop rather than leaning on the pcall inside it, because a refusal there
-- is the normal state in an encounter and not an error worth swallowing five
-- times a second.
--
-- Co-tanks are walked because the co-tank row is what this journal exists to
-- feed, and that row draws auras on *other* tanks. A journal that only ever
-- saw your own debuffs could never offer you the one you actually wanted to
-- mark -- you would have watched it on the other tank's row all night and
-- still not found it in the list.
local function FullScan()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    if ns.AurasRestricted() then return end

    local now = GetTime and GetTime() or 0
    if (now - lastScan) < SCAN_GAP then return end
    lastScan = now

    ScanUnit("player")

    -- ns.tankUnits carries "player" when we tank, and scanning the same auras
    -- twice would file every one of them as two sightings -- `n` is the count
    -- the window sorts by, so it has to mean what it says.
    local tanks = ns.tankUnits
    if not tanks then return end
    for i = 1, #tanks do
        local u = tanks[i]
        if u ~= "player" and UnitExists and UnitExists(u) then ScanUnit(u) end
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
        -- Two different ways the log door is shut, and they want different
        -- answers: the client refused the registration, or it let us listen
        -- but will not tell us which lines are ours.
        logAllowed = logAllowed,
        -- We did not ask this session: a previous one was refused on this same
        -- client build. Not the same fact as "it said no", and the difference
        -- is the one that tells you /tt debuffs log exists.
        logRemembered = logRemembered,
        -- Open when there is any way at all to tell our own lines apart. The
        -- flag route needs no identity and so survives an encounter, which is
        -- why this is no longer just "do we have a GUID".
        logOpen    = (myGUID ~= nil) or sawMineFlag,
        selfByFlag = sawMineFlag,
        -- Co-tanks we hold a usable GUID for, and co-tanks the client would
        -- not name. The second number is the one worth printing: it is the
        -- whole reason a raid night can end with a journal full of your own
        -- debuffs and none of the other tank's.
        tanksKnown = TankGUIDCount(),
        tanksBlind = blindTanks,
        -- Auras that arrived and could not be identified. Non-zero is the
        -- answer to "the panel is drawing them, why is the journal empty".
        unnamed    = unnamedAuras,
        unreadableHarmful = unreadableHarmful,
        -- The journal door. `journalTried` separates "never pulled a boss this
        -- session" from "tried and got nothing", which is the difference
        -- between waiting and debugging.
        fromJournal = db and db.djFromJournal and true or false,
        journalIDs  = journalIDs,
        journalTried = journalTried,
        journalErr  = journalErr,
        sawAura    = sawAura,
        sawLog     = sawLog,
        cap        = MAX_RECORDS,
    }
end

-- Wipes the journal, not the marks in it: a mark is a decision you made on
-- purpose, and "forget everything recorded" is for the clutter that piled up
-- on its own. Anything marked survives, both the record and the mark.
function ns.ForgetDebuffs()
    local n = 0
    if seen then
        for id, r in pairs(seen) do
            if not r.mark then
                seen[id] = nil
                n = n + 1
            end
        end
    end
    dirty = true
    return n
end

--------------------------------------------------------------------------------
-- Marking
--
-- The client tells us what a debuff is; only you can say whether it matters.
-- A mark is the answer, kept on the record so it rides along with everything
-- else learned about the debuff, and read by UI/AuraRow.lua to pin a debuff
-- into the co-tank row past its usual filters or drop it from that row
-- entirely -- see CandidateFilters there for how.
--------------------------------------------------------------------------------

local MARKS = { important = true, ignored = true }

-- nil clears a mark; "important" or "ignored" sets one. Anything else is
-- refused rather than written -- a typo here is a debuff that quietly stops
-- being marked at all, and it is worse to no-op than to guess.
function ns.SetDebuffMark(id, mark)
    if type(id) ~= "number" then return end
    if mark ~= nil and not MARKS[mark] then return end

    local r = seen and seen[id]
    if not r or r.mark == mark then return end

    r.mark = mark
    dirty = true

    -- The co-tank row's engine container only re-reads its filters when told
    -- to, and nothing else would tell it a mark just changed.
    if ns.TankWatchLooksChanged then ns.TankWatchLooksChanged() end
end

-- Every marked id, split by verdict -- two plain sets rather than a record
-- walk handed to the caller, because AuraRow.lua asks for this every time a
-- co-tank row reconfigures.
function ns.DebuffMarkedIDs()
    local important, ignored = {}, {}
    if seen then
        for id, r in pairs(seen) do
            if r.mark == "important" then important[id] = true
            elseif r.mark == "ignored" then ignored[id] = true end
        end
    end
    return important, ignored
end

-- How many of each, for the journal window's footer.
function ns.DebuffMarkCounts()
    local important, ignored = 0, 0
    if seen then
        for _, r in pairs(seen) do
            if r.mark == "important" then important = important + 1
            elseif r.mark == "ignored" then ignored = ignored + 1 end
        end
    end
    return important, ignored
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

local LOG_EVENTS = {
    SPELL_AURA_APPLIED      = true,
    SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REFRESH      = true,
}

-- WHO A LOG LINE IS ABOUT, WITHOUT ASKING WHO ANYBODY IS
--
-- The GUID compare below used to be the only test, and it is the reason the
-- journal was thinnest in exactly the content worth cataloguing. `myGUID` is
-- UnitGUID("player") laundered, and inside an instance that is a secret --
-- so myGUID is nil, every line is unattributable, and the log door shuts on
-- its own in the one place the aura door is already shut.
--
-- destFlags is the way out. It is a bitmask on a log line rather than an
-- answer about a unit -- a different permission, the same one that lets the
-- log be read at all -- and its affiliation bits say MINE without anybody's
-- identity being involved. That covers the player everywhere, encounter
-- included.
--
-- It does NOT cover co-tanks. The mask distinguishes mine / party / raid /
-- outsider and has no notion of role, so "is this line about a tank" still
-- needs a GUID, and a GUID is what an encounter takes away. Co-tank lines are
-- therefore attributed where identity is readable and not at all where it is
-- not -- reported by /tt status rather than left as a mystery, because a
-- silently tank-blind journal is the bug this whole change is fixing.
local AFFILIATION_MINE = 0x00000001

local function RebuildTankGUIDs()
    for k in pairs(tankGUIDs) do tankGUIDs[k] = nil end
    blindTanks = 0

    if not (UnitGUID and ns.tankUnits) then return end
    for i = 1, #ns.tankUnits do
        local u = ns.tankUnits[i]
        if u ~= "player" then
            local g = Clean(UnitGUID(u))
            if type(g) == "string" then tankGUIDs[g] = true
            else blindTanks = blindTanks + 1 end
        end
    end
end

-- True when this line is about somebody the journal records: us, or a co-tank
-- we can still recognise.
--
-- Ordered by cost and by certainty. The flag test is arithmetic on a number we
-- already have; the GUID compares need a table lookup and can only run at all
-- when the client is still naming people.
local function Recordable(destFlags, dest)
    local f = Clean(destFlags)
    if type(f) == "number" and f % (AFFILIATION_MINE * 2) >= AFFILIATION_MINE then
        sawMineFlag = true
        return true
    end

    if type(dest) ~= "string" then return false end
    if myGUID and dest == myGUID then return true end
    return tankGUIDs[dest] == true
end

-- The combat log handler, and the one hot path in this file: it runs on every
-- line of the log, which in a raid is thousands a second.
--
-- So it is ordered by how cheaply each test rejects. The subevent is looked at
-- first and throws out almost everything; attribution runs only for the
-- handful of lines that survive that.
--
-- Nothing is used as a table key before it has been laundered and type
-- checked. A secret used as a key throws, and a handler that throws on every
-- log line is one the event dispatcher stops within five of them.
local function OnCombatLog()
    if not (db.djRecord and db.djFromLog) then return end
    if not CombatLogGetCurrentEventInfo then return end

    local _, sub, _, _, _, _, _, destGUID, _, destFlags, _,
          spellId, spellName, _, auraType = CombatLogGetCurrentEventInfo()

    sub = Clean(sub)
    if type(sub) ~= "string" or not LOG_EVENTS[sub] then return end

    if Clean(auraType) ~= "DEBUFF" then return end

    if not Recordable(destFlags, Clean(destGUID)) then return end

    local id = Clean(spellId)
    if type(id) ~= "number" then return end

    local r = Touch(id, "log")
    sawLog = true

    local name = Clean(spellName)
    if not r.name and type(name) == "string" and name ~= "" then r.name = name end
    FillFromSpellbook(r)
end

-- Forget a remembered refusal and ask the client again, right now.
--
-- For the case the refusal was situational after all -- reloading inside an
-- encounter, say -- or Blizzard relented mid-patch. Nobody should have to edit
-- a saved variables file to ask a question that costs one call.
--
-- Returns early when the door is already open: registering the same handler
-- twice would file every log line as two sightings.
function ns.RetryDebuffLog()
    if not db then return false end

    db.djLogRefusedOn = nil
    logRemembered = false
    if logAllowed then return true end

    logAllowed = ns.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    if not logAllowed then db.djLogRefusedOn = ClientBuild() end
    return logAllowed
end

--------------------------------------------------------------------------------
-- The third door: the Encounter Journal
--
-- The other two doors record what LANDED. This one records what the boss can
-- do, which is a different fact and worth keeping apart.
--
-- It works in an encounter for the same reason the spell database does: the
-- Dungeon Journal is the game's own content data, not an answer about a unit,
-- so nothing here is restricted and nothing needs laundering. That is the
-- whole appeal -- it is the only door that stays open regardless of who the
-- debuff lands on, which is exactly the gap the other two leave.
--
-- WHAT IT IS NOT
--
-- A sighting. A record from here has never been on anybody, so it carries
-- n = 0 and via = "journal", and the window says "not seen yet" rather than
-- pretending. Marking one important before the pull is the point: you can
-- build the co-tank row's list from the journal instead of having to meet a
-- debuff first.
--
-- THE ID MISMATCH, WHICH IS THE TRAP
--
-- ENCOUNTER_START hands over a *dungeon* encounter id. The journal is keyed by
-- *journal* encounter id. They are different numbers for the same boss, and
-- feeding one to the other's API returns nothing at all -- silently, the way
-- everything else in this file fails. The mapping is a walk of the current
-- instance's encounters looking for a matching dungeonEncounterID.
--------------------------------------------------------------------------------

-- How much of the section tree to walk before giving up. A boss has tens of
-- sections; a bound this loose will never be reached by real data, and it is
-- here so that a malformed sibling link cannot hang the client mid-pull.
local MAX_SECTIONS = 400

-- Encounters already walked this session, so a wipe and a re-pull does not
-- redo the whole tree. Keyed by dungeon encounter id.
local journalDone = {}

-- A record the journal contributed. Deliberately NOT Touch(): that counts a
-- sighting, and nothing here has been seen.
--
-- An existing record is only ever filled in, never downgraded -- if a debuff
-- has actually landed on you, that is the better fact and it stays.
local function FromJournal(id, name, icon)
    local r = seen[id]
    if not r then
        r = { id = id, n = 0, first = Now(), last = Now(), via = "journal" }
        seen[id] = r
        journalIDs = journalIDs + 1
    end

    if not r.name and type(name) == "string" and name ~= "" then r.name = name end
    if not r.icon and icon then r.icon = icon end
    FillFromSpellbook(r)

    dirty = true
end

-- Walk a boss's section tree, depth first, collecting every spell id on it.
--
-- Iterative rather than recursive: the tree is client data and a sibling link
-- that points back up it would take the stack down, where a visit budget just
-- stops.
local function WalkSections(rootID)
    local GetSection = C_EncounterJournal and C_EncounterJournal.GetSectionInfo
    if not GetSection then return 0, "this client has no GetSectionInfo" end

    local stack, n, found = { rootID }, 0, 0
    local visited = {}

    while #stack > 0 and n < MAX_SECTIONS do
        local id = tremove(stack)
        if type(id) == "number" and not visited[id] then
            visited[id] = true
            n = n + 1

            local ok, s = pcall(GetSection, id)
            if ok and type(s) == "table" then
                -- A section is either an ability or a heading that holds them,
                -- and only the first kind has a spell.
                if type(s.spellID) == "number" and s.spellID > 0 then
                    FromJournal(s.spellID, s.title, s.abilityIcon)
                    found = found + 1
                end
                stack[#stack + 1] = s.siblingSectionID
                stack[#stack + 1] = s.firstChildSectionID
            end
        end
    end

    return found
end

-- dungeonEncounterID -> the journal's own encounter id and section root.
--
-- EJ_GetEncounterInfoByIndex is asked with an explicit instance id first,
-- because the form without one reads whatever instance the player last
-- selected -- and EJ_SelectInstance would then change what their Dungeon
-- Journal is showing. Silently repointing a window the player has open is not
-- a thing an addon should do to look up a spell id, so the mutating call is
-- only a fallback for a client whose API does not take the argument.
local function FindEncounter(dungeonEncounterID)
    if not (EJ_GetCurrentInstance and EJ_GetEncounterInfoByIndex) then
        return nil, "this client has no Encounter Journal API"
    end

    local okInst, instanceID = pcall(EJ_GetCurrentInstance)
    if not okInst or type(instanceID) ~= "number" or instanceID == 0 then
        return nil, "the client would not say which instance this is"
    end

    local selected = false
    for i = 1, 40 do
        local ok, name, _, journalID, rootSectionID, _, _, dungeonID =
            pcall(EJ_GetEncounterInfoByIndex, i, instanceID)

        -- Nothing came back for index 1 with an explicit instance: this client
        -- wants the selection instead. Do it once, then restart the walk.
        if (not ok or name == nil) and i == 1 and not selected and EJ_SelectInstance then
            selected = true
            pcall(EJ_SelectInstance, instanceID)
            ok, name, _, journalID, rootSectionID, _, _, dungeonID =
                pcall(EJ_GetEncounterInfoByIndex, i)
        end

        if not ok or name == nil then break end
        if dungeonID == dungeonEncounterID then
            return rootSectionID, nil, journalID
        end
    end

    return nil, "this boss is not in the journal for this instance"
end

-- Called at the pull. Everything is guarded and nothing here is required to
-- succeed: a journal that cannot be read costs the two doors that already
-- work exactly nothing.
local function LearnEncounter(dungeonEncounterID)
    if not (db and db.djRecord and db.djFromJournal) then return end
    if type(dungeonEncounterID) ~= "number" then return end
    if journalDone[dungeonEncounterID] then return end
    journalDone[dungeonEncounterID] = true
    journalTried = true

    local rootSectionID, err = FindEncounter(dungeonEncounterID)
    if not rootSectionID then
        journalErr = err
        return
    end

    local found, werr = WalkSections(rootSectionID)
    journalErr = (found == 0) and (werr or "the boss has no abilities listed")
                 or nil
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
        if not db.djRecord or not Watched(unit) then return end

        if type(updateInfo) == "table" then
            local added = updateInfo.addedAuras
            if type(added) == "table" then
                for i = 1, #added do FromAura(added[i], false) end
            end
            if added and not updateInfo.isFullUpdate then return end
        end

        FullScan()
    end)

    -- Probed, not assumed -- but asked once per patch, not once per login.
    --
    -- On a client that protects the combat log this call is refused, and until
    -- it was guarded the refusal unwound the rest of this function: no zone-in
    -- scan, no ticker, no redraw, and a journal that looked broken rather than
    -- merely poorer. Guarding it stopped the damage but not the noise -- the
    -- client fires ADDON_ACTION_FORBIDDEN whether or not the error is caught,
    -- so an addon that simply retries every login hands the player an error
    -- report every login about a door it already knows is shut.
    --
    -- So the refusal is dated with the interface version and believed until
    -- that changes, which is the soonest Blizzard's answer could change.
    -- /tt debuffs log asks again now, for the case it was situational.
    local build = ClientBuild()
    if not db.djFromLog then
        -- Switched off, so nothing is asked. Not the same as a refusal, and
        -- worth having as its own branch: it is the one setting that
        -- guarantees this addon gives the client nothing to complain about.
        logAllowed = false
    elseif db.djLogRefusedOn == build then
        logAllowed, logRemembered = false, true
    else
        logAllowed = ns.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
        db.djLogRefusedOn = (not logAllowed) and build or nil
    end

    -- Catches what is already on you: a debuff applied while the addon was
    -- loading, or across a zone in, never produces an added-aura event we see.
    -- GROUP_ROSTER_UPDATE is in the list because who the co-tanks are is half
    -- of what this module records, and it changes without a loading screen.
    -- Core/State.lua rebuilds ns.tankUnits on the same event and is earlier in
    -- the .toc, so by the time this runs the list is the new one -- that
    -- ordering is the .toc's job and the reason it is written down.
    ns.RegisterEvents({ "PLAYER_ENTERING_WORLD", "PLAYER_LOGIN",
                        "GROUP_ROSTER_UPDATE" }, function()
        myGUID = UnitGUID and Clean(UnitGUID("player")) or nil
        RebuildTankGUIDs()
        if db.djRecord then FullScan() end
    end)

    -- The pull. This is the only event the journal door needs, and it carries
    -- the dungeon encounter id that FindEncounter has to map.
    ns.RegisterEvent("ENCOUNTER_START", function(_, encounterID)
        LearnEncounter(Clean(encounterID))
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
                 (not s.fromLog) and "|cff808080off|r -- nothing is asked of "
                         .. "the client"
                     or s.logRemembered
                     and "|cffff4040refused before on this build|r "
                         .. "-- |cffffff00/tt debuffs log|r asks again"
                     or (not s.logAllowed)
                     and "|cffff4040the client refuses to register for it|r"
                     or (s.logOpen and "|cff00ff00on|r"
                         or "|cffff4040cannot tell our own lines apart|r")))

    -- The line that answers "the panel drew them, so why is the list empty".
    -- Printed only when it has actually happened, because zero is the normal
    -- state and a diagnostic that is always on screen stops being read.
    if s.unnamed > 0 then
        Print(format("  |cffff8000%d aura(s) arrived that the client would not"
                     .. " name|r -- drawn on the panel, not recordable",
                     s.unnamed))
    end
    if s.unreadableHarmful > 0 then
        Print(format("  %d aura(s) would not say whether they were harmful",
                     s.unreadableHarmful))
    end

    Print(format("  encounter journal=%s", not s.fromJournal
                     and "|cff808080off|r"
                     or (not s.journalTried)
                         and "|cff808080on -- no boss pulled yet|r"
                     or s.journalErr
                         and format("|cffff4040%s|r", s.journalErr)
                     or format("|cff00ff00on|r -- %d spell(s) learned from "
                               .. "boss ability lists", s.journalIDs)))

    -- Co-tanks are half of what this records, and the half that goes quiet
    -- without anything looking wrong. Printed only in a group, because "0
    -- co-tanks" solo is not news.
    if s.tanksKnown > 0 or s.tanksBlind > 0 then
        Print(format("  co-tanks recognised=%d%s", s.tanksKnown,
                     s.tanksBlind > 0
                         and format("  |cffff8000%d the client will not name|r"
                                    .. " -- their debuffs cannot be recorded"
                                    .. " from the log here", s.tanksBlind)
                         or ""))
    end
end, "debuffs")
