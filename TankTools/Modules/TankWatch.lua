--------------------------------------------------------------------------------
-- Tank Tools -- co-tank panel
--
-- You and every other tank in the group, side by side: health, debuffs, and
-- which of you is actually holding the boss right now. The question it answers
-- is the tank-swap one -- "how many stacks does the other tank have, and is it
-- my turn yet" -- without looking away from the fight to find their raid frame.
--
-- SETTER-FIRST, WHICH IS THE WHOLE DESIGN
--
-- Inside an instance the client hands back secret values for anything that
-- identifies a unit, and a secret throws the moment it is compared, formatted
-- or used as a table key. But it can be passed straight into a frame setter.
--
-- So every value here goes into SetText, SetValue or SetMinMaxValues *unread*.
-- The health bar fills correctly -- which does not require this addon to know
-- what the numbers are.
--
-- Only three things genuinely need arithmetic, and each degrades on its own
-- rather than taking the panel with it:
--
--   the "94%" text        -> blank when health cannot be read
--   the absorb overlay    -> absent when health cannot be read
--   class colour          -> falls back to white
--
-- AURAS ARE NOT LIKE THAT, AND ASSUMING THEY WERE IS WHY THIS PANEL WENT BLANK
--
-- The first version of this file read debuffs the same way it reads health --
-- walk the indices, hand each field to a setter unread -- on the assumption
-- that a restricted aura would arrive as a secret value. It does not. In an
-- encounter or a Mythic+ the client refuses the enumeration itself: the call
-- throws, three throws in a row latch the ticker off, and the panel stops
-- exactly where it is needed.
--
-- Drawing auras therefore belongs to UI/AuraRow.lua, which hands the job to
-- the client's own aura engine and never reads anything. This file owns the
-- health bar, the roster and the aggro ring, and asks the row for the rest.
--------------------------------------------------------------------------------

local _, ns = ...

local UnitExists          = UnitExists
local UnitName            = UnitName
local UnitHealth          = UnitHealth
local UnitHealthMax       = UnitHealthMax
local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
local UnitIsDeadOrGhost   = UnitIsDeadOrGhost
local UnitIsConnected     = UnitIsConnected
local UnitClassBase       = UnitClassBase
local UnitThreatSituation = UnitThreatSituation
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local GetRaidRosterInfo   = GetRaidRosterInfo
local GetNumGroupMembers  = GetNumGroupMembers
local IsInRaid            = IsInRaid
local GetTime             = GetTime
local twipe               = wipe
local floor               = math.floor
local format              = string.format
local strupper, strlower  = string.upper, string.lower

local Clean, IsTrue, Show = ns.Clean, ns.IsTrue, ns.Show
local Print = ns.Print
local state = ns.state

-- Still being worked on: off unless the flag is set, which is what keeps its
-- commands out of the help and its tab out of the settings window. Everything
-- below still loads and is still covered by the test suite -- being gated
-- costs the module its OnInit, and nothing else.
ns.RegisterFeature{
    name    = "cotanks",
    title   = "Co-tank panel",
    default = false,
    desc    = "Health, debuff stacks and the aggro ring for\n"
              .. "every tank in the group. Renders, but the\n"
              .. "restricted-value behaviour is unproven.",
}

local M = ns.NewModule("tankwatch", {
    feature  = "cotanks",
    defaults = {
        twEnabled     = true,
        twShowSelf    = true,    -- your own block, first in the row
        twMinTanks    = 2,       -- hide below this many tanks in the group
        twSoloDungeon = false,   -- ...except in a five-man, where you are it
        twLayout      = "ROW",   -- ROW | COLUMN -- tanks beside or below
        twAuraAnchor  = "RIGHT", -- LEFT | RIGHT -- which side of the bar
        twMaxAuras    = 5,
        -- Narrows the row to boss and role auras.
        --
        -- OFF by default, which is the opposite of what it looks like it
        -- should be. The argument for turning it on is real -- the aura engine
        -- cannot be asked to sort by stack count, so procs can push the tank
        -- debuff off the end of a five-icon row -- but it is an argument for a
        -- filter whose behaviour we can see, and this one's we cannot: the
        -- engine applies it and never reports what it dropped, so a filter
        -- that matches nothing is indistinguishable from a tank with no
        -- debuffs. DBM ships it off for the same reason. Showing too much is
        -- recoverable by looking; showing nothing is not.
        twBossAuras   = false,
        twBarWidth    = 150,
        twBarHeight   = 20,
        twIconSize    = 22,
        twSpacing     = 14,      -- between one tank's block and the next
        twScale       = 1.0,
        twLocked      = false,
        twShowPercent = true,
        twAggroRing   = true,    -- ring the tank who is holding a boss
        twTooltips    = true,    -- hover a debuff icon for its tooltip
        -- twPoint is deliberately absent: an unset position means "centre",
        -- and it is written as a whole table the first time the panel is
        -- dragged. A default here would have to be a table with string keys,
        -- which is not a shape the settings window can edit.
    },
})

