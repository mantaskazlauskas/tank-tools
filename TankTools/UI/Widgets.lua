--------------------------------------------------------------------------------
-- Tank Tools -- settings widgets
--
-- The widget kit, separated from the window that hosts it so a new module can
-- add a settings page without copying a checkbox constructor.
--
-- Every widget takes the settings table it edits as an explicit argument
-- rather than reaching for a global `ns.db`. That is what lets two modules put
-- a control named the same thing on the same page and have them edit
-- different settings -- and it is why a widget cannot be pointed at another
-- module's table by accident.
--
-- Widgets are built from core widget types and long-lived Blizzard templates
-- (UICheckButtonTemplate, UIPanelButtonTemplate, InputBoxTemplate) rather than
-- the Settings-era ones, and pickers are segmented buttons instead of
-- dropdowns -- the dropdown API was rewritten in 11.0 and there is no reason
-- to take a dependency on it for a four-way choice.
--
-- Each constructor returns the next free Y, so a column is built by threading
-- y through the calls and nothing carries a hand-computed offset.
--------------------------------------------------------------------------------

local _, ns = ...

local floor, abs = math.floor, math.abs
local format     = string.format

local ui = {}
ns.ui = ui

ui.PAD   = 16
ui.COL_W = 258

-- The host UI skinning facade, when one is present. Set by UI/Options.lua as
-- soon as the host hands it over; read here at construction time, which is
-- what makes lazily built widgets pick it up.
ui.skin = nil

-- Everything with a :Refresh(), replayed by ns.RefreshOptions.
ui.controls = {}

local function Add(c)
    ui.controls[#ui.controls + 1] = c
    return c
end
ui.Add = Add

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

function ui.FontPath()
    return (GameFontNormal:GetFont())
end

function ui.Label(parent, text, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(ui.FontPath(), size or 12, "")
    fs:SetTextColor(r or 0.9, g or 0.9, b or 0.9)
    fs:SetText(text)
    if ui.skin then ui.skin.Font(fs, r or 0.9, g or 0.9, b or 0.9) end
    return fs
end

-- Section heading plus a hairline rule, so groups read as groups without
-- needing boxes around them.
function ui.Header(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(ui.FontPath(), 13, "OUTLINE")
    fs:SetTextColor(1, 0.82, 0.2)
    fs:SetText(text)
    fs:SetPoint("TOPLEFT", x, y)

    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.12)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", x, y - 18)
    rule:SetWidth(ui.COL_W)

    return y - 30
end

-- Multi-line notes are laid out by a caller that only knows its own newlines,
-- so hand back a Y that has actually cleared the text -- which is what lets
-- the panel size itself to its content instead of to a remembered number.
-- A scratch string kept off screen, purely to measure with. It never has a
-- width set, so it never wraps, which is what makes it a ruler.
local measure

-- How many lines `text` will occupy once the column has wrapped it.
--
-- Counting the newlines we wrote is not the same question, and treating it as
-- though it were is what let notes run off the side of the panel: a hand-
-- wrapped line that turns out to be too wide becomes two on screen and one in
-- the arithmetic, and everything below it is laid out on top.
local function WrappedLines(text, size, width)
    if not measure then
        measure = UIParent:CreateFontString(nil, "OVERLAY")
    end
    measure:SetFont(ui.FontPath(), size, "")

    local lines = 0
    -- The trailing newline makes the last segment match like any other, and
    -- the pattern keeps empty segments so a blank line still costs a line.
    for segment in string.gmatch(text .. "\n", "([^\n]*)\n") do
        measure:SetText(segment)
        local w = measure:GetStringWidth() or 0
        local n = (w > width) and math.ceil(w / width) or 1
        lines = lines + n
    end
    return lines
end

-- `width` defaults to the full column. Pass a narrower one when the note is
-- indented, or it runs past the column by exactly the indent.
function ui.Note(parent, x, y, text, width)
    width = width or ui.COL_W

    local fs = ui.Label(parent, text, 11, 0.6, 0.6, 0.6)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")

    -- Bounded to the column, like every other widget in this file. This one
    -- was the exception -- no width, so the string was free to run past the
    -- column and, in the right-hand one, past the edge of the frame itself.
    -- The newlines in a note are now a suggestion about where lines look best
    -- rather than the only thing stopping the text escaping.
    fs:SetWidth(width)
    fs:SetWordWrap(true)

    -- GetStringHeight is measured, not laid out, so it is available
    -- immediately -- but a zero from it would silently collapse the panel onto
    -- its own last note. The measured line count is the floor.
    local h = fs:GetStringHeight() or 0
    local floorH = WrappedLines(text, 11, width) * 13
    if h < floorH then h = floorH end

    return y - h - 8
end

--------------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------------

function ui.Check(parent, x, y, text, store, key, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)

    -- Own label rather than the template's, which has moved between builds.
    local fs = ui.Label(cb, text, 12)
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)

    -- Extend the click target across the label: a 24px box is a small target
    -- to hit repeatedly while comparing settings.
    cb:SetHitRectInsets(0, -(fs:GetStringWidth() + 8), 0, 0)

    cb:SetScript("OnClick", function(self)
        store[key] = self:GetChecked() and true or false
        if onChange then onChange() end
        ns.RefreshOptions()
    end)

    cb.Refresh = function() cb:SetChecked(store[key]) end
    Add(cb)
    if ui.skin then ui.skin.Checkbox(cb) end

    return y - 26
end

function ui.Slider(parent, x, y, text, store, key, minV, maxV, step, decimals, onChange)
    local lbl = ui.Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    local val = ui.Label(parent, "", 12, 1, 0.82, 0.2)
    val:SetPoint("TOPLEFT", x + ui.COL_W - 44, y)
    val:SetJustifyH("RIGHT")
    val:SetWidth(44)

    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetPoint("TOPLEFT", x, y - 16)
    s:SetSize(ui.COL_W - 4, 16)
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
        store[key] = (decimals and decimals > 0) and v or floor(v)
        val:SetText(format(fmt, store[key]))
        if onChange then onChange() end
    end)

    s.Refresh = function()
        s._refreshing = true
        s:SetValue(store[key])
        val:SetText(format(fmt, store[key]))
        s._refreshing = false
    end
    Add(s)

    return y - 40
