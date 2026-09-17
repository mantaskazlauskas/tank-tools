--------------------------------------------------------------------------------
-- The important-cast marker: a glyph plus a sound when an enemy nameplate is
-- casting something the game itself flags important, via
-- C_Spell.IsSpellImportant -- not a spell-ID list this addon keeps.
--
-- Scenarios:
--   fresh   everything readable, as it is out in the world.
--   secret  the client answers the important-cast flag with a secret boolean,
--           as it may inside an instance. The scan must not throw, and an
--           unreadable answer must mark NOTHING -- the opposite direction
--           from an identity gate, and deliberately so: this is a decorative
--           alert, not a check that would blind the addon to a real mob if it
--           failed the other way.
--------------------------------------------------------------------------------

local SECRETS = (SCENARIO == "secret")
WORLD.secretMode = SECRETS

SPELLDB[90001] = { name = "Big Nuke",   icon = 111, important = true  }
SPELLDB[90002] = { name = "Small Poke", icon = 222, important = false }

local plate = CreateFrame("Frame")
NAMEPLATES["nameplate1"] = plate
WORLD.units["nameplate1"] = { attackable = true }

-- The plate also carries Nameplates.lua's own aggro-marker child once a
-- PLAYER_ENTERING_WORLD/NAME_PLATE_UNIT_ADDED reconcile has run -- same shape
-- (a Frame with a `.text` FontString), different content, so the two are told
-- apart by which glyph is actually on the frame.
local function MarkerFor(p)
    local db = TankToolsDB.modules.importantcasts
    local kids = FramesParentedTo(p)
    for i = 1, #kids do
        if kids[i].text and kids[i].text:GetText() == db.icGlyph then
            return kids[i]
        end
    end
end

local function Shown(p)
    local m = MarkerFor(p)
    return m ~= nil and m:IsShown()
end

local function StartCast(spellId, channel)
    WORLD.units["nameplate1"].cast = {
        name    = SPELLDB[spellId].name,
        icon    = SPELLDB[spellId].icon,
        spellId = spellId,
        channel = channel,
    }
end

local function EndCast()
    WORLD.units["nameplate1"].cast = nil
end

FireEvent("ADDON_LOADED", "TankTools")
FireEvent("PLAYER_LOGIN")
FireEvent("PLAYER_ENTERING_WORLD")

--------------------------------------------------------------------------------
section("load")
--------------------------------------------------------------------------------

ok(NS.GetModule("importantcasts") ~= nil, "importantcasts module registered")

local db = TankToolsDB.modules.importantcasts
ok(db ~= nil, "importantcasts has its own settings table")
eq(db.icGlyph,  "!!",  "default glyph differs from the aggro marker's \"!\"")
eq(db.icAnchor, "TOP", "default anchor differs from the aggro marker's LEFT")
eq(db.icMarker, true,  "marker on by default")
eq(db.icSound,  true,  "sound on by default")

--------------------------------------------------------------------------------
section("marking an important cast")
--------------------------------------------------------------------------------

local before = SOUNDS_PLAYED
StartCast(90001)
Tick(0.25)

if SECRETS then
    ok(not Shown(plate), "secret: nothing drawn on an unreadable important-cast flag")
    eq(SOUNDS_PLAYED, before, "secret: no sound either")
else
    ok(Shown(plate), "a marker appears once something casts an important spell")
    eq(MarkerFor(plate).text:GetText(), "!!", "with the default glyph")
    eq(SOUNDS_PLAYED, before + 1, "and the sound fired once")
end
eq(FAILED_TICKS(), 0, "the scan did not throw")

--------------------------------------------------------------------------------
section("no repeat sound while the same cast continues")
--------------------------------------------------------------------------------

before = SOUNDS_PLAYED
Tick(0.25)
Tick(0.25)
eq(SOUNDS_PLAYED, before, "polling the same ongoing cast makes no extra sound")

--------------------------------------------------------------------------------
section("clears when the cast ends, and sounds again on the next one")
--------------------------------------------------------------------------------

EndCast()
Tick(0.25)
ok(not Shown(plate), "marker hides once the cast ends")

before = SOUNDS_PLAYED
StartCast(90001)
Tick(0.25)
if not SECRETS then
    eq(SOUNDS_PLAYED, before + 1, "a fresh cast makes a fresh sound")
end
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("a cast the game does not flag important is ignored")
--------------------------------------------------------------------------------

before = SOUNDS_PLAYED
StartCast(90002)
Tick(0.25)
ok(not Shown(plate), "no marker for an unimportant cast")
eq(SOUNDS_PLAYED, before, "and no sound")
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("a channeled important cast marks the same way")
--------------------------------------------------------------------------------

before = SOUNDS_PLAYED
StartCast(90001, true)
Tick(0.25)
if SECRETS then
    ok(not Shown(plate), "secret: still nothing on a channel either")
else
    ok(Shown(plate), "UnitChannelInfo is read the same way UnitCastingInfo is")
    eq(SOUNDS_PLAYED, before + 1, "and it sounds")
end
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("a friendly unit is never marked")
--------------------------------------------------------------------------------

WORLD.units["nameplate1"].attackable = false
before = SOUNDS_PLAYED
StartCast(90001)
Tick(0.25)
ok(not Shown(plate), "friendly casts do not mark, important or not")
eq(SOUNDS_PLAYED, before, "and do not sound")
WORLD.units["nameplate1"].attackable = true
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("commands")
--------------------------------------------------------------------------------

Slash("ic")
eq(db.icMarker, false, "/tt ic toggles the marker off")

before = SOUNDS_PLAYED
StartCast(90001)
Tick(0.25)
ok(not Shown(plate), "marker stays off")
if not SECRETS then
    eq(SOUNDS_PLAYED, before + 1, "but the sound is a separate toggle and still fires")
end
EndCast()
Tick(0.25)
Slash("ic")
eq(db.icMarker, true, "toggled back on")

Slash("icsound")
eq(db.icSound, false, "/tt icsound toggles the sound off")
Slash("icsound")
eq(db.icSound, true, "toggled back on")

Slash("icglyph ##")
eq(db.icGlyph, "##", "/tt icglyph sets a custom symbol")
db.icGlyph = "!!"

Slash("icanchor bottom")
eq(db.icAnchor, "BOTTOM", "/tt icanchor accepts a position, case-insensitively")
db.icAnchor = "TOP"

Slash("icanchor sideways")
eq(db.icAnchor, "TOP", "a bad position is rejected rather than saved")

--------------------------------------------------------------------------------
section("preview")
--------------------------------------------------------------------------------

WORLD.units["nameplate1"].attackable = true
Slash("ictest")
Tick(0.25)
ok(Shown(plate), "preview marks an idle enemy nameplate with no cast at all")

FireEvent("PLAYER_ENTERING_WORLD")
Tick(0.25)
ok(not Shown(plate), "preview ends on zone change, same as the aggro marker's")

--------------------------------------------------------------------------------

eq(FAILED_TICKS(), 0, "no ticker failed anywhere in this suite")

report()
