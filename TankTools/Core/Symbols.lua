--------------------------------------------------------------------------------
-- Tank Tools -- marker symbols
--
-- A marker's symbol is text, and stays text in the saved settings. What this
-- file adds is the raid-marker notation every player already knows from chat:
-- `{skull}`, `{cross}`, `{rt8}` and so on are drawn as the game's own raid
-- target icons, inline in the same font string that draws a `!`.
--
-- Stored as the `{name}` form rather than as texture markup for three reasons:
--
--   * a slash command can carry it. Chat escapes a typed `|` to `||`, so
--     `/tt npglyph |T137008:0|t` never arrives as markup; `{skull}` does.
--   * the settings box can show it, legibly, in the few characters it has.
--   * a name that stops meaning anything degrades to its own text, which is
--     visible and fixable, rather than to a broken texture.
--
-- Emoji are not an option: the game's fonts carry no emoji glyphs.
--
-- Why the raid markers and not any icon: the markers are meant to be told
-- apart by *shape* (see the README), and these eight are the most familiar
-- set of distinct silhouettes in the game. They keep their own colors -- the
-- color swatches tint text, not inline textures.
--------------------------------------------------------------------------------

local _, ns = ...

local gsub, lower = string.gsub, string.lower

-- In the order a tank marks a pull: kill-first first. File IDs are the
-- UI-RaidTargetingIcon_1..8 textures, as DBM's HUD map lists them.
local SYMBOLS = {
    { key = "skull",    file = 137008, rt = 8 },
    { key = "cross",    file = 137007, rt = 7 },
    { key = "square",   file = 137006, rt = 6 },
    { key = "moon",     file = 137005, rt = 5 },
    { key = "triangle", file = 137004, rt = 4 },
    { key = "diamond",  file = 137003, rt = 3 },
    { key = "circle",   file = 137002, rt = 2 },
    { key = "star",     file = 137001, rt = 1 },
}

-- Every spelling chat accepts: the name, `rtN`, and `x` for the cross.
local fileByName = { x = 137007 }
for _, s in ipairs(SYMBOLS) do
    fileByName[s.key] = s.file
    fileByName["rt" .. s.rt] = s.file
end

-- A size of 0 makes the icon as tall as the font, so the marker size slider
-- keeps working unchanged.
local function Markup(name)
    local file = fileByName[lower(name)]
    if file then return "|T" .. file .. ":0|t" end
    return nil   -- gsub keeps the original `{name}` text
end

-- Text in, drawable text out. Anything that is not a known `{name}` is left
-- exactly as written, so every glyph that worked before still does.
function ns.GlyphMarkup(text)
    if not text or text == "" then return "" end
    return (gsub(text, "{(%w+)}", Markup))
end

-- For the settings picker: key, the `{name}` value it stores, and the icon.
function ns.RaidSymbols()
    local out = {}
    for i, s in ipairs(SYMBOLS) do
        out[i] = { key = s.key, value = "{" .. s.key .. "}", file = s.file }
    end
    return out
end
