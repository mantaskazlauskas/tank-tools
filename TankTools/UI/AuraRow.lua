--------------------------------------------------------------------------------
-- Tank Tools -- the aura row
--
-- A horizontal strip of debuff icons for one unit, and the only place in the
-- addon that draws auras.
--
-- WHY THIS IS NOT JUST A LOOP OVER GetAuraDataByIndex
--
-- It used to be, and that is precisely the code that went blank in every boss
-- fight. Since Midnight the client refuses aura *enumeration* while auras are
-- secret -- an encounter, a Mythic+ -- and refuses it by throwing rather than
-- by returning nothing. No amount of laundering the result helps when the call
-- itself does not return. See ns.AurasRestricted in Core/Secret.lua.
--
-- What replaces it is the client's own aura engine: an AuraContainer frame is
-- told which unit and which filter, and it draws the icons itself. We hand it
-- the regions to draw into -- a texture, a cooldown, a font string -- and it
-- fills them in. The addon never learns what the debuff is, how many stacks it
-- has, or when it ends, and does not need to: the tank reads the icon.
--
-- That inversion is the entire design. Every visible thing here is a region we
-- own and the engine writes; nothing is a value we read and then draw.
--
-- WHAT IT COSTS
--
-- Two things, and both are stated plainly rather than worked around:
--
--   No stack sort. The engine sorts by its own rules or by expiry, and cannot
--   be asked for "biggest stack first" -- so the icon you care about is not
--   pinned to a fixed position the way it was. The mitigation is filtering
--   rather than sorting: `bossOnly` narrows the row to boss and role auras, so
--   what is left is almost entirely the debuff you are watching.
--
--   No count. The row cannot report how many icons it is showing, because it
--   does not know. /tt cotanks says so rather than printing a zero.
--
-- THE FALLBACK
--
-- On a client with no aura engine the row falls back to reading the auras
-- itself, which is the old behaviour and is correct wherever it is allowed --
-- it even sorts by stacks. It is guarded by ns.AurasRestricted() so that it
-- goes quiet instead of throwing when it is not.
--------------------------------------------------------------------------------

local _, ns = ...

local CreateFrame = CreateFrame
local floor       = math.floor
local tsort       = table.sort

local Clean, IsSecret = ns.Clean, ns.IsSecret

local ui = ns.ui

local MAX_AURA_SCAN = 40   -- the client's own per-unit aura cap

local FONT = select(1, GameFontNormal:GetFont())

-- Debuffs that are on you constantly and say nothing about a tank swap. The
-- engine takes an exclusion list but will not tell us what it dropped, so this
-- is written once and never inspected -- the same list DBM ships, because it
-- is the same problem.
local NEVER_SHOW = {
    [57723]  = true,   -- Exhaustion
    [57724]  = true,   -- Sated
    [80354]  = true,   -- Temporal Displacement
    [390435] = true,   -- Exhaustion
    [264689] = true,   -- Fatigued
    [160455] = true,   -- Fatigued
    [95809]  = true,   -- Insanity
    [124255] = true,   -- Stagger
    [71041]  = true,   -- Dungeon Deserter
    [206151] = true,   -- Challenger's Burden
}

--------------------------------------------------------------------------------
-- The engine, and whether we have one
--
-- Probed once, by building a container and asking whether it answers the three
-- calls the row needs. A version check would be a guess about which build the
-- widget landed in; this is the question we actually care about.
--------------------------------------------------------------------------------

local engine   -- nil = not yet probed, false = absent, true = present

local function HaveEngine()
    if engine ~= nil then return engine end
    engine = false

    if C_AddOns and C_AddOns.LoadAddOn and C_AddOns.IsAddOnLoaded
       and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_AuraContainer")
    end

    local ok, f = pcall(CreateFrame, "AuraContainer", nil, UIParent,
                        "CustomAuraContainerTemplate")
    if ok and type(f) == "table"
       and type(f.AddAuraGroup) == "function"
       and type(f.SetUnit) == "function"
       and type(f.SetAuraGroupMaxFrameCount) == "function" then
        f:Hide()
        engine = true
    end

    return engine
