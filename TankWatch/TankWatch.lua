--------------------------------------------------------------------------------
-- TankWatch
--
-- A tank's answer to one question: "which pack member is about to leave me?"
--
-- EllesmereUI's nameplate module already colors individual plates by threat, so
-- this addon deliberately does NOT touch nameplates. It fills the other gap: a
-- single consolidated list of every enemy engaged with your group, ranked so the
-- mobs you have lost (or are about to lose) float to the top -- including mobs
-- whose nameplate is behind you, off-screen, or lost in a big pull.
--------------------------------------------------------------------------------

local ADDON, ns = ...

-- Hot-path upvalues. Refresh() runs ~5x/sec in combat and walks
-- (mobs x group members), so every global lookup here is one we do not pay for.
local UnitDetailedThreatSituation = UnitDetailedThreatSituation
local UnitExists                  = UnitExists
local UnitName                    = UnitName
local UnitCanAttack               = UnitCanAttack
local UnitIsDead                  = UnitIsDead
local UnitIsPlayer                = UnitIsPlayer
local UnitIsUnit                  = UnitIsUnit
local UnitPlayerOrPetInParty      = UnitPlayerOrPetInParty
local UnitPlayerOrPetInRaid       = UnitPlayerOrPetInRaid
local UnitAffectingCombat         = UnitAffectingCombat
local UnitGUID                    = UnitGUID
local UnitClassification          = UnitClassification
local UnitGroupRolesAssigned      = UnitGroupRolesAssigned
local GetTime                     = GetTime
local tsort, twipe                = table.sort, wipe
local min, max, floor             = math.min, math.max, math.floor

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

local defaults = {
    locked          = false,
    scale           = 1.0,
    width           = 250,
    rowHeight       = 20,
    maxRows         = 10,
    onlyTankSpec    = true,   -- hide entirely unless the player is a tank
    onlyInCombat    = true,   -- hide entirely out of combat
    hideWhenClean   = false,  -- hide while every mob is securely tanked
    sound           = true,   -- audible alert when a mob is lost
    warnThreshold   = 80,     -- rival % at which a tanked mob turns "warning"
    point           = { "CENTER", "CENTER", 250, 0 },

    -- Nameplate marker. Accessibility-first: the signal is a *glyph appearing*,
    -- not a hue change, so it carries no color information at all -- absence
    -- means "mine", presence means "not mine". Color is decoration on top.
    npMarker        = true,          -- mark mobs you do NOT have aggro on
    npMarkerWarn    = false,         -- also mark mobs you are about to lose
    npGlyph         = "!",           -- glyph for "you do not have this one"
    npWarnGlyph     = "?",           -- glyph for "about to lose this one"
    npSize          = 28,
    npAnchor        = "LEFT",        -- LEFT | RIGHT | TOP | BOTTOM
    npPulse         = true,          -- motion, a channel independent of color
    npColor         = { 1, 0.92, 0.15 },
}

local db  -- resolved at ADDON_LOADED

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local TW = CreateFrame("Frame", "TankWatchFrame", UIParent, "BackdropTemplate")
_G.TankWatch = TW

local rows       = {}     -- pooled display rows
local mobs       = {}     -- current scan results (recycled entry tables)
local mobPool    = {}     -- entry tables not currently in `mobs`
local seenGUID   = {}     -- GUID -> true, dedupe within one scan
local groupUnits = {}     -- cached "party1".. / "raid1".. tokens (no per-call concat)
local wasTanking = {}     -- GUID -> bool, drives the "you just lost it" alert
local skin                -- EllesmereUI skinning facade, once handed to us

local isTankRole  = false
local inCombat    = false
local testMode    = false
local lastAlert   = 0
local elapsed     = 0

local UPDATE_INTERVAL = 0.2
local ALERT_COOLDOWN  = 1.5

-- Threat states, ordered so a plain sort puts the urgent ones first.
local STATE_LOST   = 1   -- something else is tanking it
local STATE_WARN   = 2   -- you have it, but a rival is close behind
local STATE_SECURE = 3   -- yours, comfortably

