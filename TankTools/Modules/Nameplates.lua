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
--
-- This module reads Modules/Threat.lua's output and makes no threat API calls
-- of its own.
--------------------------------------------------------------------------------

local _, ns = ...

local C_NamePlate      = C_NamePlate
local UnitCanAttack    = UnitCanAttack
local UnitExists       = UnitExists
local GetTime          = GetTime
local twipe            = wipe
local issecretvalue    = issecretvalue
local strmatch, tonumber = string.match, tonumber
local strupper, strlower = string.upper, string.lower
local floor            = math.floor

local Print = ns.Print

local M = ns.NewModule("nameplates", {
    defaults = {
        -- Accessibility-first: the signal is a *glyph appearing*, not a hue
        -- change, so it carries no color information at all -- absence means
        -- "mine", presence means "not mine". Color is decoration on top.
        npMarker       = true,          -- mark mobs you do NOT have aggro on
        npMarkerWarn   = false,         -- also mark mobs you are about to lose
        npMarkerSecure = false,         -- mark mobs you DO have aggro on
        npGlyph        = "!",           -- glyph for "you do not have this one"
        npWarnGlyph    = "?",           -- glyph for "about to lose this one"
        npSecureGlyph  = "o",           -- glyph for "this one is yours"
        npSize         = 28,
        npAnchor       = "LEFT",        -- LEFT | RIGHT | TOP | BOTTOM
        npPulse        = true,          -- motion, a channel independent of color
        npColor        = { 1, 0.92, 0.15 },

        -- The aggro marker is the "nothing is wrong" state, so it gets its
        -- own, deliberately quiet color -- a grey that recedes and lets the
        -- alert glyphs keep the loud one. It never pulses, whatever npPulse
        -- says.
        npSecureColor  = { 0.62, 0.62, 0.62 },
    },
})

local db   -- resolved in OnInit

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
-- The state ids come from Modules/Threat.lua, which the .toc loads first.
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
-- Keeping the unit map honest
--
-- ADDED and REMOVED are the fast path and are right almost all of the time.
-- What they are not is a complete account of which plates exist, and a zone
-- change is exactly where that gap opens: plates are torn down and rebuilt
-- around PLAYER_ENTERING_WORLD rather than inside it, so an ADDED can land
-- before the zone change is announced and a REMOVED can simply never arrive.
--
-- Trusting the events alone meant walking into a delve and marking nothing --
-- the plates were already there, the map was wiped after their ADDED had been
-- and gone, and no further event was coming -- and walking back out with
-- markers still on screen for plates that no longer existed. Both cleared on
-- /reload, which is the tell: the state was wrong, not the drawing.
--
-- So the events stay, and around a zone change the truth is re-derived from
-- the client rather than accumulated from what it told us.
--------------------------------------------------------------------------------

-- Every token the client can hand out for a nameplate. A fixed list, walked
-- rather than concatenated per pass, for the same reason Core caches its group
-- tokens.
local PLATE_UNITS = {}
for i = 1, 40 do PLATE_UNITS[i] = "nameplate" .. i end

local seenUnits = {}   -- scratch for Reconcile, wiped in place

local function RetireMarker(unit, m)
    m.pulse:Stop()
    m:SetAlpha(1)
    m:Hide()
    activeByUnit[unit] = nil
    -- The threat module's alert bookkeeping is keyed by this token and has to
    -- go with it, or a token recycled onto a different mob inherits the last
    -- one's history.
    ns.ForgetUnit(unit)
end

-- Bring activeByUnit back in step with the plates that actually exist: adopt
-- what we missed, retire what has gone. Idempotent, so it is safe to run
-- repeatedly while the world is still streaming in.
local function Reconcile()
    twipe(seenUnits)

    for i = 1, #PLATE_UNITS do
        local u = PLATE_UNITS[i]
        if UnitExists(u) then
            seenUnits[u] = true
            if not activeByUnit[u] then
                local plate = C_NamePlate.GetNamePlateForUnit(u)
                if plate then
                    local m = AcquireMarker(plate)
                    m._kind   = nil    -- force a full re-apply for this occupant
                    m._serial = nil
                    activeByUnit[u] = m
                end
            end
        end
    end

    for u, m in pairs(activeByUnit) do
        if not seenUnits[u] then RetireMarker(u, m) end
    end