end

ns.HaveAuraEngine = HaveEngine

-- Enum tables, with the values DBM falls back to when the globals are absent.
local SORT = rawget(_G, "AuraContainerSortMethod")
             or { Default = 1, ExpirationOnly = 2 }
local SORT_DIR = rawget(_G, "AuraContainerSortDirection")
                 or { Normal = 1, Reverse = 2 }

local function FlowAxis()
    return AnchorUtil and AnchorUtil.FlowLayoutAxis
           and AnchorUtil.FlowLayoutAxis.Horizontal or 1
end

local function FlowDirs(grow)
    local F = AnchorUtil and AnchorUtil.FlowDirection
    if not F then return 1, 1 end
    return (grow == "LEFT") and F.Left or F.Right, F.Down
end

--------------------------------------------------------------------------------
-- Row
--------------------------------------------------------------------------------

local Row = {}
local RowMT = { __index = Row }

local nextKey = 0

-- `parent` hosts the row; the row anchors itself and reports its own width so
-- the caller can lay a block out around it.
function ui.NewAuraRow(parent)
    nextKey = nextKey + 1

    local r = setmetatable({
        parent   = parent,
        groupKey = "TankTools_" .. nextKey,
        look     = { size = 22, max = 5, spacing = 3, grow = "RIGHT" },
        icons    = {},   -- fallback path only
    }, RowMT)

    -- A frame of our own, not the container, and not the block. The container
    -- resizes itself on every layout pass the engine runs, so anchoring the
    -- block's other pieces to it would make them twitch as debuffs come and
    -- go. This one keeps the rect the row was *asked* for.
    r.host = CreateFrame("Frame", nil, parent)
    r.host:SetSize(1, 1)

    return r
end

function Row:IsEngine()
    return self.container ~= nil
end

function Row:SetPoint(...)
    self.host:ClearAllPoints()
    self.host:SetPoint(...)
end

function Row:Width()
    local L = self.look
    return L.max * (L.size + L.spacing) - L.spacing
end

--------------------------------------------------------------------------------
-- Engine path
--------------------------------------------------------------------------------