local db          -- resolved in OnInit
local frame       -- the panel
local blocks = {} -- pooled, one per tank on screen

local UPDATE_INTERVAL = 0.2
local MAX_BLOCKS      = 8      -- more tanks than any group can hold
local AURA_RESCAN     = 1.0    -- seconds; the safety net under UNIT_AURA
local BOSS_UNITS      = { "boss1", "boss2", "boss3", "boss4", "boss5" }

local FONT = select(1, GameFontNormal:GetFont())
local BAR  = "Interface\\Buttons\\WHITE8X8"

local ANCHORS = { LEFT = true, RIGHT = true }
local LAYOUTS = { ROW = true, COLUMN = true }

local previewMode = false
local looksSerial = 0     -- bumped when a layout setting changes
local builtSerial = -1

-- Which tank units we are currently drawing, so UNIT_AURA can tell in one
-- lookup whether an event concerns us.
local tracked   = {}
local auraDirty = {}

--------------------------------------------------------------------------------
-- Block construction
--------------------------------------------------------------------------------

local function CreateBlock(index)
    local b = CreateFrame("Frame", nil, frame)

    b.bar = CreateFrame("StatusBar", nil, b)
    b.bar:SetStatusBarTexture(BAR)
    b.bar:SetStatusBarColor(0.25, 0.55, 0.30)

    b.bg = b.bar:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.10, 0.10, 0.10, 0.85)

    -- Absorbs sit on top of the fill rather than extending past it: a shielded
    -- tank at 40% is not at 60%, and drawing it that way would be a lie in the
    -- one direction that gets someone killed.
    b.absorb = b.bar:CreateTexture(nil, "ARTWORK")
    b.absorb:SetColorTexture(0.7, 0.8, 1.0, 0.45)
    b.absorb:Hide()

    b.name = b:CreateFontString(nil, "OVERLAY")
    b.name:SetJustifyH("LEFT")

    b.pct = b:CreateFontString(nil, "OVERLAY")
    b.pct:SetJustifyH("RIGHT")

    -- The aggro ring. Four edges rather than a backdrop, because the signal is
    -- the ring *being there at all* -- presence, not hue -- which is the same
    -- channel the nameplate glyphs use and the one that survives any colour
    -- vision deficiency.
    b.ring = {}
    for i = 1, 4 do
        local t = b:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 0.82, 0.2, 1)
        t:Hide()
        b.ring[i] = t
    end

    b.auras = ns.ui.NewAuraRow(b)

    b:Hide()
    blocks[index] = b
    return b
end

--------------------------------------------------------------------------------
-- Layout
--
-- Runs only when a setting changed, never per tick.
--------------------------------------------------------------------------------

-- The row is told what it should look like and where it sits; how it draws is
-- its own business, and on a client with an aura engine we do not find out.
local function LayoutAuras(b)
    local gap  = 3
    local left = (db.twAuraAnchor == "LEFT")

    b.auras:Configure{
        size     = db.twIconSize,
        max      = db.twMaxAuras,
        spacing  = gap,
        grow     = left and "LEFT" or "RIGHT",
        tooltips = db.twTooltips,
        bossOnly = db.twBossAuras,
    }

    -- Anchored so the first icon is the one nearest the bar on either side.
    if left then
        b.auras:SetPoint("RIGHT", b.bar, "LEFT", -gap, 0)
    else
        b.auras:SetPoint("LEFT", b.bar, "RIGHT", gap, 0)
    end
end

local function BlockSize()
    local auraW = db.twMaxAuras * (db.twIconSize + 3) + 3
    local w = db.twBarWidth + auraW
    local h = db.twBarHeight + 14
    return w, h
end

