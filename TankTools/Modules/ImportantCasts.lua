--------------------------------------------------------------------------------
-- Tank Tools -- important-cast marker
--
-- A second question, answered the same way the aggro marker answers the
-- first: a glyph on the nameplate when an enemy starts casting something the
-- game itself flags as worth your attention.
--
-- A glyph and nothing else. There used to be a sound too, and it could only
-- ever work outdoors: inside an instance the important-cast answer is secret,
-- the glyph survives because the client draws it (see Mark), and nothing
-- equivalent exists for audio -- every sound call refuses a secret argument
-- from addon code (C_Sound.PlaySound is AllowedWhenUntainted), no event fires
-- only for important casts, and a frame's OnShow fires for the invisible
-- markers too. A sound that is silent in exactly the content a tank cares
-- about is a setting that lies, so it went.
--
-- "Worth your attention" is not a spell-ID list this addon curates. It is
-- read straight from `C_Spell.IsSpellImportant`, the same flag the default UI
-- uses to ring a boss's cast bar on an enemy nameplate. Riding it means the
-- marker tracks whatever Blizzard curates release to release, and never goes
-- stale the way a hand-typed spell list would.
--
-- Unlike the threat scan, this is not built around a periodic re-derivation
-- of "who is fighting whom" -- a cast either exists on a unit right now or it
-- does not, and UnitCastingInfo/UnitChannelInfo answer that directly. So the
-- scan below still polls (for the same reason Threat.lua does: a unit token
-- surviving a zone change or a plate appearing before its ADDED event fires
-- both self-heal for free on the next tick, with no reconcile window to get
-- wrong), but it carries no state across a "not casting" gap -- a marker is
-- either on because the unit is casting an important spell *right now*, or it
-- is not there at all.
--------------------------------------------------------------------------------

local _, ns = ...

local UnitExists         = UnitExists
local UnitCanAttack      = UnitCanAttack
local UnitCastingInfo    = UnitCastingInfo
local UnitChannelInfo    = UnitChannelInfo
local C_NamePlate        = C_NamePlate
local C_Spell            = C_Spell
local strupper, strlower = string.upper, string.lower

local IsFalse, IsSecret = ns.IsFalse, ns.IsSecret
local Print           = ns.Print

local M = ns.NewModule("importantcasts", {
    defaults = {
        icMarker = true,                    -- show the glyph
        icGlyph  = "!!",                     -- distinct from the aggro marker's "!"
        icSize   = 30,
        icAnchor = "TOP",                   -- distinct from the aggro marker's default LEFT
        icPulse  = true,
        icColor  = { 1, 0.2, 0.2 },
    },
})

local db   -- resolved in OnInit

local UPDATE_INTERVAL = 0.2

local FONT = select(1, GameFontNormal:GetFont())

local ANCHORS = {
    LEFT   = { "RIGHT",  "LEFT",   -6,  0 },
    RIGHT  = { "LEFT",   "RIGHT",   6,  0 },
    TOP    = { "BOTTOM", "TOP",     0,  6 },
    BOTTOM = { "TOP",    "BOTTOM",  0, -6 },
}

-- Nameplate unit tokens, built once. Same pool Threat.lua and Nameplates.lua
-- walk, and for the same reason: not C_NamePlate.GetNamePlates(), whose
-- frames no longer carry a namePlateUnitToken field.
local PLATE_UNITS = {}
for i = 1, 40 do PLATE_UNITS[i] = "nameplate" .. i end

--------------------------------------------------------------------------------
-- Marker construction
--
-- One frame per *plate frame*, exactly like Nameplates.lua's aggro marker --
-- Blizzard recycles a small fixed pool, so a whole session allocates at most
-- ~40 of these regardless of how many mobs are actually seen casting.
--------------------------------------------------------------------------------

local markerByPlate = {}   -- plate frame -> marker
local markedUnit    = {}   -- unit token -> the marker currently shown for it
-- unit token -> true while its marker is up but the *client* decides whether
-- it can be seen, because the important-cast answer was secret. Kept apart
-- from markedUnit so /tt status can say "armed, unreadable" instead of
-- counting every casting mob in a dungeon as an important one.
local unreadable    = {}

