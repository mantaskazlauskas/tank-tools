--------------------------------------------------------------------------------
-- Tank Tools -- feature flags
--
-- A door for work that is not finished yet.
--
-- The addon ships as one folder, so a half-built module still loads, still
-- registers its commands, and still puts a tab in the settings window. That is
-- fine while it lives on a branch and wrong the moment it is tagged: someone
-- finds the feature, it misbehaves, and the bug report is about a thing that
-- was never claimed to work.
--
-- A flagged module is invisible instead. Its OnInit never runs, so it
-- registers no ticker and no events; its commands do not appear in the help
-- and do not dispatch; its settings page is dropped, and its status lines are
-- not printed. What is left is the file sitting in the .toc, loaded and inert
-- -- which is exactly what you want while you are still working on it, because
-- it means the code is still compiled and its tests still run.
--
-- The flags are per character, live in the database like any other setting,
-- and are edited through /tt features. That command is deliberately absent
-- from the help: this is a door for the author, not a beta programme.
--
-- Turning one on takes effect on the next UI load, and the window says so.
-- Enabling could be made live by calling OnInit here, but disabling could not
-- -- a ticker cannot be unregistered, an event handler cannot be taken back --
-- and a switch that works in one direction only is worse than one that is
-- honest about needing a reload.
--------------------------------------------------------------------------------

local _, ns = ...

-- Flags are settings, so they live where every other setting does. The module
-- has no behaviour of its own beyond remembering the state at login.
local M = ns.NewModule("features", { defaults = {} })

local list   = {}   -- in registration order, which is .toc order
local byName = {}
local boot   = {}   -- what each flag was when the UI last loaded

ns.features = list

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

-- def fields:
--   name      identifier, and the key the flag is stored under
--   title     as it appears in the window
--   desc      one or more lines saying what state the feature is in
--   default   whether it is on for someone who has never touched it
--
-- Called at file scope by the module it gates, so the flag exists before
-- ADDON_LOADED resolves the database and can be given a default like any other
-- setting.
function ns.RegisterFeature(def)
    assert(not byName[def.name], "duplicate feature: " .. tostring(def.name))
    def.default = def.default and true or false
    list[#list + 1] = def
    byName[def.name] = def
    M.defaults[def.name] = def.default
    return def
end

function ns.GetFeature(name)
    return byName[name]
end

-- The store the settings window edits. Only valid once the database has
-- resolved, which is the only time the window can be open.
function ns.FeatureStore()
    return M.db
end

--------------------------------------------------------------------------------
-- Querying
--------------------------------------------------------------------------------

-- An unregistered name is enabled. Gating is opt-in: a feature that has been
-- finished has its RegisterFeature call deleted, and every `feature = "..."`
-- field left behind in the modules must keep working until they are tidied up.
-- Failing the other way would make a half-finished cleanup hide a shipped
-- feature, which is the expensive direction of this mistake.
function ns.FeatureEnabled(name)
    local f = byName[name]
    if not f then return true end

    local store = M.db
    if not store or store[name] == nil then return f.default end
    return store[name] and true or false
end

-- Anything carrying an optional `feature` field -- a module, a command, a
-- settings section, a status provider. No field means no gate.
function ns.FeatureAllows(def)
    return def.feature == nil or ns.FeatureEnabled(def.feature)
end

function ns.SetFeatureEnabled(name, on)
    local store = M.db
    if not store or not byName[name] then return end
    store[name] = on and true or false
end

-- Whether the flags have been moved away from what the modules were started
-- with. Drives the reload prompt: toggling back to where you started leaves
-- nothing to apply, and the window should stop asking.
function ns.FeatureNeedsReload()
    for i = 1, #list do
        local name = list[i].name
        if ns.FeatureEnabled(name) ~= boot[name] then return true end
    end
    return false
end

--------------------------------------------------------------------------------

-- Runs in the OnInit pass, before any gated module is asked to start -- the
-- module registry is in .toc order and Core loads first, so this file's module
-- is always ahead of the ones it gates.
function M:OnInit()
    for i = 1, #list do
        boot[list[i].name] = ns.FeatureEnabled(list[i].name)
    end
end
