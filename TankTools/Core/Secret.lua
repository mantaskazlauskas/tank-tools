--------------------------------------------------------------------------------
-- Tank Tools -- reading restricted values
--
-- Since Midnight the client returns "secret values" for anything that could
-- identify a unit while you are inside an instance. A secret can be handed
-- straight to a frame setter, but comparing it, formatting it, or using it as
-- a table key throws immediately.
--
-- Every value that comes out of a unit API goes through this file. Rather than
-- reason about which call is restricted in which context -- a set that has
-- grown across patches and will grow again -- every read is laundered: a
-- secret comes back as nil, meaning "unavailable", and every consumer already
-- handles nil.
--
-- This lives in Core because the rules are addon-wide. A module that copies
-- these three functions instead of requiring them is a module whose copy will
-- drift the next time the restricted set changes.
--------------------------------------------------------------------------------

local _, ns = ...

local issecretvalue = issecretvalue

--------------------------------------------------------------------------------

-- Guarded call: issecretvalue does not exist on older clients.
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
-- OPEN -- the unit carries on through whatever gate is being applied instead
-- of being dropped.
--
-- That direction is deliberate. UnitCanAttack, UnitIsDead and UnitIsPlayer can
-- all come back secret inside an instance, and dropping a mob when the answer
-- is unreadable would blind the addon in exactly the content it exists for.
local function IsTrue(v)
    local c = Clean(v)
    return c ~= nil and c ~= false
end

local function IsFalse(v)
    return Clean(v) == false
end

-- Renders a value the way the addon sees it, for the diagnostic commands. The
-- whole point is telling apart the three cases a plain tostring() flattens:
-- absent, restricted, and real.
local function Show(v)
    if v == nil then return "|cff888888nil|r" end
    if issecretvalue and issecretvalue(v) then return "|cffff8000SECRET|r" end
    if v == true  then return "|cff00ff00true|r" end
    if v == false then return "|cffff4040false|r" end
    return "|cff00ff00" .. tostring(v) .. "|r"
end

-- The one case Clean() cannot serve: telling "restricted" apart from "absent"
-- when both matter.
--
-- Frame setters accept a secret, so a display can pass one straight through to
-- SetText or SetValue and render correctly without ever reading it. But it has
-- to know that is what it is holding: an aura stack count of nil means "this
-- debuff does not stack" and should draw nothing, while a secret one means "we
-- are not allowed to look" and should be handed to the font string unread.
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

ns.Clean    = Clean
ns.IsTrue   = IsTrue
ns.IsFalse  = IsFalse
ns.IsSecret = IsSecret
ns.Show     = Show

--------------------------------------------------------------------------------
-- Auras are a different kind of restricted, and the difference is the whole
-- reason UI/AuraRow.lua exists.
--
-- Everything else in this file launders a value that came back: the call
-- succeeds, and what it hands over may be unreadable. Auras are not like that.
-- Inside an encounter or a Mythic+ the client refuses the *enumeration* --
-- C_UnitAuras.GetAuraDataByIndex does not return a secret, it throws -- so
-- there is no value to launder and no amount of Clean() helps. An addon that
-- walks aura indices in a boss fight does not degrade; it errors, five times a
-- second, until the ticker latch stops it.
--
-- This is the probe for that state. Two sources, because neither is complete:
-- C_Secrets answers the policy question directly where it exists, and the
-- pcall answers the empirical one on a build whose restricted set has moved.
--
-- The cache is deliberately one-sided. A stale "restricted" costs one frame of
-- icons; a stale "unreadable is fine" costs an error storm, so that answer is
-- never remembered.
--------------------------------------------------------------------------------

local ShouldAurasBeSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret
local restrictedAt = -1

function ns.AurasRestricted()
    if ShouldAurasBeSecret and ShouldAurasBeSecret() then return true end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return true end

    local now = GetTime and GetTime() or 0
    if now == restrictedAt then return true end
    if pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL") then
        return false
    end

    restrictedAt = now
    return true
end
