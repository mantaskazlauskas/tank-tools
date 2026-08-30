--------------------------------------------------------------------------------
-- Tank Tools -- saved variables
--
-- Every module's settings live in their own table, keyed by module name:
--
--   TankToolsDB.modules.nameplates.npSize
--
-- rather than in one flat namespace. The flat version worked while there was
-- one feature and a `np` prefix by convention, but conventions are not
-- enforcement: two modules picking the same key would silently share a
-- setting, and that is the class of bug this whole restructure exists to make
-- impossible. A module can only ever see its own table.
--
-- Defaults are declared by the module, merged here, and never aliased -- a
-- table default is copied, so a saved value cannot write back into the
-- module's `defaults` and corrupt the next character to log in.
--------------------------------------------------------------------------------

local _, ns = ...

local DB_VERSION = 2

--------------------------------------------------------------------------------

local function CopyDefault(v)
    if type(v) ~= "table" then return v end
    local t = {}
    -- Every table default in this addon is an array (a colour triple). Kept
    -- narrow deliberately: a general deep copy would quietly accept a nested
    -- default that the settings UI has no way to edit.
    for i = 1, #v do t[i] = v[i] end
    return t
end

local function ApplyDefaults(store, defaults)
    for k, v in pairs(defaults) do
        if store[k] == nil then store[k] = CopyDefault(v) end
    end
end

-- v1 -> v2. The v1 database was flat, and no key was renamed in the move, so
-- the migration needs no hand-written map: a key belongs to whichever module
-- declares it as a default. That also means it stays correct if a module's
-- settings change before someone with a v1 database logs in again.
local function MigrateFlat(root)
    for i = 1, #ns.modules do
        local m = ns.modules[i]
        if m.defaults then
            local store = root.modules[m.name]
            for k in pairs(m.defaults) do
                if root[k] ~= nil then
                    store[k] = root[k]
                    root[k]  = nil
                end
            end
        end
    end

    -- Anything left at the top level belonged to no module -- a setting from a
    -- feature that no longer exists. Dropped rather than carried forever.
    for k in pairs(root) do
        if k ~= "modules" and k ~= "dbVersion" then root[k] = nil end
    end
end

--------------------------------------------------------------------------------

ns.RegisterEvent("ADDON_LOADED", function(_, addon)
    if addon ~= ns.ADDON then return end

    TankToolsDB = TankToolsDB or {}
    local root  = TankToolsDB

    local fresh = (next(root) == nil)
    root.modules = root.modules or {}

    for i = 1, #ns.modules do
        local m = ns.modules[i]
        root.modules[m.name] = root.modules[m.name] or {}
        m.db = root.modules[m.name]
    end

    -- Order matters: migrate before defaults are applied, or every v1 value
    -- would find its key already filled in and be discarded.
    if not fresh and root.dbVersion == nil then MigrateFlat(root) end
    root.dbVersion = DB_VERSION

    for i = 1, #ns.modules do
        local m = ns.modules[i]
        if m.defaults then ApplyDefaults(m.db, m.defaults) end
    end

    ns.db    = root
    ns.ready = true

    -- Only now, with every module's `db` resolved, is it safe to let modules
    -- run. A module's OnInit may read any *other* module's settings too, which
    -- is why this is a second pass rather than folded into the loop above.
    -- A module behind an unset feature flag is never started: no OnInit means
    -- no ticker, no events, and nothing of it running. Its settings are still
    -- given their defaults above, so turning the flag on does not arrive to an
    -- empty table.
    for i = 1, #ns.modules do
        local m = ns.modules[i]
        if m.OnInit and ns.FeatureAllows(m) then
            local ok, err = pcall(m.OnInit, m)
            if not ok then
                m.failed = true
                ns.Print("|cffff4040module " .. m.name .. " failed to start|r: "
                         .. tostring(err))
            end
        end
    end
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
    for i = 1, #ns.modules do
        local m = ns.modules[i]
        if m.OnEnable and not m.failed and ns.FeatureAllows(m) then
            local ok, err = pcall(m.OnEnable, m)
            if not ok then
                m.failed = true
                ns.Print("|cffff4040module " .. m.name .. " failed to enable|r: "
                         .. tostring(err))
            end
        end
    end
end)