end

-- How long after a zone change to keep checking. The plates do not all exist
-- the moment PLAYER_ENTERING_WORLD fires -- they arrive as the world streams
-- in -- so a single pass at the announcement is not enough on its own.
local RECONCILE_FOR   = 10
local RECONCILE_EVERY = 0.25
local reconcileUntil  = 0

-- Counters, for /tt npdebug. Cheap, and the difference between "the reconcile
-- ran and found nothing" and "the reconcile never ran" is otherwise invisible
-- -- which is exactly the hole the first attempt at this fix fell into.
local reconcileRuns = 0
local refreshRuns   = 0
local lastZoneAt    = 0

-- Nameplate events seen, in total and since the last zone change.
--
-- A snapshot of what exists right now cannot tell "no plates have appeared
-- since you got here" from "you happened to type this while nothing was on
-- screen", and those are completely different bugs. Counters survive the mob
-- dying before you finish typing.
local addedSeen, removedSeen = 0, 0
local addedSinceZone, adoptedSinceZone = 0, 0

local function ReconcileWindowOpen()
    reconcileUntil = (GetTime and GetTime() or 0) + RECONCILE_FOR
    lastZoneAt = (GetTime and GetTime() or 0)
    addedSinceZone, adoptedSinceZone = 0, 0
end

-- THE WINDOW NEEDS A DRIVER OF ITS OWN, AND THIS IS WHY
--
-- The obvious place to run it is ns.RefreshMarkers, which the threat scan
-- calls on every tick. Except it does not: Threat's Tick has an idle fast path
-- that returns without notifying anyone when nothing is worth scanning, and
-- walking into an instance is precisely that moment -- no plates yet, an empty
-- state map, nothing to report. So the window opened, nothing called it, and
-- by the time the first mob appeared and the scan resumed the window had shut.
-- The panel stayed blank until a reload, which is the bug this was meant to
-- fix, still there after the first attempt at fixing it.
--
-- So the module drives its own. It sits on the shared ticker like everything
-- else -- which means it is inside the same failure latch, and a marker sync
-- that starts throwing stops on its own instead of once per frame forever.
local function ReconcileTick()
    if reconcileUntil == 0 then return end

    local now = GetTime and GetTime() or 0
    if now >= reconcileUntil then
        reconcileUntil = 0
        return
    end

    reconcileRuns = reconcileRuns + 1
    local before = 0
    for _ in pairs(activeByUnit) do before = before + 1 end

    Reconcile()

    local after = 0
    for _ in pairs(activeByUnit) do after = after + 1 end
    -- Adopting a plate only puts it in the map; drawing it is a separate step,
    -- and the scan may not be running yet to ask for it.
    if after ~= before then ns.RefreshMarkers() end
end

--------------------------------------------------------------------------------
-- Refresh
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

local function MarkersWanted()
    return db.npMarker or db.npMarkerWarn or db.npMarkerSecure
end

-- Preview spreads the enabled glyphs across the mobs on screen so they can be
-- compared side by side, and picks each one from the plate's own token number
-- so a given nameplate keeps the same symbol instead of flickering between
-- them tick to tick. The scratch table is reused: preview still runs at 5 Hz.
local previewKinds = {}

local function PreviewKind(unit)
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
    if not db then return end

    refreshRuns = refreshRuns + 1

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
                kind = PreviewKind(unit)
            end
        else
            -- Friendly plates simply have no entry here, so they fall through
            -- with kind = nil and never get a marker.
            local st = stateByUnit[unit]
            local want = st and KIND[st].want
            if want and db[want] then kind = st end
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

ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    -- Walking into a dungeon with every plate still marked would be worse than
    -- useless, so a zone change always ends the preview. Pull the settings
    -- window back in step if it happens to be open.
    if previewMode then
        previewMode = false
        ns.RefreshOptions()
    end

    -- Once now, for the plates that already exist, and then for a few seconds
    -- as the rest arrive. A blind wipe used to live here, which is what left
    -- the delve unmarked: it threw away markers for plates whose ADDED had
    -- already fired, and nothing was going to fire again.
    Reconcile()
    ReconcileWindowOpen()
end)