local function LayoutBlock(b, index)
    local w, h = BlockSize()
    local left = (db.twAuraAnchor == "LEFT")
    local auraW = w - db.twBarWidth

    b:SetSize(w, h)
    b:ClearAllPoints()
    if db.twLayout == "COLUMN" then
        b:SetPoint("TOPLEFT", frame, "TOPLEFT",
                   8, -8 - (index - 1) * (h + db.twSpacing))
    else
        b:SetPoint("TOPLEFT", frame, "TOPLEFT",
                   8 + (index - 1) * (w + db.twSpacing), -8)
    end

    b.bar:ClearAllPoints()
    b.bar:SetSize(db.twBarWidth, db.twBarHeight)
    b.bar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", left and auraW or 0, 0)

    b.name:SetFont(FONT, 12, "OUTLINE")
    b.name:ClearAllPoints()
    b.name:SetPoint("BOTTOMLEFT", b.bar, "TOPLEFT", 0, 2)
    b.name:SetWidth(db.twBarWidth * 0.6)

    b.pct:SetFont(FONT, 12, "OUTLINE")
    b.pct:ClearAllPoints()
    b.pct:SetPoint("BOTTOMRIGHT", b.bar, "TOPRIGHT", 0, 2)
    b.pct:SetWidth(db.twBarWidth * 0.4)

    -- Ring the bar, not the whole block: the aura row is information about the
    -- tank, but the bar is the tank.
    local r = b.ring
    r[1]:ClearAllPoints(); r[1]:SetPoint("TOPLEFT", b.bar, -2, 2)
    r[1]:SetPoint("TOPRIGHT", b.bar, 2, 2);      r[1]:SetHeight(2)
    r[2]:ClearAllPoints(); r[2]:SetPoint("BOTTOMLEFT", b.bar, -2, -2)
    r[2]:SetPoint("BOTTOMRIGHT", b.bar, 2, -2);  r[2]:SetHeight(2)
    r[3]:ClearAllPoints(); r[3]:SetPoint("TOPLEFT", b.bar, -2, 2)
    r[3]:SetPoint("BOTTOMLEFT", b.bar, -2, -2);  r[3]:SetWidth(2)
    r[4]:ClearAllPoints(); r[4]:SetPoint("TOPRIGHT", b.bar, 2, 2)
    r[4]:SetPoint("BOTTOMRIGHT", b.bar, 2, -2);  r[4]:SetWidth(2)

    LayoutAuras(b)
end

local function LayoutPanel(count)
    local w, h = BlockSize()
    local run = (count - 1) * db.twSpacing + 16
    if db.twLayout == "COLUMN" then
        frame:SetSize(w + 16, count * h + run)
    else
        frame:SetSize(count * w + run, h + 16)
    end
    frame:SetScale(db.twScale)
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function HoldingABoss(unit)
    for i = 1, #BOSS_UNITS do
        local boss = BOSS_UNITS[i]
        if UnitExists(boss) then
            -- Readable 0-3 even inside an instance, which is the whole reason
            -- this indicator can exist at all. 2 and 3 both mean "highest
            -- threat"; 3 is merely comfortable about it.
            local s = Clean(UnitThreatSituation(unit, boss))
            if type(s) == "number" and s >= 2 then return true end
        end
    end
    return false
end

local function UpdateName(b, unit)
    -- Straight into the setter, unread. A secret name renders as whatever the
    -- client chooses to show for it; asking what it says would throw.
    b.name:SetText(UnitName(unit))

    local class = Clean(UnitClassBase and UnitClassBase(unit))
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then
        b.name:SetTextColor(c.r, c.g, c.b)
    else
        b.name:SetTextColor(1, 1, 1)
    end
end

local function UpdateHealth(b, unit)
    -- Both may be secret. Neither is read.
    b.bar:SetMinMaxValues(0, UnitHealthMax(unit))
    b.bar:SetValue(UnitHealth(unit))

    local hp    = Clean(UnitHealth(unit))
    local hpMax = Clean(UnitHealthMax(unit))
    local readable = type(hp) == "number" and type(hpMax) == "number" and hpMax > 0

    if db.twShowPercent and readable then
        b.pct:SetText(floor(hp / hpMax * 100 + 0.5) .. "%")
    else
        b.pct:SetText("")
    end

    -- The absorb overlay needs to know where the fill ends, which is a
    -- division. It is the one element with no setter-only form, so it is
    -- simply absent when health cannot be read.
    local absorb = Clean(UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(unit))
    if readable and type(absorb) == "number" and absorb > 0 then
        local w = db.twBarWidth
        local startX = (hp / hpMax) * w
        local width  = (absorb / hpMax) * w
        if startX + width > w then width = w - startX end
        if width > 0.5 then
            b.absorb:ClearAllPoints()
            b.absorb:SetPoint("TOPLEFT", b.bar, "TOPLEFT", startX, 0)
            b.absorb:SetSize(width, db.twBarHeight)
            b.absorb:Show()
        else
            b.absorb:Hide()
        end
    else
        b.absorb:Hide()
    end

    -- Dead is worth calling out even though the empty bar implies it, because
    -- an empty bar also means "out of range". IsTrue answers only on a
    -- readable value, so an unreadable one leaves the block alone.
    local dead = IsTrue(UnitIsDeadOrGhost(unit))
    local gone = UnitIsConnected and Clean(UnitIsConnected(unit)) == false
    if dead or gone then
        b.bar:SetStatusBarColor(0.35, 0.35, 0.35)
        b.pct:SetText(dead and "dead" or "offline")
    else
        b.bar:SetStatusBarColor(0.25, 0.55, 0.30)
    end