-- Three frames deep, and each layer has one job:
--
--   m      ours. Anchored to the plate, shown and hidden, and the only one of
--          the three we ever read (IsShown) -- which is why it is on top.
--   gate   takes the important-cast answer through SetAlphaFromBoolean. Inside
--          an instance that answer is a secret boolean, and this is the one
--          door a tainted addon has for acting on one: the client resolves it
--          and the addon never learns which way it went. Doing so marks the
--          frame's alpha secret for good (SecretArgumentsAddAspect), so nothing
--          ever reads this frame's alpha, and nothing but the gate sets it.
--   inner  holds the glyph and the pulse. The pulse is an Alpha animation, and
--          on the gate itself it would drive the very alpha the gate exists
--          to set; one level down, effective alpha multiplies instead.
--
-- Blizzard's own important-cast ring is built the same way round -- its flash
-- is an Alpha animation on a child texture (Blizzard_NamePlateCastingBar.xml).
local function CreateMarker(plate)
    local m = CreateFrame("Frame", nil, plate)
    m:SetSize(1, 1)

    local gate = CreateFrame("Frame", nil, m)
    gate:SetAllPoints()
    m.gate = gate

    local inner = CreateFrame("Frame", nil, gate)
    inner:SetAllPoints()
    m.inner = inner

    m.text = inner:CreateFontString(nil, "OVERLAY")
    m.text:SetPoint("CENTER")

    -- Same BOUNCE alpha pulse as the aggro marker, bottoming out well above
    -- zero so the glyph stays legible through the whole cycle.
    local ag = inner:CreateAnimationGroup()
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

local looksSerial = 0

local function ApplyLook(m, plate)
    m.text:SetFont(FONT, db.icSize, "THICKOUTLINE")
    m:SetSize(db.icSize, db.icSize)

    local a = ANCHORS[db.icAnchor] or ANCHORS.TOP
    m:ClearAllPoints()
    m:SetPoint(a[1], plate, a[2], a[3], a[4])
    m:SetFrameLevel(plate:GetFrameLevel() + 50)

    m.text:SetText(ns.GlyphMarkup(db.icGlyph))
    local c = db.icColor or { 1, 0.2, 0.2 }
    m.text:SetTextColor(c[1], c[2], c[3])
end

--------------------------------------------------------------------------------
-- Mark / clear
--------------------------------------------------------------------------------

local function Clear(unit)
    local m = markedUnit[unit]
    if m then
        m.pulse:Stop()
        m.inner:SetAlpha(1)
        m:Hide()
        markedUnit[unit] = nil
    end
    unreadable[unit] = nil
end

-- `important` is either a readable true or the client's secret boolean --
-- never a readable false, which ScanUnit has already turned into Clear().
local function Mark(unit, important)
    local hidden = IsSecret(important)
    unreadable[unit] = hidden or nil

    if db.icMarker then
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if plate then
            local m = AcquireMarker(plate)
            if not markedUnit[unit] or m._serial ~= looksSerial then
                m._serial = looksSerial
                ApplyLook(m, plate)
            end
            if not m:IsShown() then m:Show() end

            -- Last, after anything else that touches alpha: a SetAlpha after
            -- this would override the client's answer.
            if hidden then
                m.gate:SetAlphaFromBoolean(important, 1, 0)
            else
                m.gate:SetAlpha(1)
            end

            local wantPulse = db.icPulse
            if wantPulse ~= m.pulse:IsPlaying() then
                if wantPulse then
                    m.pulse:Play()
                else
                    m.pulse:Stop()
                    m.inner:SetAlpha(1)
                end
            end
            markedUnit[unit] = m
        end
    end
end

-- Force every visible marker to re-apply font/anchor/color on its next Mark().
local function LooksChanged()
    looksSerial = looksSerial + 1
    for unit, m in pairs(markedUnit) do
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if plate then ApplyLook(m, plate) end
    end
end

