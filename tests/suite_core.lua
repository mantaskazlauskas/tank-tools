--------------------------------------------------------------------------------
-- Core: module registry, database, events, ticker, commands, settings window.
--
-- Scenarios:
--   fresh    a clean install
--   migrate  an existing v1 (flat) saved-variables table
--   tabs     a third module registers a settings page, so a tab strip appears
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
section("load")
--------------------------------------------------------------------------------

-- Counts are deliberately avoided here: a suite that has to be edited every
-- time a module is added is the coupling this structure exists to remove.
-- What is asserted is the load-order contract the .toc encodes.
local function IndexOf(name)
    for i = 1, #FILES do if FILES[i]:find(name, 1, true) then return i end end
end

ok(IndexOf("Core/Namespace.lua") == 1, "Namespace loads first")
ok(IndexOf("Core/Events.lua") < IndexOf("Core/DB.lua"),
   "Events before DB -- the database resolves on an event")
ok(IndexOf("Core/Secret.lua") < IndexOf("Core/State.lua"),
   "Secret before its first consumer")
ok(IndexOf("UI/Widgets.lua") < IndexOf("UI/Options.lua"), "widgets before the window")
ok(IndexOf("Modules/Threat.lua") < IndexOf("Modules/Nameplates.lua"),
   "Threat before Nameplates -- the state ids are read at file scope")
for i = 1, #FILES do
    ok(FileExists(ADDON_PATH .. "/" .. FILES[i]), "toc file exists: " .. FILES[i])
end

ok(NS.Print ~= nil, "ns.Print exists")
ok(NS.ready ~= true, "not ready before ADDON_LOADED")
ok(NS.GetModule("threat") ~= nil, "threat module registered")
ok(NS.GetModule("nameplates") ~= nil, "nameplates module registered")

if SCENARIO == "tabs" then
    -- Stand in for a third module's settings page. Registered at load time,
    -- which is when a real module registers: the panel is built once, on
    -- first open, and only sees what was registered before that.
    NS.RegisterOptionsSection{
        page = "Tank Watch", pageOrder = 90, column = "left", order = 10,
        build = function(f, x, y)
            y = NS.ui.Header(f, "Co-tanks", x, y)
            return NS.ui.Note(f, x, y, "placeholder")
        end,
    }
end

--------------------------------------------------------------------------------
section("ADDON_LOADED / database")
--------------------------------------------------------------------------------

FireEvent("ADDON_LOADED", "SomeOtherAddon")
ok(NS.ready ~= true, "ignores another addon's ADDON_LOADED")

FireEvent("ADDON_LOADED", "TankTools")
ok(NS.ready == true, "ready after our ADDON_LOADED")

local db = TankToolsDB
eq(db.dbVersion, 2, "dbVersion stamped")
ok(db.modules.threat ~= nil, "threat store exists")
ok(db.modules.nameplates ~= nil, "nameplates store exists")
eq(db.npMarker, nil, "no flat keys left at the top level")

if SCENARIO == "migrate" then
    section("v1 -> v2 migration")
    eq(db.modules.nameplates.npMarker, false, "npMarker carried over")
    eq(db.modules.nameplates.npMarkerWarn, true, "npMarkerWarn carried over")
    eq(db.modules.nameplates.npSize, 44, "npSize carried over")
    eq(db.modules.nameplates.npAnchor, "TOP", "npAnchor carried over")
    eq(db.modules.nameplates.npColor[1], 0.35, "npColor carried over")
    eq(db.modules.threat.onlyTankSpec, false, "onlyTankSpec carried over")
    eq(db.modules.threat.sound, false, "sound carried over")
    eq(db.someDeadSettingFromV0, nil, "dead v0 setting dropped")
    -- defaults still fill the gaps the v1 table never had
    eq(db.modules.nameplates.npSecureGlyph, "o", "missing key got its default")
    eq(db.modules.nameplates.npPulse, true, "missing bool got its default")
