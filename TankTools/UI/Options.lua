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
-- The window owns no settings of its own. Modules register *sections*, and
-- this file only decides where they go: which tab, which column, in what
-- order. A module that is removed takes its section with it and leaves no gap
-- in a hand-written layout, which is what the old single BuildContents did.
--
-- The tab strip appears only once a second page is registered. With one page
-- it would be chrome that carries no information.
--------------------------------------------------------------------------------

local _, ns = ...

local tinsert = table.insert
local tsort   = table.sort

local ui = ns.ui

local panel        -- the window, built lazily on first open
local pages   = {} -- name -> { name, order, frame, sections }
local pageList = {}

-- Public for the same reason ns.modules is: it is the answer to "what did the
-- addon actually register", which is the first question when a page does not
-- appear.
ns.optionsPages = pageList

--------------------------------------------------------------------------------
-- Section registry
--------------------------------------------------------------------------------

-- def fields:
--   page       tab title the section belongs to
--   pageOrder  where that tab sits, if this section is the one that creates it
--   column     "left" or "right"
--   order      position within the column
--   feature    optional flag name; the section is dropped while it is off
--   build      function(frame, x, y) -> next y
function ns.RegisterOptionsSection(def)
    local p = pages[def.page]
    if not p then
        p = { name = def.page, order = def.pageOrder or 100, sections = {} }
        pages[def.page] = p
        pageList[#pageList + 1] = p
    end
    -- The lowest pageOrder seen wins, so a page's position does not depend on
    -- which of its sections happened to load first.
    if def.pageOrder and def.pageOrder < p.order then p.order = def.pageOrder end

    p.sections[#p.sections + 1] = def
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function BuildPage(p, parent, topY)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    p.frame = f

    local left, right = {}, {}
    for i = 1, #p.sections do
        local s = p.sections[i]
        local into = (s.column == "right") and right or left
        into[#into + 1] = s
    end

    local function ByOrder(a, b) return (a.order or 0) < (b.order or 0) end
    tsort(left, ByOrder)
    tsort(right, ByOrder)

    local lx = ui.PAD
    local rx = ui.PAD * 2 + ui.COL_W
    local ly, ry = topY, topY

    for i = 1, #left  do ly = left[i].build(f, lx, ly)  end
    for i = 1, #right do ry = right[i].build(f, rx, ry) end

    -- How far down the taller column reached, so the panel can be sized to fit
    -- rather than to a number someone has to remember to update.
    p.height = -math.min(ly, ry) + ui.PAD
    return f
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function ShowPage(p)
    for i = 1, #pageList do
        local other = pageList[i]
        if other.frame then other.frame:SetShown(other == p) end
        if other.tab then
            other.tab.sel:SetShown(other == p)
            local t = other.tab:GetFontString()
            if t then
                local on = (other == p)
                t:SetTextColor(on and 1 or 0.55, on and 1 or 0.55, on and 1 or 0.55)
            end
        end
    end
    ns.RefreshOptions()
end

local function BuildTabs(f)
    local gap, y = 4, -36
    local w = (ui.PAD * 3 + ui.COL_W * 2 - ui.PAD * 2 - gap * (#pageList - 1))
              / #pageList

    for i = 1, #pageList do
        local p = pageList[i]
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("TOPLEFT", ui.PAD + (i - 1) * (w + gap), y)
        b:SetText(p.name)

        local sel = b:CreateTexture(nil, "OVERLAY")
        sel:SetColorTexture(1, 1, 1, 0.16)
        sel:SetAllPoints()
        sel:Hide()
        b.sel = sel

        b:SetScript("OnClick", function() ShowPage(p) end)
        if ui.skin then ui.skin.Button(b) end
        p.tab = b
    end

    return y - 30   -- where page content starts once a strip is present
end

local function BuildPanel()
    local f = CreateFrame("Frame", "TankToolsOptionsFrame", UIParent, "BackdropTemplate")
    f:SetWidth(ui.PAD * 3 + ui.COL_W * 2)
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
    f.title:SetFont(ui.FontPath(), 15, "OUTLINE")
    f.title:SetTextColor(1, 1, 1)
    f.title:SetText("Tank Tools")
    f.title:SetPoint("TOPLEFT", ui.PAD, -12)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -4, -4)

    panel = f
    return f
end

-- Sections behind an unset feature flag are dropped, and a page left with no
-- sections goes with them -- an empty tab is worse than a missing one, because
-- it advertises a feature and then shows nothing.
--
-- Done here rather than in RegisterOptionsSection because the flag is a
-- setting: registration happens at load time, before the database exists,
-- while this runs on first open and can read it.
local function PruneHidden()
    for i = #pageList, 1, -1 do
        local p = pageList[i]
        local keep = {}
        for j = 1, #p.sections do
            local s = p.sections[j]
            if ns.FeatureAllows(s) then keep[#keep + 1] = s end
        end
        p.sections = keep
        if #keep == 0 then
            pages[p.name] = nil
            table.remove(pageList, i)
        end
    end
end

local function BuildContents(f)
    PruneHidden()
    tsort(pageList, function(a, b) return a.order < b.order end)

    local topY = -42
    if #pageList > 1 then topY = BuildTabs(f) end

    local tallest = 0
    for i = 1, #pageList do
        local p = pageList[i]
        BuildPage(p, f, topY)
        if p.height > tallest then tallest = p.height end
    end

    -- Every page is the same height, so switching tabs does not resize the
    -- window under the cursor.
    f:SetHeight(math.max(tallest, 200))

    if pageList[1] then ShowPage(pageList[1]) end
end

--------------------------------------------------------------------------------
-- Public entry points
--------------------------------------------------------------------------------

function ns.RefreshOptions()
    if not panel or not panel:IsShown() then return end
    local controls = ui.controls
    for i = 1, #controls do
        local c = controls[i]
        if c.Refresh then c.Refresh() end
    end
end

-- Skins the window chrome. Individual widgets skin themselves as they are
-- constructed; this covers the parts that only exist once the panel does.
local function SkinPanel()
    if not (ui.skin and panel) or panel._skinned then return end
    panel._skinned = true
    -- Our own backdrop must go first: S.Shell fades texture regions, and a
    -- backdrop is not one, so it would show through the skinned shell.
    panel:SetBackdrop(nil)
    ui.skin.Shell(panel)
    ui.skin.Font(panel.title)
    ui.skin.CloseButton(panel.close)
end

function ns.ShowOptions()
    if not ns.ready then return end
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

ns.RegisterCommand{
    name    = "config",
    aliases = { "options", "opt" },
    section = "commands:",
    order   = 10,
    desc    = "open the settings window",
    handler = ns.ToggleOptions,
}

--------------------------------------------------------------------------------
-- Optional skinning + Blizzard Settings entry
--------------------------------------------------------------------------------

if EllesmereUI and EllesmereUI.RegisterSkin then
    EllesmereUI.RegisterSkin("TankToolsOptions", function(S)
        -- Keeping S is the important part: the window is built on first open,
        -- normally well after this runs, and every widget constructor reads it
        -- back out of ui.skin itself -- the usual pattern for lazily created
        -- frames.
        ui.skin = S
        if not panel then return end

        SkinPanel()
        local controls = ui.controls
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
    title:SetFont(ui.FontPath(), 17, "OUTLINE")
    title:SetPoint("TOPLEFT", 12, -14)
    title:SetText("Tank Tools")

    local desc = holder:CreateFontString(nil, "OVERLAY")
    desc:SetFont(ui.FontPath(), 12, "")
    desc:SetTextColor(0.75, 0.75, 0.75)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("These settings open in their own window, so you can see\nthe game while you adjust them.")
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

ns.RegisterEvent("PLAYER_LOGIN", RegisterSettingsStub)