-- Runs once per button the engine creates, and it is the only window in which
-- the button may be decorated: post-creation writes are denied while auras are
-- secret, which is exactly the fight this row exists for. Everything is
-- pcall-guarded because an error in here aborts the engine's whole button
-- batch, taking the group with it.
local function InitButton(row, button)
    local L = row.look
    row.built = (row.built or 0) + 1

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    -- Trim the stock border so the art sits flush inside our own edge, the
    -- same crop the fallback icons use.
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local edge = button:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0, 0, 0, 1)

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(button)
    cd:SetReverse(true)
    cd:SetHideCountdownNumbers(true)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)

    -- The stack count is why this panel exists, so it sits above the cooldown
    -- swipe in a thick outline rather than tucked into a corner at border size.
    local overlay = CreateFrame("Frame", nil, button)
    overlay:SetAllPoints(button)
    overlay:SetFrameLevel(cd:GetFrameLevel() + 1)
    overlay:EnableMouse(false)

    local count = overlay:CreateFontString(nil, "OVERLAY")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
    count:SetFont(FONT, floor(L.size * 0.62), "THICKOUTLINE")

    -- Regions are created and styled before they are registered: each Set*
    -- makes the engine draw into them immediately, and a font string with no
    -- font assigned errors inside the engine when it does.
    -- Recorded, not swallowed. A button with no icon registered draws
    -- nothing, which is indistinguishable from "no debuffs" -- and that is
    -- precisely the failure this row was written to end.
    local function Wire(what, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then row.wireErr = what .. ": " .. tostring(err) end
        return ok
    end

    Wire("SetIcon", button.SetIcon, button, icon)
    Wire("SetDurationCooldown", button.SetDurationCooldown, button, cd)
    Wire("SetApplicationCount", button.SetApplicationCount, button, count, {})

    -- Engine buttons come click-enabled, and this row sits in the middle of
    -- the screen during a fight. Motion stays on when tooltips are wanted --
    -- the engine supplies the tooltip, which is the only way to get one for an
    -- aura we are not allowed to identify.
    pcall(button.SetMouseClickEnabled, button, false)
    pcall(button.SetMouseMotionEnabled, button, L.tooltips and true or false)
end

local function GroupOptions(row)
    local L = row.look

    -- Write-only: the engine applies these and never reports what they
    -- matched. `isBossOrRoleAura` is the one that matters -- it is what keeps
    -- a five-icon row from filling with procs and leaving the tank debuff off
    -- the end, now that we cannot sort it to the front ourselves.
    local candidateFilters = { excludeSpellIDs = NEVER_SHOW }
    if L.bossOnly then
        candidateFilters.isBossOrRoleAura = true
    else
        candidateFilters.isFromPlayerOrPlayerPet = false
    end

    return {
        maxFrameCount = L.max,
        -- Longest remaining last: a debuff about to fall off is the one with
        -- a decision attached to it.
        sortMethod    = SORT.ExpirationOnly,
        sortDirection = SORT_DIR.Normal,
        candidateFilters = candidateFilters,
        initializeFrame = function(button) InitButton(row, button) end,
        layout = {
            elementWidth   = L.size,
            elementHeight  = L.size,
            elementSpacing = L.spacing,
            lineSpacing    = L.spacing,
        },
    }
end

local function ApplyEngineLayout(row)
    local c, L = row.container, row.look
    local left = (L.grow == "LEFT")
    local corner = left and "TOPRIGHT" or "TOPLEFT"

    c:ClearAllPoints()
    c:SetSize(row:Width(), L.size)
    c:SetPoint(corner, row.host, corner, 0, 0)

    pcall(c.SetFlowLayoutAxis, c, FlowAxis())
    pcall(c.SetFlowLayoutAnchorPoint, c, corner)
    pcall(c.SetFlowLayoutGrowthDirection, c, FlowDirs(L.grow))
    -- One line, always: this is a row beside a health bar, and a second line
    -- would overlap the block below it.
    pcall(c.SetFlowLayoutMaximumLineSize, c, row:Width())
end

local function BuildContainer(row)
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, row.host,
                        "CustomAuraContainerTemplate")
    if not ok or type(c) ~= "table" then
        row.err = "CreateFrame: " .. tostring(c)
        return false
    end

    row.container = c

    -- Anchor and size BEFORE declaring the group. The engine drains its parse
    -- and layout passes from an update armed the moment a group exists, so the
    -- container needs a real rect from the first one -- a 1x1 container lays
    -- its buttons out inside 1x1. Both reference implementations do it in this
    -- order and it costs nothing to match them.
    ApplyEngineLayout(row)

    -- Groups first, unit last. Assigning the unit is what makes the container
    -- work out which events to register for, and that decision is made against
    -- the groups it has at the time -- set the unit first and it registers for
    -- nothing, silently.
    local okGroup, err = pcall(c.AddAuraGroup, c, row.groupKey, "HARMFUL",
                               GroupOptions(row))
    if not okGroup then
        -- The engine builds its buttons through initializeFrame during this
        -- call, so an error in our decoration lands here and takes the whole
        -- group with it. Keeping the message is the difference between a
        -- diagnosable bug and a blank row.
        row.err = "AddAuraGroup: " .. tostring(err)
        row.container = nil
        c:Hide()
        return false
    end

    return true
end

--------------------------------------------------------------------------------
-- Fallback path -- we read the auras ourselves
--------------------------------------------------------------------------------