ns.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
    -- The personal resource display is a nameplate too, and it is us. The
    -- event hands it over under the literal token "player", so compare the
    -- string: UnitIsUnit would be the natural test and is a secret boolean
    -- inside instances, which throws the moment it is tested.
    addedSeen, addedSinceZone = addedSeen + 1, addedSinceZone + 1

    if unit == "player" then return end

    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end

    adoptedSinceZone = adoptedSinceZone + 1

    local m = AcquireMarker(plate)
    m._kind   = nil        -- force a full re-apply for the new occupant
    m._serial = nil
    activeByUnit[unit] = m
end)

ns.RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
    removedSeen = removedSeen + 1
    local m = activeByUnit[unit]
    if m then
        RetireMarker(unit, m)
    else
        -- Still unconditional: the threat module's alert bookkeeping is keyed
        -- by this token and has to be dropped whether or not we ever built a
        -- marker for it.
        ns.ForgetUnit(unit)
    end
end)

--------------------------------------------------------------------------------
-- Module lifecycle
--------------------------------------------------------------------------------

function M:OnInit()
    db = self.db

    -- Its own ticker rather than a hook into the scan's, so the post-zone
    -- reconcile keeps running through exactly the moment the scan decides
    -- there is nothing worth scanning.
    ns.RegisterTicker("markersync", "marker sync", RECONCILE_EVERY, ReconcileTick)

    ns.RegisterThreatConsumer{
        -- Preview forces the scan on even out of a tank spec: the whole point
        -- of a preview is seeing the marker before you are in the situation it
        -- exists for.
        wants   = function() return MarkersWanted(), previewMode end,
        updated = ns.RefreshMarkers,
    }
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function Toggle(key, label)
    return function()
        db[key] = not db[key]
        ns.MarkersLooksChanged()
        Print(label .. " " .. (db[key] and "enabled." or "disabled."))
    end
end

-- Hidden. Prints the whole chain between "a plate exists" and "a glyph is on
-- screen", because every link in it fails silently and they all look the same
-- from the chair.
local function DumpPlates()
    local now = GetTime and GetTime() or 0

    Print("|cffffff00---- nameplate markers ----|r")
    Print(format("markers wanted=%s  preview=%s  db=%s",
                 tostring(MarkersWanted()), tostring(previewMode),
                 tostring(db ~= nil)))
    Print(format("plate events: added=%d (|cffffff00%d since this zone|r, "
                 .. "%d gave us a plate)  removed=%d",
                 addedSeen, addedSinceZone, adoptedSinceZone, removedSeen))
    Print(format("refreshes=%d  reconciles=%d  window=%s  last zone %.1fs ago",
                 refreshRuns, reconcileRuns,
                 (reconcileUntil > 0)
                     and format("|cff00ff00open %.1fs|r", reconcileUntil - now)
                     or "|cff888888shut|r",
                 (lastZoneAt > 0) and (now - lastZoneAt) or -1))

    for _, name in ipairs({ "markersync", "threat" }) do
        local t = ns.GetTicker(name)
        if not t then
            Print(format("ticker %s: |cffff4040NOT REGISTERED|r", name))
        elseif t.disabled then
            Print(format("ticker %s: |cffff4040stopped|r -- %s",
                         name, tostring(t.err)))
        else
            Print(format("ticker %s: |cff00ff00running|r (failures=%d)",
                         name, t.failures or 0))
        end
    end

    local live, tracked, drawn = 0, 0, 0
    for i = 1, #PLATE_UNITS do
        local u = PLATE_UNITS[i]
        if UnitExists(u) then
            live = live + 1
            local plate = C_NamePlate.GetNamePlateForUnit(u)
            local m = activeByUnit[u]
            if m then tracked = tracked + 1 end
            local shown = m and m:IsShown()
            if shown then drawn = drawn + 1 end
            Print(format("  %-12s plate=%s  tracked=%s  shown=%s  state=%s",
                         u, plate and "yes" or "|cffff4040no|r",
                         m and "yes" or "|cffff4040no|r",
                         shown and "|cff00ff00yes|r" or "no",
                         tostring(ns.stateByUnit[u])))
        end
    end

    Print(format("live plates=%d  tracked=%d  drawn=%d", live, tracked, drawn))
    if live == 0 and addedSinceZone == 0 then
        Print("|cffff8000No plate has been announced since you arrived, and "
              .. "none exists now.|r If glyphs are missing while mobs are on "
              .. "screen, run this again |cffffff00with those mobs in front of "
              .. "you|r -- this snapshot was taken with nothing to mark.")
    elseif live == 0 and addedSinceZone > 0 then
        Print(format("|cffff8000%d plates were announced here but none exists "
                     .. "now.|r Either they are all gone, or the client stopped "
                     .. "answering UnitExists for their tokens -- run this with "
                     .. "mobs on screen to tell those apart.", addedSinceZone))
    elseif live > 0 and tracked == 0 then
        Print("|cffff8000Plates exist and none is tracked.|r The unit map was "
              .. "not rebuilt -- reconciles above should be climbing while the "
              .. "window is open.")
    elseif tracked > 0 and drawn == 0 then
        Print("|cffff8000Tracked but nothing drawn.|r The map is fine; this is "
              .. "the threat state or the marker toggles -- see "
              .. "|cffffff00/tt status|r.")
    end