--------------------------------------------------------------------------------
-- Scan
--
-- Inside an instance nearly everything here is secret. UnitCastingInfo and
-- UnitChannelInfo carry SecretWhenUnitSpellCastRestricted -- for any unit that
-- is not you or your pet, the spell ID comes back secret -- and
-- C_Spell.IsSpellImportant accepts that secret ID and answers with a secret
-- boolean.
--
-- This file used to launder that answer through IsTrue() and fail closed on
-- "cannot say". Failing closed on a secret that is secret *everywhere the
-- feature matters* is not a safe default; it is the feature switched off in
-- every dungeon, silently. So a secret answer is not read at all: the marker
-- is put up for the cast and the client decides, through SetAlphaFromBoolean,
-- whether it can be seen. That is how EllesmereUI's nameplates do it.
--
-- Two things that must never happen to the answer, because both throw:
-- a boolean test (`if imp`, `imp and ...`, `not imp`) and a comparison. It is
-- only ever handed to IsSecret() and, if secret, straight to the gate.
--------------------------------------------------------------------------------

local previewMode = false

-- Casting at all? Answered from isTradeskill, which the client declares
-- NeverSecret and returns for every cast and channel -- so this stays a
-- readable question inside an instance, where the name and spell ID do not.
-- Field positions match UnitCastingInfo/UnitChannelInfo exactly: a cast
-- carries castID (position 7) that a channel does not, which shifts
-- notInterruptible and spellID back by one.
local function CastInfo(unit)
    local _, _, _, _, _, isTradeskill, _, _, spellID = UnitCastingInfo(unit)
    if isTradeskill ~= nil then return true, spellID, false end
    local _, _, _, _, _, chTradeskill, _, chSpellID = UnitChannelInfo(unit)
    if chTradeskill ~= nil then return true, chSpellID, true end
    return false
end

-- pcall'd because the answer is not worth an error storm, and its failure is
-- a readable false. Returns ok, answer -- the answer may be secret.
local function Importance(spellID)
    if not (C_Spell and C_Spell.IsSpellImportant) then return false end
    return pcall(C_Spell.IsSpellImportant, spellID)
end

local function ScanUnit(unit)
    if previewMode then
        if UnitExists(unit) and not IsFalse(UnitCanAttack("player", unit)) then
            Mark(unit, true)
        else
            Clear(unit)
        end
        return
    end

    if not UnitExists(unit) then Clear(unit); return end
    if IsFalse(UnitCanAttack("player", unit)) then Clear(unit); return end

    local casting, spellID = CastInfo(unit)
    if not casting then Clear(unit); return end

    local ok, important = Importance(spellID)
    if not ok then Clear(unit); return end

    -- IsSecret first: `important == true` would throw on a secret.
    if IsSecret(important) or important == true then
        Mark(unit, important)
    else
        Clear(unit)
    end
end

local function Tick()
    if not (previewMode or db.icMarker) then
        if next(markedUnit) then
            for unit in pairs(markedUnit) do Clear(unit) end
        end
        return
    end

    for i = 1, #PLATE_UNITS do ScanUnit(PLATE_UNITS[i]) end
end

--------------------------------------------------------------------------------
-- Preview
--------------------------------------------------------------------------------

local function SetPreview(on)
    previewMode = on and true or false
    if not previewMode then
        for unit in pairs(markedUnit) do Clear(unit) end
    end
    return previewMode
end

ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    -- Same rule as the aggro marker's preview: it never survives a zone
    -- change, so it cannot follow you into a dungeon and light up every plate.
    if previewMode then
        SetPreview(false)
        ns.RefreshOptions()
    end
end)

--------------------------------------------------------------------------------
-- Module lifecycle
--------------------------------------------------------------------------------

function M:OnInit()
    db = self.db
    ns.RegisterTicker("importantcasts", "cast scan", UPDATE_INTERVAL, Tick)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function Toggle(key, label)
    return function()
        db[key] = not db[key]
        LooksChanged()
        Print(label .. " " .. (db[key] and "enabled." or "disabled."))
    end
end

