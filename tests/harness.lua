-- Minimal WoW API stub, enough to load Tank Tools and drive it.

local ADDON_DIR = ...

-- Global copy, so suites can resolve the paths the .toc lists.
ADDON_PATH = ADDON_DIR

--------------------------------------------------------------------------------
-- Frame mock
--------------------------------------------------------------------------------

local allFrames  = {}
local allRegions = {}

-- Declared up here rather than beside WORLD because the aura widgets below
-- hand it back from their own getters, and an upvalue has to exist before the
-- function that closes over it.
local SECRET = setmetatable({}, { __tostring = function() return "secret" end })

local function NewRegion(kind, parent)
    local r = {
        _type = kind, _text = "", _shown = true, _alpha = 1,
        _points = {}, _scripts = {},
    }
    local mt = {}
    mt.__index = function(t, k)
        -- Data fields (our own, underscore-prefixed) stay nil; anything else
        -- is assumed to be a frame method we did not bother to model.
        if type(k) ~= "string" or k:sub(1, 1) == "_" then return nil end
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end
    setmetatable(r, mt)
    r._parent = parent
    allRegions[#allRegions + 1] = r

    function r:GetObjectType() return self._type end
    function r:SetText(v) self._text = v end
    function r:GetText() return self._text end
    function r:GetStringWidth() return #tostring(self._text) * 6 end
    function r:GetStringHeight()
        local lines = 1
        for _ in string.gmatch(tostring(self._text), "\n") do lines = lines + 1 end
        return lines * 12
    end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:SetShown(v) self._shown = v and true or false end
    function r:IsShown() return self._shown end
    function r:IsVisible() return self._shown end
    function r:SetAlpha(v) self._alpha = v end
    function r:GetAlpha() return self._alpha end
    function r:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function r:ClearAllPoints() self._points = {} end
    function r:SetAllPoints() end
    function r:SetHeight(v) self._height = v end
    function r:SetWidth(v) self._width = v end
    function r:SetSize(w, hh) self._width, self._height = w, hh end
    function r:GetHeight() return self._height or 0 end
    function r:GetWidth() return self._width or 0 end
    function r:GetFrameLevel() return self._level or 1 end
    function r:SetFrameLevel(v) self._level = v end
    function r:GetParent() return self._parent end
    function r:HasFocus() return false end
    function r:GetChecked() return self._checked and true or false end
    function r:SetChecked(v) self._checked = v and true or false end
    function r:GetFontString() return self._fontstring end
    function r:GetThumbTexture()
        self._thumb = self._thumb or NewRegion("Texture")
        return self._thumb
    end
    function r:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
    function r:GetValue() return self._value or 0 end
    function r:SetValue(v)
        self._value = v
        local fn = self._scripts.OnValueChanged
        if fn then fn(self, v) end
    end
    function r:SetMinMaxValues(lo, hi) self._min, self._max = lo, hi end
    function r:GetMinMaxValues() return self._min or 0, self._max or 0 end
    function r:SetStatusBarColor(cr, cg, cb) self._barColor = { cr, cg, cb } end
    function r:SetTexture(t) self._texture = t end
    function r:GetTexture() return self._texture end
    function r:SetColorTexture(cr, cg, cb, ca) self._color = { cr, cg, cb, ca } end
    function r:SetCooldown(start, dur) self._cd = { start, dur } end
    function r:Clear() self._cd = nil end

    function r:SetScript(k, fn) self._scripts[k] = fn end
    function r:GetScript(k) return self._scripts[k] end
    function r:HookScript(k, fn) self._scripts[k] = fn end

    function r:CreateFontString()
        local fs = NewRegion("FontString", self)
        self._fontstring = self._fontstring or fs
        return fs
    end
    function r:CreateTexture() return NewRegion("Texture", self) end

    function r:CreateAnimationGroup()
        local ag = NewRegion("AnimationGroup")
        ag._playing = false
        function ag:CreateAnimation() return NewRegion("Animation") end
        function ag:SetLooping() end
        function ag:Play() self._playing = true end
        function ag:Stop() self._playing = false end
        function ag:IsPlaying() return self._playing end
        return ag
    end

    function r:RegisterEvent(e)
        self._events = self._events or {}
        self._events[e] = true
    end
    function r:UnregisterEvent(e)
        if self._events then self._events[e] = nil end
    end
    function r:RegisterUnitEvent(e) self:RegisterEvent(e) end

    return r
end

--------------------------------------------------------------------------------
-- The aura engine
--
-- Modelled rather than stubbed, because the behaviour under test is precisely
-- that the engine keeps drawing while the addon itself is forbidden to read
-- auras. A no-op mock would let a broken row pass.
--
-- The container reads WORLD directly and ignores WORLD.aurasSecret: that is
-- what "the client draws it, the addon does not read it" means.
--------------------------------------------------------------------------------

-- A widget the client owns answers its own getters with secrets while auras
-- are secret -- IsShown, GetWidth and GetHeight included. That is not a detail:
-- `if button:IsShown() then` throws, and an addon that reads its own frames the
-- same way it reads the client's will error inside the very diagnostic written
-- to explain why nothing is on screen. Modelled here so the suite fails the
-- way the client does.
local function Restrict(r)
    local isShown, getW, getH = r.IsShown, r.GetWidth, r.GetHeight
    -- The suite needs ground truth about what is on screen, which the addon
    -- itself is not allowed to have. Kept off the widget's public surface so a
    -- test cannot accidentally assert through a door the addon lacks.
    r._RawShown = isShown
    r._RawWidth = getW
    r._RawHeight = getH
    function r:IsShown()
        if WORLD.aurasSecret then return SECRET end
        return isShown(self)
    end
    function r:GetWidth()
        if WORLD.aurasSecret then return SECRET end
        return getW(self)
    end
    function r:GetHeight()
        if WORLD.aurasSecret then return SECRET end
        return getH(self)
    end
    return r
end

local function NewAuraContainer(parent)
    local c = Restrict(NewRegion("AuraContainer", parent))
    c._groups, c._order = {}, {}

    function c:AddAuraGroup(key, filter, opts)
        assert(type(filter) == "string", "aura filter must be a string")
        assert(self._unit == nil, "groups must be declared before the unit")
        self._groups[key] = { filter = filter, opts = opts, max = opts.maxFrameCount,
                              filters = opts.candidateFilters, buttons = {} }
        self._order[#self._order + 1] = key
    end
    function c:HasAuraGroup(key) return self._groups[key] ~= nil end
    function c:SetAuraGroupMaxFrameCount(key, n)
        if self._groups[key] then self._groups[key].max = n end
    end
    function c:SetAuraGroupCandidateFilters(key, f)
        if self._groups[key] then self._groups[key].filters = f end
    end
    function c:SetAuraGroupLayout() end
    function c:SetAuraGroupSortMethod() end
    function c:SetFlowLayoutAxis() end
    function c:SetFlowLayoutAnchorPoint() end
    function c:SetFlowLayoutGrowthDirection() end
    function c:SetFlowLayoutMaximumLineSize() end
    function c:SetEnabled(v) self._enabled = v and true or false end

    function c:SetUnit(u)
        self._unit = u
        self:UpdateAllAuras()
    end

    -- Buttons are created lazily through the caller's initializeFrame, which
    -- is the only window the real engine gives an addon to decorate one.
    local function Button(group, i)
        local b = group.buttons[i]
        if b then return b end
        b = Restrict(NewRegion("AuraButton"))
        function b:SetIcon(t) self._icon = t end
        function b:SetDurationCooldown(cd) self._cd = cd end
        function b:SetApplicationCount(fs) self._count = fs end
        function b:ClearApplicationCount() self._count = nil end
        function b:SetMouseClickEnabled(v) self._click = v end
        function b:SetMouseMotionEnabled(v) self._motion = v end
        b:Hide()
        group.buttons[i] = b
        if group.opts.initializeFrame then group.opts.initializeFrame(b) end
        return b
    end

    function c:UpdateAllAuras()
        local d = WORLD.units[self._unit]
        for _, key in ipairs(self._order) do
            local g = self._groups[key]
            local n = 0
            if d and d.auras and self._enabled ~= false then
                local f = g.filters or {}
                for i = 1, #d.auras do
                    local a = d.auras[i]
                    local drop = f.excludeSpellIDs and a.spellId
                                 and f.excludeSpellIDs[a.spellId]
                    if f.isBossOrRoleAura and not a.boss then drop = true end
                    if not drop and n < (g.max or 0) then
                        n = n + 1
                        local b = Button(g, n)
                        if b._icon then b._icon:SetTexture(a.icon) end
                        if b._count then
                            b._count:SetText(a.applications or "")
                        end
                        if b._cd and a.duration then
                            b._cd:SetCooldown(a.expirationTime - a.duration, a.duration)
                        end
                        b:Show()
                    end
                end
            end
            for i = n + 1, #g.buttons do g.buttons[i]:Hide() end
        end
    end

    return c
end

function CreateFrame(kind, name, parent, template)
    -- Only a client with the engine answers this, which is what lets the
    -- suite run the addon's fallback path and its engine path against the
    -- same assertions.
    if kind == "AuraContainer" then
        if not WORLD.auraEngine then
            error("CreateFrame: unknown frame type AuraContainer", 2)
        end
        local c = NewAuraContainer(parent)
        allFrames[#allFrames + 1] = c
        return c
    end

    local f = NewRegion(kind or "Frame")
    f._parent = parent
    f._name = name
    f._template = template
    f._shown = false
    allFrames[#allFrames + 1] = f
    if name then _G[name] = f end
    return f
end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

_G = _G or getfenv(0)

CHAT = {}
DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg) CHAT[#CHAT + 1] = msg end,
}

GameFontNormal = NewRegion("Font")

UIParent = CreateFrame("Frame", "UIParent")
UISpecialFrames = {}
SlashCmdList = {}

format   = string.format
strlower = string.lower
strupper = string.upper
tinsert  = table.insert

function strtrim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

function strsplit(sep, str, limit)
    local out, i = {}, 1
    while true do
        if limit and #out == limit - 1 then
            out[#out + 1] = string.sub(str, i)
            break
        end
        local a, b = string.find(str, sep, i, true)
        if not a then
            out[#out + 1] = string.sub(str, i)
            break
        end
        out[#out + 1] = string.sub(str, i, a - 1)
        i = b + 1
    end
    return unpack(out)
end

function wipe(t) for k in pairs(t) do t[k] = nil end return t end

SOUNDKIT = { RAID_WARNING = 1 }
SOUNDS_PLAYED = 0
function PlaySound() SOUNDS_PLAYED = SOUNDS_PLAYED + 1 end

-- GameTooltip, enough of it to see what a hover asked for.
GameTooltip = {
    _owner = nil, _shown = false, _content = nil,
    SetOwner = function(self, frame) self._owner = frame; self._content = nil end,
    IsOwned  = function(self, frame) return self._owner == frame end,
    Show     = function(self) self._shown = true end,
    Hide     = function(self) self._shown = false; self._owner = nil end,
    IsShown  = function(self) return self._shown end,
    SetUnitDebuffByAuraInstanceID = function(self, unit, id)
        if id == nil then error("no aura instance id") end
        self._content = { how = "instance", unit = unit, id = id }
    end,
    SetUnitDebuff = function(self, unit, index, filter)
        self._content = { how = "index", unit = unit, index = index, filter = filter }
    end,
}

function HideUIPanel() end

RELOADS = 0
function ReloadUI() RELOADS = RELOADS + 1 end
SettingsPanel = nil
Settings = {
    RegisterCanvasLayoutCategory = function() return {} end,
    RegisterAddOnCategory = function() end,
}

--------------------------------------------------------------------------------
-- Unit world -- driven by the WORLD table below
--------------------------------------------------------------------------------

WORLD = {
    inInstance   = false,
    instanceType = "none",  -- none | party | raid | pvp | arena | scenario
    inRaid       = false,
    groupSize    = 0,
    spec         = 1,
    specRole     = "TANK",
    playerCombat = false,
    secretMode   = false,   -- when true, identity reads come back secret
    -- Auras are restricted differently from everything else: the client does
    -- not hand back a secret, it refuses the enumeration. Modelled as a throw,
    -- which is what it is -- and what latched the ticker off in the field.
    aurasSecret  = false,
    auraEngine   = false,   -- whether CreateFrame("AuraContainer") answers
    raidIndex    = 0,       -- our own 0-based raid slot; nil = client will not say
    raidIndexSecret = false,
    units        = {},      -- token -> { exists, isPlayer, dead, combat, threat = {by unit} }
}

function issecretvalue(v) return v == SECRET end

local function U(token) return WORLD.units[token] end

function UnitExists(u) return U(u) ~= nil end
function UnitName(u)
    if not U(u) then return nil end
    if WORLD.secretMode then return SECRET end
    return U(u).name or u
end
function UnitIsPlayer(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.isPlayer and true or false
end
function UnitIsDead(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.dead and true or false
end
function UnitCanAttack(_, u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.attackable ~= false
end
function UnitAffectingCombat(u)
    if u == "player" then return WORLD.playerCombat end
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.combat and true or false
end
function UnitThreatSituation(who, mob)
    local d = U(mob); if not d or not d.threat then return nil end
    return d.threat[who]
end
function UnitIsUnit(a, b)
    if WORLD.secretMode then return SECRET end
    return a == b
end
function UnitPlayerOrPetInParty() return false end
function UnitPlayerOrPetInRaid() return false end
-- The role someone queued as. Per unit, because the addon's whole reason for
-- preferring the roster's combat role is that these two can disagree.
function UnitGroupRolesAssigned(u)
    if u == "player" then return WORLD.specRoleAssigned or WORLD.specRole end
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.assignedRole or d.combatRole or "NONE"
end
function UnitInRaid()
    if not WORLD.inRaid then return nil end
    if WORLD.raidIndexSecret then return SECRET end
    return WORLD.raidIndex          -- may be nil: the client declining to say
end
function IsInInstance() return WORLD.inInstance, WORLD.instanceType end
function IsInRaid() return WORLD.inRaid end
function GetNumGroupMembers() return WORLD.groupSize end

function UnitHealth(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.hp or 100
end
function UnitHealthMax(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.hpMax or 100
end
function UnitGetTotalAbsorbs(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.absorb or 0
end
function UnitIsDeadOrGhost(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.dead and true or false
end
function UnitIsConnected(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.offline ~= true
end
function UnitClassBase(u)
    local d = U(u); if not d then return nil end
    if WORLD.secretMode then return SECRET end
    return d.class or "WARRIOR"
end

RAID_CLASS_COLORS = {
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
    DRUID   = { r = 1.00, g = 0.49, b = 0.04 },
}

-- Auras. WORLD.units[token].auras is an array of
--   { icon =, applications =, duration =, expirationTime =, boss = }
-- `boss` is both the aura engine's isBossOrRoleAura candidate filter and the
-- data table's isBossAura flag: one world fact, read through whichever door
-- the path under test is allowed to use.
C_Secrets = {
    ShouldAurasBeSecret = function() return WORLD.aurasSecret end,
    ShouldUnitIdentityBeSecret = function() return WORLD.secretMode end,
}

C_UnitAuras = {
    GetAuraDataByIndex = function(u, i, filter)
        -- Not a nil return. The call itself is denied, and an addon that does
        -- not expect that takes the error.
        if WORLD.aurasSecret then
            error("Attempt to access aura data while auras are secret", 2)
        end
        local d = U(u)
        if not d or filter ~= "HARMFUL" or not d.auras then return nil end
        local a = d.auras[i]
        if not a then return nil end
        -- Return a fresh table each call, the way the real API does.
        local out = {
            icon           = a.icon,
            applications   = a.applications,
            duration       = a.duration,
            expirationTime = a.expirationTime,
            spellId        = a.spellId,
            -- Left readable under secretMode: it is only ever handed to a
            -- tooltip setter, which takes a secret as happily as a number.
            auraInstanceID = a.auraInstanceID,
            isBossAura     = a.boss,
            -- Both are documented as always present on AuraData, and
            -- isFromPlayerOrPlayerPet is explicitly never secret. The row
            -- filters on it, so a stub that left it off would have the addon
            -- reading nil where the client always answers a boolean.
            isTankRoleAura = a.tankRole and true or false,
            isFromPlayerOrPlayerPet = a.fromPlayer and true or false,
        }
        if WORLD.secretMode then
            -- Identity-ish fields go secret; the icon stays usable because a
            -- texture id is not identifying.
            out.applications   = a.applications ~= nil and SECRET or nil
            out.duration       = a.duration ~= nil and SECRET or nil
            out.expirationTime = a.expirationTime ~= nil and SECRET or nil
        end
        return out
    end,
}

AuraUtil = {
    ForEachAura = function(u, filter, maxCount, fn)
        if WORLD.aurasSecret then
            error("Attempt to access aura data while auras are secret", 2)
        end
        local d = U(u)
        if not d or filter ~= "HARMFUL" or not d.auras then return end
        for i = 1, math.min(#d.auras, maxCount or 40) do
            if fn(d.auras[i]) then return end
        end
    end,
}

-- name, rank, subgroup, level, class, fileName, zone, online, isDead, role,
-- isML, combatRole
function GetRaidRosterInfo(i)
    local d = U("raid" .. i)
    if not d then return nil end
    return d.name, 0, 1, 80, "Warrior", d.class or "WARRIOR", "Zone", true,
           d.dead and true or false, nil, false, d.combatRole
end

C_SpecializationInfo = {
    GetSpecialization     = function() return WORLD.spec end,
    GetSpecializationRole = function() return WORLD.specRole end,
}

NAMEPLATES = {}   -- unit token -> plate frame
C_NamePlate = {
    GetNamePlateForUnit = function(u) return NAMEPLATES[u] end,
}

TIME = 1000
function GetTime() return TIME end

--------------------------------------------------------------------------------
-- Driving
--------------------------------------------------------------------------------

function FireEvent(event, ...)
    for i = 1, #allFrames do
        local f = allFrames[i]
        if f._events and f._events[event] then
            local fn = f._scripts.OnEvent
            if fn then fn(f, event, ...) end
        end
    end
end

function Tick(seconds)
    for i = 1, #allFrames do
        local f = allFrames[i]
        local fn = f._scripts.OnUpdate
        if fn then fn(f, seconds) end
    end
    TIME = TIME + seconds
end

function Slash(cmd)
    SlashCmdList.TANKTOOLS(cmd)
end

function ChatSince(n)
    local out = {}
    for i = n + 1, #CHAT do out[#out + 1] = CHAT[i] end
    return out
end

-- Colour codes out, and the chat prefix ns.Print adds in front of every line.
-- Frames whose direct parent is `p`, in creation order.
function FramesParentedTo(p)
    local out = {}
    for i = 1, #allFrames do
        if allFrames[i]._parent == p then out[#out + 1] = allFrames[i] end
    end
    return out
end

local function RegionsIn(p, kind)
    local out = {}
    for i = 1, #allRegions do
        local r = allRegions[i]
        if r._parent == p and r._type == kind then out[#out + 1] = r end
    end
    return out
end

function TexturesIn(p) return RegionsIn(p, "Texture") end

-- Every font string anywhere under `p`, so a test can ask what the panel says
-- without knowing which frame each string hangs off.
function TextsIn(p)
    local subtree, out = { [p] = true }, {}
    local added = true
    while added do
        added = false
        for i = 1, #allFrames do
            local f = allFrames[i]
            if not subtree[f] and f._parent and subtree[f._parent] then
                subtree[f] = true
                added = true
            end
        end
    end
    for i = 1, #allRegions do
        local r = allRegions[i]
        if r._type == "FontString" and r._parent and subtree[r._parent] then
            out[#out + 1] = r._text
        end
    end
    return out
end

function FindText(list, want)
    for i = 1, #list do if list[i] == want then return true end end
    return false
end

function IsSecretValue(v) return issecretvalue(v) end

-- Total failures across every ticker the addon registered.
function FAILED_TICKS()
    local n = 0
    for _, name in ipairs({ "threat", "tankwatch" }) do
        local t = NS.GetTicker(name)
        if t then n = n + (t.failures or 0) end
    end
    return n
end

function FileExists(path)
    local f = io.open(path)
    if f then f:close() return true end
    return false
end

function Strip(s)
    s = tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("^Tank Tools: ", "")
    return s
end

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------

PASSED, FAILED = 0, 0

function ok(cond, label)
    if cond then
        PASSED = PASSED + 1
    else
        FAILED = FAILED + 1
        print("  FAIL: " .. label)
    end
end

function eq(a, b, label)
    if a == b then
        PASSED = PASSED + 1
    else
        FAILED = FAILED + 1
        print(string.format("  FAIL: %s  (got %s, want %s)",
                            label, tostring(a), tostring(b)))
    end
end

function section(s) print("\n== " .. s .. " ==") end

function report()
    print(string.format("\n%d passed, %d failed", PASSED, FAILED))
end

--------------------------------------------------------------------------------
-- Load the addon exactly as the .toc does
--------------------------------------------------------------------------------

FILES = {}
local toc = assert(io.open(ADDON_DIR .. "/TankTools.toc"))
for line in toc:lines() do
    line = strtrim(line)
    if line ~= "" and not line:match("^#") and line:match("%.lua$") then
        FILES[#FILES + 1] = (line:gsub("\\", "/"))
    end
end
toc:close()

local ns = {}
for i = 1, #FILES do
    local path = ADDON_DIR .. "/" .. FILES[i]
    local chunk = assert(loadfile(path))
    chunk("TankTools", ns)
end

NS = ns
