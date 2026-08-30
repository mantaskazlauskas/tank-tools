--------------------------------------------------------------------------------
-- Tank Tools -- slash commands
--
-- A registry rather than one long if/elseif chain. Each module registers the
-- verbs it owns, next to the code they drive, which means adding a feature
-- cannot accidentally edit an unrelated branch of a shared dispatcher -- and
-- removing a module's file removes its commands with it.
--
-- The help text is generated from the same registrations, so a command that
-- exists is a command that is listed. The old hand-written help block had
-- already drifted from the dispatcher above it once.
--------------------------------------------------------------------------------

local _, ns = ...

local format, strlower = string.format, string.lower
local strrep = string.rep

local commands = {}   -- verb (and alias) -> entry
local entries  = {}   -- one per command, for help
local sections = {}   -- title -> order

--------------------------------------------------------------------------------

-- Declares a help group and where it sits. Sections print in this order, and
-- commands within a section print in their own `order`.
function ns.RegisterCommandSection(title, order)
    sections[title] = order
end

-- def fields:
--   name      the verb, e.g. "npsize"
--   aliases   optional array of extra verbs, not listed in help
--   section   help group title
--   order     position within the group
--   args      optional argument hint, e.g. "<n>"
--   desc      one line, as it appears in help
--   feature   optional flag name; the command does not exist while it is off
--   hidden    optional; dispatches but is not listed in the help
--   handler   function(arg, larg, n)
--               arg   the remainder of the line, trimmed, case preserved
--               larg  the same, lowercased
--               n     the same, as a number, or nil
--
-- `arg` keeps its case so /tt npglyph can take an uppercase glyph; `larg` is
-- there so keyword arguments do not each have to lowercase it themselves.
function ns.RegisterCommand(def)
    entries[#entries + 1] = def
    commands[def.name] = def
    if def.aliases then
        for i = 1, #def.aliases do commands[def.aliases[i]] = def end
    end
end

--------------------------------------------------------------------------------
-- Help
--------------------------------------------------------------------------------

local function Usage(e)
    return "/tt " .. e.name .. (e.args and (" " .. e.args) or "")
end

-- What the help is allowed to mention. A gated command is not listed because
-- it does not work; a hidden one is not listed because it is not for whoever
-- is reading. Both are excluded before the column width is measured, or an
-- absent command would still be widening every line that is present.
local function Listed(e)
    return not e.hidden and ns.FeatureAllows(e)
end

local function PrintHelp()
    -- Column width is measured, not hardcoded: a module adding a longer verb
    -- must not silently break the alignment of every line above it.
    local width = 0
    for i = 1, #entries do
        if Listed(entries[i]) then
            local len = #Usage(entries[i])
            if len > width then width = len end
        end
    end
    width = width + 1

    local order = {}
    for title in pairs(sections) do order[#order + 1] = title end
    table.sort(order, function(a, b) return sections[a] < sections[b] end)

    for i = 1, #order do
        local title = order[i]
        local shown = false

        -- Collected per section rather than sorting `entries` once, so a
        -- module can share an `order` with another module's command without
        -- the two fighting over a global sequence.
        local group = {}
        for j = 1, #entries do
            if entries[j].section == title and Listed(entries[j]) then
                group[#group + 1] = entries[j]
            end
        end
        table.sort(group, function(a, b) return (a.order or 0) < (b.order or 0) end)

        for j = 1, #group do
            local e = group[j]
            if not shown then
                ns.Print(title)
                shown = true
            end
            local usage = Usage(e)
            ns.Print(format("  |cffffff00/tt %s|r%s%s-- %s",
                            e.name,
                            e.args and (" " .. e.args) or "",
                            strrep(" ", width - #usage),
                            e.desc))
        end
    end
end

ns.PrintHelp = PrintHelp

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

SLASH_TANKTOOLS1 = "/tanktools"
SLASH_TANKTOOLS2 = "/tt"

SlashCmdList.TANKTOOLS = function(input)
    if not ns.ready then
        ns.Print("still loading -- try again in a moment.")
        return
    end

    local cmd, arg = strsplit(" ", strtrim(input or ""), 2)
    cmd = strlower(cmd or "")
    arg = arg and strtrim(arg) or nil

    -- A gated command is treated as one that was never registered, rather
    -- than as one that refuses: printing "that feature is off" would announce
    -- the existence of the thing the flag exists to hide.
    local e = commands[cmd]
    if e and ns.FeatureAllows(e) then
        e.handler(arg, arg and strlower(arg) or nil, tonumber(arg))
    else
        PrintHelp()
    end

    -- Slash commands and the settings window edit the same tables, so pull the
    -- window back into sync rather than letting it show stale values.
    ns.RefreshOptions()
end

--------------------------------------------------------------------------------
-- Status
--
-- "Why is nothing happening?" is the question this addon gets asked most, and
-- the answer is almost always one of a handful of legitimate reasons -- wrong
-- spec, nothing in combat, a setting off, a latch tripped. Each module knows
-- its own reasons, so each contributes its own lines here rather than one
-- module trying to describe the state of the others.
--------------------------------------------------------------------------------

local providers = {}

-- `feature`, when given, is the flag the provider's module sits behind: a
-- module that never started has no state to describe, and its provider would
-- be reading a database handle its OnInit never resolved.
function ns.RegisterStatusProvider(order, fn, feature)
    providers[#providers + 1] = { order = order or 100, fn = fn, feature = feature }
end

local function YesNo(v)
    return v and "|cff00ff00yes|r" or "|cffff4040no|r"
end

ns.RegisterCommand{
    name    = "status",
    section = "commands:",
    order   = 30,
    desc    = "why is nothing marking?",
    handler = function()
        table.sort(providers, function(a, b) return a.order < b.order end)
        for i = 1, #providers do
            if ns.FeatureAllows(providers[i]) then providers[i].fn(YesNo) end
        end
    end,
}

--------------------------------------------------------------------------------

ns.RegisterCommandSection("commands:", 10)
ns.RegisterCommandSection("markers:",  20)
ns.RegisterCommandSection("other:",    30)
