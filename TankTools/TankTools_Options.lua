--------------------------------------------------------------------------------
-- Tank Tools -- settings window
--
-- A standalone, movable panel rather than a page inside Blizzard's Settings
-- frame, for one practical reason: most of these options are things you judge
-- by looking at the result. Marker size, position, symbol and color all want
-- real nameplates visible while you drag the slider, and the Settings window
-- covers most of the screen. A small floating panel lets you see what you are
-- changing -- turn on the preview and adjust against live plates.
--
-- A stub page IS registered under ESC > Options > AddOns so the addon is
-- discoverable in the usual place; it just opens this window.
--
-- Widgets are built from core widget types and long-lived Blizzard templates
-- (UICheckButtonTemplate, UIPanelButtonTemplate, InputBoxTemplate) rather than
-- the Settings-era ones, and the anchor/color pickers are segmented buttons
-- instead of dropdowns -- the dropdown API was rewritten in 11.0 and there is
-- no reason to take a dependency on it for a four-way choice.
--------------------------------------------------------------------------------

local _, ns = ...

local floor, abs = math.floor, math.abs
local format     = string.format
local tinsert    = table.insert

local skin          -- host UI skinning facade, if one is present
local panel         -- the window
local controls = {} -- everything with a :Refresh(), replayed by RefreshOptions

local PAD   = 16
local COL_W = 258

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function FontPath()
    return (GameFontNormal:GetFont())
end

local function Label(parent, text, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FontPath(), size or 12, "")
    fs:SetTextColor(r or 0.9, g or 0.9, b or 0.9)
    fs:SetText(text)
    if skin then skin.Font(fs, r or 0.9, g or 0.9, b or 0.9) end
    return fs
end

-- Section heading plus a hairline rule, so the three groups read as groups
-- without needing boxes around them.
local function Header(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FontPath(), 13, "OUTLINE")
    fs:SetTextColor(1, 0.82, 0.2)
    fs:SetText(text)
    fs:SetPoint("TOPLEFT", x, y)

    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.12)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", x, y - 18)
    rule:SetWidth(COL_W)

    return y - 30
end

--------------------------------------------------------------------------------
-- Controls
--
-- Each returns the next free Y, so a column is built by threading y through
-- the calls and nothing carries a hand-computed offset.
--------------------------------------------------------------------------------