end

-- Segmented picker. Used instead of a dropdown for small, fixed choice sets:
-- every option stays visible, which suits "which side of the nameplate" far
-- better than a collapsed list.
function ui.Segmented(parent, x, y, text, store, key, options, onChange)
    local lbl = ui.Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    local buttons = {}
    local n   = #options
    local gap = 4
    local bw  = (ui.COL_W - (gap * (n - 1))) / n

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
            store[key] = opt.value
            if onChange then onChange() end
            ns.RefreshOptions()
        end)

        if ui.skin then ui.skin.Button(b) end
        buttons[i] = b
    end

    local holder = CreateFrame("Frame", nil, parent)
    holder.Refresh = function()
        for i, opt in ipairs(options) do
            local on = (store[key] == opt.value)
            buttons[i].sel:SetShown(on)
            -- Selection is carried by the fill *and* the label brightness, so
            -- it does not rest on one visual cue alone.
            local t = buttons[i]:GetFontString()
            if t then t:SetTextColor(on and 1 or 0.55, on and 1 or 0.55, on and 1 or 0.55) end
        end
    end
    Add(holder)

    return y - 42
end

-- Color swatches. Deliberately NOT skinned: a swatch has to show its own
-- color, which is the one case the skinning guide says to draw yourself.
function ui.Swatches(parent, x, y, text, store, key, onChange, order)
    local lbl = ui.Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    -- The owning module decides which slice of the palette suits each row --
    -- loud presets for an alert, quiet ones for a confirmation.
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

            -- BACKGROUND, below the 2px-inset color above it, so this reads as
            -- a border around the swatch. At OVERLAY it covered the colour
            -- outright and every selected swatch rendered solid white.
            local ring = b:CreateTexture(nil, "BACKGROUND")
            ring:SetAllPoints()
            ring:SetColorTexture(1, 1, 1, 1)
            ring:Hide()
            b.ring  = ring
            b.color = c

            b:SetScript("OnClick", function()
                store[key] = { c[1], c[2], c[3] }
                if onChange then onChange() end
                ns.RefreshOptions()
            end)

            buttons[#buttons + 1] = b
        end
    end

    local holder = CreateFrame("Frame", nil, parent)
    holder.Refresh = function()
        local cur = store[key] or {}
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
    Add(holder)

    return y - 46
end

-- Several one-character fields on a single line. Glyphs are chosen against
-- each other -- the whole point is that the silhouettes stay distinct -- so
-- they belong side by side, and a column has no vertical room for three
-- stacked fields anyway.
function ui.InputRow(parent, x, y, text, store, specs, onChange)
    local lbl = ui.Label(parent, text, 12)
    lbl:SetPoint("TOPLEFT", x, y)

    local n   = #specs
    local gap = 8
    local bw  = (ui.COL_W - gap * (n - 1)) / n

    for i = 1, n do
        local spec = specs[i]
        local bx   = x + (i - 1) * (bw + gap)

        local sub = ui.Label(parent, spec.label, 11, 0.6, 0.6, 0.6)
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
                store[spec.key] = v
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
            if not eb:HasFocus() then eb:SetText(store[spec.key] or "") end
        end
        Add(eb)
        if ui.skin then ui.skin.EditBox(eb) end
    end

    return y - 58
end

-- A plain action button. `label` is optional and, when given, is replayed on
-- every refresh -- for a button whose text states the thing it will do next.
function ui.Button(parent, x, y, text, onClick, label)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(ui.COL_W, 22)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", function()
        onClick()
        ns.RefreshOptions()
    end)
    if label then b.Refresh = function() b:SetText(label()) end end
    Add(b)
    if ui.skin then ui.skin.Button(b) end

    return y - 28
end
