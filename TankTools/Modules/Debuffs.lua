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
-- TWO DOORS
--
-- The aura data itself: UNIT_AURA hands over an AuraData table per added aura,
-- with every flag on it. That is the rich door, and it narrows where it
-- matters: inside an encounter or a Mythic+ the client refuses aura
-- enumeration (see ns.AurasRestricted in Core/Secret.lua). The added-aura list
-- still arrives there -- it is pushed, not enumerated -- so records still land,
-- just fewer of them.
--
-- And the Encounter Journal, further down: what a boss can do, learned at the
-- pull or pre-filled for a whole expansion, before anything has landed.
--
-- THERE USED TO BE A THIRD
--
-- The combat log (SPELL_AURA_APPLIED) was read too, as the door that stays
-- open in an encounter. It was removed. On a client that protects
-- COMBAT_LOG_EVENT_UNFILTERED the registration is refused, and the refusal is
-- shown to the player as ADDON_ACTION_FORBIDDEN -- an error on screen at
-- startup, which remembering the refusal per patch did not stop in practice.
-- A journal that is thinner inside encounters is the better trade. Records it
-- wrote before then keep via = "log" and still read as "log only".
--
-- NOTHING HERE IS READ RAW
--
-- Every value off an aura table goes through Clean() before it is compared,
-- formatted or used as a table key. A flag that comes back
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
        -- The pre-filled catalog: every boss ability of the current expansion,
        -- read out of the Encounter Journal on request. Kept apart from djSeen
        -- so it never counts against the journal's cap and never evicts a
        -- real sighting -- see "The catalog" below. Shaped
        -- { entries = { [spellID] = entry }, tier =, built =, ... } once built;
        -- empty until then, for the same CopyDefault reason as djSeen.
        djCatalog = {},
    },
})

local db      -- resolved in OnInit
local seen    -- db.djSeen
local catalog -- db.djCatalog

-- A record has changed since the window last drew. Batched onto a ticker
-- rather than redrawn per event: a fast-ticking debuff refreshes several times
-- a second and the list looks identical each time.
local dirty = false

local lastScan = 0

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

-- Encounters already walked this session, so a wipe and a re-pull does not
-- redo the whole tree. Keyed by dungeon encounter id. Up here rather than
-- beside the walk because clearing the journal has to reset it too.
local journalDone = {}

-- Whether the aura door has actually produced anything this session.
local sawAura = false

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