local auraList = {}   -- scratch, refilled every read
local slots    = {}   -- our own rows, so the client's tables are never written

local function StackKey(a)
    local n = Clean(a.applications)
    return (type(n) == "number") and n or 0
end

local function ByStacks(a, b)
    local ka, kb = StackKey(a), StackKey(b)
    if ka ~= kb then return ka > kb end
    -- Ties break on the original index, never on the table address: table.sort
    -- is not stable, and icons that swap places tick to tick are worse than no
    -- icons at all.
    return a.index < b.index
end

local function ReadAuras(unit, bossOnly)
    local n = 0

    for i = 1, MAX_AURA_SCAN do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
        if not ok or not a then break end

        -- The engine's filter is "boss or role aura" and this one is only
        -- "boss aura" -- the narrower of the two, because it is the only flag
        -- on the data table. The paths therefore agree on what a tank cares
        -- about and can differ at the margins, which is the right way round.
        if not (bossOnly and not Clean(a.isBossAura)) then
            n = n + 1
            local s = slots[n]
            if not s then s = {}; slots[n] = s end
            s.icon           = a.icon
            s.applications   = a.applications
            s.duration       = a.duration
            s.expirationTime = a.expirationTime
            -- The real aura index, not our position in the list: it is what a
            -- tooltip has to be asked for, and filtering has moved the two
            -- apart.
            s.index          = i
            s.instanceID     = a.auraInstanceID
            auraList[n] = s
        end
    end

    for i = n + 1, #auraList do auraList[i] = nil end

    -- Everything harmful is collected, then the stacking ones are sorted to
    -- the front and the rest are truncated by the icon cap. Nothing else is
    -- filtered before sorting, so raising the cap reveals more of the same
    -- list rather than a different one.
    if n > 1 then tsort(auraList, ByStacks) end
    return n
end

local function ShowAuraTooltip(ic)
    local row = ic._row
    if not row or not row.unit or not row.look.tooltips then return end

    GameTooltip:SetOwner(ic, "ANCHOR_RIGHT")

    local ok = false
    if ic._instanceID ~= nil and GameTooltip.SetUnitDebuffByAuraInstanceID then
        ok = pcall(GameTooltip.SetUnitDebuffByAuraInstanceID,
                   GameTooltip, row.unit, ic._instanceID)
    end
    if not ok and ic._index and GameTooltip.SetUnitDebuff then
        ok = pcall(GameTooltip.SetUnitDebuff, GameTooltip, row.unit,
                   ic._index, "HARMFUL")
    end

    if ok then GameTooltip:Show() else GameTooltip:Hide() end
end

local function HideAuraTooltip(ic)
    -- Only ours. Hiding unconditionally would rip away a tooltip that some
    -- other frame put up in the meantime.
    if GameTooltip:IsOwned(ic) then GameTooltip:Hide() end
end

local function CreateIcon(row)
    local ic = CreateFrame("Frame", nil, row.host)
    ic._row = row

    ic.tex = ic:CreateTexture(nil, "ARTWORK")
    ic.tex:SetAllPoints()
    ic.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    ic.edge = ic:CreateTexture(nil, "BACKGROUND")
    ic.edge:SetPoint("TOPLEFT", -1, 1)
    ic.edge:SetPoint("BOTTOMRIGHT", 1, -1)
    ic.edge:SetColorTexture(0, 0, 0, 1)

    ic.cd = CreateFrame("Cooldown", nil, ic, "CooldownFrameTemplate")
    ic.cd:SetAllPoints()
    ic.cd:SetReverse(true)
    ic.cd:SetHideCountdownNumbers(true)

    ic.count = ic:CreateFontString(nil, "OVERLAY")
    ic.count:SetPoint("BOTTOMRIGHT", 2, -2)

    ic:SetScript("OnEnter", ShowAuraTooltip)
    ic:SetScript("OnLeave", HideAuraTooltip)
    -- An icon can be hidden while the cursor is still on it -- the debuff
    -- expires, the tank dies, the panel goes away -- and OnLeave does not fire
    -- for a frame that simply stopped existing on screen.
    ic:SetScript("OnHide",  HideAuraTooltip)

    ic:Hide()
    return ic
