--------------------------------------------------------------------------------
-- Tank Tools -- nameplate aggro marker
--
-- Accessibility module. Threat UI in WoW signals almost entirely by recoloring
-- the plate, but a hue shift is exactly the channel that fails for the ~8% of
-- men and ~0.5% of women with a color vision deficiency -- and red/green, the
-- pair that UI leans on hardest, is the pair protanopia and deuteranopia
-- collapse first.
--
-- So this module adds a channel that carries no color information at all:
--
--   1. SHAPE     -- a glyph with a distinct silhouette ("!" by default).
--   2. PRESENCE  -- by default it appears only on mobs you do NOT hold.
--                   Nothing on screen means everything is yours. The signal is
--                   the glyph existing, which is readable in full grayscale.
--                   (The optional aggro marker inverts this, for people who
--                   would rather have a positive confirmation than an absence.
--                   It is off by default: absence is the cheaper signal to
--                   read in the middle of a fifteen-pull.)
--   3. MOTION    -- an optional pulse; movement is orthogonal to color entirely.
--   4. CONTRAST  -- thick black outline, so it reads against any backdrop
--                   regardless of how the nameplate underneath is colored.
--
-- Color is applied last and is pure decoration: strip it and every bit of
-- information above survives intact.
--
-- Nothing here modifies the nameplate itself. The marker is a child frame of
-- Blizzard's base nameplate container, so whatever owns the plate -- the
-- default UI or any nameplate addon -- keeps full ownership of it, and the two
-- compose instead of fighting.
--------------------------------------------------------------------------------

local _, ns = ...

local C_NamePlate      = C_NamePlate
local UnitCanAttack    = UnitCanAttack
local issecretvalue    = issecretvalue
local strmatch, tonumber = string.match, tonumber

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
    -- The last two exist for the aggro marker, which wants to recede rather
    -- than shout. Offered to the alert glyphs too, though green on an alert
    -- is a poor choice and grey is a worse one.
    green   = { 0.40, 0.90, 0.50 },
    grey    = { 0.62, 0.62, 0.62 },
}
COLOR_PRESETS.gray = COLOR_PRESETS.grey
ns.COLOR_PRESETS = COLOR_PRESETS

-- Swatch orders for the settings window: the alert glyphs get the five loud
-- presets, the aggro glyph gets the quiet end of the range.
ns.COLOR_ORDER        = { "white", "yellow", "cyan", "magenta", "orange" }
ns.COLOR_ORDER_SECURE = { "grey", "white", "green", "cyan", "yellow" }

-- One row per marker kind, keyed by the threat state it belongs to, so adding
-- the aggro marker did not mean a third branch everywhere a glyph is touched.
-- The state ids come from the core file, which the .toc loads first.
local LOST, WARN, SECURE = ns.STATE_LOST, ns.STATE_WARN, ns.STATE_SECURE

local KIND = {
    [LOST]   = { want = "npMarker",       glyph = "npGlyph",       color = "npColor"       },
    [WARN]   = { want = "npMarkerWarn",   glyph = "npWarnGlyph",   color = "npColor"       },
    [SECURE] = { want = "npMarkerSecure", glyph = "npSecureGlyph", color = "npSecureColor" },
}

-- Fixed iteration order: pairs() over KIND would shuffle between calls, and
-- the preview picks each mob a glyph out of this list.
local KIND_ORDER = { LOST, WARN, SECURE }

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

    -- BOUNCE alpha pulse. It bottoms out at 0.55 rather than near zero -- this
    -- is an alert, and it must stay legible at every point in the cycle,
    -- including for anyone who finds motion hard to track.
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

    -- Re-asserted on every look change because a nameplate addon may rebuild
    -- the plate's internals and shuffle frame levels; a marker that quietly
    -- ends up behind the health bar is worse than none.
    m:SetFrameLevel(plate:GetFrameLevel() + 50)
end

--------------------------------------------------------------------------------
-- Refresh
--
-- Reads ns.stateByUnit, which the core scan fills each tick. No threat API
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