-- A sighting. Only the aura door calls this now, so a sighting always makes
-- the record an aura record -- which is also how a journal entry ("not seen
-- yet") or an old combat-log one is upgraded the first time it really lands.
local function Touch(id)
    local r = seen[id]
    local fresh = false
    if not r then
        r = { id = id, n = 0, first = Now(), where = Where() }
        seen[id] = r
        fresh = true
    end

    r.n    = r.n + 1
    r.last = Now()
    r.via  = "aura"

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

    local r = Touch(id)
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
-- typed into the box finds an id you half remember -- and, for a boss ability,
-- the encounter and the instance (not `boss`, which is the boss-aura flag), so typing a dungeon's name lists its abilities.
--
-- `withCatalog` adds the pre-filled boss abilities that are not in the journal
-- yet. They come back as fresh view rows, never the catalog's own tables, and
-- with `last = 0` so a "recent" sort puts everything you actually met first.
local function CatalogCount()
    local n = 0
    if catalog and catalog.entries then
        for _ in pairs(catalog.entries) do n = n + 1 end
    end
    return n
end

local function Matches(query, r)
    if query == "" then return true end
    return strlower(r.name or ""):find(query, 1, true) ~= nil
           or tostring(r.id):find(query, 1, true) ~= nil
           or strlower(r.encounter or ""):find(query, 1, true) ~= nil
           or strlower(r.instance or ""):find(query, 1, true) ~= nil
end

function ns.DebuffRecords(query, sort, withCatalog)
    local out = {}
    if not seen then return out end

    query = (type(query) == "string") and strlower(strtrim(query)) or ""

    for _, r in pairs(seen) do
        if Matches(query, r) then out[#out + 1] = r end
    end

    local entries = withCatalog and catalog and catalog.entries
    if entries then
        for id, c in pairs(entries) do
            if not seen[id] then
                local v = { id = id, name = c.name, icon = c.icon, n = 0, last = 0,
                            via = "journal", encounter = c.encounter, instance = c.instance,
                            dispel = c.dispel, tank = c.tank, bleed = c.bleed,
                            catalog = true }
                if Matches(query, v) then out[#out + 1] = v end
            end
        end
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
        restricted = ns.AurasRestricted(),
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
        cap        = MAX_RECORDS,
        -- The pre-filled catalog: how many boss abilities, from which
        -- expansion, and when it was built. Zero entries and no `built` is
        -- "never pre-filled", not "pre-filled and found nothing".
        catalog          = CatalogCount(),
        catalogTier      = catalog and catalog.tier or nil,
        catalogBuilt     = catalog and catalog.built or nil,
        catalogInstances = catalog and catalog.instances or 0,
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

-- The whole slate: every record marked or not, and the pre-filled catalog.
-- ForgetDebuffs above is for clutter and keeps what you decided; this is for
-- starting the list over, so it takes the decisions with it. Returns how many
-- records and how many catalog entries went.
--
-- The co-tank row is told, because the marks it filters by just vanished.
function ns.ClearDebuffJournal()
    local records, entries = 0, 0
    if seen then
        for id in pairs(seen) do
            seen[id] = nil
            records = records + 1
        end
    end
    if catalog then
        entries = CatalogCount()
        for k in pairs(catalog) do catalog[k] = nil end
    end
    -- A boss already walked this session would otherwise not be learned
    -- again at its next pull, and the list would stay empty for a reason
    -- nobody can see.
    for k in pairs(journalDone) do journalDone[k] = nil end
    journalIDs = 0

    dirty = true
    if ns.TankWatchLooksChanged then ns.TankWatchLooksChanged() end
    return records, entries
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
    -- A catalog entry has no record to carry a mark, so marking one writes it
    -- into the journal first -- and a marked record is never evicted, so the
    -- decision outlives the next rebuild of the catalog it came from.
    if not r and mark ~= nil then
        local c = catalog and catalog.entries and catalog.entries[id]
        if c then
            r = { id = id, n = 0, first = Now(), last = Now(), via = "journal",
                  name = c.name, icon = c.icon, encounter = c.encounter,
                  instance = c.instance, dispel = c.dispel, tank = c.tank,
                  bleed = c.bleed }
            seen[id] = r
        end
    end
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
-- The second door: the Encounter Journal
--
-- The aura door records what LANDED. This one records what the boss can do,
-- which is a different fact and worth keeping apart.
--
-- It works in an encounter for the same reason the spell database does: the
-- Dungeon Journal is the game's own content data, not an answer about a unit,
-- so nothing here is restricted and nothing needs laundering. That is the
-- whole appeal -- it is the only door that stays open regardless of who the
-- debuff lands on, which is exactly the gap the aura door leaves in an
-- encounter.
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


-- A record the journal contributed. Deliberately NOT Touch(): that counts a
-- sighting, and nothing here has been seen.
--
-- An existing record is only ever filled in, never downgraded -- if a debuff
-- has actually landed on you, that is the better fact and it stays.
-- WHICH ABILITIES ARE DEBUFFS
--
-- The journal lists every ability a boss has -- casts, adds, frontals,
-- enrages -- and nothing on a spell says "this one leaves a debuff on you".
-- What the journal does carry is the row of little icons beside each ability
-- in the Adventure Guide (Enum.JournalEncounterIconFlags), and six of them
-- mean a debuff a tank cares about: the four dispel types, Bleed, and the Tank
-- alert, which is how the journal marks a tank buster. Those are kept; every
-- other ability is not written down.
--
-- Two limits, stated rather than hidden. Magic is also how the journal tags a
-- purgeable buff on the boss, so one of those can get through. And the journal
-- lists the spell a boss *casts*, which is not always the id of the debuff it
-- leaves -- a real sighting records the real id when it lands.
--
-- GetSectionIconFlags returns icon *indices*, not flag values: the index is
-- the flag's bit position, which is how Blizzard's own journal maps them
-- (GetIconFlagIndices in Blizzard_EncounterJournal.lua). Derived from the enum
-- when there is one, so a renumbering follows along.
local function BitIndex(v, fallback)
    if type(v) ~= "number" or v < 1 then return fallback end
    local i = 0
    while v > 1 do v = v / 2; i = i + 1 end
    return i
end

local ICON = (Enum and Enum.JournalEncounterIconFlags) or {}
-- The fallbacks are today's bit positions, for a client with no enum.
local DEBUFF_ICONS = {
    [BitIndex(ICON.Tank,    0)]  = "tank",
    [BitIndex(ICON.Magic,   7)]  = "Magic",
    [BitIndex(ICON.Curse,   8)]  = "Curse",
    [BitIndex(ICON.Poison,  9)]  = "Poison",
    [BitIndex(ICON.Disease, 10)] = "Disease",
    [BitIndex(ICON.Bleed,   13)] = "bleed",
}

-- The tags that make a section worth keeping, as record fields -- `dispel`,
-- `tank`, `bleed`, the same names the aura door fills in -- or nil when the
-- section carries none of them. A client without the call keeps everything,
-- which is how the journal behaved before it could tell: an unfiltered list
-- is recoverable by reading it, an empty one is not.
local function DebuffTags(sectionID)
    local get = C_EncounterJournal and C_EncounterJournal.GetSectionIconFlags
    if not get then return {} end
    local ok, flags = pcall(get, sectionID)
    if not ok or type(flags) ~= "table" then return nil end

    local tags
    for _, index in ipairs(flags) do
        local tag = DEBUFF_ICONS[index]
        if tag then
            tags = tags or {}
            if tag == "tank" then tags.tank = true
            elseif tag == "bleed" then tags.bleed = true
            else tags.dispel = tag end
        end
    end
    return tags
end

local function ApplyTags(r, tags)
    if tags.dispel and r.dispel == nil then r.dispel = tags.dispel end
    if tags.tank and r.tank == nil then r.tank = true end
    if tags.bleed then r.bleed = true end
end

local function FromJournal(id, name, icon, sectionID)
    local tags = DebuffTags(sectionID)
    if not tags then return end

    local r = seen[id]
    if not r then
        r = { id = id, n = 0, first = Now(), last = Now(), via = "journal" }
        seen[id] = r
        journalIDs = journalIDs + 1
    end

    if not r.name and type(name) == "string" and name ~= "" then r.name = name end
    if not r.icon and icon then r.icon = icon end
    -- Only fills gaps: a flag the aura door actually read wins over the
    -- journal's tag for the same spell.
    ApplyTags(r, tags)
    FillFromSpellbook(r)

    dirty = true
end

-- Walk a boss's section tree, depth first, collecting every spell id on it.
--
-- Iterative rather than recursive: the tree is client data and a sibling link
-- that points back up it would take the stack down, where a visit budget just
-- stops.
--
-- `sink(spellID, title, icon, sectionID)` is where each ability goes: the journal at the
-- pull, the catalog when pre-filling. Same walk, two destinations.
local function WalkSections(rootID, sink)
    sink = sink or FromJournal
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
                    sink(s.spellID, s.title, s.abilityIcon, id)
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
-- The journal instance you are standing in.
--
-- Not EJ_GetCurrentInstance: that was removed in 8.0.1, and for as long as this
-- file called it the pull-time door answered "no Encounter Journal API" on
-- every live client -- the harness defined the function, so the suite never
-- noticed. This is the route Blizzard's own AdventureGuideUtil takes: the game
-- map id from GetInstanceInfo, mapped to the journal's own instance id.
local function CurrentJournalInstance()
    if not (GetInstanceInfo and C_EncounterJournal
            and C_EncounterJournal.GetInstanceForGameMap) then
        return nil
    end
    local mapID = Clean(select(8, GetInstanceInfo()))
    if type(mapID) ~= "number" then return nil end
    local ok, id = pcall(C_EncounterJournal.GetInstanceForGameMap, mapID)
    return (ok and type(id) == "number" and id ~= 0) and id or nil
end

local function FindEncounter(dungeonEncounterID)
    if not EJ_GetEncounterInfoByIndex then
        return nil, "this client has no Encounter Journal API"
    end

    local instanceID = CurrentJournalInstance()
    if not instanceID then
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
-- succeed: a journal that cannot be read costs the aura door exactly
-- nothing.
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
-- The catalog: every boss ability of the current expansion, ahead of time
--
-- The pull-time door above learns one boss at the moment it is pulled. This
-- walks the same section trees for every dungeon and raid of the current
-- expansion, on request, so the whole list can be marked before you set foot
-- in any of them.
--
-- KEPT APART FROM THE JOURNAL
--
-- An expansion is several hundred to a thousand spell ids, and the journal
-- holds four hundred and evicts never-seen records first -- a pre-fill written
-- into it would evict itself. So it lives in djCatalog, counts against nothing,
-- and is replaced wholesale on every rebuild. The window shows the two
-- together; marking a catalog entry writes it into the journal (SetDebuffMark),
-- where a marked record is never evicted.
--
-- IT HAS TO MOVE THE PLAYER'S DUNGEON JOURNAL, SO IT PUTS IT BACK
--
-- EJ_GetInstanceByIndex only lists the *selected* tier, and there is no way to
-- enumerate one without EJ_SelectTier -- which the Adventure Guide persists as
-- the player's own choice. So the selected tier is saved and restored, the way
-- RCLootCouncil does it, and the whole walk runs inside a single call: no frame
-- is ever drawn with the selection moved. The selected *instance* has no
-- getter at all, so the walk refuses while the Adventure Guide is open -- its
-- boss list reads whatever instance is selected -- and otherwise restores the
-- one it remembers, when its window has been loaded.
--
-- Difficulty is never touched. Sections are flagged by difficulty rather than
-- removed, so collecting every one gives the Mythic superset without calling
-- EJ_SetDifficulty -- which changes what the player sees in the Adventure
-- Guide, and which DBM notes has crashed the client with a bad index.
--------------------------------------------------------------------------------

local MAX_INSTANCES  = 30   -- per list; an expansion has around a dozen
local MAX_ENCOUNTERS = 20   -- per instance; a raid has around ten

-- The Adventure Guide, if it has been loaded, and whether it is on screen.
-- Its IsShown is a getter on a client-owned frame, so it is asked through a
-- pcall rather than trusted not to throw.
local function AdventureGuideOpen()
    local ej = rawget(_G, "EncounterJournal")
    if not ej or not ej.IsShown then return false end
    local ok, shown = pcall(ej.IsShown, ej)
    return ok and shown == true
end

-- The tier the game considers current: expansion level is 0-based, tiers are
-- 1-based and in expansion order -- the same arithmetic Blizzard's own journal
-- uses. Clamped, because a tier past the end is a question with no answer.
local function CurrentExpansionTier()
    local n = EJ_GetNumTiers()
    if type(n) ~= "number" or n < 1 then return nil end
    local level = GetServerExpansionLevel and GetServerExpansionLevel()
    local tier = (type(level) == "number") and (level + 1) or n
    if tier > n then tier = n end
    if tier < 1 then tier = 1 end
    return tier
end

-- Every dungeon and raid of the selected tier. The raid list opens with an
-- "instance" that is really the tier's world bosses, which has no dungeon map;
-- it is skipped by that, the way MRT skips it.
local function ListInstances()
    local out = {}
    for _, isRaid in ipairs({ false, true }) do
        for i = 1, MAX_INSTANCES do
            local id, name, _, _, _, _, _, areaMapID = EJ_GetInstanceByIndex(i, isRaid)
            if not id then break end
            if areaMapID ~= 0 then
                out[#out + 1] = { id = id, name = name, raid = isRaid }
            end
        end
    end
    return out
end

-- The walk proper, run under pcall by PrefillDebuffs so the journal's
-- selection is restored whatever happens in here.
local function BuildCatalog(tier, entries)
    EJ_SelectTier(tier)
    local tierName = EJ_GetTierInfo and EJ_GetTierInfo(tier) or nil

    local instances = ListInstances()
    for _, inst in ipairs(instances) do
        -- Selected first even though the id is passed explicitly: the explicit
        -- form is documented to need a selection made at least once this
        -- session, and every shipping caller selects before it asks.
        EJ_SelectInstance(inst.id)
        for e = 1, MAX_ENCOUNTERS do
            local name, _, _, rootSectionID = EJ_GetEncounterInfoByIndex(e, inst.id)
            if not name then break end
            WalkSections(rootSectionID, function(spellID, title, icon, sectionID)
                -- Debuffs only -- see DebuffTags.
                local tags = DebuffTags(sectionID)
                if not tags then return end
                -- First writer wins: an ability two bosses share is filed
                -- under the first one listed, not moved about by the walk.
                if not entries[spellID] then
                    local c = { name = title, icon = icon, encounter = name,
                                instance = inst.name, raid = inst.raid }
                    ApplyTags(c, tags)
                    entries[spellID] = c
                end
            end)
        end
    end

    return tierName, #instances
end

-- Returns the number of boss abilities catalogued, or nil and a reason. A
-- failed or empty walk leaves the previous catalog exactly as it was.
function ns.PrefillDebuffs()
    if not catalog then return nil, "the debuff journal is not loaded" end
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetCurrentTier
            and EJ_GetInstanceByIndex and EJ_SelectInstance
            and EJ_GetEncounterInfoByIndex) then
        return nil, "this client has no Encounter Journal API"
    end
    if InCombatLockdown and InCombatLockdown() then
        return nil, "not in combat -- try again once the fight is over"
    end
    if AdventureGuideOpen() then
        return nil, "close the Adventure Guide first -- pre-filling has to "
                    .. "borrow its selection for a moment"
    end

    local tier = CurrentExpansionTier()
    if not tier then return nil, "the Encounter Journal lists no tiers" end

    local prevTier = EJ_GetCurrentTier()
    local ej = rawget(_G, "EncounterJournal")
    local prevInstance = ej and ej.instanceID

    local entries = {}
    local ok, tierName, instances = pcall(BuildCatalog, tier, entries)

    if type(prevTier) == "number" and prevTier > 0 then pcall(EJ_SelectTier, prevTier) end
    if type(prevInstance) == "number" then pcall(EJ_SelectInstance, prevInstance) end

    if not ok then return nil, "the walk failed: " .. tostring(tierName) end

    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    if n == 0 then
        return nil, format("the Encounter Journal listed no boss abilities for %s",
                           tierName or ("tier " .. tier))
    end

    catalog.entries   = entries
    catalog.tier      = tierName
    catalog.instances = instances
    catalog.built     = Now()
    dirty = true
    return n
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
    if type(db.djCatalog) ~= "table" then db.djCatalog = {} end
    catalog = db.djCatalog

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

    -- Settings from the combat log door, which is gone. Cleared rather than
    -- left to ride along in the saved variables forever.
    db.djFromLog, db.djLogRefusedOn = nil, nil

    -- Catches what is already on you: a debuff applied while the addon was
    -- loading, or across a zone in, never produces an added-aura event we see.
    -- GROUP_ROSTER_UPDATE is in the list because who the co-tanks are is half
    -- of what this module records, and it changes without a loading screen.
    -- Core/State.lua rebuilds ns.tankUnits on the same event and is earlier in
    -- the .toc, so by the time this runs the list is the new one -- that
    -- ordering is the .toc's job and the reason it is written down.
    ns.RegisterEvents({ "PLAYER_ENTERING_WORLD", "PLAYER_LOGIN",
                        "GROUP_ROSTER_UPDATE" }, function()
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
    Print(format("  aura reads here=%s",
                 s.restricted and "|cffff8000refused|r" or "|cff00ff00allowed|r"))

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

    Print(format("  pre-filled catalog=%s", s.catalog > 0
                     and format("%d boss abilities from %d instance(s)%s",
                                s.catalog, s.catalogInstances,
                                s.catalogTier and (" of " .. s.catalogTier) or "")
                     or "|cff808080empty|r -- |cffffff00/tt debuffs prefill|r"
                        .. " builds it"))

end, "debuffs")
