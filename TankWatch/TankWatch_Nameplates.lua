--------------------------------------------------------------------------------
-- TankWatch -- nameplate aggro marker
--
-- Accessibility module. EllesmereUI already recolors nameplates by threat, but
-- a hue shift is exactly the channel that fails for the ~8% of men and ~0.5% of
-- women with a color vision deficiency -- and red/green, the pair WoW threat
-- UI leans on hardest, is the pair protanopia and deuteranopia collapse first.
--
-- So this module adds a channel that carries no color information at all:
--
--   1. SHAPE     -- a glyph with a distinct silhouette ("!" by default).
--   2. PRESENCE  -- it appears only on mobs you do NOT hold. Nothing on screen
--                   means everything is yours. The signal is the glyph existing,
--                   which is readable in full grayscale.
--   3. MOTION    -- an optional pulse; movement is orthogonal to color entirely.
--   4. CONTRAST  -- thick black outline, so it reads against any backdrop
--                   regardless of how the nameplate underneath is colored.
--
-- Color is applied last and is pure decoration: strip it and every bit of
-- information above survives intact.
--
-- Nothing here touches EllesmereUI's nameplates. The marker is a child frame
-- of Blizzard's base nameplate container, so EUI keeps full ownership of the
-- plate itself and the two compose instead of fighting.
--------------------------------------------------------------------------------

local _, ns = ...

local C_NamePlate      = C_NamePlate
local UnitGUID         = UnitGUID
local UnitIsUnit       = UnitIsUnit
local UnitCanAttack    = UnitCanAttack

-- One marker per *plate frame*. Blizzard recycles a small fixed pool of plates
-- and hands the same frames back out for new units, so keying on the frame
-- means we allocate at most ~40 markers for the whole session.
local markerByPlate = {}
local activeByUnit  = {}

local FONT = select(1, GameFontNormal:GetFont())

-- Bright, high-luminance choices that stay distinguishable under protanopia,
-- deuteranopia and tritanopia alike. Every one of them also survives being
-- rendered in pure grayscale, which is the real test.
local COLOR_PRESETS = {
    white   = { 1.00, 1.00, 1.00 },
    yellow  = { 1.00, 0.92, 0.15 },
    cyan    = { 0.35, 0.95, 1.00 },
    magenta = { 1.00, 0.45, 0.90 },
    orange  = { 1.00, 0.60, 0.10 },
}
ns.COLOR_PRESETS = COLOR_PRESETS

local ANCHORS = {
    LEFT   = { "RIGHT",  "LEFT",   -6,  0 },
    RIGHT  = { "LEFT",   "RIGHT",   6,  0 },
    TOP    = { "BOTTOM", "TOP",     0,  6 },
    BOTTOM = { "TOP",    "BOTTOM",  0, -6 },
}

--------------------------------------------------------------------------------
-- Marker construction
--------------------------------------------------------------------------------

local function CreateMarker(plate)
    local m = CreateFrame("Frame", nil, plate)
    m:SetSize(1, 1)

    m.text = m:CreateFontString(nil, "OVERLAY")
    m.text:SetPoint("CENTER")

    -- BOUNCE alpha pulse: the same idiom EllesmereUI uses for its own nameplate
    -- glows, so it is known-good on this client. It bottoms out at 0.55 rather
    -- than near zero -- this is an alert, and it must stay legible at every
    -- point in the cycle, including for anyone who finds motion hard to track.
    local ag = m:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0.55)
    a:SetDuration(0.45)
    a:SetSmoothing("IN_OUT")
    m.pulse = ag

    m:Hide()
    return m
end

local function AcquireMarker(plate)
    local m = markerByPlate[plate]
    if not m then
        m = CreateMarker(plate)
        markerByPlate[plate] = m
    end
    return m
end

-- Applies everything that depends on settings rather than on threat state.
-- Called on a real change only, so the per-tick path stays free of SetFont and
-- SetPoint churn.
local function ApplyLook(m, plate)
    local db = ns.db
    m.text:SetFont(FONT, db.npSize, "THICKOUTLINE")

    -- Size the frame to the glyph. Left at 1x1 the text would be centered on a
    -- point and spill halfway back over the nameplate, so "next to the plate"
    -- would drift as the glyph size changed.
    m:SetSize(db.npSize, db.npSize)

    local a = ANCHORS[db.npAnchor] or ANCHORS.LEFT
    m:ClearAllPoints()
    m:SetPoint(a[1], plate, a[2], a[3], a[4])

    -- Re-asserted on every look change because EllesmereUI (or any nameplate
    -- addon) may rebuild the plate's internals and shuffle frame levels; a
    -- marker that quietly ends up behind the health bar is worse than none.
    m:SetFrameLevel(plate:GetFrameLevel() + 50)