ns.RegisterCommand{
    name = "ic", section = "markers:", order = 120,
    desc = "mark enemies casting something the game flags important",
    handler = Toggle("icMarker", "important-cast marker"),
}

ns.RegisterCommand{
    name = "icpulse", section = "markers:", order = 140,
    desc = "toggle the important-cast pulse",
    handler = Toggle("icPulse", "important-cast pulse"),
}

ns.RegisterCommand{
    name = "icsize", args = "<n>", section = "markers:", order = 150,
    desc = "10 to 72",
    handler = function(_, _, n)
        if n and n >= 10 and n <= 72 then
            db.icSize = math.floor(n)
            LooksChanged()
            Print("important-cast marker size set to " .. db.icSize .. ".")
        else
            Print("usage: /tt icsize 10 - 72")
        end
    end,
}

ns.RegisterCommand{
    name = "icanchor", args = "<p>", section = "markers:", order = 160,
    desc = "left | right | top | bottom",
    handler = function(_, larg)
        local a = larg and strupper(larg) or ""
        if ANCHORS[a] then
            db.icAnchor = a
            LooksChanged()
            Print("important-cast marker anchored to the " .. strlower(a)
                  .. " of the nameplate.")
        else
            Print("usage: /tt icanchor left | right | top | bottom")
        end
    end,
}

ns.RegisterCommand{
    name = "icglyph", args = "<t>", section = "markers:", order = 170,
    desc = "important-cast symbol (default !!)",
    handler = function(arg)
        if arg and arg ~= "" then
            db.icGlyph = arg
            LooksChanged()
            Print("important-cast symbol set to " .. ns.GlyphMarkup(arg) .. ".")
        else
            Print("usage: /tt icglyph <text>, or a raid marker such as "
                  .. "{skull}, {cross}, {star}")
        end
    end,
}

ns.RegisterCommand{
    name = "iccolor", args = "<c>", section = "markers:", order = 180,
    desc = "important-cast color",
    handler = function(arg, larg)
        local preset = larg and ns.COLOR_PRESETS[larg]
        if preset then
            db.icColor = { preset[1], preset[2], preset[3] }
            LooksChanged()
            Print("important-cast color set to " .. arg .. ".")
        else
            Print("usage: /tt iccolor white | yellow | cyan | magenta | orange | green | grey")
        end
    end,
}

ns.RegisterCommand{
    name = "ictest", aliases = { "icpreview" },
    section = "commands:", order = 25,
    desc = "preview the important-cast symbol on every nameplate",
    handler = function()
        local on = SetPreview(not previewMode)
        if on then
            Print("important-cast preview |cff00ff00on|r -- every enemy nameplate "
                  .. "is marked so you can see the symbol. It ends on zone change, "
                  .. "or run |cffffff00/tt ictest|r again.")
        else
            Print("important-cast preview |cffff0000off|r.")
        end
    end,
}

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

-- Everything printed through ns.Show, never tostring: inside an instance the
-- name and spell ID are secret, and the whole point of this command is to say
-- so rather than to throw.
local function DumpUnit(unit)
    local casting, spellID, channel = CastInfo(unit)
    if not casting then
        Print("  " .. unit .. ": not casting")
        return
    end

    local name
    if channel then name = UnitChannelInfo(unit) else name = UnitCastingInfo(unit) end
    local important = "n/a"
    if C_Spell and C_Spell.IsSpellImportant then
        local castOK, imp = Importance(spellID)
        important = castOK and ns.Show(imp) or "|cffff4040error|r"
    end

    local verdict = ""
    if unreadable[unit] then
        verdict = markedUnit[unit] and "  |cffff8000armed -- the game decides if it shows|r"
                  or "  |cffff8000unreadable|r"
    elseif markedUnit[unit] then
        verdict = "  |cff00ff00marked|r"
    end

    Print(string.format("  %s: %s%s spellID=%s important=%s%s",
                         unit, ns.Show(name), channel and " (channel)" or "",
                         ns.Show(spellID), important, verdict))
end