-- Preview spreads the enabled glyphs across the mobs on screen so they can be
-- compared side by side, and picks each one from the plate's own token number
-- so a given nameplate keeps the same symbol instead of flickering between
-- them tick to tick. The scratch table is reused: preview still runs at 5 Hz.
local previewKinds = {}

local function PreviewKind(db, unit)
    local n = 0
    for i = 1, #KIND_ORDER do
        local k = KIND_ORDER[i]
        if db[KIND[k].want] then
            n = n + 1
            previewKinds[n] = k
        end
    end
    -- Preview deliberately ignores the enable toggles when they are all off:
    -- you have to be able to see the thing before deciding to turn it on.
    if n == 0 then return LOST end
    if n == 1 then return previewKinds[1] end

    -- The token number, not the GUID: unit GUIDs can be secret values, and a
    -- secret cannot be fed to tonumber() or used as a table key.
    local h = tonumber(strmatch(unit, "%d+") or "") or 0
    return previewKinds[(h % n) + 1]
end

function ns.RefreshMarkers()
    local db = ns.db
    if not db then return end

    local stateByUnit = ns.stateByUnit

    for unit, m in pairs(activeByUnit) do
        local kind

        if previewMode then
            -- Hostile check matters here specifically: normally the marker is
            -- driven by threat data, which only ever covers enemies, but
            -- preview shows unconditionally -- and this list holds friendly
            -- plates too when the user has those turned on.
            --
            -- UnitCanAttack can come back secret inside an instance, and
            -- testing a secret throws. Preview is a tuning mode, so an
            -- unreadable answer marks the plate rather than skipping it:
            -- showing one glyph too many while sizing the symbol is harmless.
            local canAttack = UnitCanAttack("player", unit)
            if not (issecretvalue and issecretvalue(canAttack)) and not canAttack then
                kind = nil
            else
                kind = PreviewKind(db, unit)
            end
        else
            -- Friendly plates simply have no entry here, so they fall through
            -- with kind = nil and never get a marker.
            local state = stateByUnit[unit]
            local want = state and KIND[state].want
            if want and db[want] then kind = state end
        end

        if kind then
            -- Only touch the frame on an actual transition. In a big pull this
            -- runs across ~40 plates five times a second, so the steady state
            -- has to be a couple of comparisons and nothing more. The serial
            -- covers settings edits, which can change a glyph or a color
            -- without changing which kind is on screen.
            if m._kind ~= kind or m._serial ~= looksSerial then
                local k = KIND[kind]
                m._kind   = kind
                m._serial = looksSerial
                ApplyLook(m, m:GetParent())
                m.text:SetText(db[k.glyph] or "")
                local c = db[k.color] or db.npColor
                m.text:SetTextColor(c[1], c[2], c[3])
            end

            -- Motion stays reserved for the two alert states. Pulsing "this
            -- one is yours" would spend the loudest channel on the quietest
            -- news, and in a big pull every held plate would twitch at once.
            local wantPulse = db.npPulse and kind ~= SECURE

            if not m:IsShown() then m:Show() end
            if wantPulse ~= m.pulse:IsPlaying() then
                if wantPulse then
                    m.pulse:Play()
                else
                    m.pulse:Stop()
                    m:SetAlpha(1)
                end
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
            ns.ForgetUnit(u)
        end

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- The personal resource display is a nameplate too, and it is us. The
        -- event hands it over under the literal token "player", so compare the
        -- string: UnitIsUnit would be the natural test and is a secret boolean
        -- inside instances, which throws the moment it is tested.
        if unit == "player" then return end

        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if not plate then return end

        local m = AcquireMarker(plate)
        m._kind   = nil        -- force a full re-apply for the new occupant
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
        -- Unconditional: the core's alert bookkeeping is keyed by this token
        -- and has to be dropped whether or not we ever built a marker for it.
        ns.ForgetUnit(unit)
    end
end)