end

local function ApplyFallbackLayout(row)
    local L = row.look
    local left = (L.grow == "LEFT")

    for i = 1, L.max do
        local ic = row.icons[i]
        if not ic then
            ic = CreateIcon(row)
            row.icons[i] = ic
        end
        ic:SetSize(L.size, L.size)
        -- Mouse-enabled only when tooltips are wanted: an interactive frame
        -- swallows clicks meant for the world behind it, and this row sits in
        -- the middle of the screen during a fight.
        ic:EnableMouse(L.tooltips and true or false)
        ic:ClearAllPoints()
        if left then
            -- Laid out right-to-left so the first icon stays nearest the bar
            -- whichever side the row is on. The icon you look at should not
            -- move when you flip the anchor.
            ic:SetPoint("RIGHT", row.host, "RIGHT",
                        -(i - 1) * (L.size + L.spacing), 0)
        else
            ic:SetPoint("LEFT", row.host, "LEFT",
                        (i - 1) * (L.size + L.spacing), 0)
        end
        ic.count:SetFont(FONT, floor(L.size * 0.62), "THICKOUTLINE")
    end

    -- Icons left over from a larger cap stay allocated but hidden.
    for i = L.max + 1, #row.icons do row.icons[i]:Hide() end
end

local function DrawFallback(row)
    local L = row.look
    local unit = row.unit

    -- Restricted is not "no debuffs": the icons that are up are the last ones
    -- we were allowed to see, and blanking them would replace stale
    -- information with wrong information. They are left alone, and the caller
    -- is told through :Count() that the row is not live.
    if not unit or ns.AurasRestricted() then
        row.shown = nil
        if not unit then
            for i = 1, #row.icons do row.icons[i]:Hide() end
        end
        return
    end

    local n = ReadAuras(unit, L.bossOnly)
    local shown = (n < L.max) and n or L.max
    row.shown = shown

    for i = 1, L.max do
        local ic = row.icons[i]
        if not ic then break end

        if i <= shown then
            local a = auraList[i]
            ic.tex:SetTexture(a.icon)

            -- Three cases, and collapsing any two of them is a bug:
            --   secret  -> hand it to the font string unread
            --   number  -> draw it only when it is a real stack
            --   nil     -> this debuff does not stack; draw nothing
            local apps = a.applications
            if IsSecret(apps) then
                ic.count:SetText(apps)
            elseif type(apps) == "number" and apps > 1 then
                ic.count:SetText(apps)
            else
                ic.count:SetText("")
            end

            -- The swipe needs expiration minus duration, so it needs both
            -- readable. SetCooldown would accept secrets happily; the
            -- subtraction is what would throw.
            local dur = Clean(a.duration)
            local exp = Clean(a.expirationTime)
            if type(dur) == "number" and type(exp) == "number" and dur > 0 then
                ic.cd:SetCooldown(exp - dur, dur)
            else
                ic.cd:Clear()
            end

            -- What the tooltip needs, refreshed with the icon, so a hover held
            -- across a debuff swap describes what is on screen now.
            ic._instanceID = a.instanceID
            ic._index      = a.index
            if GameTooltip:IsOwned(ic) then ShowAuraTooltip(ic) end

            ic:Show()
        else
            ic:Hide()
        end
    end
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