ns.RegisterCommand{
    name = "icdebug", hidden = true,
    section = "markers:", order = 190,
    desc = "why is nothing marked",
    handler = function()
        Print("|cffffff00---- important-cast scan ----|r")
        Print("marker=" .. tostring(db.icMarker) .. "  preview=" .. tostring(previewMode))
        local live = 0
        for i = 1, #PLATE_UNITS do
            local u = PLATE_UNITS[i]
            if UnitExists(u) then
                live = live + 1
                DumpUnit(u)
            end
        end
        if live == 0 then
            Print("|cffff8000No nameplate is on screen right now.|r Run this with "
                  .. "an enemy casting something in front of you.")
        end
    end,
}

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

ns.RegisterStatusProvider(25, function(yn)
    -- Two counts, not one: a readable "important" and a secret answer handed
    -- to the client are different things, and adding them together would
    -- report every casting mob in a dungeon as an important cast.
    local marked, armed = 0, 0
    for unit in pairs(markedUnit) do
        if not unreadable[unit] then marked = marked + 1 end
    end
    for _ in pairs(unreadable) do armed = armed + 1 end
    Print("important casts -- marker: " .. yn(db.icMarker)
          .. ", preview: " .. yn(previewMode) .. ", marked now: " .. marked
          .. ", unreadable (the game decides): " .. armed)

    local ticker = ns.GetTicker("importantcasts")
    if ticker and ticker.disabled then
        Print("|cffff4040Scan stopped.|r Last error: " .. tostring(ticker.err))
        Print("Change zone to retry. Please report this error.")
    end
end)

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

ns.RegisterOptionsSection{
    page = "Casts", pageOrder = 30, column = "left", order = 10,
    build = function(f, x, y)
        local ui = ns.ui
        y = ui.Header(f, "Important casts", x, y)
        y = ui.Check(f, x, y, "Mark casts the game flags important", db, "icMarker", LooksChanged)
        y = ui.Check(f, x, y, "Pulse", db, "icPulse", LooksChanged)
        return y
    end,
}

ns.RegisterOptionsSection{
    page = "Casts", pageOrder = 30, column = "left", order = 30,
    build = function(f, x, y)
        return ns.ui.Note(f, x, y - 10,
            "Read from the game's own important-cast flag, the same one\n"
            .. "that rings a boss's cast bar -- not a spell list this addon\n"
            .. "keeps, so it never goes stale.\n\n"
            .. "In dungeons and raids the game hides that flag from\n"
            .. "addons, so the game itself decides whether the marker\n"
            .. "shows. That is also why there is no sound for it.")
    end,
}

ns.RegisterOptionsSection{
    page = "Casts", pageOrder = 30, column = "right", order = 10,
    build = function(f, x, y)
        local ui = ns.ui
        y = ui.Header(f, "Appearance", x, y)
        y = ui.Slider(f, x, y, "Marker size", db, "icSize", 10, 72, 1, 0, LooksChanged)
        y = ui.Segmented(f, x, y, "Position", db, "icAnchor", {
            { text = "Left",   value = "LEFT"   },
            { text = "Right",  value = "RIGHT"  },
            { text = "Top",    value = "TOP"    },
            { text = "Bottom", value = "BOTTOM" },
        }, LooksChanged)
        y = ui.InputRow(f, x, y, "Symbol", db, {
            { label = "Symbol", key = "icGlyph" },
        }, LooksChanged)
        y = ui.Symbols(f, x, y, "Or an icon", db, "icGlyph", LooksChanged)
        y = ui.Note(f, x, y,
            "Icons keep their own colors; the color below tints text\n"
            .. "symbols only. {skull} typed in the box works too.")
        y = ui.Swatches(f, x, y, "Color", db, "icColor", LooksChanged, ns.COLOR_ORDER)

        y = ui.Button(f, x, y, "Preview marker on all nameplates",
            function() SetPreview(not previewMode) end,
            function()
                return previewMode
                       and "Stop marker preview"
                       or  "Preview marker on all nameplates"
            end)

        return ui.Note(f, x, y,
            "Marks every enemy nameplate so you can size and place the\n"
            .. "symbol on a target dummy. Ends when you change zone.")
    end,
}