else
    section("fresh defaults")
    eq(db.modules.nameplates.npMarker, true, "npMarker default")
    eq(db.modules.nameplates.npSize, 28, "npSize default")
    eq(db.modules.nameplates.npAnchor, "LEFT", "npAnchor default")
    eq(db.modules.threat.onlyTankSpec, true, "onlyTankSpec default")
    eq(db.modules.nameplates.npColor[2], 0.92, "npColor default copied")
    -- the copy must not alias the module's defaults table
    db.modules.nameplates.npColor[2] = 0.5
    eq(NS.GetModule("nameplates").defaults.npColor[2], 0.92, "defaults not aliased")
    db.modules.nameplates.npColor[2] = 0.92
end

--------------------------------------------------------------------------------
section("login / world state")
--------------------------------------------------------------------------------

WORLD.inRaid = true
WORLD.groupSize = 5
WORLD.specRole = "TANK"
FireEvent("PLAYER_LOGIN")
FireEvent("PLAYER_ENTERING_WORLD")

eq(NS.state.isTankRole, true, "tank role detected")
eq(NS.state.inInstance, false, "not in an instance")
eq(#NS.groupUnits, 4, "roster drops our own raid token")
-- We are raid1, so our own token is the one that must be absent.
eq(NS.groupUnits[1], "raid2", "roster starts after our own slot")

--------------------------------------------------------------------------------
section("scan and markers")
--------------------------------------------------------------------------------

-- Reset to shipped defaults for the behaviour tests.
local npdb = db.modules.nameplates
npdb.npMarker, npdb.npMarkerWarn, npdb.npMarkerSecure = true, false, false
npdb.npSize, npdb.npAnchor, npdb.npPulse = 28, "LEFT", true
db.modules.threat.onlyTankSpec = true
db.modules.threat.sound = true

-- Three mobs: one held by someone else, one at risk, one securely ours.
WORLD.units["nameplate1"] = { name = "Add A", combat = true, threat = { player = 0 } }
WORLD.units["nameplate2"] = { name = "Add B", combat = true, threat = { player = 2 } }
WORLD.units["nameplate3"] = { name = "Add C", combat = true, threat = { player = 3 } }

for i = 1, 3 do
    local u = "nameplate" .. i
    NAMEPLATES[u] = CreateFrame("Frame", nil, UIParent)
    FireEvent("NAME_PLATE_UNIT_ADDED", u)
end

Tick(0.25)

eq(NS.stateByUnit["nameplate1"], NS.STATE_LOST,   "mob on someone else -> LOST")
eq(NS.stateByUnit["nameplate2"], NS.STATE_WARN,   "insecure hold -> WARN")
eq(NS.stateByUnit["nameplate3"], NS.STATE_SECURE, "secure hold -> SECURE")

--------------------------------------------------------------------------------
section("the personal resource display is not a mob")
--------------------------------------------------------------------------------

local before = 0
for _ in pairs(WORLD.units) do before = before + 1 end
FireEvent("NAME_PLATE_UNIT_ADDED", "player")
ok(true, "player plate token ignored without error")

--------------------------------------------------------------------------------
section("idle fast path")
--------------------------------------------------------------------------------

npdb.npMarker, npdb.npMarkerWarn, npdb.npMarkerSecure = false, false, false
Tick(0.25)
eq(next(NS.stateByUnit), nil, "no markers wanted -> state map emptied")

npdb.npMarker = true
Tick(0.25)
ok(NS.stateByUnit["nameplate1"] ~= nil, "re-enabling a marker resumes the scan")

-- Out of a tank spec, with tankonly on, the scan idles...
WORLD.specRole = "DAMAGER"
FireEvent("PLAYER_SPECIALIZATION_CHANGED")
eq(NS.state.isTankRole, false, "role update saw the spec change")
Tick(0.25)
eq(next(NS.stateByUnit), nil, "not a tank + tankonly -> idle")

-- ...unless preview is on, which must override the role gate.
NS.SetMarkerPreview(true)
Tick(0.25)
ok(NS.stateByUnit["nameplate1"] ~= nil, "preview forces the scan on regardless of spec")
NS.SetMarkerPreview(false)

WORLD.specRole = "TANK"
FireEvent("PLAYER_SPECIALIZATION_CHANGED")

--------------------------------------------------------------------------------
section("lost-mob alert")
--------------------------------------------------------------------------------

SOUNDS_PLAYED = 0
WORLD.playerCombat = true
FireEvent("PLAYER_REGEN_DISABLED")

WORLD.units["nameplate3"].threat.player = 3
Tick(0.25)                       -- establishes "this one is mine"
eq(SOUNDS_PLAYED, 0, "holding a mob is silent")

WORLD.units["nameplate3"].threat.player = 0
Tick(0.25)                       -- it just stopped being ours
eq(SOUNDS_PLAYED, 1, "losing a held mob fires the alert")

Tick(0.25)
eq(SOUNDS_PLAYED, 1, "the alert does not repeat while it stays lost")

--------------------------------------------------------------------------------
section("in an instance, with every identity read restricted")
--------------------------------------------------------------------------------

WORLD.secretMode = true
WORLD.inInstance = true
FireEvent("PLAYER_ENTERING_WORLD")
eq(NS.state.inInstance, true, "instance flag set")

WORLD.units["nameplate1"].threat.player = 0
WORLD.units["nameplate2"].threat.player = nil
Tick(0.25)
eq(NS.stateByUnit["nameplate1"], NS.STATE_LOST, "threat still readable under secrets")

-- A mob nobody has any threat on stays unmarked in an instance rather than
-- throwing on the target comparison.
WORLD.units["nameplate2"].threat = {}
Tick(0.25)
eq(NS.stateByUnit["nameplate2"], nil, "untouched mob in an instance is skipped, not an error")

-- ...but a group member's threat entry is enough to mark it.
WORLD.units["nameplate2"].threat = { raid2 = 3 }
WORLD.units["raid2"] = { name = "Cotank", isPlayer = true }
Tick(0.25)
eq(NS.stateByUnit["nameplate2"], NS.STATE_LOST, "group threat entry marks the mob")

local n = #CHAT
Slash("debug")
ok(#CHAT > n, "/tt debug survives secret values")

WORLD.secretMode = false
WORLD.inInstance = false
FireEvent("PLAYER_ENTERING_WORLD")

--------------------------------------------------------------------------------
section("commands")
--------------------------------------------------------------------------------

Slash("npsize 44")
eq(npdb.npSize, 44, "/tt npsize sets the size")
Slash("npsize 900")
eq(npdb.npSize, 44, "/tt npsize rejects out of range")

Slash("npanchor top")
eq(npdb.npAnchor, "TOP", "/tt npanchor accepts a side")
Slash("npanchor sideways")
eq(npdb.npAnchor, "TOP", "/tt npanchor rejects nonsense")

Slash("npcolor cyan")
eq(npdb.npColor[1], 0.35, "/tt npcolor sets a preset")
Slash("npcolor puce")
eq(npdb.npColor[1], 0.35, "/tt npcolor rejects an unknown preset")

Slash("npglyph X")
eq(npdb.npGlyph, "X", "/tt npglyph keeps the argument's case")

local was = npdb.npMarker
Slash("np")
eq(npdb.npMarker, not was, "/tt np toggles")
Slash("npmine")
eq(npdb.npMarkerSecure, true, "alias /tt npmine works")

local wasSound = db.modules.threat.sound
Slash("sound")
eq(db.modules.threat.sound, not wasSound, "/tt sound toggles")

--------------------------------------------------------------------------------
section("help text")
--------------------------------------------------------------------------------

local n2 = #CHAT
Slash("")
local help = ChatSince(n2)
ok(#help >= 18, "help lists every command and section")

local sections, cmds = {}, {}
for _, line in ipairs(help) do
    local s = Strip(line)
    if s:match("^[%a%-]+:$") then sections[#sections + 1] = s
    else cmds[#cmds + 1] = s end
end
eq(sections[1], "commands:", "first section")
eq(sections[2], "markers:",  "second section")
eq(sections[#sections], "other:", "last section")

-- Every verb the core and the shipping modules register must be listed. Extra
-- ones are fine -- that is a new module doing its job.
local listed = {}
for _, line in ipairs(cmds) do
    listed[line:match("^%s*/tt%s+(%S+)")] = true
end
for _, verb in ipairs({ "config", "nptest", "status", "debug",
                        "np", "npwarn", "npsecure", "nppulse", "npsize",
                        "npanchor", "npglyph", "npwarnglyph", "npsecglyph",
                        "npcolor", "npseccolor", "sound", "tankonly" }) do
    ok(listed[verb], "help lists /tt " .. verb)
end

-- Every command line must have its description at the same column.
local col
local aligned = true
for _, line in ipairs(cmds) do
    local at = line:find("%-%- ")
    if not col then col = at elseif at ~= col then aligned = false end
end
ok(aligned, "descriptions are column-aligned")

-- Every listed verb must actually dispatch. An unrecognised one falls through
-- to the help block, so "did it print a section header" is the tell -- and it
-- works for /tt config, which dispatches while printing nothing at all.
local unknown = {}
for _, line in ipairs(cmds) do
    local verb = line:match("^%s*/tt%s+(%S+)")
    local before = #CHAT
    Slash(verb .. " ")
    for _, out in ipairs(ChatSince(before)) do
        if Strip(out) == "commands:" then unknown[#unknown + 1] = verb end
    end
end
eq(#unknown, 0, "every listed command dispatches (" .. table.concat(unknown, ",") .. ")")

-- ...and an unlisted one does fall through to help.
local before = #CHAT
Slash("definitelynotacommand")
local fellThrough = false
for _, out in ipairs(ChatSince(before)) do
    if Strip(out) == "commands:" then fellThrough = true end
end
ok(fellThrough, "an unknown verb prints the help")

-- The sweep above toggled a pile of settings, preview among them.
if NS.GetMarkerPreview() then NS.SetMarkerPreview(false) end

--------------------------------------------------------------------------------
section("status")
--------------------------------------------------------------------------------

local n3 = #CHAT
Slash("status")
local st = ChatSince(n3)
ok(#st >= 3, "status prints from both modules")

local joined = ""
for _, l in ipairs(st) do joined = joined .. Strip(l) .. "\n" end
ok(joined:find("tank spec:") ~= nil, "status has the threat module's world line")
ok(joined:find("markers %-%-") ~= nil, "status has the nameplate module's line")
ok(joined:find("marked right now") ~= nil, "status has the mark counts")

--------------------------------------------------------------------------------
section("settings window")
--------------------------------------------------------------------------------

NS.ShowOptions()
local panel = _G.TankToolsOptionsFrame
ok(panel ~= nil, "panel built")
ok(panel:IsShown(), "panel shown")
ok(panel._height and panel._height > 300, "panel sized to its content: "
   .. tostring(panel._height))

local pages = NS.optionsPages
eq(pages[1].name, "Threat", "the threat page sorts first")

-- The strip exists exactly when there is more than one page to choose between.
local tabs = 0
for _, p in ipairs(pages) do if p.tab then tabs = tabs + 1 end end
if #pages > 1 then
    eq(tabs, #pages, "one tab per page")
else
    eq(tabs, 0, "no tab strip with a single page")
end

-- Exactly one page is visible, whichever page that is.
local visible = 0
for _, p in ipairs(pages) do if p.frame:IsShown() then visible = visible + 1 end end
eq(visible, 1, "exactly one page visible")

if SCENARIO == "tabs" then
    eq(pages[#pages].name, "Tank Watch", "the added page sorts last")

    local before = #NS.ui.controls
    pages[#pages].tab._scripts.OnClick()
    ok(pages[#pages].frame:IsShown(), "clicking a tab shows its page")
    ok(not pages[1].frame:IsShown(),  "and hides the others")
    eq(#NS.ui.controls, before, "switching tabs registers no new controls")
end

ok(#NS.ui.controls >= 14, "controls registered for refresh: " .. #NS.ui.controls)

NS.RefreshOptions()
ok(true, "refresh replays every control without error")

NS.ToggleOptions()
ok(not panel:IsShown(), "toggle hides")

--------------------------------------------------------------------------------
section("feature flags")
--------------------------------------------------------------------------------

-- The co-tank panel is the flagged module at the time of writing. If it ever
-- ships, this section moves to whatever is behind the flag next -- what is
-- being tested is the gate, not the module.
ok(NS.GetModule("features") ~= nil, "features module registered")
ok(NS.GetFeature("cotanks") ~= nil, "the co-tank panel registered a flag")
eq(db.modules.features.cotanks, false, "flag defaults to off")
eq(NS.FeatureEnabled("cotanks"), false, "...and reads as off")

-- Gating is opt-in, so a name nobody registered is allowed through. A stale
-- `feature = "..."` left on a command after the flag is deleted must not
-- silently hide a shipped feature.
eq(NS.FeatureEnabled("nosuchfeature"), true, "an unregistered flag is enabled")

-- The whole point: a gated module never starts, so nothing of it is running.
eq(NS.GetTicker("tankwatch"), nil, "a gated module registers no ticker")
ok(TankToolsDB.modules.tankwatch ~= nil, "...but its settings still exist")

-- Not in the help, and not dispatchable. An unknown verb falls through to the
-- help block, which is the tell for both.
local nf = #CHAT
Slash("")
local helpText = ""
for _, line in ipairs(ChatSince(nf)) do helpText = helpText .. Strip(line) .. "\n" end
ok(helpText:find("/tt tw") == nil, "help does not list a gated command")
ok(helpText:find("co%-tanks:") == nil, "an empty section prints no header")
ok(helpText:find("/tt features") == nil, "the hidden command is not listed either")

local nf2 = #CHAT
Slash("tw")
local fell = false
for _, out in ipairs(ChatSince(nf2)) do
    if Strip(out) == "commands:" then fell = true end
end
ok(fell, "a gated command does not dispatch")

-- No tab for it, and no status lines from a module that never started.
local hasPage = false
for _, p in ipairs(NS.optionsPages) do
    if p.name == "Co-tanks" then hasPage = true end
end
ok(not hasPage, "a gated settings page is dropped")

local nf3 = #CHAT
Slash("status")
local statusText = ""
for _, line in ipairs(ChatSince(nf3)) do statusText = statusText .. Strip(line) .. "\n" end
ok(statusText:find("co%-tank panel:") == nil, "a gated status provider stays quiet")

--------------------------------------------------------------------------------
section("the feature window")
--------------------------------------------------------------------------------

local ctrlsBefore = #NS.ui.controls
NS.ShowFeatures()

local fpanel = _G.TankToolsFeaturesFrame
ok(fpanel ~= nil, "features window built")
ok(fpanel:IsShown(), "features window shown")
ok(fpanel:GetHeight() > 0, "sized to its content: " .. tostring(fpanel:GetHeight()))

local box
for i = ctrlsBefore + 1, #NS.ui.controls do
    local c = NS.ui.controls[i]
    if not box and c.GetObjectType and c:GetObjectType() == "CheckButton" then
        box = c
    end
end
ok(box ~= nil, "one checkbox per registered feature")

-- A real click toggles the box first, then runs OnClick.
box:SetChecked(true)
box._scripts.OnClick(box)
eq(NS.FeatureEnabled("cotanks"), true, "ticking the box sets the flag")
eq(db.modules.features.cotanks, true, "...and it is saved")
eq(NS.FeatureNeedsReload(), true, "...and a reload is now needed")

-- Toggling back to the state the modules were started with leaves nothing to
-- apply, so the window must stop asking for a reload.
box:SetChecked(false)
box._scripts.OnClick(box)
eq(NS.FeatureEnabled("cotanks"), false, "unticking clears the flag")
eq(NS.FeatureNeedsReload(), false, "back where we started -- nothing to apply")

NS.ToggleFeatures()
ok(not fpanel:IsShown(), "toggle hides the features window")

--------------------------------------------------------------------------------
section("ticker latch")
--------------------------------------------------------------------------------

local t = NS.GetTicker("threat")
ok(t ~= nil, "threat ticker registered")
local realFn = t.fn
t.fn = function() error("simulated restriction") end
local n4 = #CHAT
Tick(0.25); Tick(0.25); Tick(0.25)
eq(t.disabled, true, "three failures disable the ticker")
ok(#CHAT > n4, "the failure is reported")
Tick(0.25)
t.fn = realFn
FireEvent("PLAYER_ENTERING_WORLD")
eq(t.disabled, false, "a zone change clears the latch")
Tick(0.25)
ok(true, "scanning resumes")

--------------------------------------------------------------------------------
section("nameplate teardown")
--------------------------------------------------------------------------------

FireEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1")
WORLD.units["nameplate1"] = nil
Tick(0.25)
eq(NS.stateByUnit["nameplate1"], nil, "a removed plate leaves no state behind")

--------------------------------------------------------------------------------
report()
