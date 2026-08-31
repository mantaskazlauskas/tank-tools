--------------------------------------------------------------------------------
-- Tank Tools -- namespace and module registry
--
-- Loaded first. Everything else in the addon hangs off `ns`, and this file is
-- the only place that decides what that word means.
--
-- The addon is a set of independent modules -- a threat scan, a nameplate
-- marker, and whatever comes next -- that share four things and nothing else:
-- a saved-variables table, a ticker, an event dispatcher, and a settings
-- window. A module declares what it wants from each and never touches another
-- module's internals. The point is that a broken or removed module costs you
-- that module and nothing more.
--
-- Registration is declarative and happens at load time; nothing is *run* until
-- ADDON_LOADED has resolved the database, which is what stops a module from
-- reading settings that do not exist yet.
--------------------------------------------------------------------------------

local ADDON, ns = ...

ns.ADDON = ADDON

--------------------------------------------------------------------------------
-- Printing
--------------------------------------------------------------------------------

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Tank Tools|r: " .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Module registry
--------------------------------------------------------------------------------

local modules     = {}   -- in registration order, which is .toc order
local moduleByName = {}

ns.modules = modules

-- A module is a plain table. The fields the framework understands:
--
--   name       identifier, and the key its settings live under in the DB
--   defaults   settings table, merged into the DB on load (see Core/DB.lua)
--   OnInit     called once, after `self.db` exists and before any event fires
--   OnEnable   called at PLAYER_LOGIN, after every module has initialised
--
-- Everything else a module needs -- events, a ticker slot, slash commands, a
-- settings page -- it asks for by calling the matching Register* function,
-- because those registries are owned by the files that implement them and a
-- module may want several of each.
--
-- Returns the module table so the calling file can keep it as a local.
function ns.NewModule(name, def)
    assert(not moduleByName[name], "duplicate module: " .. tostring(name))
    def = def or {}
    def.name = name
    modules[#modules + 1] = def
    moduleByName[name] = def
    return def
end

function ns.GetModule(name)
    return moduleByName[name]
end

--------------------------------------------------------------------------------
-- Shared state
--
-- The world facts more than one module needs. A table rather than accessor
-- functions on purpose: the threat scan reads `inInstance` once per nameplate
-- per tick, and a field read is the cheapest thing that can be written there.
--
-- Core/State.lua owns the writes. Everyone else reads.
--------------------------------------------------------------------------------

ns.state = {
    inCombat     = false,
    inInstance   = false,
    -- "none" | "party" | "raid" | "pvp" | "arena" | "scenario", as the client
    -- reports it. Kept separately from `inInstance` because "am I somewhere
    -- the client restricts unit reads" and "am I in a five-man" are different
    -- questions, and only the second one can answer "show the panel here".
    instanceType = "none",
    isTankRole   = false,
}

--------------------------------------------------------------------------------
-- Cross-module stubs
--
-- Replaced by the file that implements each. Stubbed here so a caller can
-- invoke them unconditionally, and so removing a module's file leaves the rest
-- of the addon running rather than erroring on a nil call.
--------------------------------------------------------------------------------

-- Core/Features.lua. Ungated is the safe answer: without the flag registry,
-- every module and every command is simply visible.
function ns.FeatureEnabled(_) return true end
function ns.FeatureAllows(_) return true end

-- UI/Features.lua
function ns.ShowFeatures() end
function ns.ToggleFeatures() end

-- UI/Debuffs.lua
function ns.ShowDebuffs() end
function ns.ToggleDebuffs() end
function ns.RefreshDebuffs() end

-- Modules/Debuffs.lua. An empty journal is the safe answer: the window can be
-- built and read with the module's file removed, and shows nothing rather than
-- erroring on the first row.
function ns.DebuffRecords() return {} end
function ns.DebuffDescription(_) return nil end
function ns.ForgetDebuffs() return 0 end
function ns.DebuffStats()
    return { total = 0, cap = 0, recording = false, fromLog = false,
             restricted = false, logOpen = false, sawAura = false,
             sawLog = false }
end

-- UI/Options.lua
function ns.ToggleOptions() end
function ns.ShowOptions() end
function ns.RefreshOptions() end

-- Modules/Nameplates.lua
function ns.RefreshMarkers() end
function ns.MarkersLooksChanged() end
function ns.SetMarkerPreview(_) return false end
function ns.GetMarkerPreview() return false end

-- Modules/Threat.lua
function ns.ForgetUnit(_) end
