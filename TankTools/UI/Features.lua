--------------------------------------------------------------------------------
-- Tank Tools -- the feature window
--
-- /tt features. A checkbox per unfinished module, and a reload button.
--
-- Its own window rather than a page in the settings panel, for the reason the
-- flags exist at all: a tab is something you find by accident. Nothing in the
-- addon links here and the command is not listed in the help, so this is
-- reachable only by someone who already knows it is there.
--
-- The window is built on first open, like the settings panel, which is what
-- lets it read the flag store directly -- by then the database has resolved.
--------------------------------------------------------------------------------

local _, ns = ...

local tinsert = table.insert

local ui = ns.ui

local panel
local mine = {}   -- the controls this window owns, for its own refresh

local WIDTH = ui.PAD * 2 + ui.COL_W

--------------------------------------------------------------------------------

-- ns.RefreshOptions only replays controls while the *settings* panel is open,
-- so this window refreshes its own. The slice is taken by position: every
-- widget constructor appends to ui.controls, so whatever landed there while
-- Build ran belongs to us.
local function Refresh()
    for i = 1, #mine do
        if mine[i].Refresh then mine[i].Refresh() end
    end
end

local function BuildChrome()
    local f = CreateFrame("Frame", "TankToolsFeaturesFrame", UIParent, "BackdropTemplate")
    f:SetWidth(WIDTH)
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

    tinsert(UISpecialFrames, "TankToolsFeaturesFrame")

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(ui.FontPath(), 15, "OUTLINE")
    f.title:SetTextColor(1, 1, 1)
    f.title:SetText("Tank Tools -- features")
    f.title:SetPoint("TOPLEFT", ui.PAD, -12)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -4, -4)

    return f
end

local function BuildContents(f)
    local store = ns.FeatureStore()
    local x, y  = ui.PAD, -42
    local first = #ui.controls + 1

    y = ui.Header(f, "Work in progress", x, y)
    y = ui.Note(f, x, y,
        "Unfinished features, off by default. Turning one on\n"
        .. "is how it gets tested -- expect it to be rough, and\n"
        .. "do not report it as broken.")
    y = y - 6

    local features = ns.features
    if #features == 0 then
        y = ui.Note(f, x, y, "Nothing in progress. Everything the addon\nhas is shipped and switched on normally.")
    end

    for i = 1, #features do
        local feat = features[i]
        y = ui.Check(f, x, y, feat.title or feat.name, store, feat.name, Refresh)
        if feat.desc then
            -- Indented under its checkbox, so a feature reads as one block
            -- however many lines its note runs to.
            -- Indented under its checkbox, so the note has 24 fewer pixels
            -- to live in than the column does.
            y = ui.Note(f, x + 24, y + 4, feat.desc, ui.COL_W - 24)
        end
        y = y - 4
    end

    y = y - 6
    -- Called through a wrapper rather than passed by value: the window is
    -- built lazily, and a global captured at build time is a global that has
    -- to exist at build time.
    y = ui.Button(f, x, y, "Reload the UI", function() ReloadUI() end, function()
        return ns.FeatureNeedsReload()
               and "|cffffff00Reload the UI to apply|r"
               or  "Reload the UI"
    end)

    y = ui.Note(f, x, y,
        "A flag is read once, when the addon starts. Until you\n"
        .. "reload, a feature you just switched on is still off.")

    for i = first, #ui.controls do mine[#mine + 1] = ui.controls[i] end

    f:SetHeight(-y + ui.PAD)
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

function ns.ShowFeatures()
    if not ns.ready then return end
    if not panel then
        panel = BuildChrome()
        BuildContents(panel)
        SkinPanel()
    end
    panel:Show()
    Refresh()
end

function ns.ToggleFeatures()
    if panel and panel:IsShown() then
        panel:Hide()
    else
        ns.ShowFeatures()
    end
end

-- `hidden` keeps it out of the generated help without breaking the rule that
-- generated help is the only help there is: this is still one registration,
-- and there is still no hand-written list to drift from.
ns.RegisterCommand{
    name    = "features",
    hidden  = true,
    section = "other:",
    order   = 90,
    desc    = "toggle unfinished features",
    handler = ns.ToggleFeatures,
}
