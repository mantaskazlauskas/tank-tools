--------------------------------------------------------------------------------
-- Tank Tools -- the debuff journal window
--
-- /tt debuffs. Everything Modules/Debuffs.lua has written down, one row per
-- spell: the icon, the name, the id, and what the client was willing to say
-- about it.
--
-- Its own window rather than a settings page, for the same reason the settings
-- are their own window: this is a list you read, and a list you read wants
-- room. The settings page it does have is four controls and a way in.
--
-- THE LIST IS A FIXED SET OF ROWS
--
-- Twelve row frames exist, and scrolling moves an offset rather than building
-- anything. Four hundred records is four hundred frames if you build one each,
-- and a journal that is slower to open the longer you have played is a journal
-- people stop opening.
--
-- WHAT A ROW MAY SAY IT DOES NOT KNOW
--
-- Half the point of the journal is that its facts come through two doors of
-- very different quality -- see the header of Modules/Debuffs.lua -- so a row
-- distinguishes three states per flag, not two: yes, no, and "we never got to
-- look". A debuff caught only in the combat log has an id, a name and an icon
-- and no flags at all, and it says so rather than drawing five empty boxes
-- that read as five noes.
--------------------------------------------------------------------------------

local _, ns = ...

local CreateFrame = CreateFrame
local tinsert     = table.insert
local format      = string.format
local floor       = math.floor

local ui = ns.ui

local PAD     = ui.PAD
local WIDTH   = 560
local ROW_H   = 32
local VISIBLE = 12
local LIST_H  = ROW_H * VISIBLE
local BAR_W   = 8                       -- the scrollbar
local ROW_W   = WIDTH - PAD * 2 - BAR_W - 6

local FONT = ui.FontPath()

local panel
local rows    = {}   -- the fixed row frames, top to bottom
local mine    = {}   -- controls this window owns, for its own refresh
local records = {}   -- the current filtered, sorted view
local offset  = 0

-- View state, session only and deliberately not saved. Which way a list is
-- sorted while you are looking for one debuff is a question, not a preference,
-- and a saved one is a sort you will still be fighting six weeks later without
-- remembering why. It is shaped like a settings store because ui.Segmented
-- takes any table -- which is the point of the widget kit taking the table as
-- an argument rather than reaching for ns.db.
local view  = { sort = "recent" }
local query = ""

-- Arms the wipe. Reset whenever the window closes, so a click left armed
-- yesterday cannot become a wipe you did not mean today.
local armed = false

--------------------------------------------------------------------------------
-- Words for the flags
--------------------------------------------------------------------------------

-- The dispel-type colours the game itself uses, so a Magic debuff in this list
-- is the colour a Magic debuff is on a raid frame.
local DISPEL_COLOR = {
    Magic   = "ff3fc7eb",
    Curse   = "ff8f5fd0",
    Disease = "ff9d8a4c",
    Poison  = "ff4fd44f",
}

local GREY = "ff808080"

local function Chip(text, color)
    return "|c" .. color .. text .. "|r"
end

