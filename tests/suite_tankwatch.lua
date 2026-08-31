--------------------------------------------------------------------------------
-- Co-tank panel: roster, layout, health, auras, the aggro ring.
--
-- Scenarios:
--   fresh   everything readable, as it is out in the world
--   secret  every identity read comes back a secret value, as it may inside an
--           instance. The panel must still render: health goes straight into
--           setters and is never read, so only the percent text, the aura sort
--           and the class colour are allowed to degrade.
--   engine  the client has an aura container widget AND has denied aura reads
--           outright, which is a boss fight. This is the scenario the panel
--           was failing: the addon must not touch an aura API at all, and the
--           icons must still be on screen.
--------------------------------------------------------------------------------

local ENGINE  = (SCENARIO == "engine")
local SECRETS = (SCENARIO == "secret")

-- Both set before the addon loads: the row probes for an engine once, on its
-- first layout, and the answer is cached for the session the way it is in the
-- real client.
WORLD.auraEngine  = ENGINE
WORLD.aurasSecret = ENGINE

--------------------------------------------------------------------------------
-- A raid with three tanks: us (raid1), plus raid2 and raid5.
--------------------------------------------------------------------------------

-- Boss auras by default: the panel filters to boss and role debuffs out of the
-- box, because the aura engine cannot be asked to sort by stacks and a row
-- full of procs would push the tank debuff off the end.
local function Aura(icon, stacks, dur, remaining, boss)
    return {
        icon = icon, applications = stacks, duration = dur,
        expirationTime = remaining and (GetTime() + remaining) or nil,
        boss = (boss ~= false),
    }
end

local function BuildRaid()
    WORLD.inRaid, WORLD.groupSize = true, 5
    WORLD.specRole = "TANK"
    WORLD.raidIndex = 0                     -- we are raid1

    -- raid1 is us. In a raid our own slot is a raid token like any other, and
    -- the panel draws us under it rather than under "player".
    WORLD.units["raid1"] = {
        name = "Tankadin", isPlayer = true, class = "WARRIOR",
        combatRole = "TANK", hp = 94, hpMax = 100, auras = {},
    }
    WORLD.units["raid2"] = {
        name = "Bearbutt", isPlayer = true, class = "DRUID",
        combatRole = "TANK", hp = 81, hpMax = 100, absorb = 6,
        auras = {
            Aura("icon-a",  nil, 12, 6),   -- no stacks
            Aura("icon-b",    7, 30, 21),  -- the tank-swap debuff
            Aura("icon-c",    2, 20, 11),
            Aura("icon-d",  nil, nil, nil),
        },
    }
    WORLD.units["raid3"] = { name = "Healbot",  isPlayer = true, combatRole = "HEALER"  }
    WORLD.units["raid4"] = { name = "Stabbity", isPlayer = true, combatRole = "DAMAGER" }
    WORLD.units["raid5"] = {
        name = "Shieldwall", isPlayer = true, class = "PALADIN",
        combatRole = "TANK", hp = 100, hpMax = 100,
        auras = { Aura("icon-e", 3, 10, 4) },
    }
    WORLD.units["player"] = {
        name = "Tankadin", isPlayer = true, class = "WARRIOR",
        hp = 94, hpMax = 100, auras = {},
    }
end

--------------------------------------------------------------------------------
section("load")
--------------------------------------------------------------------------------

BuildRaid()

FireEvent("ADDON_LOADED", "TankTools")

-- Shipped, so there is nothing to switch on: the module starts for everybody.
-- This suite used to seed a saved-variables table with the flag set, which was
-- the only state in which any of it was reachable.
eq(NS.GetFeature("cotanks"), nil, "the co-tank panel ships without a flag")
-- By name, not by count: a suite that has to be edited every time a module is
-- added is the coupling the module registry exists to remove.
ok(NS.GetModule("tankwatch") ~= nil, "tankwatch module registered")
ok(NS.GetModule("threat") ~= nil, "threat module registered")
ok(NS.GetModule("nameplates") ~= nil, "nameplates module registered")

local db = TankToolsDB.modules.tankwatch
ok(db ~= nil, "tankwatch has its own settings table")
eq(db.twAuraAnchor, "RIGHT", "aura anchor default")
eq(db.twMaxAuras, 5, "icon cap default")
eq(db.twPoint, nil, "no saved position until the panel is dragged")

--------------------------------------------------------------------------------
section("tank roster")
--------------------------------------------------------------------------------

FireEvent("PLAYER_LOGIN")
FireEvent("PLAYER_ENTERING_WORLD")