local STATE_COLOR = {
    [STATE_LOST]   = { 0.92, 0.22, 0.22 },
    [STATE_WARN]   = { 1.00, 0.68, 0.10 },
    [STATE_SECURE] = { 0.22, 0.78, 0.35 },
}

-- Shared with the nameplate module, which reads this rather than recomputing
-- threat: the main scan already walks every visible nameplate each tick, so a
-- second pass would double the cost for identical answers.
ns.STATE_LOST   = STATE_LOST
ns.STATE_WARN   = STATE_WARN
ns.STATE_SECURE = STATE_SECURE
ns.stateByGUID  = {}
local stateByGUID = ns.stateByGUID

-- Replaced by TankWatch_Nameplates.lua. Stubbed here so the hot path can call
-- it unconditionally, and so the core still runs if that file is ever removed.
function ns.RefreshMarkers() end
function ns.MarkersLooksChanged() end
function ns.SetMarkerPreview(_) return false end
function ns.GetMarkerPreview() return false end

-- Replaced by TankWatch_Options.lua.
function ns.ToggleOptions() end
function ns.RefreshOptions() end

--------------------------------------------------------------------------------
-- Roster cache
--
-- Rebuilding the token list only on roster change keeps Refresh() free of
-- string concatenation, which is the actual cost in a mobs x members scan.
--------------------------------------------------------------------------------