end

local function ShowRing(b, on)
    for i = 1, 4 do b.ring[i]:SetShown(on) end
end

-- Which units the panel should be drawing, in order.
local shownUnits = {}

local function CollectUnits()
    twipe(shownUnits)

    if previewMode then
        -- The player, repeated. Enough to size and place the panel against
        -- something real, and it needs no group.
        for i = 1, 3 do shownUnits[i] = "player" end
        return shownUnits
    end

    local tanks = ns.tankUnits
    local me    = ns.selfUnit
    for i = 1, #tanks do
        local u = tanks[i]
        -- In a raid we are drawn under our raid token, not "player", so the
        -- comparison has to be against whatever Core resolved us to. If it
        -- could not resolve us at all, nothing matches and our own bar cannot
        -- be hidden -- which is the honest outcome of not knowing which one
        -- we are, and better than hiding somebody else's.
        if (u ~= me or db.twShowSelf) and UnitExists(u) then
            shownUnits[#shownUnits + 1] = u
        end
    end
    return shownUnits
end

local function Hide()
    if frame:IsShown() then
        frame:Hide()
        twipe(tracked)
        twipe(shownUnits)

        -- Forget which unit each block was drawing. While hidden, UNIT_AURA is
        -- ignored (nothing is tracked), so a block that came back holding the
        -- same unit would have kept whatever icons it had when it went away --
        -- stale debuffs from the last pull, shown as current.
        for i = 1, #blocks do
            blocks[i]._unit = nil
            blocks[i].auras:Hide()
        end
    end
end

-- How many tanks the group needs before the panel is worth the screen space.
--
-- In a five-man you are normally the only tank, so the tank-swap question the
-- panel exists to answer is not in play, and the default minimum of two keeps
-- it off screen. But your own debuffs are drawn by exactly the code that draws
-- a co-tank's in a raid -- same reads, same setters, same restrictions -- and a
-- dungeon is where that can be checked without asking nineteen other people to
-- hold. So "solo in dungeons" drops the minimum to one, and only there: not in
-- the open world, not in a battleground, and not while you are standing in a
-- capital city with a panel of yourself in the way.
local function MinTanks()
    if db.twSoloDungeon and state.instanceType == "party" then return 1 end
    return db.twMinTanks
end

local function Refresh()
    if not db.twEnabled and not previewMode then return Hide() end

    local units = CollectUnits()
    local count = #units
    if count > MAX_BLOCKS then count = MAX_BLOCKS end

    if not previewMode and count < MinTanks() then return Hide() end
    if count == 0 then return Hide() end

    -- Layout is re-applied only when a setting changed or the number of blocks
    -- did, so the steady state is health and aura writes and nothing else.
    local relayout = (builtSerial ~= looksSerial) or (frame._count ~= count)
    if relayout then
        builtSerial  = looksSerial
        frame._count = count
        LayoutPanel(count)
    end

    twipe(tracked)

    for i = 1, count do
        local unit = units[i]
        local b = blocks[i] or CreateBlock(i)
        if relayout then LayoutBlock(b, i) end

        tracked[unit] = true

        -- A block's occupant only changes on a roster event, which clears
        -- _unit -- so the name and class colour are written once per occupant
        -- rather than five times a second. That also keeps a secret name out
        -- of a per-tick code path for no benefit.
        local newOccupant = (b._unit ~= unit) or relayout
        if newOccupant then UpdateName(b, unit) end

        UpdateHealth(b, unit)

        -- Binding the row to a unit is idempotent, so this is the one call
        -- that has to happen every tick: it is what re-attaches a block to a
        -- new occupant after a roster change.
        b.auras:SetUnit(unit)

        -- UNIT_AURA is the fast path; the timer under it is the guarantee. The
        -- engine drives itself off its own events, but "the icons were empty
        -- for two whole boss fights" is a far worse failure than a nudge every
        -- second, and an event we never receive is indistinguishable from a
        -- tank with no debuffs.
        local now = GetTime()
        if newOccupant or auraDirty[unit]
           or (now - (b._auraAt or 0)) >= AURA_RESCAN then
            auraDirty[unit] = nil
            b._auraAt = now
            b.auras:Refresh()
        end

        ShowRing(b, db.twAggroRing and not previewMode and HoldingABoss(unit))

        b._unit = unit
        b:Show()
    end

    for i = count + 1, #blocks do
        blocks[i].auras:Hide()
        blocks[i]:Hide()
    end

    if not frame:IsShown() then frame:Show() end
end

function ns.RefreshTankWatch()
    if db then Refresh() end
end

function ns.TankWatchLooksChanged()
    looksSerial = looksSerial + 1
    ns.RefreshTankWatch()
end

function ns.SetTankWatchPreview(on)
    previewMode = on and true or false
    ns.RefreshTankWatch()
    return previewMode
end

function ns.GetTankWatchPreview()
    return previewMode
end

--------------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------------

local function BuildFrame()
    local f = CreateFrame("Frame", "TankToolsTankWatchFrame", UIParent)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    f:SetSize(200, 60)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")

    f:SetScript("OnDragStart", function(self)
        if not db.twLocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.twPoint = { point, relPoint, x, y }
    end)

    -- Shown only while unlocked, so the panel is invisible furniture in a
    -- fight and a draggable object the moment you want to move it.
    f.grip = f:CreateTexture(nil, "BACKGROUND")
    f.grip:SetAllPoints()
    f.grip:SetColorTexture(1, 1, 1, 0.08)
    f.grip:Hide()

    f:Hide()
    frame = f
    return f
end

local function ApplyPosition()
    local p = db.twPoint
    if type(p) ~= "table" or #p < 4 then return end
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

local function ApplyLock()
    frame:EnableMouse(not db.twLocked)
    frame.grip:SetShown(not db.twLocked)
end

--------------------------------------------------------------------------------
-- Module lifecycle
--------------------------------------------------------------------------------

function M:OnInit()
    db = self.db

    BuildFrame()
    ApplyPosition()
    ApplyLock()

    -- Everything on the shared ticker, including the aura work, so the whole
    -- feature sits behind one failure latch. If the client starts restricting
    -- something read here, the panel stops -- once, naming the error -- and
    -- the nameplate markers carry on.
    ns.RegisterTicker("tankwatch", "co-tank panel", UPDATE_INTERVAL, Refresh)

    -- UNIT_AURA only marks the unit dirty; the reading happens on the tick, so
    -- it is inside the latch and cannot fire faster than the panel redraws.
    ns.RegisterEvent("UNIT_AURA", function(_, unit)
        if tracked[unit] then auraDirty[unit] = true end

        -- Our own auras arrive under "player", but in a raid we are drawn
        -- under a raid token -- so without this our own bar would be the one
        -- block whose debuffs never moved.
        local me = ns.selfUnit
        if unit == "player" then
            if me ~= "player" and tracked[me] then auraDirty[me] = true end
        elseif unit == me and tracked.player then
            auraDirty.player = true
        end
    end)

    -- The roster changing can change who is drawn, and the tokens are recycled
    -- -- raid3 is a different person after someone leaves -- so nothing about
    -- the old occupant may survive into the new one.
    ns.RegisterEvents({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }, function()
        twipe(auraDirty)
        for i = 1, #blocks do blocks[i]._unit = nil end
        if previewMode then
            previewMode = false
            ns.RefreshOptions()
        end
    end)
end

--------------------------------------------------------------------------------
-- Diagnostics
--
-- /tt cotanks. The panel is written so that it renders whether or not these
-- reads are restricted -- this is how you find out which of the three
-- degradations are actually in play, without having to notice a missing
-- percentage mid-pull.
--------------------------------------------------------------------------------

local function BlockFor(unit)
    for i = 1, #blocks do
        if blocks[i]._unit == unit then return blocks[i] end
    end
end

local function DumpTanks()
    local tanks = ns.tankUnits
    Print("|cffffff00---- co-tanks ----|r")
    Print(format("instance=%s (%s)  tanks=%d  drawn=%d  min=%d",
                 Show(state.inInstance), tostring(state.instanceType),
                 #tanks, #shownUnits, MinTanks()))

    -- Which slot the client says we are. A nil here is what put two copies of
    -- us on screen, so it is worth stating outright rather than inferring.
    Print(format("UnitInRaid(player)=%s  ->  we are drawn as |cffffff00%s|r",
                 Show(UnitInRaid("player")), tostring(ns.selfUnit)))

    Print(format("aura engine=%s   auras restricted right now=%s",
                 ns.HaveAuraEngine() and "|cff00ff00yes|r" or "|cffff4040no|r",
                 ns.AurasRestricted() and "|cffff8000yes|r" or "|cff00ff00no|r"))

    local ticker = ns.GetTicker("tankwatch")
    if ticker and (ticker.disabled or (ticker.failures or 0) > 0) then
        Print(format("|cffff4040ticker failures=%d disabled=%s|r: %s",
                     ticker.failures or 0, tostring(ticker.disabled),
                     tostring(ticker.err)))
    end

    -- The roster, every member, with how each role resolved. Printed always
    -- and not just when a tank is missing, because "the panel did not appear"
    -- and "it appeared with the wrong people" have the same root and this is
    -- the line that separates them.
    --
    -- combatRole is the spec-derived role from the raid roster and is what the
    -- addon prefers; assigned is what the person queued as, which goes stale
    -- on a spec swap. If combatRole reads nil here, the addon is falling back
    -- to assigned for everyone, and in a manually formed raid that is often
    -- NONE -- which is a group with no tanks as far as the panel can tell.
    Print("|cffffff00roster:|r")
    local n = GetNumGroupMembers() or 0
    local raid = IsInRaid()
    for i = 1, (raid and n or n - 1) do
        local u = raid and ("raid" .. i) or ("party" .. i)
        if UnitExists(u) then
            local combatRole = raid and GetRaidRosterInfo
                               and Show(select(12, GetRaidRosterInfo(i)))
                               or "|cff888888n/a|r"
            Print(format("    %-7s %-14s combatRole=%s  assigned=%s%s",
                         u, tostring(Clean(UnitName(u)) or "?"),
                         combatRole, Show(UnitGroupRolesAssigned(u)),
                         (u == ns.selfUnit) and "  |cff00ff00<- us|r" or ""))
        end
    end
    if not raid then
        Print(format("    %-7s %-14s our own spec says tank=%s",
                     "player", tostring(Clean(UnitName("player")) or "?"),
                     Show(state.isTankRole)))
    end

    if #tanks == 0 then
        Print("|cffff8000No tanks counted.|r The panel needs "
              .. tostring(db.twMinTanks) .. " -- see the roster above for why "
              .. "each member was not one.")
        return
    end

    for i = 1, #tanks do
        local u = tanks[i]
        Print(format("|cffffff00%s|r  name=%s", u, Show(UnitName(u))))
        Print(format("    health=%s / %s   absorbs=%s",
                     Show(UnitHealth(u)), Show(UnitHealthMax(u)),
                     Show(UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(u))))
        Print(format("    class=%s  dead=%s  connected=%s",
                     Show(UnitClassBase and UnitClassBase(u)),
                     Show(UnitIsDeadOrGhost(u)),
                     Show(UnitIsConnected and UnitIsConnected(u))))

        -- Whether the row is live, and how it is drawing. The interesting
        -- distinction is no longer "does the index walk agree with
        -- ForEachAura" -- both are denied together -- but "is the engine
        -- doing the drawing", because that is what decides whether the icons
        -- survive the pull.
        local b = BlockFor(u)
        local row = b and b.auras
        if not row then
            Print("    debuffs: |cff888888no block drawing this unit|r")
        else
            local r = row:Report()
            if r.container then
                Print(format("    debuffs: |cff00ff00aura engine|r  "
                             .. "group=%s  buttons built=%d  bound=%s",
                             tostring(r.group), r.built, tostring(r.bound)))
                Print(format("      container shown=%s rect=%s   "
                             .. "host shown=%s   want %dx%d",
                             tostring(r.shown), r.rect, tostring(r.hostShown),
                             r.width, r.size))
                Print(format("      filter: bossOrRoleAura=%s  max=%d",
                             tostring(r.bossOnly), r.max))
            elseif r.engine then
                Print("    debuffs: |cffff4040the engine exists but this row "
                      .. "could not use it|r -- fell back to reading")
            else
                Print(format("    debuffs: |cffff8000read by the addon|r -- "
                             .. "no aura engine on this client. drawn=%s",
                             tostring(row:Count() or 0)))
            end
            if r.err then
                Print("      |cffff4040build failed:|r " .. r.err)
            end
            if r.wireErr then
                Print("      |cffff4040button wiring denied:|r " .. r.wireErr)
            end
        end

        -- The read the addon is no longer allowed to make, reported anyway:
        -- this is the line that tells you whether the restriction is on right
        -- now, which is the first thing to know when a row looks wrong.
        local okRead, a = pcall(C_UnitAuras.GetAuraDataByIndex, u, 1, "HARMFUL")
        if not okRead then
            Print("    direct read: |cffff4040denied|r -- the client refuses "
                  .. "aura enumeration here")
        elseif a then
            Print(format("    direct read: icon=%s stacks=%s dur=%s exp=%s",
                         Show(a.icon), Show(a.applications),
                         Show(a.duration), Show(a.expirationTime)))
        else
            Print("    direct read: |cff888888allowed, nothing at index 1|r")
        end


        for j = 1, #BOSS_UNITS do
            if UnitExists(BOSS_UNITS[j]) then
                Print(format("    threat vs %s = %s", BOSS_UNITS[j],
                             Show(UnitThreatSituation(u, BOSS_UNITS[j]))))
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommandSection("co-tanks:", 25)

ns.RegisterCommand{
    name = "tw", feature = "cotanks", section = "co-tanks:", order = 10,
    desc = "toggle the co-tank panel",
    handler = function()
        db.twEnabled = not db.twEnabled
        ns.RefreshTankWatch()
        Print("co-tank panel " .. (db.twEnabled and "enabled." or "disabled."))
    end,
}

ns.RegisterCommand{
    name = "twlock", feature = "cotanks", section = "co-tanks:", order = 20,
    desc = "lock the panel in place",
    handler = function()
        db.twLocked = not db.twLocked
        ApplyLock()
        Print("co-tank panel " .. (db.twLocked and "locked." or "unlocked -- drag to move."))
    end,
}

ns.RegisterCommand{
    name = "twsolo", feature = "cotanks", section = "co-tanks:", order = 25,
    desc = "show the panel in dungeons when you are the only tank",
    handler = function()
        db.twSoloDungeon = not db.twSoloDungeon
        ns.RefreshTankWatch()
        if db.twSoloDungeon then
            Print("co-tank panel shows |cff00ff00solo in five-mans|r -- your own "
                  .. "bar and debuffs, drawn by the same code that draws a "
                  .. "co-tank's in a raid.")
        else
            Print("co-tank panel needs " .. db.twMinTanks
                  .. " tanks again, dungeons included.")
        end
    end,
}

ns.RegisterCommand{
    name = "twtest", feature = "cotanks", aliases = { "twpreview" },
    section = "co-tanks:", order = 30,
    desc = "show the panel with placeholder tanks",
    handler = function()
        local on = ns.SetTankWatchPreview(not previewMode)
        if on then
            Print("co-tank preview |cff00ff00on|r -- three blocks of you, so "
                  .. "you can place and size the panel solo. Ends on zone "
                  .. "change, or run |cffffff00/tt twtest|r again.")
        else
            Print("co-tank preview |cffff0000off|r.")
        end
    end,
}

ns.RegisterCommand{
    name = "twlayout", feature = "cotanks", args = "<l>", section = "co-tanks:", order = 40,
    desc = "tanks side by side (row) | stacked (column)",
    handler = function(_, larg)
        local l = larg and strupper(larg) or ""
        -- The words people reach for first, mapped onto the two layouts.
        if l == "SIDE" or l == "HORIZONTAL" or l == "H" then l = "ROW"    end
        if l == "STACKED" or l == "VERTICAL" or l == "V" then l = "COLUMN" end
        if LAYOUTS[l] then
            db.twLayout = l
            ns.TankWatchLooksChanged()
            Print("tanks laid out " ..
                  (l == "ROW" and "side by side." or "stacked, one per line."))
        else
            Print("usage: /tt twlayout row | column")
        end
    end,
}

ns.RegisterCommand{
    name = "twtips", feature = "cotanks", section = "co-tanks:", order = 60,
    desc = "toggle debuff tooltips on hover",
    handler = function()
        db.twTooltips = not db.twTooltips
        ns.TankWatchLooksChanged()
        Print("debuff tooltips " .. (db.twTooltips and "enabled."
              or "disabled -- the icons no longer take the mouse."))
    end,
}

ns.RegisterCommand{
    name = "twanchor", feature = "cotanks", args = "<s>", section = "co-tanks:", order = 50,
    desc = "debuffs on the left | right",
    handler = function(_, larg)
        local a = larg and strupper(larg) or ""
        if ANCHORS[a] then
            db.twAuraAnchor = a
            ns.TankWatchLooksChanged()
            Print("debuffs shown to the " .. strlower(a) .. " of the bar.")
        else
            Print("usage: /tt twanchor left | right")
        end
    end,
}

ns.RegisterCommand{
    name = "cotanks", feature = "cotanks", section = "commands:", order = 50,
    desc = "dump what the co-tank reads return",
    handler = DumpTanks,
}

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

ns.RegisterStatusProvider(30, function(yn)
    Print("co-tank panel: " .. yn(db.twEnabled)
          .. "  |  tanks in group: " .. #ns.tankUnits
          .. "  |  drawn: " .. #shownUnits
          .. "  |  preview: " .. yn(previewMode))

    local ticker = ns.GetTicker("tankwatch")
    if ticker and ticker.disabled then
        Print("|cffff4040Co-tank panel stopped.|r Last error: " .. tostring(ticker.err))
    elseif db.twEnabled and #ns.tankUnits < MinTanks() and not previewMode then
        Print("|cffff8000Panel hidden:|r fewer than " .. MinTanks()
              .. " tanks in the group. |cffffff00/tt twtest|r shows it anyway"
              .. (db.twSoloDungeon and "."
                  or ", and |cffffff00/tt twsolo|r shows it solo in dungeons."))
    end
end, "cotanks")

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

ns.RegisterOptionsSection{
    page = "Co-tanks", pageOrder = 20, column = "left", order = 10,
    feature = "cotanks",
    build = function(f, x, y)
        local ui = ns.ui
        local apply = ns.TankWatchLooksChanged

        y = ui.Header(f, "Co-tank panel", x, y)
        y = ui.Check(f, x, y, "Show the panel", db, "twEnabled", ns.RefreshTankWatch)
        y = ui.Check(f, x, y, "Include my own bar", db, "twShowSelf", apply)
        y = ui.Check(f, x, y, "Show health percent", db, "twShowPercent", apply)
        y = ui.Check(f, x, y, "Ring whoever is holding a boss", db, "twAggroRing", apply)
        y = ui.Check(f, x, y, "Lock in place", db, "twLocked", ApplyLock)

        y = y - 10
        y = ui.Header(f, "Layout", x, y)
        y = ui.Segmented(f, x, y, "Tanks", db, "twLayout", {
            { text = "Side by side", value = "ROW"    },
            { text = "Stacked",      value = "COLUMN" },
        }, apply)

        y = y - 6
        y = ui.Header(f, "Debuffs", x, y)
        y = ui.Segmented(f, x, y, "Side of the bar", db, "twAuraAnchor", {
            { text = "Left",  value = "LEFT"  },
            { text = "Right", value = "RIGHT" },
        }, apply)
        y = ui.Slider(f, x, y, "How many icons", db, "twMaxAuras", 1, 8, 1, 0, apply)
        y = ui.Slider(f, x, y, "Icon size", db, "twIconSize", 12, 40, 1, 0, apply)
        y = ui.Check(f, x, y, "Tooltip on hover", db, "twTooltips", apply)
        y = ui.Check(f, x, y, "Boss and role debuffs only", db, "twBossAuras", apply)

        return ui.Note(f, x, y,
            "Icons are drawn by the game's own aura display, which is\n"
            .. "what lets them keep working in a boss fight -- but it\n"
            .. "sorts by time left, not by stacks. The filter trades\n"
            .. "a tidier row for not being able to see what it drops.")
    end,
}

ns.RegisterOptionsSection{
    page = "Co-tanks", pageOrder = 20, column = "right", order = 10,
    feature = "cotanks",
    build = function(f, x, y)
        local ui = ns.ui
        local apply = ns.TankWatchLooksChanged

        y = ui.Header(f, "Size and position", x, y)
        y = ui.Slider(f, x, y, "Bar width", db, "twBarWidth", 80, 320, 5, 0, apply)
        y = ui.Slider(f, x, y, "Bar height", db, "twBarHeight", 8, 48, 1, 0, apply)
        y = ui.Slider(f, x, y, "Gap between tanks", db, "twSpacing", 0, 60, 1, 0, apply)
        y = ui.Slider(f, x, y, "Panel scale", db, "twScale", 0.5, 2.0, 0.05, 2, apply)
        y = ui.Slider(f, x, y, "Hide below this many tanks", db, "twMinTanks",
                      1, 4, 1, 0, ns.RefreshTankWatch)
        y = ui.Check(f, x, y, "...but show it solo in dungeons",
                     db, "twSoloDungeon", ns.RefreshTankWatch)

        y = ui.Button(f, x, y, "Preview panel with placeholder tanks",
            function() ns.SetTankWatchPreview(not previewMode) end,
            function()
                return previewMode and "Stop panel preview"
                       or "Preview panel with placeholder tanks"
            end)

        return ui.Note(f, x, y,
            "Unlock the panel to drag it; the grey block is the drag\n"
            .. "handle and disappears once locked. Preview fills it with\n"
            .. "three copies of you so you can place it solo.\n\n"
            .. "In a five-man you are usually the only tank, so the panel\n"
            .. "stays hidden. Showing it solo there draws your own health\n"
            .. "and debuffs through the same code a co-tank goes through\n"
            .. "in a raid -- a cheap way to see what the client will and\n"
            .. "will not hand over before it matters.")
    end,
}
