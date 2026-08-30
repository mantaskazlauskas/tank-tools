--------------------------------------------------------------------------------
-- Tank Tools -- event dispatch
--
-- One frame for the whole addon instead of one per module.
--
-- That is not a micro-optimisation -- a handful of frames costs nothing. It is
-- so that ordering is a property of the .toc rather than an accident: handlers
-- for an event run in registration order, registration order is file order,
-- and file order is written down. The database resolving before anything reads
-- it depends on exactly that.
--
-- A handler that errors is caught, so it cannot take the event down for every
-- module behind it in the list. It is reported once and then keeps running --
-- a single throw is usually a transient bad unit token, and permanently
-- disabling a feature over one is a worse outcome than the error itself. Only
-- a handler that keeps failing is finally stopped.
--------------------------------------------------------------------------------

local _, ns = ...

local FAILURE_LIMIT = 5

local frame    = CreateFrame("Frame")
local handlers = {}   -- event -> array of fn
local failures = {}   -- fn -> count
local broken   = {}   -- fn -> true, once it has passed the limit

-- fn is called as fn(event, ...) -- the frame itself is never passed, because
-- no module has any business touching it.
function ns.RegisterEvent(event, fn)
    local list = handlers[event]
    if not list then
        list = {}
        handlers[event] = list
        frame:RegisterEvent(event)
    end
    list[#list + 1] = fn
end

-- Convenience for the common "several events, same handler" case.
function ns.RegisterEvents(events, fn)
    for i = 1, #events do ns.RegisterEvent(events[i], fn) end
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end

    for i = 1, #list do
        local fn = list[i]
        if not broken[fn] then
            local ok, err = pcall(fn, event, ...)
            if not ok then
                local n = (failures[fn] or 0) + 1
                failures[fn] = n

                -- Reported on the first failure and never again, because an
                -- event that fires every frame would otherwise paper the chat
                -- window with the same line. The error is printed in full, not
                -- as a pointer to itself -- a "run /tt status" nudge is how the
                -- last one of these stayed invisible.
                if n == 1 then
                    ns.Print("|cffff4040a handler for " .. tostring(event)
                             .. " failed|r:")
                    ns.Print("  " .. tostring(err))
                    ns.Print("Please report that line.")
                elseif n >= FAILURE_LIMIT then
                    broken[fn] = true
                    ns.Print("|cffff4040that " .. tostring(event)
                             .. " handler keeps failing and has been stopped.|r"
                             .. " Reloading retries it.")
                end
            end
        end
    end
end)