-- The one-line summary under a debuff's name.
--
-- Only true flags get a chip: a row listing every flag it does not have is a
-- row you cannot scan. What does appear unconditionally is the admission that
-- none of them was readable, because that is not the same as all of them being
-- false and it is the difference between "this is a plain debuff" and "we only
-- ever saw this in the combat log".
local function MetaLine(r)
    local parts = { Chip("#" .. r.id, GREY) }

    if r.dispel == nil then
        parts[#parts + 1] = Chip("dispel unknown", GREY)
    elseif r.dispel == "none" then
        parts[#parts + 1] = Chip("no dispel", GREY)
    else
        parts[#parts + 1] = Chip(r.dispel, DISPEL_COLOR[r.dispel] or "ffffffff")
    end

    if r.raid then parts[#parts + 1] = Chip("raid", "ffff9a3c") end
    if r.boss then parts[#parts + 1] = Chip("boss", "ffff5555") end
    if r.tank then parts[#parts + 1] = Chip("tank", "ffffd100") end
    if r.mine then parts[#parts + 1] = Chip("yours", GREY) end

    -- Never read through the aura door, so every flag above is absent rather
    -- than false. Said once, at the end, instead of five times.
    if r.via ~= "aura" then
        parts[#parts + 1] = Chip("log only", GREY)
    end

    return table.concat(parts, "  ")
end

local function Ago(when)
    if not when or when <= 0 then return "" end
    if not (time and date) then return "" end

    local d = time() - when
    if d < 60      then return "just now" end
    if d < 3600    then return format("%dm ago", floor(d / 60)) end
    if d < 86400   then return format("%dh ago", floor(d / 3600)) end
    if d < 86400 * 7 then return format("%dd ago", floor(d / 86400)) end
    return date("%d %b", when)
end

--------------------------------------------------------------------------------
-- The tooltip
--
-- SetSpellByID is the whole spell tooltip, description included, straight from
-- the game's data files -- which is why the journal does not store a
-- description of its own. Our own lines go underneath it: where we caught it,
-- how often, and through which door.
--------------------------------------------------------------------------------

local function ShowRowTooltip(row)
    local r = row._rec
    if not r then return end

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")

    local ok = false
    if GameTooltip.SetSpellByID then
        ok = pcall(GameTooltip.SetSpellByID, GameTooltip, r.id)
    end
    if not ok then
        GameTooltip:SetText(r.name or ("spell " .. r.id))
        local desc = ns.DebuffDescription(r.id)
        if desc then GameTooltip:AddLine(desc, 1, 1, 1, true) end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(format("spell id %d", r.id), 0.6, 0.6, 0.6)

    if r.dispel == nil then
        GameTooltip:AddLine("dispel type: never readable", 0.6, 0.6, 0.6)
    elseif r.dispel == "none" then
        GameTooltip:AddLine("cannot be dispelled", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("dispel type: " .. r.dispel, 0.6, 0.6, 0.6)
    end

    if r.via == "aura" then
        GameTooltip:AddLine(format("raid aura: %s   boss aura: %s   tank aura: %s",
                                   r.raid and "yes" or "no",
                                   r.boss and "yes" or "no",
                                   r.tank and "yes" or "no"),
                            0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("only ever seen in the combat log, which carries no "
                            .. "flags", 0.6, 0.6, 0.6, true)
    end

    GameTooltip:AddLine(format("seen %d time%s%s", r.n, r.n == 1 and "" or "s",
                              r.where and (" -- first in " .. r.where) or ""),
                        0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function HideRowTooltip(row)
    -- Only ours: hiding unconditionally would rip away a tooltip some other
    -- frame put up in the meantime.
    if GameTooltip:IsOwned(row) then GameTooltip:Hide() end
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function CreateRow(parent, i)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(ROW_W, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:EnableMouse(true)

    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.07)
    r.hl:Hide()

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(26, 26)
    r.icon:SetPoint("LEFT", 2, 0)
    -- The same crop the aura row uses, so an icon looks the same in both.
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    r.edge = r:CreateTexture(nil, "BACKGROUND")
    r.edge:SetPoint("TOPLEFT", r.icon, "TOPLEFT", -1, 1)
    r.edge:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", 1, -1)
    r.edge:SetColorTexture(0, 0, 0, 1)

    r.name = r:CreateFontString(nil, "OVERLAY")
    r.name:SetFont(FONT, 13, "")
    r.name:SetTextColor(0.95, 0.95, 0.95)
    r.name:SetJustifyH("LEFT")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -1)
    -- Short enough to clear the two right-hand columns, which are anchored to
    -- the other edge and would otherwise be written over by a long name.
    r.name:SetWidth(ROW_W - 180)

    r.meta = r:CreateFontString(nil, "OVERLAY")
    r.meta:SetFont(FONT, 11, "")
    r.meta:SetJustifyH("LEFT")
    r.meta:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
    r.meta:SetWidth(ROW_W - 180)

    r.when = r:CreateFontString(nil, "OVERLAY")
    r.when:SetFont(FONT, 11, "")
    r.when:SetTextColor(0.6, 0.6, 0.6)
    r.when:SetJustifyH("RIGHT")
    r.when:SetPoint("RIGHT", -6, 6)
    r.when:SetWidth(110)

    r.count = r:CreateFontString(nil, "OVERLAY")
    r.count:SetFont(FONT, 11, "")
    r.count:SetTextColor(0.6, 0.6, 0.6)
    r.count:SetJustifyH("RIGHT")
    r.count:SetPoint("RIGHT", -6, -7)
    r.count:SetWidth(110)

    r:SetScript("OnEnter", function(self)
        self.hl:Show()
        ShowRowTooltip(self)
    end)
    r:SetScript("OnLeave", function(self)
        self.hl:Hide()
        HideRowTooltip(self)
    end)
    -- A row can be hidden with the cursor still on it -- the filter changes,
    -- the window closes -- and OnLeave does not fire for a frame that simply
    -- stopped being on screen.
    r:SetScript("OnHide", HideRowTooltip)

    r:Hide()
    return r
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function MaxOffset()
    local extra = #records - VISIBLE
    return (extra > 0) and extra or 0
end

local function Redraw()
    if not panel then return end

    records = ns.DebuffRecords(query, view.sort)

    local maxOff = MaxOffset()
    if offset > maxOff then offset = maxOff end
    if offset < 0 then offset = 0 end

    for i = 1, VISIBLE do
        local row = rows[i]
        local rec = records[i + offset]
        row._rec = rec

        if rec then
            -- SetTexture with nil draws the last icon this row happened to
            -- hold, which is a debuff wearing another debuff's face. The
            -- question mark is the honest answer for a record whose icon we
            -- never learned.
            row.icon:SetTexture(rec.icon or 134400)
            row.name:SetText(rec.name or format("spell %d", rec.id))
            row.meta:SetText(MetaLine(rec))
            row.when:SetText(Ago(rec.last))
            row.count:SetText(format("%dx", rec.n))
            row:Show()
        else
            row:Hide()
        end
    end

    panel.scroll:SetMinMaxValues(0, maxOff)
    panel.scroll:SetShown(maxOff > 0)
    panel.scroll._quiet = true
    panel.scroll:SetValue(offset)
    panel.scroll._quiet = nil

    local s = ns.DebuffStats()

    panel.empty:SetShown(#records == 0)
    if #records == 0 then
        panel.empty:SetText(s.total == 0
            and "Nothing recorded yet.\n\nDebuffs are written down as they land "
                .. "on you -- go and\ntake some."
            or "No debuff here matches that filter.")
    end

    panel.footer:SetText(format(
        "%d recorded of %d  --  recording %s  --  aura reads here %s, combat log %s",
        s.total, s.cap,
        s.recording and "|cff00ff00on|r" or "|cffff4040off|r",
        s.restricted and "|cffff8000refused|r" or "|cff00ff00allowed|r",
        (not s.logOpen) and "|cffff4040unusable|r"
            or (s.fromLog and "|cff00ff00on|r" or "|cff808080off|r")))

    for i = 1, #mine do
        if mine[i].Refresh then mine[i].Refresh() end
    end
end

-- Called by the journal's ticker when a record has changed. Cheap while the
-- window is closed, which is nearly always.
function ns.RefreshDebuffs()
    if panel and panel:IsShown() then Redraw() end
end

local function Scroll(by)
    offset = offset + by
    Redraw()
end

--------------------------------------------------------------------------------
-- Chrome
--------------------------------------------------------------------------------

local function BuildChrome()
    local f = CreateFrame("Frame", "TankToolsDebuffsFrame", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, 560)
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

    tinsert(UISpecialFrames, "TankToolsDebuffsFrame")

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(FONT, 15, "OUTLINE")
    f.title:SetTextColor(1, 1, 1)
    f.title:SetText("Tank Tools -- debuff journal")
    f.title:SetPoint("TOPLEFT", PAD, -12)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -4, -4)

    return f
end

local function BuildFilter(f)
    local lbl = ui.Label(f, "Filter by name or spell id", 12)
    lbl:SetPoint("TOPLEFT", PAD, -44)

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(230, 22)
    eb:SetPoint("TOPLEFT", PAD + 6, -60)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlight")

    -- Filtering as you type rather than on enter: the list is short enough to
    -- re-sort on every keystroke, and a filter box that needs a keypress to
    -- commit reads as broken for the first second you use it.
    eb:SetScript("OnTextChanged", function(self)
        query  = self:GetText() or ""
        offset = 0
        Redraw()
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    if ui.skin then ui.skin.EditBox(eb) end
    f.filter = eb
end

local function BuildSort(f)
    local first = #ui.controls + 1

    ui.Segmented(f, WIDTH - PAD - ui.COL_W, -44, "Sort by", view, "sort", {
        { text = "Recent", value = "recent" },
        { text = "Name",   value = "name" },
        { text = "Times",  value = "count" },
    }, function()
        offset = 0
        Redraw()
    end)

    for i = first, #ui.controls do mine[#mine + 1] = ui.controls[i] end
end

local function BuildList(f)
    local list = CreateFrame("Frame", nil, f)
    list:SetSize(ROW_W, LIST_H)
    list:SetPoint("TOPLEFT", PAD, -92)
    list:EnableMouseWheel(true)
    -- Three rows a notch, which is the usual feel and enough that a long
    -- journal does not need forty flicks to cross.
    list:SetScript("OnMouseWheel", function(_, delta) Scroll(-delta * 3) end)

    for i = 1, VISIBLE do rows[i] = CreateRow(list, i) end

    f.empty = f:CreateFontString(nil, "OVERLAY")
    f.empty:SetFont(FONT, 12, "")
    f.empty:SetTextColor(0.6, 0.6, 0.6)
    f.empty:SetJustifyH("LEFT")
    f.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -8)
    f.empty:SetWidth(ROW_W - 8)
    f.empty:Hide()

    -- The scrollbar, built here rather than with ui.Slider: that one edits a
    -- settings key, and this moves a view offset that is nobody's setting.
    local s = CreateFrame("Slider", nil, f)
    s:SetOrientation("VERTICAL")
    s:SetSize(BAR_W, LIST_H)
    s:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -92)
    s:SetMinMaxValues(0, 0)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.10)
    track:SetPoint("TOP")
    track:SetPoint("BOTTOM")
    track:SetWidth(3)

    s:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = s:GetThumbTexture()
    thumb:SetSize(BAR_W, 24)
    thumb:SetColorTexture(0.85, 0.85, 0.85, 1)

    s:SetScript("OnValueChanged", function(self, v)
        -- Redraw writes the bar back to the offset it settled on, and without
        -- this that write would come straight back here as a scroll.
        if self._quiet then return end
        offset = floor(v + 0.5)
        Redraw()
    end)

    f.list   = list
    f.scroll = s
end

local function BuildFooter(f)
    f.footer = f:CreateFontString(nil, "OVERLAY")
    f.footer:SetFont(FONT, 11, "")
    f.footer:SetTextColor(0.6, 0.6, 0.6)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetPoint("TOPLEFT", PAD, -(92 + LIST_H + 10))
    f.footer:SetWidth(WIDTH - PAD * 2)

    local first = #ui.controls + 1
    local y = -(92 + LIST_H + 30)

    ui.Button(f, PAD, y, "Forget everything recorded", function()
        -- Two clicks, because this is the only button in the addon that
        -- destroys something you cannot get back by playing for five minutes.
        if not armed then
            armed = true
            return
        end
        armed = false
        local n = ns.ForgetDebuffs()
        ns.Print(format("forgot %d recorded debuff%s.", n, n == 1 and "" or "s"))
        offset = 0
        Redraw()
    end, function()
        return armed and "|cffff4040Click again to forget them|r"
                      or "Forget everything recorded"
    end)

    ui.Button(f, WIDTH - PAD - ui.COL_W, y, "Settings", function()
        ns.ShowOptions()
    end)

    for i = first, #ui.controls do mine[#mine + 1] = ui.controls[i] end

    f:SetHeight(-y + 28 + PAD)
end

local function SkinPanel()
    if not (ui.skin and panel) or panel._skinned then return end
    panel._skinned = true
    panel:SetBackdrop(nil)
    ui.skin.Shell(panel)
    ui.skin.Font(panel.title)
    ui.skin.CloseButton(panel.close)
end

--------------------------------------------------------------------------------
-- Public entry points
--------------------------------------------------------------------------------

function ns.ShowDebuffs()
    if not ns.ready then return end
    if not ns.FeatureEnabled("debuffs") then return end

    if not panel then
        panel = BuildChrome()
        BuildFilter(panel)
        BuildSort(panel)
        BuildList(panel)
        BuildFooter(panel)
        SkinPanel()

        -- Disarming on close rather than on open, so the window cannot be
        -- reopened onto a primed wipe.
        panel:SetScript("OnHide", function() armed = false end)
    end

    panel:Show()
    Redraw()
end

function ns.ToggleDebuffs()
    if panel and panel:IsShown() then
        panel:Hide()
    else
        ns.ShowDebuffs()
    end
end

--------------------------------------------------------------------------------
-- Command and settings
--------------------------------------------------------------------------------

ns.RegisterCommandSection("debuffs:", 27)

ns.RegisterCommand{
    name    = "debuffs",
    aliases = { "dj" },
    feature = "debuffs",
    section = "debuffs:",
    order   = 10,
    args    = "[clear]",
    desc    = "the debuff journal -- everything that has landed on you",
    handler = function(_, larg)
        if larg == "clear" then
            local n = ns.ForgetDebuffs()
            ns.Print(format("forgot %d recorded debuff%s.", n, n == 1 and "" or "s"))
            ns.RefreshDebuffs()
            return
        end
        ns.ToggleDebuffs()
    end,
}

ns.RegisterOptionsSection{
    page      = "Debuffs",
    pageOrder = 40,
    column    = "left",
    order     = 10,
    feature   = "debuffs",
    build = function(f, x, y)
        -- The page is registered by this file and the settings it edits are
        -- owned by another. Removing that file must cost the page, not the
        -- whole settings window.
        local m = ns.GetModule("debuffs")
        if not (m and m.db) then
            return ui.Note(f, x, y, "The debuff journal is not loaded.")
        end
        local store = m.db

        y = ui.Header(f, "Debuff journal", x, y)
        y = ui.Note(f, x, y,
            "Every debuff that lands on you is written down once,\n"
            .. "with whatever the client would say about it.")
        y = y - 6

        y = ui.Check(f, x, y, "Record debuffs", store, "djRecord")
        y = ui.Check(f, x, y, "Also record from the combat log", store, "djFromLog")
        y = ui.Note(f, x + 24, y + 4,
            "The combat log is the only door open in an encounter,\n"
            .. "but it carries a spell id and nothing else -- no\n"
            .. "dispel type and no raid or boss flags.", ui.COL_W - 24)

        y = y - 6
        y = ui.Button(f, x, y, "Open the journal", function() ns.ShowDebuffs() end)

        return y
    end,
}