local function RebuildGroupUnits()
    twipe(groupUnits)
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, n do groupUnits[#groupUnits + 1] = "raid" .. i end
    elseif n > 0 then
        for i = 1, n - 1 do groupUnits[#groupUnits + 1] = "party" .. i end
    end
end

local function UpdateRole()
    -- The player's own spec is authoritative: someone can queue as tank and then
    -- swap spec, and UnitGroupRolesAssigned still answers TANK for the old one.
    local C = C_SpecializationInfo
    local spec = (C and C.GetSpecialization and C.GetSpecialization())
              or (GetSpecialization and GetSpecialization())
    local role
    if spec then
        role = (C and C.GetSpecializationRole and C.GetSpecializationRole(spec))
             or (GetSpecializationRole and GetSpecializationRole(spec))
    end
    isTankRole = (role or UnitGroupRolesAssigned("player")) == "TANK"
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

local function ReleaseMobs()
    for i = #mobs, 1, -1 do
        mobPool[#mobPool + 1] = mobs[i]
        mobs[i] = nil
    end
end

local function AcquireMob()
    local e = mobPool[#mobPool]
    if e then
        mobPool[#mobPool] = nil
        return e
    end
    return {}
end

-- Find the group member (other than us) closest to ripping this mob away.
-- Only called for mobs we currently hold, where "who is about to take it" is
-- the number a tank actually needs.
local function TopRival(mobUnit)
    local bestPct, bestName = 0, nil
    for i = 1, #groupUnits do
        local u = groupUnits[i]
        if UnitExists(u) and not UnitIsDead(u) then
            local _, _, scaled = UnitDetailedThreatSituation(u, mobUnit)
            if scaled and scaled > bestPct then
                bestPct, bestName = scaled, UnitName(u)
            end
        end
    end
    return bestPct, bestName
end

local function AddMob(unit)
    if not UnitExists(unit) then return end
    if UnitIsPlayer(unit) then return end            -- threat is a PvE concept
    if not UnitCanAttack("player", unit) then return end
    if UnitIsDead(unit) then return end

    local guid = UnitGUID(unit)
    if not guid or seenGUID[guid] then return end

    local isTanking, status, scaled = UnitDetailedThreatSituation("player", unit)

    if not status then
        -- No threat entry at all: the mob has never been on our table. Keep it
        -- only if it is fighting *our group* -- that healer-grabbed add is the
        -- one a tank most needs to see, and the exact case a nameplate color
        -- cannot convey, since there is no threat data to color it with.
        -- Without the target check this would also scoop up every unrelated
        -- fight happening nearby in the open world.
        if not UnitAffectingCombat(unit) then return end
        local t = unit .. "target"
        if not (UnitExists(t) and (UnitIsUnit(t, "player")
                or UnitPlayerOrPetInParty(t) or UnitPlayerOrPetInRaid(t))) then
            return
        end
    end

    seenGUID[guid] = true

    local e = AcquireMob()
    e.guid      = guid
    e.unit      = unit
    e.name      = UnitName(unit) or UNKNOWN
    e.isTanking = isTanking and true or false
    e.elite     = (UnitClassification(unit) or "normal") ~= "normal"

    if e.isTanking then
        local rivalPct, rivalName = TopRival(unit)
        e.pct   = rivalPct
        e.other = rivalName
        -- status 2 means we hold it insecurely; treat that like a close rival.
        e.state = (status == 2 or rivalPct >= db.warnThreshold) and STATE_WARN or STATE_SECURE
    else
        -- We do not have it. Our own scaled % is now "how close are you to
        -- taking it back", and the mob's own target names the current holder.
        e.pct   = scaled or 0
        local t = unit .. "target"
        e.other = UnitExists(t) and UnitName(t) or nil
        e.state = STATE_LOST
    end

    stateByGUID[guid] = e.state
    mobs[#mobs + 1] = e
end

local function CollectMobs()
    ReleaseMobs()
    twipe(seenGUID)
    twipe(stateByGUID)

    if C_NamePlate and C_NamePlate.GetNamePlates then
        local plates = C_NamePlate.GetNamePlates()
        for i = 1, #plates do
            local token = plates[i].namePlateUnitToken
            if token then AddMob(token) end
        end
    end

    -- Boss frames catch encounter units with no nameplate in range.
    for i = 1, 8 do AddMob("boss" .. i) end

    -- Our own target may also be out of nameplate range (ranged pulls).
    AddMob("target")
end

local function SortMobs()
    tsort(mobs, function(a, b)
        if a.state ~= b.state then return a.state < b.state end
        if a.pct   ~= b.pct   then return a.pct > b.pct end
        return a.name < b.name
    end)
end

--------------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------------

local function CheckAlerts()
    local now, fire = GetTime(), false

    for i = 1, #mobs do
        local e = mobs[i]
        -- Alert only on a real transition (it was ours, now it is not), so
        -- fresh pulls and wandering patrols stay quiet.
        if wasTanking[e.guid] and not e.isTanking then fire = true end
        wasTanking[e.guid] = e.isTanking
    end

    if fire and now - lastAlert > ALERT_COOLDOWN then
        lastAlert = now
        if db.sound then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
        TW.flash:SetAlpha(0.8)
    end
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local function PositionRow(row, index)
    row:SetHeight(db.rowHeight)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT",  TW.body, "TOPLEFT",  0, -(index - 1) * (db.rowHeight + 1))
    row:SetPoint("TOPRIGHT", TW.body, "TOPRIGHT", 0, -(index - 1) * (db.rowHeight + 1))
end

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, TW.body)
    PositionRow(row, index)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.06)

    -- Fill length is the threat percentage, so the row reads at a glance
    -- without anyone parsing the number mid-pull.
    row.fill = row:CreateTexture(nil, "ARTWORK")
    row.fill:SetPoint("TOPLEFT")
    row.fill:SetPoint("BOTTOMLEFT")
    row.fill:SetColorTexture(1, 1, 1, 1)

    row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.pct:SetPoint("RIGHT", -5, 0)
    row.pct:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 5, 0)
    row.name:SetPoint("RIGHT", row.pct, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")

    if skin then
        skin.Font(row.name)
        skin.Font(row.pct)
    end

    rows[index] = row
    return row
end

local TEST_DATA = {
    { name = "Ghastly Voidsoul", state = STATE_LOST,   pct = 62, other = "Healbot",  isTanking = false, elite = false },
    { name = "Xylar the Cruel",  state = STATE_WARN,   pct = 91, other = "Stabbems", isTanking = true,  elite = true  },
    { name = "Void Adept",       state = STATE_SECURE, pct = 44, other = "Pewpew",   isTanking = true,  elite = false },
}

local function UpdateDisplay()
    local list  = testMode and TEST_DATA or mobs
    local width = TW.body:GetWidth()
    local shown = 0

    for i = 1, db.maxRows do
        local e = list[i]
        if not e then break end

        local row = rows[i] or CreateRow(i)
        local c = STATE_COLOR[e.state]

        row.fill:SetColorTexture(c[1], c[2], c[3], 0.35)
        row.fill:SetWidth(max(1, width * min(e.pct, 100) / 100))

        row.name:SetText(e.elite and ("|cffffd100+|r " .. e.name) or e.name)
        row.name:SetTextColor(c[1], c[2], c[3])

        if e.isTanking then
            -- Tanked: the number is the rival closing on us.
            row.pct:SetText(e.other and format("%s %d%%", e.other, e.pct)
                                     or format("%d%%", e.pct))
        else
            -- Lost: who holds it matters more than our own climb back.
            row.pct:SetText(e.other and format("|cffff4040on %s|r", e.other)
                                     or format("%d%%", e.pct))
        end

        row:Show()
        shown = i
    end

    for i = shown + 1, #rows do rows[i]:Hide() end

    TW.title:SetText(shown > 0 and format("Threat  |cff888888(%d)|r", shown) or "Threat")
    TW.body:SetHeight(max(db.rowHeight, shown * (db.rowHeight + 1)))
    TW:SetHeight(TW.body:GetHeight() + 26)
end

--------------------------------------------------------------------------------
-- Visibility + main loop
--------------------------------------------------------------------------------

local function ShouldShow()
    if testMode then return true end
    if db.onlyTankSpec and not isTankRole then return false end
    if db.onlyInCombat and not inCombat then return false end
    if #mobs == 0 then return false end
    if db.hideWhenClean then
        for i = 1, #mobs do
            if mobs[i].state ~= STATE_SECURE then return true end
        end
        return false
    end
    return true
end

function TW:Refresh()
    if db.onlyTankSpec and not isTankRole and not testMode then
        ReleaseMobs()
        twipe(stateByGUID)
        ns.RefreshMarkers()
        self:Hide()
        return
    end

    -- The real scan runs even in test mode: test mode fakes the *list rows*
    -- only, so the nameplate markers must keep tracking live threat rather than
    -- freezing while someone drags the frame around.
    CollectMobs()
    SortMobs()
    ns.RefreshMarkers()

    -- Skipped while testing, so positioning the frame never triggers a
    -- surprise raid-warning sound.
    if not testMode then CheckAlerts() end

    if ShouldShow() then
        UpdateDisplay()
        self:Show()
    else
        self:Hide()
    end
end

-- The ticker deliberately does NOT live on TW: OnUpdate stops firing on a
-- hidden frame, so hosting it here would mean the list could hide itself once
-- and never reappear. `ev` is a bare, always-shown frame, so it keeps ticking.
local function OnTick(_, e)
    elapsed = elapsed + e
    if elapsed < UPDATE_INTERVAL then return end
    elapsed = 0

    -- Idle fast path: when we are gated off there is nothing worth scanning,
    -- so out-of-combat and non-tank play costs one comparison per tick.
    if not testMode
       and ((db.onlyTankSpec and not isTankRole) or (db.onlyInCombat and not inCombat)) then
        if TW:IsShown() then TW:Hide() end
        -- Markers follow the same gating, so drop any left over from the
        -- moment combat ended rather than freezing them on screen.
        if next(stateByGUID) then
            twipe(stateByGUID)
            ns.RefreshMarkers()
        elseif ns.GetMarkerPreview() then
            -- Preview is exempt from the gating on purpose: judging the marker
            -- means standing at a target dummy, out of combat, quite possibly
            -- on the wrong spec. Without this it would show nothing there.
            ns.RefreshMarkers()
        end
        return
    end

    TW:Refresh()

    local a = TW.flash:GetAlpha()
    if a > 0 then TW.flash:SetAlpha(max(0, a - 0.12)) end
end

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

local function ApplyLock()
    -- Locked means click-through, so the list never eats a mouse-turn or a
    -- ground-targeted ability during a pull.
    TW:EnableMouse(not db.locked)
end

--------------------------------------------------------------------------------
-- Actions shared with the options panel, so the window and the slash commands
-- drive the same code instead of two copies drifting apart.
--------------------------------------------------------------------------------

ns.ApplyLock = ApplyLock

function ns.ApplyDisplay()
    TW:SetScale(db.scale)
    TW:SetWidth(db.width)
end

function ns.SetTestMode(on)
    testMode = on and true or false
    TW:Refresh()
    return testMode
end

function ns.GetTestMode()
    return testMode
end

function ns.ResetPosition()
    db.point = { "CENTER", "CENTER", 250, 0 }
    db.scale = 1.0
    TW:SetScale(1.0)
    TW:ClearAllPoints()
    TW:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
end

local function BuildFrame()
    TW:SetSize(db.width, 120)
    TW:SetScale(db.scale)
    TW:SetClampedToScreen(true)
    TW:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    TW:SetBackdropColor(0, 0, 0, 0.72)
    TW:SetBackdropBorderColor(0, 0, 0, 1)

    TW.title = TW:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    TW.title:SetPoint("TOPLEFT", 7, -7)
    TW.title:SetText("Threat")

    TW.body = CreateFrame("Frame", nil, TW)
    TW.body:SetPoint("TOPLEFT", 4, -22)
    TW.body:SetPoint("TOPRIGHT", -4, -22)
    TW.body:SetHeight(db.rowHeight)

    -- Red wash on losing a mob: peripheral-vision feedback that does not
    -- require reading the list mid-pull. It lives on a child frame rather than
    -- on TW because S.Shell alpha-outs every texture region on the frame it
    -- skins, which would silently kill the flash for EllesmereUI users.
    local flashHolder = CreateFrame("Frame", nil, TW)
    flashHolder:SetAllPoints()
    flashHolder:SetFrameLevel(TW:GetFrameLevel() + 10)
    TW.flash = flashHolder:CreateTexture(nil, "OVERLAY")
    TW.flash:SetAllPoints()
    TW.flash:SetColorTexture(1, 0, 0, 0.35)
    TW.flash:SetAlpha(0)

    TW:SetMovable(true)
    TW:RegisterForDrag("LeftButton")
    TW:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    TW:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        db.point = { p, rp, x, y }
    end)

    TW:ClearAllPoints()
    TW:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
    TW:Hide()
end

--------------------------------------------------------------------------------
-- EllesmereUI integration
--
-- Registration is free and silently no-ops when EUI is absent or the user has
-- third-party skinning turned off, so it needs no setting of our own.
--------------------------------------------------------------------------------

local function RegisterEUISkin()
    if not (EllesmereUI and EllesmereUI.RegisterSkin) then return end

    EllesmereUI.RegisterSkin("TankWatch", function(S)
        skin = S
        -- Drop our own backdrop first: S.Shell fades *texture regions*, and a
        -- backdrop is not one, so leaving it would sit under the EUI shell.
        TW:SetBackdrop(nil)
        S.Shell(TW)
        S.Font(TW.title)
        for i = 1, #rows do
            S.Font(rows[i].name)
            S.Font(rows[i].pct)
        end
    end)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        TankWatchDB = TankWatchDB or {}
        for k, v in pairs(defaults) do
            if TankWatchDB[k] == nil then
                -- Copy table defaults rather than aliasing them, so a saved
                -- value can never write back into `defaults`.
                if type(v) == "table" then
                    local t = {}
                    for i = 1, #v do t[i] = v[i] end
                    TankWatchDB[k] = t
                else
                    TankWatchDB[k] = v
                end
            end
        end
        db = TankWatchDB
        ns.db = db
        BuildFrame()
        ApplyLock()
        RegisterEUISkin()
        -- Started only now, so the ticker never runs against a nil db.
        ev:SetScript("OnUpdate", OnTick)

    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        UpdateRole()
        RebuildGroupUnits()
        inCombat = UnitAffectingCombat("player") and true or false

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        twipe(wasTanking)

    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildGroupUnits()
        UpdateRole()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        UpdateRole()
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TankWatch|r: " .. msg)
end

SLASH_TANKWATCH1 = "/tankwatch"
SLASH_TANKWATCH2 = "/tw"

SlashCmdList.TANKWATCH = function(input)
    -- Case is folded for the command and for keyword arguments, but `arg` is
    -- kept verbatim so /tw npglyph can take an uppercase glyph.
    local cmd, arg = strsplit(" ", strtrim(input or ""), 2)
    cmd = strlower(cmd or "")
    arg = arg and strtrim(arg) or nil
    local larg = arg and strlower(arg) or nil
    local n = tonumber(arg)

    if cmd == "lock" then
        db.locked = true
        ApplyLock()
        Print("frame locked (click-through).")

    elseif cmd == "unlock" then
        db.locked = false
        ApplyLock()
        Print("frame unlocked -- drag to move.")

    elseif cmd == "test" then
        local on = ns.SetTestMode(not ns.GetTestMode())
        Print("test mode " .. (on and "|cff00ff00on|r." or "|cffff0000off|r."))

    elseif cmd == "config" or cmd == "options" or cmd == "opt" then
        ns.ToggleOptions()

    elseif cmd == "scale" then
        if n and n >= 0.5 and n <= 2.0 then
            db.scale = n
            ns.ApplyDisplay()
            Print("scale set to " .. n .. ".")
        else
            Print("usage: /tw scale 0.5 - 2.0")
        end

    elseif cmd == "width" then
        if n and n >= 120 and n <= 600 then
            db.width = floor(n)
            ns.ApplyDisplay()
            Print("width set to " .. db.width .. ".")
        else
            Print("usage: /tw width 120 - 600")
        end

    elseif cmd == "rows" then
        if n and n >= 1 and n <= 40 then
            db.maxRows = floor(n)
            Print("showing up to " .. db.maxRows .. " rows.")
        else
            Print("usage: /tw rows 1 - 40")
        end

    elseif cmd == "warn" then
        if n and n >= 1 and n <= 100 then
            db.warnThreshold = n
            Print("warning threshold set to " .. n .. "%.")
        else
            Print("usage: /tw warn 1 - 100")
        end

    elseif cmd == "sound" then
        db.sound = not db.sound
        Print("lost-mob sound " .. (db.sound and "enabled." or "disabled."))

    elseif cmd == "np" then
        db.npMarker = not db.npMarker
        ns.MarkersLooksChanged()
        Print("nameplate marker " .. (db.npMarker and "enabled." or "disabled."))

    elseif cmd == "nptest" or cmd == "nppreview" then
        local on = ns.SetMarkerPreview(not ns.GetMarkerPreview())
        if on then
            Print("marker preview |cff00ff00on|r -- every enemy nameplate is "
                  .. "marked so you can see the symbol. It ends on zone change, "
                  .. "or run |cffffff00/tw nptest|r again.")
        else
            Print("marker preview |cffff0000off|r.")
        end

    elseif cmd == "npwarn" then
        db.npMarkerWarn = not db.npMarkerWarn
        ns.MarkersLooksChanged()
        Print("at-risk nameplate marker " .. (db.npMarkerWarn and "enabled." or "disabled."))

    elseif cmd == "nppulse" then
        db.npPulse = not db.npPulse
        ns.MarkersLooksChanged()
        Print("marker pulse " .. (db.npPulse and "enabled." or "disabled."))

    elseif cmd == "npsize" then
        if n and n >= 10 and n <= 72 then
            db.npSize = floor(n)
            ns.MarkersLooksChanged()
            Print("marker size set to " .. db.npSize .. ".")
        else
            Print("usage: /tw npsize 10 - 72")
        end

    elseif cmd == "npanchor" then
        local a = larg and strupper(larg) or ""
        if a == "LEFT" or a == "RIGHT" or a == "TOP" or a == "BOTTOM" then
            db.npAnchor = a
            ns.MarkersLooksChanged()
            Print("marker anchored to the " .. strlower(a) .. " of the nameplate.")
        else
            Print("usage: /tw npanchor left | right | top | bottom")
        end

    elseif cmd == "npglyph" then
        if arg and arg ~= "" then
            db.npGlyph = arg
            ns.MarkersLooksChanged()
            Print("marker glyph set to \"" .. arg .. "\".")
        else
            Print("usage: /tw npglyph <text>   (e.g. /tw npglyph !!)")
        end

    elseif cmd == "npcolor" then
        local preset = larg and ns.COLOR_PRESETS and ns.COLOR_PRESETS[larg]
        if preset then
            db.npColor = { preset[1], preset[2], preset[3] }
            ns.MarkersLooksChanged()
            Print("marker color set to " .. arg .. ".")
        else
            Print("usage: /tw npcolor white | yellow | cyan | magenta | orange")
        end

    elseif cmd == "tankonly" then
        db.onlyTankSpec = not db.onlyTankSpec
        Print("tank-spec-only " .. (db.onlyTankSpec and "enabled." or "disabled."))

    elseif cmd == "ooc" then
        db.onlyInCombat = not db.onlyInCombat
        Print("combat-only display " .. (db.onlyInCombat and "enabled." or "disabled."))

    elseif cmd == "clean" then
        db.hideWhenClean = not db.hideWhenClean
        Print("hide-while-all-secure " .. (db.hideWhenClean and "enabled." or "disabled."))

    elseif cmd == "reset" then
        ns.ResetPosition()
        ns.RefreshOptions()
        Print("position and scale reset.")

    else
        Print("commands:")
        Print("  |cffffff00/tw config|r       -- open the settings window")
        Print("  |cffffff00/tw unlock|r / |cffffff00lock|r -- move the frame")
        Print("  |cffffff00/tw test|r         -- fake rows for positioning")
        Print("  |cffffff00/tw scale|r <n>    -- 0.5 to 2.0")
        Print("  |cffffff00/tw width|r <n>    -- 120 to 600 pixels")
        Print("  |cffffff00/tw rows|r <n>     -- max rows shown")
        Print("  |cffffff00/tw warn|r <n>     -- rival % that turns a mob orange")
        Print("  |cffffff00/tw sound|r        -- toggle lost-mob sound")
        Print("  |cffffff00/tw tankonly|r     -- toggle tank-spec-only")
        Print("  |cffffff00/tw ooc|r          -- toggle combat-only")
        Print("  |cffffff00/tw clean|r        -- toggle hiding while all secure")
        Print("  |cffffff00/tw reset|r        -- reset position and scale")
        Print("nameplate marker (colorblind-friendly):")
        Print("  |cffffff00/tw np|r           -- toggle the marker")
        Print("  |cffffff00/tw nptest|r       -- preview it on every nameplate")
        Print("  |cffffff00/tw npwarn|r       -- also mark mobs you may lose")
        Print("  |cffffff00/tw nppulse|r      -- toggle the pulse")
        Print("  |cffffff00/tw npsize|r <n>   -- 10 to 72")
        Print("  |cffffff00/tw npanchor|r <p> -- left | right | top | bottom")
        Print("  |cffffff00/tw npglyph|r <t>  -- symbol to show (default !)")
        Print("  |cffffff00/tw npcolor|r <c>  -- white | yellow | cyan | magenta | orange")
    end

    -- Slash commands and the settings window edit the same table, so pull the
    -- window back into sync rather than letting it show stale values.
    ns.RefreshOptions()
end