eq(#NS.tankUnits, 3, "three tanks found")
eq(NS.tankUnits[1], "raid1", "we come first, under our raid token")
eq(NS.tankUnits[2], "raid2", "co-tanks follow in roster order")
eq(NS.tankUnits[3], "raid5", "a tank further down the roster is still found")
eq(NS.selfUnit, "raid1", "Core resolved which token is us")

-- The bug this replaced: "player" plus a roster that still contained our own
-- raid token, which drew two of us.
for i = 1, #NS.tankUnits do
    ok(NS.tankUnits[i] ~= "player", "our own slot is never listed twice")
end

--------------------------------------------------------------------------------
section("when the client will not say which slot we are")
--------------------------------------------------------------------------------

WORLD.raidIndex = nil
FireEvent("GROUP_ROSTER_UPDATE")

eq(#NS.tankUnits, 3, "still exactly three tanks, not four")
local seen = {}
for i = 1, #NS.tankUnits do
    ok(not seen[NS.tankUnits[i]], "no duplicate entry: " .. NS.tankUnits[i])
    seen[NS.tankUnits[i]] = true
end
ok(not seen["player"], "no separate player entry to double us up")

-- With UnitInRaid silent, the name match is the remaining way to know which
-- bar is ours. It drives presentation only -- never who counts as a tank.
eq(NS.selfUnit, "raid1", "the name fallback still identifies our slot")

-- ...and when names are unreadable too, it gives up rather than guessing.
WORLD.secretMode = true
FireEvent("GROUP_ROSTER_UPDATE")
eq(NS.selfUnit, "player", "no identification left, so no claim is made")
eq(#NS.tankUnits, 3, "the tank list is unaffected by not knowing which is us")
WORLD.secretMode = SECRETS
FireEvent("GROUP_ROSTER_UPDATE")

-- A secret index must not throw on the `+ 1`.
WORLD.raidIndexSecret = true
FireEvent("GROUP_ROSTER_UPDATE")
eq(#NS.tankUnits, 3, "a secret raid index is survivable")
WORLD.raidIndexSecret = false

WORLD.raidIndex = 0
FireEvent("GROUP_ROSTER_UPDATE")
eq(NS.selfUnit, "raid1", "and it recovers when the client answers again")

-- The roster's spec-derived combat role must beat the queued role, which is
-- what UnitGroupRolesAssigned reports and what goes stale on a spec swap.
-- Our own slot is judged by our spec, not by the roster, which lags a swap.
-- raid1 still says TANK in the roster here; our spec says otherwise, and our
-- spec wins.
WORLD.specRole = "DAMAGER"
FireEvent("GROUP_ROSTER_UPDATE")
eq(#NS.tankUnits, 2, "we drop out when our own spec stops tanking")
eq(NS.tankUnits[1], "raid2", "the raid's combat roles still identify the others")

WORLD.specRole = "TANK"
FireEvent("GROUP_ROSTER_UPDATE")
eq(#NS.tankUnits, 3, "and we come back")

-- A tank leaving must not leave a block pointing at a recycled token.
WORLD.units["raid5"].combatRole = "DAMAGER"
FireEvent("GROUP_ROSTER_UPDATE")
eq(#NS.tankUnits, 2, "a tank respeccing leaves the list")
WORLD.units["raid5"].combatRole = "TANK"
FireEvent("GROUP_ROSTER_UPDATE")

--------------------------------------------------------------------------------
section("panel renders")
--------------------------------------------------------------------------------

if SECRETS then WORLD.secretMode = true end

Tick(0.25)

local panel = _G.TankToolsTankWatchFrame
ok(panel ~= nil, "panel frame built")
ok(panel:IsShown(), "panel shown with three tanks")
ok(panel._width > 0 and panel._height > 0, "panel sized")

--------------------------------------------------------------------------------
section("health goes into setters, never through a comparison")
--------------------------------------------------------------------------------

-- One block per tank, and they are the panel's only direct child frames.
local blocks = FramesParentedTo(panel)
eq(#blocks, 3, "one block per tank")

local bars = {}
for i, b in ipairs(blocks) do
    for _, child in ipairs(FramesParentedTo(b)) do
        if child._type == "StatusBar" then bars[i] = child end
    end
end
eq(#bars, 3, "each block has a status bar")
for i = 1, 3 do
    ok(bars[i]._max ~= nil, "bar " .. i .. " got SetMinMaxValues")
    ok(bars[i]._value ~= nil, "bar " .. i .. " got SetValue")
end

if SECRETS then
    ok(IsSecretValue(bars[1]._value), "a secret health value reached the bar unread")
else
    eq(bars[1]._value, 94, "our health reached the bar (via our raid token)")
    eq(bars[2]._value, 81, "the co-tank's health reached the bar")
end

--------------------------------------------------------------------------------
section("percent text degrades, the bar does not")
--------------------------------------------------------------------------------

local texts = TextsIn(panel)
if SECRETS then
    ok(not FindText(texts, "94%"), "no percent text when health cannot be read")
else
    ok(FindText(texts, "94%"), "our percent shown")
    ok(FindText(texts, "81%"), "the co-tank's percent shown")
end

--------------------------------------------------------------------------------
section("debuffs")
--------------------------------------------------------------------------------

-- raid2 is block 2 and carries four harmful auras, one of them stacking to 7.
-- Shown buttons the aura engine created for a row, in the order it drew them.
-- Through _RawShown, not IsShown: a restricted widget answers its own getters
-- with secrets, so the addon cannot count these and neither could this helper.
local function EngineButtons(row)
    local out = {}
    local c = row.container
    if not c then return out end
    for _, key in ipairs(c._order) do
        for _, b in ipairs(c._groups[key].buttons) do
            if b:_RawShown() then out[#out + 1] = b end
        end
    end
    return out
end

local function IconsIn(b)
    local out = {}
    for _, f in ipairs(FramesParentedTo(b.auras.host)) do
        if f._type == "Frame" then out[#out + 1] = f end
    end
    return out
end

if ENGINE then
    -- The whole point. Aura reads throw in this scenario, so any icon on
    -- screen is one the client drew after being told a unit and a filter.
    local row = blocks[2].auras
    ok(row:IsEngine(), "the row handed the drawing to the aura engine")
    eq(row:Count(), nil, "and does not pretend to know how many it drew")

    local buttons = EngineButtons(row)
    eq(#buttons, 4, "four debuffs drawn while aura reads are denied")

    -- Nothing in the engine gives an AuraButton a rect. The template carries
    -- no size, the frame provider sets none, and the flow layout's
    -- ApplyElementLayout only clears the points and sets one anchor -- its
    -- elementWidth/elementHeight decide spacing, not the frame. So a button is
    -- 0x0 until we say otherwise, an icon told to SetAllPoints on it is 0x0
    -- too, and the row reports a group, buttons, positions and shows -- and
    -- puts nothing on screen. It read as "the filter ate my debuffs" for a
    -- long time.
    eq(buttons[1]:_RawWidth(), NS.GetModule("tankwatch").db.twIconSize,
       "engine buttons are sized by us, or they are invisible")
    eq(buttons[1]:_RawHeight(), NS.GetModule("tankwatch").db.twIconSize,
       "in both directions")
    eq(buttons[2]._icon._texture, "icon-b", "the engine drew the icon art")
    eq(buttons[2]._count._text, 7, "and the stack count that decides the swap")
    ok(buttons[2]._click == false, "buttons do not eat clicks meant for the world")
    ok(buttons[2]._motion == true, "but keep motion, so the engine can tooltip them")

    -- The row never touched an aura API: if it had, the harness would have
    -- thrown and the ticker latch would have stopped the panel.
    local ticker = NS.GetTicker("tankwatch")
    ok(not ticker.disabled, "the panel is still running: " .. tostring(ticker.err))
    eq(ticker.failures, 0, "and has not thrown once")

    -- The boss/role filter is off by default -- deliberately, because the
    -- engine never reports what it dropped -- so a proc is shown.
    WORLD.units["raid2"].auras[5] = Aura("proc", nil, 8, 4, false)
    FireEvent("UNIT_AURA", "raid2")
    Tick(0.25)
    eq(#EngineButtons(row), 5, "everything harmful is shown out of the box")

    -- ...and turning the filter on drops it, live, without a reload.
    NS.GetModule("tankwatch").db.twBossAuras = true
    NS.TankWatchLooksChanged()
    Tick(0.25)
    eq(#EngineButtons(row), 4, "the filter drops a non-boss proc when asked")

    NS.GetModule("tankwatch").db.twBossAuras = false
    NS.TankWatchLooksChanged()
    Tick(0.25)
    WORLD.units["raid2"].auras[5] = nil
    FireEvent("UNIT_AURA", "raid2")
    Tick(0.25)
end

local icons = IconsIn(blocks[2])
if ENGINE then
    eq(#icons, 0, "no fallback icons are built when the engine is doing it")
else
    ok(#icons >= 4, "icons created for the co-tank: " .. #icons)

    local shown = 0
    for _, ic in ipairs(icons) do if ic:IsShown() then shown = shown + 1 end end
    eq(shown, 4, "all four harmful auras drawn, none filtered out")
end

if ENGINE then
    -- covered above
elseif not SECRETS then
    -- Stacking auras sort to the front, so the tank-swap debuff is the icon
    -- nearest the bar and does not wander.
    eq(icons[1].tex._texture, "icon-b", "the 7-stack debuff sorts first")
    eq(icons[1].count._text, 7, "its stack count is drawn")
    eq(icons[2].tex._texture, "icon-c", "the 2-stack debuff sorts second")
    eq(icons[2].count._text, 2, "its stack count is drawn")
    eq(icons[3].count._text, "", "a non-stacking debuff draws no count")
    ok(icons[1].cd._cd ~= nil, "a timed aura gets a cooldown swipe")
    ok(icons[4].cd._cd == nil, "an aura with no duration gets no swipe")
else
    -- Unreadable counts still reach the font string: SetText takes a secret,
    -- and the client renders it. What must not happen is a comparison.
    -- icon-a has no stacks at all, so its count is genuinely empty; icon-b
    -- stacks to 7, and that is the one that must arrive as a secret rather
    -- than as a blank.
    eq(icons[1].count._text, "", "a debuff that does not stack still draws no count")
    ok(IsSecretValue(icons[2].count._text),
       "an unreadable stack count is handed to the font string unread")
    ok(icons[1].cd._cd == nil, "no swipe when the duration cannot be read")
    -- Order falls back to the client's own, which is aura index order.
    eq(icons[1].tex._texture, "icon-a", "unsortable auras keep the client's order")
end

--------------------------------------------------------------------------------
section("debuffs appear without ever receiving UNIT_AURA")
--------------------------------------------------------------------------------

-- The reported failure was no debuff icons at all across two boss fights. A
-- change event that never arrives is indistinguishable from a tank with no
-- debuffs, so the panel must not depend on one: a tank who gains a debuff has
-- to light up within a second whether or not UNIT_AURA fires.
local function IconsShown(b)
    if ENGINE then return #EngineButtons(b.auras) end
    local n = 0
    for _, f in ipairs(IconsIn(b)) do
        if f:IsShown() then n = n + 1 end
    end
    return n
end

WORLD.units["raid5"].auras = {}
for _ = 1, 6 do Tick(0.25) end       -- past AURA_RESCAN
eq(IconsShown(blocks[3]), 0, "no icons for a tank with no debuffs")

-- A debuff lands, and no event is fired at all.
WORLD.units["raid5"].auras = {
    { icon = "late", applications = 4, duration = 20,
      expirationTime = GetTime() + 15, boss = true },
}
Tick(0.25)
Tick(0.25)   -- more than AURA_RESCAN of simulated time
Tick(0.25)
Tick(0.25)
Tick(0.25)

eq(IconsShown(blocks[3]), 1, "the periodic re-read finds it anyway")

-- ...and it goes away again the same way.
WORLD.units["raid5"].auras = {}
for _ = 1, 6 do Tick(0.25) end
eq(IconsShown(blocks[3]), 0, "and clears it when it drops")

--------------------------------------------------------------------------------
section("the client's aura tables are never written to")
--------------------------------------------------------------------------------

-- Attaching a sort index to a table the client owns is the kind of thing a
-- restricted client may refuse. Nothing the API hands back may come back
-- modified.
local probe = { icon = "p", applications = 3, duration = 10,
                expirationTime = GetTime() + 5, boss = true }
WORLD.units["raid5"].auras = { probe }
FireEvent("UNIT_AURA", "raid5")
Tick(0.25)

local extra = {}
for k in pairs(probe) do
    if k ~= "icon" and k ~= "applications" and k ~= "duration"
       and k ~= "expirationTime" and k ~= "boss" then
        extra[#extra + 1] = tostring(k)
    end
end
eq(#extra, 0, "no field added to the aura table: " .. table.concat(extra, ","))

--------------------------------------------------------------------------------
section("debuff tooltips")
--------------------------------------------------------------------------------

-- Fallback-path only. On the engine path the icons are the engine's own
-- buttons and so is the tooltip on them: the addon has nothing to address
-- and no aura instance id to address it with, which is the trade for having
-- any icons at all in a boss fight.
if not ENGINE then

    -- raid2's icons are sorted by stack count, so icon 1 is the 7-stack debuff --
    -- which the client returned at index 2. A tooltip addressed by index would
    -- describe the wrong debuff; the instance id names the right one either way.
    WORLD.units["raid2"].auras = {
        { icon = "a", applications = nil, duration = 12, boss = true,
          expirationTime = GetTime() + 6,  auraInstanceID = 101 },
        { icon = "b", applications = 7,   duration = 30, boss = true,
          expirationTime = GetTime() + 21, auraInstanceID = 102 },
        { icon = "c", applications = 2,   duration = 20, boss = true,
          expirationTime = GetTime() + 11, auraInstanceID = 103 },
    }
    FireEvent("UNIT_AURA", "raid2")
    Tick(0.25)

    local top = icons[1]
    eq(top.tex._texture, SECRETS and "a" or "b", "the icon under test")

    top._scripts.OnEnter(top)
    ok(GameTooltip:IsOwned(top), "hovering an icon takes ownership of the tooltip")
    ok(GameTooltip:IsShown(), "and shows it")
    eq(GameTooltip._content.how, "instance", "addressed by aura instance id")
    eq(GameTooltip._content.unit, "raid2", "for the right unit")
    eq(GameTooltip._content.id, SECRETS and 101 or 102,
       "and the aura actually under the cursor, not the client's aura 1")

    -- A refresh while hovered must re-point the tooltip, not leave it stale.
    GameTooltip._content = nil
    FireEvent("UNIT_AURA", "raid2")
    Tick(0.25)
    ok(GameTooltip._content ~= nil, "a refresh under the cursor re-sets the tooltip")

    top._scripts.OnLeave(top)
    ok(not GameTooltip:IsShown(), "leaving hides it")

    -- Hiding an icon out from under the cursor must not strand the tooltip.
    top._scripts.OnEnter(top)
    ok(GameTooltip:IsShown(), "hovering again")
    top._scripts.OnHide(top)
    ok(not GameTooltip:IsShown(), "an icon hidden under the cursor drops the tooltip")

    -- ...but only ever our own tooltip.
    GameTooltip:SetOwner("somebody else")
    GameTooltip:Show()
    top._scripts.OnLeave(top)
    ok(GameTooltip:IsShown(), "another frame's tooltip is left alone")
    GameTooltip:Hide()

    -- The toggle takes the mouse away entirely, so the icons stop swallowing
    -- clicks meant for the world behind them.
    Slash("twtips")
    eq(db.twTooltips, false, "/tt twtips turns them off")
    Tick(0.25)
    top._scripts.OnEnter(top)
    ok(not GameTooltip:IsShown(), "no tooltip when they are off")
    Slash("twtips")
    eq(db.twTooltips, true, "and back on")
    Tick(0.25)
end

--------------------------------------------------------------------------------
section("stack counts stay put across refreshes")
--------------------------------------------------------------------------------

-- Whichever path drew them, the icon in the leading slot must be the same one
-- tick after tick: an icon that swaps places is worse than no icon at all,
-- because the number you are reading is attached to the position.
local function LeadIcon(b)
    if ENGINE then
        local buttons = EngineButtons(b.auras)
        return buttons[1] and buttons[1]._icon._texture
    end
    return IconsIn(b)[1].tex._texture
end

WORLD.units["raid5"].auras = {}
local first = LeadIcon(blocks[2])
for _ = 1, 5 do
    FireEvent("UNIT_AURA", "raid2")
    Tick(0.25)
end
eq(LeadIcon(blocks[2]), first, "the leading icon does not shuffle between ticks")

--------------------------------------------------------------------------------
section("the icon size slider reaches the icons")
--------------------------------------------------------------------------------

-- The bug this section exists for: making the bars taller and then dragging
-- "Icon size" up did nothing on screen.
--
-- On the engine path a button is sized exactly once, by us, inside
-- initializeFrame -- the engine owns it from then on. SetAuraGroupLayout takes
-- the new size and only respaces the buttons with it, so the row spread itself
-- out around icons that stayed the size they were first built at, and the
-- slider looked dead until a reload. The row now swaps in a container built at
-- the new size instead.

-- What every icon in the row measures, whichever path drew it.
local function IconSizes(b)
    local out = {}
    if ENGINE then
        for _, btn in ipairs(EngineButtons(b.auras)) do
            out[#out + 1] = btn:_RawWidth() .. "x" .. btn:_RawHeight()
        end
    else
        -- Only the ones on screen: icons left over from a larger cap stay
        -- allocated at whatever size they last had, and they are hidden.
        for _, ic in ipairs(IconsIn(b)) do
            if ic:IsShown() then
                out[#out + 1] = ic:GetWidth() .. "x" .. ic:GetHeight()
            end
        end
    end
    return out
end

local function AllAre(sizes, n)
    if #sizes == 0 then return false end
    for _, s in ipairs(sizes) do
        if s ~= (n .. "x" .. n) then return false end
    end
    return true
end

local sizeBlock = blocks[2]
local startSize = db.twIconSize

db.twIconSize = 34
NS.TankWatchLooksChanged()
Tick(0.25)
ok(AllAre(IconSizes(sizeBlock), 34),
   "raising the slider resizes the icons that are up, without a reload")

db.twIconSize = 16
NS.TankWatchLooksChanged()
Tick(0.25)
ok(AllAre(IconSizes(sizeBlock), 16), "and lowering it resizes them back down")

-- The debuffs themselves have to survive the swap. A container that changed
-- under a bound unit is not a unit change, so nothing else would rebind it.
ok(#IconSizes(sizeBlock) > 0, "the debuffs are still drawn after the swap")

if ENGINE then
    -- Frames cannot be destroyed and OnValueChanged fires on every step of a
    -- drag, so retired containers are reused by the size they were built at.
    -- Three sizes have been used here; sweeping back over them must allocate
    -- nothing, or a slow drag would leave a frame behind per pixel.
    local pool = sizeBlock.auras:Report().pool
    for _, n in ipairs({ 34, 16, startSize, 34, 16 }) do
        db.twIconSize = n
        NS.TankWatchLooksChanged()
        Tick(0.25)
    end
    eq(sizeBlock.auras:Report().pool, pool,
       "sizes already built at are reused, not rebuilt")
end

db.twIconSize = startSize
NS.TankWatchLooksChanged()
Tick(0.25)
ok(AllAre(IconSizes(sizeBlock), startSize), "and back to where the suite found it")
eq(FAILED_TICKS(), 0, "no ticker failures across the swaps")

--------------------------------------------------------------------------------
section("aggro ring")
--------------------------------------------------------------------------------

local function RingShown(b)
    local n = 0
    for _, t in ipairs(TexturesIn(b)) do
        if t._color and t._color[1] == 1 and t._color[2] == 0.82 and t:IsShown() then
            n = n + 1
        end
    end
    return n
end

eq(RingShown(blocks[1]), 0, "no ring with no boss in the fight")

-- The boss engages, and the co-tank is the one holding it.
WORLD.units["boss1"] = { name = "Big Guy", combat = true, threat = { raid2 = 3 } }
Tick(0.25)
eq(RingShown(blocks[2]), 4, "the tank holding the boss is ringed")
eq(RingShown(blocks[1]), 0, "we are not")

-- Taunt: threat flips to us.
-- Keyed by the token the panel asks about -- in a raid we are raid1, and
-- UnitThreatSituation answers for that token exactly as it does for "player".
WORLD.units["boss1"].threat = { raid1 = 3, raid2 = 1 }
Tick(0.25)
eq(RingShown(blocks[1]), 4, "the ring follows the taunt")
eq(RingShown(blocks[2]), 0, "and leaves the other tank")

WORLD.units["boss1"] = nil

--------------------------------------------------------------------------------
section("row and column layouts")
--------------------------------------------------------------------------------

-- Where a block was anchored, as (xOffset, yOffset) from the panel's TOPLEFT.
-- SetPoint records (point, relativeTo, relativePoint, x, y), and LayoutBlock
-- clears its points first, so there is exactly one to read.
local function Offset(b)
    local pt = b._points[#b._points]
    return pt[4], pt[5]
end

db.twLayout = "ROW"
NS.TankWatchLooksChanged()
Tick(0.25)

local rowW, rowH = panel._width, panel._height
ok(rowW > rowH, "side by side is wider than it is tall")

local x1, y1 = Offset(blocks[1])
local x2, y2 = Offset(blocks[2])
local x3, y3 = Offset(blocks[3])
eq(y1, y2, "row: every block on the same line")
eq(y2, y3, "row: including the third")
ok(x2 > x1 and x3 > x2, "row: blocks advance to the right")

-- No overlap: each block starts past the end of the one before it.
local blockW = x2 - x1
ok(blockW >= db.twBarWidth, "row: a block is at least a bar wide")

db.twLayout = "COLUMN"
NS.TankWatchLooksChanged()
Tick(0.25)

ok(panel:IsShown(), "panel still shown after switching layout")
ok(panel._height > rowH, "stacked is taller than the row was")
ok(panel._width < rowW, "and narrower")

x1, y1 = Offset(blocks[1])
x2, y2 = Offset(blocks[2])
x3, y3 = Offset(blocks[3])
eq(x1, x2, "column: every block in the same left edge")
eq(x2, x3, "column: including the third")
ok(y2 < y1 and y3 < y2, "column: blocks advance downward")

-- Stacked blocks must clear each other vertically, or the debuff row of one
-- tank draws over the name of the next.
local step = y1 - y2
ok(step >= db.twBarHeight, "column: blocks do not overlap (step " .. step .. ")")

-- The panel grows by exactly one block per extra tank in either direction.
local threeH = panel._height
db.twMinTanks = 1
db.twShowSelf = false          -- drops to two tanks
NS.TankWatchLooksChanged()
Tick(0.25)
ok(panel._height < threeH, "column: the panel shrinks when a tank drops out")
db.twShowSelf = true
db.twMinTanks = 2
NS.TankWatchLooksChanged()
Tick(0.25)

-- The aura anchor is independent of the layout.
for _, layout in ipairs({ "ROW", "COLUMN" }) do
    for _, anchor in ipairs({ "LEFT", "RIGHT" }) do
        db.twLayout, db.twAuraAnchor = layout, anchor
        NS.TankWatchLooksChanged()
        Tick(0.25)
        ok(panel:IsShown(), layout .. " + " .. anchor .. " renders")
    end
end

Slash("twlayout column")
eq(db.twLayout, "COLUMN", "/tt twlayout column")
Slash("twlayout stacked")
eq(db.twLayout, "COLUMN", "/tt twlayout accepts \"stacked\"")
Slash("twlayout row")
eq(db.twLayout, "ROW", "/tt twlayout row")
Slash("twlayout side")
eq(db.twLayout, "ROW", "/tt twlayout accepts \"side\"")
Slash("twlayout diagonal")
eq(db.twLayout, "ROW", "/tt twlayout rejects nonsense")

db.twAuraAnchor = "RIGHT"
NS.TankWatchLooksChanged()
Tick(0.25)

--------------------------------------------------------------------------------
section("hiding")
--------------------------------------------------------------------------------

db.twMinTanks = 4
Tick(0.25)
ok(not panel:IsShown(), "hidden below the minimum tank count")

db.twMinTanks = 2
Tick(0.25)
ok(panel:IsShown(), "shown again")

db.twEnabled = false
Tick(0.25)
ok(not panel:IsShown(), "hidden when disabled")

db.twEnabled = true
Tick(0.25)

-- Preview must show it regardless of group or setting.
db.twEnabled = false
NS.SetTankWatchPreview(true)
Tick(0.25)
ok(panel:IsShown(), "preview shows the panel even when disabled")
eq(NS.GetTankWatchPreview(), true, "preview flag readable")
NS.SetTankWatchPreview(false)
db.twEnabled = true
Tick(0.25)

--------------------------------------------------------------------------------
section("commands")
--------------------------------------------------------------------------------

Slash("twanchor left")
eq(db.twAuraAnchor, "LEFT", "/tt twanchor left")
Slash("twanchor sideways")
eq(db.twAuraAnchor, "LEFT", "/tt twanchor rejects nonsense")
Slash("twanchor right")
eq(db.twAuraAnchor, "RIGHT", "/tt twanchor right")

Slash("twlock")
eq(db.twLocked, true, "/tt twlock locks")
Slash("twlock")
eq(db.twLocked, false, "/tt twlock unlocks")

Slash("tw")
eq(db.twEnabled, false, "/tt tw toggles the panel off")
Slash("tw")
eq(db.twEnabled, true, "and back on")

-- Listed in the help like any other shipped command. suite_core asserts the
-- gate itself, against a module that is still behind one.
local nh = #CHAT
Slash("")
local helpText = ""
for _, line in ipairs(ChatSince(nh)) do helpText = helpText .. Strip(line) .. "\n" end
ok(helpText:find("co%-tanks:") ~= nil, "the section header is back in the help")
ok(helpText:find("/tt twlayout") ~= nil, "and so are its commands")

local n = #CHAT
Slash("cotanks")
ok(#CHAT > n + 3, "/tt cotanks dumps a line per tank")
Tick(0.25)

--------------------------------------------------------------------------------
section("the layout survives every anchor and size")
--------------------------------------------------------------------------------

for _, layout in ipairs({ "ROW", "COLUMN" }) do
  for _, anchor in ipairs({ "LEFT", "RIGHT" }) do
    for _, icons_n in ipairs({ 1, 5, 8 }) do
        db.twLayout     = layout
        db.twAuraAnchor = anchor
        db.twMaxAuras   = icons_n
        db.twIconSize   = 12 + icons_n
        db.twBarWidth   = 80 + icons_n * 20
        NS.TankWatchLooksChanged()
        Tick(0.25)
    end
  end
end
ok(panel:IsShown(), "panel survives every layout, anchor and size combination")
eq(FAILED_TICKS(), 0, "no ticker failures during the sweep")

--------------------------------------------------------------------------------
section("settings page")
--------------------------------------------------------------------------------

NS.ShowOptions()
eq(#NS.optionsPages, 2, "the module added a second settings page")
eq(NS.optionsPages[1].name, "Threat",   "threat page first")
eq(NS.optionsPages[2].name, "Co-tanks", "co-tank page second")
ok(NS.optionsPages[1].tab ~= nil, "a tab strip appeared")
ok(NS.optionsPages[2].tab ~= nil, "both tabs built")

NS.optionsPages[2].tab._scripts.OnClick()
ok(NS.optionsPages[2].frame:IsShown(), "the co-tank page can be shown")
NS.RefreshOptions()
ok(true, "refreshing every control on both pages does not error")

--------------------------------------------------------------------------------
section("status")
--------------------------------------------------------------------------------

local n2 = #CHAT
Slash("status")
local joined = ""
for _, l in ipairs(ChatSince(n2)) do joined = joined .. Strip(l) .. "\n" end
ok(joined:find("co%-tank panel:") ~= nil, "status carries the module's line")
ok(joined:find("tank spec:") ~= nil, "and still carries the threat module's")

--------------------------------------------------------------------------------
section("solo inside an instance")
--
-- The panel exists for the tank swap, so out of the box it needs two tanks and
-- a five-man never has them. But your own bar goes through the same reads and
-- the same setters a co-tank's does in a raid, and the client restricts by
-- instance rather than by group size -- so any instance you can walk into
-- alone exercises the raid path, which is the whole point of the opt-in.
--------------------------------------------------------------------------------

-- Drop out of the raid and into a five-man where we are the only tank.
WORLD.inRaid, WORLD.groupSize = false, 5
WORLD.raidIndex = nil
WORLD.inInstance, WORLD.instanceType = true, "party"
WORLD.units["player"] = {
    name = "Tankadin", isPlayer = true, class = "WARRIOR",
    hp = 71, hpMax = 100,
    auras = { Aura("icon-a", 4, 30, 12), Aura("icon-b", nil, 10, 3) },
}
for i = 1, 4 do
    WORLD.units["party" .. i] = {
        name = "Friend" .. i, isPlayer = true, assignedRole = "DAMAGER",
    }
end
FireEvent("PLAYER_ENTERING_WORLD")
FireEvent("GROUP_ROSTER_UPDATE")

eq(NS.state.instanceType, "party", "Core cached the instance type")
eq(#NS.tankUnits, 1, "we are the only tank in the dungeon")

-- Pinned, because it is a default that was deliberately flipped: being the
-- only tank in a delve or a five-man is the ordinary case, and a panel hidden
-- through all of it until you find a checkbox reads as a broken panel.
eq(NS.GetModule("tankwatch").defaults.twSoloDungeon, true,
   "showing solo inside an instance is on out of the box")

db.twEnabled, db.twMinTanks, db.twSoloDungeon = true, 2, false
Tick(0.25)
ok(not panel:IsShown(), "turned off, one tank is below the minimum again")

db.twSoloDungeon = true
Tick(0.25)
ok(panel:IsShown(), "opted in, the panel shows with just us")

local b = blocks[1]
eq(IconsShown(b), 2, "and draws our own debuffs")

-- The point of the setting is that the dungeon exercises the raid path, so the
-- health read has to be the real one and not a preview placeholder.
eq(NS.GetTankWatchPreview(), false, "shown for real, not via preview")
if not SECRETS then
    eq(b.pct:GetText(), "71%", "our own health percent renders")
end

Slash("twsolo")
eq(db.twSoloDungeon, false, "/tt twsolo toggles it off")
Tick(0.25)
ok(not panel:IsShown(), "and the panel goes away again")
Slash("twsolo")
eq(db.twSoloDungeon, true, "/tt twsolo toggles it back on")
Tick(0.25)

-- Only in a five-man. Out in the world the same lone tank must not put a panel
-- on screen, or the opt-in becomes "always show it".
WORLD.inInstance, WORLD.instanceType = false, "none"
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
eq(NS.state.instanceType, "none", "instance type follows us out")
ok(not panel:IsShown(), "not in the open world")

-- Nor in a battleground, where a panel of yourself is only ever in the way.
WORLD.inInstance, WORLD.instanceType = true, "pvp"
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
ok(not panel:IsShown(), "not in a battleground either")

-- A delve, which is the case the opt-in was widened for: instanced, entered
-- alone, and reported by the client as a scenario. If this stops showing, the
-- only place left to prove the debuff path is a raid night.
WORLD.inInstance, WORLD.instanceType = true, "scenario"
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
eq(NS.state.instanceType, "scenario", "a delve reports as a scenario")
ok(panel:IsShown(), "the panel shows solo in a delve")
eq(IconsShown(blocks[1]), 2, "and draws our own debuffs there")

-- And in a raid instance walked into alone, for the same reason: it is the
-- content the panel is ultimately for, and one tank in it is still worth a bar.
WORLD.inInstance, WORLD.instanceType = true, "raid"
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
ok(panel:IsShown(), "and solo inside a raid instance")

-- An instance type the client invents later must read as "not a dungeon"
-- rather than crash a comparison or slip through.
WORLD.inInstance, WORLD.instanceType = true, "somethingnew"
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
eq(NS.state.instanceType, "none", "an unknown instance type falls back")
ok(not panel:IsShown(), "and does not turn the panel on")

-- ...but what the client actually said is kept, because that fallback is the
-- one failure of the solo gate that looks exactly like nothing being wrong.
-- /tt cotanks prints it, so a content type we have not listed is one line away
-- from being diagnosed instead of a mystery.
eq(NS.state.instanceTypeRaw, "somethingnew", "the raw type is remembered")
local nRaw = #CHAT
Slash("cotanks")
local rawDump = ""
for _, l in ipairs(ChatSince(nRaw)) do rawDump = rawDump .. Strip(l) .. " " end
ok(rawDump:find("somethingnew") ~= nil, "and the dump says so")

-- Back to the raid the rest of the suite was built on.
db.twSoloDungeon = false
WORLD.inInstance, WORLD.instanceType = false, "none"
BuildRaid()
FireEvent("PLAYER_ENTERING_WORLD")
FireEvent("GROUP_ROSTER_UPDATE")
Tick(0.25)
eq(#NS.tankUnits, 3, "the raid roster is back")

--------------------------------------------------------------------------------
section("ticker isolation")
--------------------------------------------------------------------------------

-- The co-tank panel failing must not take the nameplate scan with it.
local t = NS.GetTicker("tankwatch")
ok(t ~= nil, "tankwatch has its own ticker")
local real = t.fn
t.fn = function() error("simulated restriction") end
Tick(0.25); Tick(0.25); Tick(0.25)
eq(t.disabled, true, "three failures stop the co-tank panel")
eq(NS.GetTicker("threat").disabled, false, "the threat scan is untouched")
t.fn = real
FireEvent("PLAYER_ENTERING_WORLD")
eq(t.disabled, false, "a zone change clears it")

--------------------------------------------------------------------------------
section("the filter ladder")
--
-- A candidate filter that matches nothing is indistinguishable from a tank
-- with no debuffs: the engine applies it and never says what it dropped. That
-- is the one failure the panel cannot show you, so /tt twfilter takes the
-- filters away a rung at a time until the icons come back.
--------------------------------------------------------------------------------

Tick(0.25)
local frow = blocks[1].auras
eq(frow:Report().filter, "normal", "the row filters normally out of the box")

Slash("twfilter")
Tick(0.25)
eq(frow:Report().filter, "loose", "one step drops the who-applied-it filter")

Slash("twfilter")
Tick(0.25)
eq(frow:Report().filter, "none", "the next drops everything")

Slash("twfilter")
Tick(0.25)
eq(frow:Report().filter, "normal", "and it wraps back round")

-- Hidden from the help: it is an instrument, and listing it would put a
-- debugging switch in front of everyone who typed /tt.
local nf = #CHAT
Slash("")
local fhelp = ""
for _, l in ipairs(ChatSince(nf)) do fhelp = fhelp .. Strip(l) .. " " end
ok(fhelp:find("twfilter") == nil, "but it is not in the help")

if ENGINE then
    -- Buttons built with none of them showing is the signature of a filter
    -- that matched nothing, and it is the number the dump leads with.
    local frow2 = blocks[2].auras
    local funit = frow2.unit
    WORLD.units[funit].auras = {
        Aura("boss-debuff", 3, 30, 20, true),
        Aura("some-proc",  nil, 10,  8, false),
    }
    FireEvent("UNIT_AURA", funit)
    Tick(0.25)

    eq(#EngineButtons(frow2), 2, "the engine draws both")

    -- ...and the row cannot say so. Every getter on an engine button is
    -- secret in here, so "how many are showing" has three answers and the
    -- honest one is "the client will not say". Reporting those as hidden
    -- would print "showing none" in the one place the engine is working
    -- perfectly, which is worse than admitting the gap.
    local r = frow2:Report()
    eq(r.built, #frow2.buttons, "the report counts the buttons it was handed")
    eq(r.visible, 0, "and claims none as readable-shown")
    eq(r.visSecret, r.built, "because every one of them is unreadable")

    -- Turning a filter on still changes what the engine draws, which the
    -- suite can see even though the addon cannot.
    NS.GetModule("tankwatch").db.twBossAuras = true
    NS.TankWatchLooksChanged()
    Tick(0.25)
    eq(#EngineButtons(frow2), 1, "the boss filter drops the proc")
    ok(frow2:Report().built >= r.built, "while the buttons it built stay built")

    NS.GetModule("tankwatch").db.twBossAuras = false
    NS.TankWatchLooksChanged()
    Tick(0.25)
end

--------------------------------------------------------------------------------
section("the zone the client has not admitted to yet")
--
-- The reported bug, and it is a caching one. At the first PLAYER_ENTERING_WORLD
-- after a transition the client will still describe the zone you just left.
-- The instance type was read once on that event and never again, so the panel
-- spent the whole delve believing it was outdoors -- and the whole trip home
-- believing it was still in the delve. /reload fixed both, which is what said
-- the reads were fine and the cached answer was old.
--------------------------------------------------------------------------------

WORLD.inRaid, WORLD.groupSize = false, 0
WORLD.raidIndex = nil
WORLD.specRole = "TANK"
WORLD.units["player"] = {
    name = "Tankadin", isPlayer = true, class = "WARRIOR",
    hp = 80, hpMax = 100,
    auras = { Aura("delve-debuff", 2, 20, 15, false) },
}
for i = 1, 4 do WORLD.units["party" .. i] = nil end
WORLD.inInstance, WORLD.instanceType = false, "none"
FireEvent("PLAYER_ENTERING_WORLD")
FireEvent("GROUP_ROSTER_UPDATE")

local zdb = NS.GetModule("tankwatch").db
zdb.twEnabled, zdb.twMinTanks, zdb.twSoloDungeon = true, 2, true
Tick(0.25)
ok(not panel:IsShown(), "outdoors and alone, the panel is away")

-- Enter the delve. The zone change fires while the client still reports the
-- old zone, which is the case the one-shot read could not survive.
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
eq(NS.state.instanceType, "none", "the client is still describing the old zone")
ok(not panel:IsShown(), "so nothing has changed yet, correctly")

-- The client catches up a moment later, and says so to nobody.
WORLD.inInstance, WORLD.instanceType = true, "scenario"
Tick(0.5)
eq(NS.state.instanceType, "scenario", "the cached answer is re-checked")
-- The panel redraws on its own ticker, which may already have run this frame.
Tick(0.25)
ok(panel:IsShown(), "and the panel appears without a reload")
eq(IconsShown(blocks[1]), 1, "drawing our own debuffs, which is the point")

-- Leaving, the same way round: the client keeps saying "delve" for a moment.
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
ok(panel:IsShown(), "still shown while the client still says delve")

WORLD.inInstance, WORLD.instanceType = false, "none"
Tick(0.5)
eq(NS.state.instanceType, "none", "and the change is noticed on its own")
Tick(0.25)
ok(not panel:IsShown(), "so the panel goes away without a reload")

-- The other thing a loading screen is not ready for. Solo there is no roster
-- event coming later to correct a role that read as nil, so an unlucky moment
-- would leave the tank list empty for the whole visit.
WORLD.inInstance, WORLD.instanceType = true, "scenario"
WORLD.specRole = "NONE"
FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
eq(NS.state.isTankRole, false, "the spec read as something other than tank")
ok(not panel:IsShown(), "so there is no tank to draw")

WORLD.specRole = "TANK"      -- the API catches up; nothing announces it
Tick(0.5)
eq(NS.state.isTankRole, true, "the settle window asks again")
Tick(0.25)
ok(panel:IsShown(), "and the panel appears, still without a reload")

-- Back to the raid the rest of the suite was built on.
WORLD.inInstance, WORLD.instanceType = false, "none"
zdb.twSoloDungeon = false
BuildRaid()
FireEvent("PLAYER_ENTERING_WORLD")
FireEvent("GROUP_ROSTER_UPDATE")
Tick(0.25)
eq(#NS.tankUnits, 3, "the raid roster is back")

--------------------------------------------------------------------------------
section("show every debuff")
--
-- The saved counterpart to the filter ladder. "Boss and role debuffs only"
-- empties the row everywhere except a boss encounter -- a delve, a trash pull,
-- anywhere the flags are not set -- and that is not obvious from the label, so
-- there has to be a setting that says "no, show me them" and outranks it.
--------------------------------------------------------------------------------

local arow = blocks[2].auras
local aunit = arow.unit
WORLD.units[aunit].auras = {
    Aura("a-boss-debuff", 4, 30, 20, true),
    Aura("a-trash-debuff", nil, 12, 9, false),
}
FireEvent("UNIT_AURA", aunit)
Tick(0.25)

local adb = NS.GetModule("tankwatch").db
eq(adb.twAllAuras, false, "off out of the box")

adb.twBossAuras = true
NS.TankWatchLooksChanged()
Tick(0.25)
eq(IconsShown(blocks[2]), 1, "the boss filter alone leaves one of the two")

adb.twAllAuras = true
NS.TankWatchLooksChanged()
Tick(0.25)
eq(arow:Report().filter, "loose", "showing everything is the loose rung")
eq(IconsShown(blocks[2]), 2, "and the trash debuff comes back")

-- Overriding rather than being overridden. A setting called "show every
-- debuff" that another checkbox can quietly veto is worse than no setting.
eq(adb.twBossAuras, true, "with the boss filter still switched on underneath")

Slash("twall")
Tick(0.25)
eq(adb.twAllAuras, false, "/tt twall toggles it off")
eq(IconsShown(blocks[2]), 1, "and the boss filter takes over again")
Slash("twall")
Tick(0.25)
eq(IconsShown(blocks[2]), 2, "and back on")

-- The session-only override still wins over the saved setting: someone who
-- has just typed /tt twfilter is asking a question now, and should not have to
-- work out which checkbox is arguing with them.
Slash("twfilter")   -- normal -> loose
Slash("twfilter")   -- loose  -> none
Tick(0.25)
eq(arow:Report().filter, "none", "twfilter outranks the setting while it is set")
Slash("twfilter")   -- none   -> normal
Tick(0.25)
eq(arow:Report().filter, "loose",
   "and hands back to the setting when it returns to normal")

-- A real setting, so unlike the instruments it is in the help.
local nall = #CHAT
Slash("")
local allHelp = ""
for _, l in ipairs(ChatSince(nall)) do allHelp = allHelp .. Strip(l) .. " " end
ok(allHelp:find("/tt twall") ~= nil, "and it is listed, being a setting")

adb.twAllAuras, adb.twBossAuras = false, false
NS.TankWatchLooksChanged()
Tick(0.25)

--------------------------------------------------------------------------------
section("the instruments")
--
-- Two questions the panel cannot answer by looking at itself: what is actually
-- on the unit, and what this client's aura widget offers. Both are commands
-- rather than lines in the main dump, because they are long and only ever
-- wanted once something is already wrong.
--------------------------------------------------------------------------------

local function Said(cmd)
    local n = #CHAT
    Slash(cmd)
    local out = ""
    for _, l in ipairs(ChatSince(n)) do out = out .. Strip(l) .. " " end
    return out
end

local auraDump = Said("twauras")
ok(auraDump:find("harmful auras") ~= nil, "/tt twauras dumps the auras")

if ENGINE then
    -- Enumeration is refused in this scenario, and saying so *is* the answer:
    -- it means nothing but the engine can see these auras, so no field in the
    -- list below could have been checked from here anyway.
    ok(auraDump:find("refused the read") ~= nil,
       "and says plainly when the client will not enumerate")
else
    ok(auraDump:find("fromPlayerOrPet") ~= nil,
       "and names the fields our filters actually look at")
    ok(auraDump:find("kept") ~= nil or auraDump:find("dropped") ~= nil,
       "with a verdict per aura")
end

local apiDump = Said("twapi")
ok(apiDump:find("aura engine") ~= nil, "/tt twapi describes the widget")
if ENGINE then
    ok(apiDump:find("AddAuraGroup") ~= nil, "listing the container methods")
    ok(apiDump:find("AuraButton setters") ~= nil,
       "and the button setters this client offers")
else
    ok(apiDump:find("failed") ~= nil,
       "and says the container could not be created at all")
end

-- Neither is in the help. They are instruments, and listing them would put a
-- wall of debugging in front of everyone who typed /tt.
local ihelp = Said("")
ok(ihelp:find("twauras") == nil, "twauras stays out of the help")
ok(ihelp:find("twapi") == nil, "and so does twapi")

--------------------------------------------------------------------------------
section("the engine probe is retried")
--
-- Latching "no aura engine" for the session was the wrong half of the cache to
-- keep. The fallback refuses to draw while auras are restricted, so a single
-- unlucky probe -- Blizzard_AuraContainer not loaded yet, a CreateFrame that
-- failed once -- left every row blank in exactly the content the panel exists
-- for, with nothing on screen saying why.
--------------------------------------------------------------------------------

if not ENGINE then
    eq(NS.HaveAuraEngine(), false, "the client had no engine when first asked")
    ok(not blocks[1].auras:IsEngine(), "so the row was drawing for itself")

    -- The engine turns up late. Nothing else changes.
    WORLD.auraEngine = true
    Tick(6)                       -- past PROBE_RETRY
    eq(NS.HaveAuraEngine(), true, "asking again finds it")

    NS.TankWatchLooksChanged()
    Tick(0.25)
    ok(blocks[1].auras:IsEngine(), "and the row moves onto it without a reload")
end

WORLD.secretMode = false
report()