local function Check(parent, x, y, text, key, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)

    -- Own label rather than the template's, which has moved between builds.
    local fs = Label(cb, text, 12)
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)

    -- Extend the click target across the label: a 24px box is a small target
    -- to hit repeatedly while comparing settings.
    cb:SetHitRectInsets(0, -(fs:GetStringWidth() + 8), 0, 0)

    cb:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        if onChange then onChange() end
        ns.RefreshOptions()
    end)

    cb.Refresh = function() cb:SetChecked(ns.db[key]) end
    controls[#controls + 1] = cb
    if skin then skin.Checkbox(cb) end

    return y - 26
end

local function Slider(parent, x, y, text, key, minV, maxV, step, decimals, onChange)
    local lbl = Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    local val = Label(parent, "", 12, 1, 0.82, 0.2)
    val:SetPoint("TOPLEFT", x + COL_W - 44, y)
    val:SetJustifyH("RIGHT")
    val:SetWidth(44)

    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetPoint("TOPLEFT", x, y - 16)
    s:SetSize(COL_W - 4, 16)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.14)
    track:SetHeight(3)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")

    s:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = s:GetThumbTexture()
    thumb:SetSize(8, 16)
    thumb:SetColorTexture(0.95, 0.95, 0.95, 1)

    local fmt = "%." .. (decimals or 0) .. "f"

    s:SetScript("OnValueChanged", function(self, v)
        if self._refreshing then return end
        -- Snap explicitly: OBEY_STEP applies to dragging, not SetValue.
        v = floor((v / step) + 0.5) * step
        ns.db[key] = (decimals and decimals > 0) and v or floor(v)
        val:SetText(format(fmt, ns.db[key]))
        if onChange then onChange() end
    end)

    s.Refresh = function()
        s._refreshing = true
        s:SetValue(ns.db[key])
        val:SetText(format(fmt, ns.db[key]))
        s._refreshing = false
    end
    controls[#controls + 1] = s

    return y - 40
end

-- Segmented picker. Used instead of a dropdown for small, fixed choice sets:
-- every option stays visible, which suits "which side of the nameplate" far
-- better than a collapsed list.
local function Segmented(parent, x, y, text, key, options, onChange)
    local lbl = Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    local buttons = {}
    local n = #options
    local gap = 4
    local bw = (COL_W - (gap * (n - 1))) / n

    for i, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(bw, 20)
        b:SetPoint("TOPLEFT", x + (i - 1) * (bw + gap), y - 16)
        b:SetText(opt.text)

        local sel = b:CreateTexture(nil, "OVERLAY")
        sel:SetColorTexture(1, 1, 1, 0.16)
        sel:SetAllPoints()
        sel:Hide()
        b.sel = sel

        b:SetScript("OnClick", function()
            ns.db[key] = opt.value
            if onChange then onChange() end
            ns.RefreshOptions()
        end)

        if skin then skin.Button(b) end
        buttons[i] = b
    end

    local holder = CreateFrame("Frame", nil, parent)
    holder.Refresh = function()
        for i, opt in ipairs(options) do
            local on = (ns.db[key] == opt.value)
            buttons[i].sel:SetShown(on)
            -- Selection is carried by the fill *and* the label brightness, so
            -- it does not rest on one visual cue alone.
            local t = buttons[i]:GetFontString()
            if t then t:SetTextColor(on and 1 or 0.55, on and 1 or 0.55, on and 1 or 0.55) end
        end
    end
    controls[#controls + 1] = holder

    return y - 42
end

-- Color swatches. Deliberately NOT skinned: a swatch has to show its own
-- color, which is the one case the skinning guide says to draw yourself.
local function Swatches(parent, x, y, text, key, onChange, order)
    local lbl = Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    -- The nameplate module owns the palette and decides which slice of it
    -- suits each swatch row -- loud presets for the alert glyphs, quiet ones
    -- for the aggro glyph.
    order = order or ns.COLOR_ORDER or { "white", "yellow", "cyan", "magenta", "orange" }
    local presets = ns.COLOR_PRESETS or {}
    local buttons = {}
    local size, gap = 26, 6

    for i, name in ipairs(order) do
        local c = presets[name]
        if c then
            local b = CreateFrame("Button", nil, parent)
            b:SetSize(size, size)
            b:SetPoint("TOPLEFT", x + (i - 1) * (size + gap), y - 16)

            local tex = b:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("TOPLEFT", 2, -2)
            tex:SetPoint("BOTTOMRIGHT", -2, 2)
            tex:SetColorTexture(c[1], c[2], c[3], 1)

            -- BACKGROUND, below the 2px-inset color above it, so this reads
            -- as a border around the swatch. At OVERLAY it covered the colour
            -- outright and every selected swatch rendered solid white.
            local ring = b:CreateTexture(nil, "BACKGROUND")
            ring:SetAllPoints()
            ring:SetColorTexture(1, 1, 1, 1)
            ring:Hide()
            b.ring = ring
            b.color = c

            b:SetScript("OnClick", function()
                ns.db[key] = { c[1], c[2], c[3] }
                if onChange then onChange() end
                ns.RefreshOptions()
            end)

            buttons[#buttons + 1] = b
        end
    end

    local holder = CreateFrame("Frame", nil, parent)
    holder.Refresh = function()
        local cur = ns.db[key] or {}
        for _, b in ipairs(buttons) do
            local c = b.color
            -- Float-safe compare; these are literals from the same table, but
            -- they make a round trip through SavedVariables.
            local same = abs((cur[1] or 0) - c[1]) < 0.01
                     and abs((cur[2] or 0) - c[2]) < 0.01
                     and abs((cur[3] or 0) - c[3]) < 0.01
            b.ring:SetShown(same)
        end
    end
    controls[#controls + 1] = holder

    return y - 46
end

-- Several one-character fields on a single line. The glyphs are chosen
-- against each other -- the whole point is that the three silhouettes stay
-- distinct -- so they belong side by side, and the column has no vertical room
-- for three stacked fields anyway.
local function InputRow(parent, x, y, text, specs, onChange)
    local lbl = Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    local n   = #specs
    local gap = 8
    local bw  = (COL_W - gap * (n - 1)) / n

    for i = 1, n do
        local spec = specs[i]
        local bx   = x + (i - 1) * (bw + gap)

        local sub = Label(parent, spec.label, 11, 0.6, 0.6, 0.6)
        sub:SetPoint("TOPLEFT", bx + 6, y - 17)

        local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        eb:SetSize(bw - 14, 20)
        eb:SetPoint("TOPLEFT", bx + 6, y - 31)
        eb:SetAutoFocus(false)
        eb:SetMaxLetters(8)
        eb:SetFontObject("GameFontHighlight")

        local function commit()
            local v = strtrim(eb:GetText() or "")
            -- An empty glyph would be a marker that shows nothing, which reads
            -- exactly like the marker being broken. Refuse it and snap back.
            if v ~= "" then
                ns.db[spec.key] = v
                if onChange then onChange() end
            end
            eb:ClearFocus()
            ns.RefreshOptions()
        end

        eb:SetScript("OnEnterPressed", commit)
        eb:SetScript("OnEditFocusLost", commit)
        eb:SetScript("OnEscapePressed", function()
            eb:ClearFocus()
            ns.RefreshOptions()
        end)

        eb.Refresh = function()
            if not eb:HasFocus() then eb:SetText(ns.db[spec.key] or "") end
        end
        controls[#controls + 1] = eb
        if skin then skin.EditBox(eb) end
    end

    return y - 58
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function BuildPanel()
    local f = CreateFrame("Frame", "TankToolsOptionsFrame", UIParent, "BackdropTemplate")
    f:SetSize(PAD * 3 + COL_W * 2, 410)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    f:SetBackdropBorderColor(0, 0, 0, 1)

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Escape closes it, like every other WoW panel.
    tinsert(UISpecialFrames, "TankToolsOptionsFrame")

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(FontPath(), 15, "OUTLINE")
    f.title:SetTextColor(1, 1, 1)
    f.title:SetText("Tank Tools")
    f.title:SetPoint("TOPLEFT", PAD, -12)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -4, -4)

    panel = f
    return f
end

local function BuildContents(f)
    local applyMarkers = ns.MarkersLooksChanged

    ----------------------------------------------------------------- left ----
    local x, y = PAD, -42

    y = Header(f, "Markers", x, y)
    -- The three states are independent switches rather than a master plus two
    -- extras, so "only tell me which ones are mine" is a setting you can
    -- actually reach.
    y = Check(f, x, y, "Mark mobs I do NOT have aggro on", "npMarker", applyMarkers)
    y = Check(f, x, y, "Mark mobs at risk of being pulled", "npMarkerWarn", applyMarkers)
    y = Check(f, x, y, "Mark mobs I DO have aggro on", "npMarkerSecure", applyMarkers)
    y = Check(f, x, y, "Pulse (alert markers only)", "npPulse", applyMarkers)

    y = y - 10
    y = Header(f, "General", x, y)
    y = Check(f, x, y, "Only in a tank spec", "onlyTankSpec")
    y = Check(f, x, y, "Sound when a mob stops being yours", "sound")

    y = y - 10
    local note = Label(f, "The markers signal by shape and by appearing at all,\nnot by color, so they stay readable in grayscale.",
                       11, 0.6, 0.6, 0.6)
    note:SetPoint("TOPLEFT", x, y)
    note:SetJustifyH("LEFT")

    ---------------------------------------------------------------- right ----
    local rx, ry = PAD * 2 + COL_W, -42

    ry = Header(f, "Appearance", rx, ry)
    ry = Slider(f, rx, ry, "Marker size", "npSize", 10, 72, 1, 0, applyMarkers)
    ry = Segmented(f, rx, ry, "Position", "npAnchor", {
        { text = "Left",   value = "LEFT"   },
        { text = "Right",  value = "RIGHT"  },
        { text = "Top",    value = "TOP"    },
        { text = "Bottom", value = "BOTTOM" },
    }, applyMarkers)
    ry = InputRow(f, rx, ry, "Symbols", {
        { label = "Not mine", key = "npGlyph"       },
        { label = "At risk",  key = "npWarnGlyph"   },
        { label = "Mine",     key = "npSecureGlyph" },
    }, applyMarkers)
    ry = Swatches(f, rx, ry, "Alert color", "npColor", applyMarkers, ns.COLOR_ORDER)
    ry = Swatches(f, rx, ry, "Aggro color", "npSecureColor", applyMarkers,
                  ns.COLOR_ORDER_SECURE)

    -- Preview lives with the appearance settings rather than off in a button
    -- bar: it exists to be toggled while adjusting size and position, and
    -- every control it relates to is directly above it.
    local prev = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prev:SetSize(COL_W, 22)
    prev:SetPoint("TOPLEFT", rx, ry)
    prev:SetScript("OnClick", function()
        ns.SetMarkerPreview(not ns.GetMarkerPreview())
        ns.RefreshOptions()
    end)
    prev.Refresh = function()
        prev:SetText(ns.GetMarkerPreview()
                     and "Stop marker preview"
                     or  "Preview marker on all nameplates")
    end
    controls[#controls + 1] = prev
    if skin then skin.Button(prev) end
    ry = ry - 28

    local pnote = Label(f, "Marks every enemy nameplate so you can size and place the\nsymbols on a target dummy -- each enabled symbol is spread\nover the mobs on screen. Ends when you change zone.",
                        11, 0.55, 0.55, 0.55)
    pnote:SetPoint("TOPLEFT", rx, ry)
    pnote:SetJustifyH("LEFT")
end

--------------------------------------------------------------------------------
-- Public entry points
--------------------------------------------------------------------------------

function ns.RefreshOptions()
    if not panel or not panel:IsShown() then return end
    for i = 1, #controls do
        local c = controls[i]
        if c.Refresh then c.Refresh() end
    end
end

-- Skins the window chrome. The individual widgets skin themselves as they are
-- constructed; this covers the parts that only exist once the panel does.
local function SkinPanel()
    if not (skin and panel) or panel._skinned then return end
    panel._skinned = true
    -- Our own backdrop must go first: S.Shell fades texture regions, and a
    -- backdrop is not one, so it would show through the skinned shell.
    panel:SetBackdrop(nil)
    skin.Shell(panel)
    skin.Font(panel.title)
    skin.CloseButton(panel.close)
end

function ns.ShowOptions()
    if not ns.db then return end
    if not panel then
        BuildPanel()
        BuildContents(panel)
        -- The panel is built lazily, on first open, which is long after any
        -- skin callback has already run. Skinning here is what actually
        -- catches it; the callback below only matters if the window happens to
        -- already exist when the host UI drains its queue.
        SkinPanel()
    end
    panel:Show()
    ns.RefreshOptions()
end

function ns.ToggleOptions()
    if panel and panel:IsShown() then
        panel:Hide()
    else
        ns.ShowOptions()
    end
end

--------------------------------------------------------------------------------
-- Optional skinning + Blizzard Settings entry
--------------------------------------------------------------------------------

if EllesmereUI and EllesmereUI.RegisterSkin then
    EllesmereUI.RegisterSkin("TankToolsOptions", function(S)
        -- Keeping S is the important part: the window is built on first open,
        -- normally well after this runs, and every widget constructor calls
        -- these primitives itself -- the usual pattern for lazily created
        -- frames.
        skin = S
        if not panel then return end

        SkinPanel()
        for i = 1, #controls do
            local c = controls[i]
            if c.GetObjectType then
                local t = c:GetObjectType()
                if t == "CheckButton" then S.Checkbox(c)
                elseif t == "EditBox"  then S.EditBox(c)
                elseif t == "Button"   then S.Button(c) end
            end
        end
    end)
end

-- Discoverable in the usual place. The page is only a launcher: the real
-- controls want the game world visible behind them.
local function RegisterSettingsStub()
    if not (Settings and Settings.RegisterCanvasLayoutCategory
            and Settings.RegisterAddOnCategory) then
        return
    end

    local holder = CreateFrame("Frame")
    holder.name = "Tank Tools"

    local title = holder:CreateFontString(nil, "OVERLAY")
    title:SetFont(FontPath(), 17, "OUTLINE")
    title:SetPoint("TOPLEFT", 12, -14)
    title:SetText("Tank Tools")

    local desc = holder:CreateFontString(nil, "OVERLAY")
    desc:SetFont(FontPath(), 12, "")
    desc:SetTextColor(0.75, 0.75, 0.75)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("These settings open in their own window, so you can see\nthe threat list change while you adjust it.")
    desc:SetJustifyH("LEFT")

    local open = CreateFrame("Button", nil, holder, "UIPanelButtonTemplate")
    open:SetSize(200, 24)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    open:SetText("Open Tank Tools settings")
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        ns.ShowOptions()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(holder, "Tank Tools")
    Settings.RegisterAddOnCategory(category)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    RegisterSettingsStub()
end)
