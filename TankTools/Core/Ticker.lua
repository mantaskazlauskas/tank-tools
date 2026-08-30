--------------------------------------------------------------------------------
-- Tank Tools -- the ticker
--
-- One OnUpdate for the addon. Modules subscribe with an interval and a
-- function; nobody else creates a script handler.
--
-- The reason this is shared rather than one OnUpdate per module is the latch.
-- The set of values the client treats as secret has grown across patches and
-- can grow again, and when it does, a polling loop does not fail once -- it
-- fails five times a second, forever, filling the chat window and dragging the
-- frame rate down with it. So every subscriber runs under pcall, and three
-- consecutive failures stop *that subscriber* -- once, loudly, naming its
-- error. The other modules keep running.
--
-- A zone change clears the latch, because the restrictions that trip it are
-- instance-scoped: what failed inside may well work outside.
--------------------------------------------------------------------------------

local _, ns = ...

local frame   = CreateFrame("Frame")   -- bare and always shown, so the ticker
                                       -- keeps firing whatever else is hidden
local tickers = {}

local FAILURE_LIMIT = 3

--------------------------------------------------------------------------------

-- `label` is the noun used in the failure message and in /tt status -- "scan",
-- not "Threat.Scan". It is what the user is told stopped working.
function ns.RegisterTicker(name, label, interval, fn)
    local t = {
        name     = name,
        label    = label,
        interval = interval,
        fn       = fn,
        elapsed  = 0,
        failures = 0,
        disabled = false,
        err      = nil,
    }
    tickers[#tickers + 1] = t
    tickers[name] = t
    return t
end

function ns.GetTicker(name)
    return tickers[name]
end

--------------------------------------------------------------------------------

frame:SetScript("OnUpdate", function(_, e)
    -- Nothing runs before the database resolves, so no subscriber has to guard
    -- against a nil settings table on its very first tick.
    if not ns.ready then return end

    for i = 1, #tickers do
        local t = tickers[i]
        t.elapsed = t.elapsed + e

        if t.elapsed >= t.interval then
            t.elapsed = 0

            if not t.disabled then
                local ok, err = pcall(t.fn)
                if ok then
                    t.failures = 0
                else
                    t.failures = t.failures + 1
                    t.err      = err
                    if t.failures >= FAILURE_LIMIT then
                        t.disabled = true
                        -- Print the error itself, not a pointer to it.
                        ns.Print("|cffff4040" .. t.label .. " stopped|r -- the "
                                 .. "game is restricting something this addon "
                                 .. "reads:")
                        ns.Print("  " .. tostring(err))
                        ns.Print("Changing zone retries. Please report that line.")
                    end
                end
            end
        end
    end
end)

ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    for i = 1, #tickers do
        local t = tickers[i]
        t.failures = 0
        t.disabled = false
    end
end)