end

--------------------------------------------------------------------------------
-- Refresh
--
-- Reads ns.stateByGUID, which the core scan fills each tick. No threat API
-- calls happen here.
--------------------------------------------------------------------------------

local looksSerial = 0   -- bumped whenever a display setting changes
local previewMode = false

-- Deliberately runtime-only, never saved: a preview that survived a relog and
-- silently marked every mob in a dungeon would be a trap. It also clears
-- itself on any zone change (see PLAYER_ENTERING_WORLD below).
function ns.SetMarkerPreview(on)
    previewMode = on and true or false
    ns.RefreshMarkers()
    return previewMode
end

function ns.GetMarkerPreview()
    return previewMode
end

function ns.RefreshMarkers()
    local db = ns.db
    if not db then return end

    local wantMarker = db.npMarker
    local wantWarn   = db.npMarkerWarn
    local stateByGUID = ns.stateByGUID
    local LOST, WARN = ns.STATE_LOST, ns.STATE_WARN

    for unit, m in pairs(activeByUnit) do
        local show, glyph

        if previewMode then
            -- Preview ignores threat entirely, and ignores the enable toggle
            -- too, so the marker can be judged on a target dummy or any
            -- open-world mob before committing to it. Your current target
            -- shows the at-risk glyph when that option is on, which puts the
            -- two symbols on screen together for comparison.
            --
            -- Hostile check matters here specifically: normally the marker is
            -- driven by threat data, which only ever covers enemies, but
            -- preview shows unconditionally -- and this list holds friendly
            -- plates too when the user has those turned on.
            if UnitCanAttack("player", unit) then
                show  = true
                glyph = (wantWarn and UnitIsUnit(unit, "target"))
                        and db.npWarnGlyph or db.npGlyph
            end

        elseif wantMarker then
            local state = stateByGUID[UnitGUID(unit)]
            if state == LOST then
                show, glyph = true, db.npGlyph
            elseif state == WARN and wantWarn then
                show, glyph = true, db.npWarnGlyph
            end
        end

        if show then
            -- Only touch the frame on an actual transition. In a big pull this
            -- runs across ~40 plates five times a second, so the steady state
            -- has to be a couple of comparisons and nothing more.
            if m._glyph ~= glyph or m._serial ~= looksSerial then
                m._glyph  = glyph
                m._serial = looksSerial
                ApplyLook(m, m:GetParent())
                m.text:SetText(glyph)
                local c = db.npColor
                m.text:SetTextColor(c[1], c[2], c[3])
            end
            if not m:IsShown() then
                m:Show()
                if db.npPulse then m.pulse:Play() end
            end
            -- Pulse can be toggled while a marker is already up.
            if db.npPulse and not m.pulse:IsPlaying() then
                m.pulse:Play()
            elseif not db.npPulse and m.pulse:IsPlaying() then
                m.pulse:Stop()
                m:SetAlpha(1)
            end
        elseif m:IsShown() then
            m.pulse:Stop()
            m:SetAlpha(1)
            m:Hide()
        end
    end
end

-- Force every marker to re-apply font/anchor/color on the next refresh.
function ns.MarkersLooksChanged()
    looksSerial = looksSerial + 1
    ns.RefreshMarkers()
end

--------------------------------------------------------------------------------
-- Nameplate lifecycle
--------------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")

ev:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Walking into a dungeon with every plate still marked would be worse
        -- than useless, so a zone change always ends the preview. Pull the
        -- settings window back in step if it happens to be open.
        if previewMode then
            previewMode = false
            ns.RefreshOptions()
        end

        -- A zone change also tears every nameplate down, and the matching
        -- REMOVED events are not guaranteed to arrive. Drop the unit map so no
        -- marker is left pointing at a token handed to something else.
        for u, m in pairs(activeByUnit) do
            m.pulse:Stop()
            m:SetAlpha(1)
            m:Hide()
            activeByUnit[u] = nil
        end

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- The personal resource display is a nameplate too, and it is us.
        if UnitIsUnit(unit, "player") then return end

        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if not plate then return end

        local m = AcquireMarker(plate)
        m._glyph  = nil        -- force a full re-apply for the new occupant
        m._serial = nil
        activeByUnit[unit] = m

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local m = activeByUnit[unit]
        if m then
            m.pulse:Stop()
            m:SetAlpha(1)
            m:Hide()
            activeByUnit[unit] = nil
        end
    end
end)