end

ns.RegisterCommand{
    name = "npdebug", hidden = true,
    section = "markers:", order = 5,
    desc = "why is no glyph on screen",
    handler = DumpPlates,
}

ns.RegisterCommand{
    name = "nptest", aliases = { "nppreview" },
    section = "commands:", order = 20,
    desc = "preview the symbols on every nameplate",
    handler = function()
        local on = ns.SetMarkerPreview(not ns.GetMarkerPreview())
        if on then
            Print("marker preview |cff00ff00on|r -- every enemy nameplate is "
                  .. "marked so you can see the symbols. It ends on zone change, "
                  .. "or run |cffffff00/tt nptest|r again.")
        else
            Print("marker preview |cffff0000off|r.")
        end
    end,
}

ns.RegisterCommand{
    name = "np", section = "markers:", order = 10,
    desc = "mobs you do NOT have aggro on",
    handler = Toggle("npMarker", "\"not mine\" marker"),
}

ns.RegisterCommand{
    name = "npwarn", section = "markers:", order = 20,
    desc = "mobs at risk of being pulled",
    handler = Toggle("npMarkerWarn", "at-risk marker"),
}

ns.RegisterCommand{
    name = "npsecure", aliases = { "npmine" },
    section = "markers:", order = 30,
    desc = "mobs you DO have aggro on",
    handler = Toggle("npMarkerSecure", "aggro marker"),
}

ns.RegisterCommand{
    name = "nppulse", section = "markers:", order = 40,
    desc = "toggle the pulse",
    handler = Toggle("npPulse", "marker pulse"),
}

ns.RegisterCommand{
    name = "npsize", args = "<n>", section = "markers:", order = 50,
    desc = "10 to 72",
    handler = function(_, _, n)
        if n and n >= 10 and n <= 72 then
            db.npSize = floor(n)
            ns.MarkersLooksChanged()
            Print("marker size set to " .. db.npSize .. ".")
        else
            Print("usage: /tt npsize 10 - 72")
        end
    end,
}

ns.RegisterCommand{
    name = "npanchor", args = "<p>", section = "markers:", order = 60,
    desc = "left | right | top | bottom",
    handler = function(_, larg)
        local a = larg and strupper(larg) or ""
        if ANCHORS[a] then
            db.npAnchor = a
            ns.MarkersLooksChanged()
            Print("marker anchored to the " .. strlower(a) .. " of the nameplate.")
        else
            Print("usage: /tt npanchor left | right | top | bottom")
        end
    end,
}

local function GlyphCommand(name, order, key, desc)
    ns.RegisterCommand{
        name = name, args = "<t>", section = "markers:", order = order,
        desc = desc,
        handler = function(arg)
            if arg and arg ~= "" then
                db[key] = arg
                ns.MarkersLooksChanged()
                Print("symbol set to \"" .. arg .. "\".")
            else
                Print("usage: /tt " .. name .. " <text>")
            end
        end,
    }
end

GlyphCommand("npglyph",      70, "npGlyph",       "\"not mine\" symbol (default !)")
GlyphCommand("npwarnglyph",  80, "npWarnGlyph",   "\"at risk\" symbol (default ?)")
GlyphCommand("npsecglyph",   90, "npSecureGlyph", "\"mine\" symbol (default o)")