-- `look` is copied, not kept: the caller's settings table is live, and a row
-- that read it later would re-lay itself out mid-fight when a slider moved.
--
-- Fields: size, max, spacing, grow ("LEFT"|"RIGHT"), tooltips, bossOnly.
function Row:Configure(look)
    local L = self.look
    L.size     = look.size or L.size
    L.max      = look.max or L.max
    L.spacing  = look.spacing or L.spacing
    L.grow     = (look.grow == "LEFT") and "LEFT" or "RIGHT"
    L.tooltips = look.tooltips and true or false
    L.bossOnly = look.bossOnly and true or false

    self.host:SetSize(self:Width(), L.size)

    if not self.container and HaveEngine() then
        if BuildContainer(self) then
            -- Icons from an earlier fallback layout would otherwise sit under
            -- the container drawing the same debuffs twice.
            for i = 1, #self.icons do self.icons[i]:Hide() end
        end
    end

    if self.container then
        ApplyEngineLayout(self)
        local c, o = self.container, GroupOptions(self)
        pcall(c.SetAuraGroupMaxFrameCount, c, self.groupKey, o.maxFrameCount)
        pcall(c.SetAuraGroupCandidateFilters, c, self.groupKey, o.candidateFilters)
        pcall(c.SetAuraGroupLayout, c, self.groupKey, o.layout)
        pcall(c.SetAuraGroupSortMethod, c, self.groupKey,
              o.sortMethod, o.sortDirection)
        -- Buttons already built keep the font size they were initialised with;
        -- the engine owns their geometry, so the only visible drift after a
        -- size change is the stack text, and it corrects on the next reload.
    else
        ApplyFallbackLayout(self)
    end
end

-- Idempotent, and called every tick: rebinding a container is not free, and a
-- block whose occupant has not changed must not be torn down and rebuilt five
-- times a second.
function Row:SetUnit(unit)
    if unit == self.unit and self.host:IsShown() == (unit ~= nil) then return end
    self.unit = unit
    self.host:SetShown(unit ~= nil)

    if self.container then
        local c = self.container
        if unit then
            pcall(c.SetUnit, c, unit)
            pcall(c.SetEnabled, c, true)
            c:Show()
            pcall(c.UpdateAllAuras, c)
        else
            pcall(c.SetEnabled, c, false)
            c:Hide()
        end
        return
    end

    DrawFallback(self)
end

-- Called on the caller's own schedule -- an aura event, or the periodic safety
-- net under it. The engine is event-driven and needs nothing from us, but
-- asking it to re-read is cheap and covers the same "an event never arrived"
-- failure the fallback's timer exists for.
function Row:Refresh()
    if self.container then
        if self.unit then pcall(self.container.UpdateAllAuras, self.container) end
        return
    end
    DrawFallback(self)
end

function Row:Hide()
    self:SetUnit(nil)
end

-- How many icons are on screen, or nil when that is not knowable -- which is
-- the normal answer on the engine path, and the honest one. Only /tt cotanks
-- asks.
function Row:Count()
    if self.container then return nil end
    return self.shown
end

-- Everything the row knows about its own state, for /tt cotanks.
--
-- This exists because "no debuffs appeared" has at least five distinct causes
-- -- no engine, a container that would not build, a group the engine rejected,
-- a decoration call it denied, and a candidate filter that matched nothing --
-- and they are indistinguishable on screen. Each one is reported separately so
-- the next report says which.
function Row:Report()
    local L = self.look
    local t = {
        engine   = HaveEngine(),
        bound    = self.unit,
        err      = self.err,
        wireErr  = self.wireErr,
        bossOnly = L.bossOnly,
        max      = L.max,
        size     = L.size,
        width    = self:Width(),
        hostShown = self.host:IsShown(),
    }

    local c = self.container
    if c then
        t.container = true
        t.built     = self.built or 0
        local okHas, has = pcall(c.HasAuraGroup, c, self.groupKey)
        t.group     = okHas and has or false
        t.shown     = c:IsShown()
        local w, h  = c:GetWidth(), c:GetHeight()
        t.rect      = (w or 0) .. "x" .. (h or 0)
    end

    return t
end