local function ColorCommand(name, order, key, label, desc)
    ns.RegisterCommand{
        name = name, args = "<c>", section = "markers:", order = order,
        desc = desc,
        handler = function(arg, larg)
            local preset = larg and COLOR_PRESETS[larg]
            if preset then
                db[key] = { preset[1], preset[2], preset[3] }
                ns.MarkersLooksChanged()
                Print(label .. " color set to " .. arg .. ".")
            else
                Print("usage: /tt " .. name
                      .. " white | yellow | cyan | magenta | orange | green | grey")
            end
        end,
    }
end

ColorCommand("npcolor",    100, "npColor",       "alert marker", "alert color")
ColorCommand("npseccolor", 110, "npSecureColor", "aggro marker", "aggro color")

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

ns.RegisterStatusProvider(20, function(yn)
    Print("markers -- not mine: " .. yn(db.npMarker)
          .. ", at-risk: " .. yn(db.npMarkerWarn)
          .. ", mine: " .. yn(db.npMarkerSecure)
          .. ", preview: " .. yn(previewMode))
end)

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

ns.RegisterOptionsSection{
    page = "Threat", pageOrder = 10, column = "left", order = 10,
    build = function(f, x, y)
        local ui = ns.ui
        y = ui.Header(f, "Markers", x, y)
        -- The three states are independent switches rather than a master plus
        -- two extras, so "only tell me which ones are mine" is a setting you
        -- can actually reach.
        y = ui.Check(f, x, y, "Mark mobs I do NOT have aggro on", db, "npMarker", ns.MarkersLooksChanged)
        y = ui.Check(f, x, y, "Mark mobs at risk of being pulled", db, "npMarkerWarn", ns.MarkersLooksChanged)
        y = ui.Check(f, x, y, "Mark mobs I DO have aggro on", db, "npMarkerSecure", ns.MarkersLooksChanged)
        y = ui.Check(f, x, y, "Pulse (alert markers only)", db, "npPulse", ns.MarkersLooksChanged)
        return y
    end,
}

ns.RegisterOptionsSection{
    page = "Threat", pageOrder = 10, column = "left", order = 30,
    build = function(f, x, y)
        return ns.ui.Note(f, x, y - 10,
            "The markers signal by shape and by appearing at all,\n"
            .. "not by color, so they stay readable in grayscale.")
    end,
}

ns.RegisterOptionsSection{
    page = "Threat", pageOrder = 10, column = "right", order = 10,
    build = function(f, x, y)
        local ui = ns.ui
        local apply = ns.MarkersLooksChanged

        y = ui.Header(f, "Appearance", x, y)
        y = ui.Slider(f, x, y, "Marker size", db, "npSize", 10, 72, 1, 0, apply)
        y = ui.Segmented(f, x, y, "Position", db, "npAnchor", {
            { text = "Left",   value = "LEFT"   },
            { text = "Right",  value = "RIGHT"  },
            { text = "Top",    value = "TOP"    },
            { text = "Bottom", value = "BOTTOM" },
        }, apply)
        y = ui.InputRow(f, x, y, "Symbols", db, {
            { label = "Not mine", key = "npGlyph"       },
            { label = "At risk",  key = "npWarnGlyph"   },
            { label = "Mine",     key = "npSecureGlyph" },
        }, apply)
        y = ui.Swatches(f, x, y, "Alert color", db, "npColor", apply, ns.COLOR_ORDER)
        y = ui.Swatches(f, x, y, "Aggro color", db, "npSecureColor", apply,
                        ns.COLOR_ORDER_SECURE)

        -- Preview lives with the appearance settings rather than off in a
        -- button bar: it exists to be toggled while adjusting size and
        -- position, and every control it relates to is directly above it.
        y = ui.Button(f, x, y, "Preview marker on all nameplates",
            function() ns.SetMarkerPreview(not ns.GetMarkerPreview()) end,
            function()
                return ns.GetMarkerPreview()
                       and "Stop marker preview"
                       or  "Preview marker on all nameplates"
            end)

        return ui.Note(f, x, y,
            "Marks every enemy nameplate so you can size and place the\n"
            .. "symbols on a target dummy -- each enabled symbol is spread\n"
            .. "over the mobs on screen. Ends when you change zone.")
    end,
}
