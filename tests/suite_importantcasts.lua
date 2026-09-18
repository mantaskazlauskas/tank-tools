--------------------------------------------------------------------------------
-- The important-cast marker: a glyph plus a sound when an enemy nameplate is
-- casting something the game itself flags important, via
-- C_Spell.IsSpellImportant -- not a spell-ID list this addon keeps.
--
-- Scenarios:
--   fresh   everything readable, as it is out in the world.
--   secret  as inside an instance: the cast's name and spell ID come back
--           secret, and so does the important-cast answer. The scan must not
--           throw, must never read the answer, and must still get the marker
--           in front of the player -- by handing the secret to the client
--           (SetAlphaFromBoolean) and letting it decide. No sound, because
--           nothing lets an addon play one on an answer it cannot read.
--
-- This scenario used to assert the opposite: that a secret answer marks
-- nothing. It passed for as long as the marker was dead in every dungeon.
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
        if kids[i].text and kids[i].text:GetText() == NS.GlyphMarkup(db.icGlyph) then
            return kids[i]
        end
    end
end

local function Shown(p)
    local m = MarkerFor(p)
    return m ~= nil and m:IsShown()
end

-- What the player actually sees: the marker is up AND the client resolved the
-- gate to opaque. Under secrets the addon cannot tell these apart; the suite
-- can, through the harness's record of what the client did with the secret.
local function Visible(p)
    local m = MarkerFor(p)
    if not (m and m:IsShown()) then return false end
    local seen = m.gate and m.gate._seenAlpha
    return seen ~= nil and seen ~= 0
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
eq(db.icSound,  nil,   "no sound setting -- a sound cannot work in instances")

--------------------------------------------------------------------------------
section("marking an important cast")
--------------------------------------------------------------------------------

local before = SOUNDS_PLAYED
StartCast(90001)
Tick(0.25)

ok(Visible(plate), "a marker appears once something casts an important spell")
eq(MarkerFor(plate).text:GetText(), "!!", "with the default glyph")
if SECRETS then
    ok(issecretvalue(MarkerFor(plate).gate:GetAlpha()),
       "secret: the client decided it -- the answer went in through the gate, unread")

    -- The diagnostics have to say "unreadable", not "marked" -- and must not
    -- throw printing a secret name and spell ID.
    local n = #CHAT
    Slash("status")
    local said = table.concat(ChatSince(n), " | ")
    ok(said:find("marked now: 0", 1, true) ~= nil,
       "status does not count an unreadable cast as a marked one")
    ok(said:find("the game decides): 1", 1, true) ~= nil,
       "it counts it as unreadable instead")

    n = #CHAT
    local dumped = pcall(Slash, "icdebug")
    ok(dumped, "/tt icdebug survives a secret name and spell ID")
    said = table.concat(ChatSince(n), " | ")
    ok(said:find("armed", 1, true) ~= nil, "and says the marker is armed")
end
eq(SOUNDS_PLAYED, before, "an important cast makes no sound")
eq(FAILED_TICKS(), 0, "the scan did not throw")

--------------------------------------------------------------------------------
section("clears when the cast ends, and marks again on the next one")
--------------------------------------------------------------------------------

Tick(0.25)
ok(Visible(plate), "the marker holds while the same cast continues")

EndCast()
Tick(0.25)
ok(not Shown(plate), "marker hides once the cast ends")

StartCast(90001)
Tick(0.25)
ok(Visible(plate), "a fresh cast marks again")
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("a cast the game does not flag important is ignored")
--------------------------------------------------------------------------------

StartCast(90002)
Tick(0.25)
ok(not Visible(plate), "no marker the player can see for an unimportant cast")
if SECRETS then
    -- Up but transparent: the addon cannot tell this cast from an important
    -- one, so it arms the marker for both and the client shows only one.
    ok(Shown(plate), "secret: armed all the same -- the client hid it, not us")
end
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("a channeled important cast marks the same way")
--------------------------------------------------------------------------------

StartCast(90001, true)
Tick(0.25)
ok(Visible(plate), "UnitChannelInfo is read the same way UnitCastingInfo is")
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("a friendly unit is never marked")
--------------------------------------------------------------------------------

WORLD.units["nameplate1"].attackable = false
StartCast(90001)
Tick(0.25)
-- Only checkable where attackability is readable. Under secretMode
-- UnitCanAttack is secret, and like every identity gate in this addon it
-- fails open (Core/Secret.lua), so the unit gets through to the cast check.
if not SECRETS then
    ok(not Shown(plate), "friendly casts do not mark, important or not")
end
WORLD.units["nameplate1"].attackable = true
EndCast()
Tick(0.25)

--------------------------------------------------------------------------------
section("commands")
--------------------------------------------------------------------------------

Slash("ic")
eq(db.icMarker, false, "/tt ic toggles the marker off")

StartCast(90001)
Tick(0.25)
ok(not Shown(plate), "marker stays off")
eq(FAILED_TICKS(), 0, "and with it off the scan simply idles")
EndCast()
Tick(0.25)
Slash("ic")
eq(db.icMarker, true, "toggled back on")

-- Removed on purpose, and it must stay removed: an unknown command falls
-- through to the help rather than toggling anything.
Slash("icsound")
eq(db.icSound, nil, "/tt icsound no longer exists")

Slash("icglyph ##")
eq(db.icGlyph, "##", "/tt icglyph sets a custom symbol")
db.icGlyph = "!!"

Slash("icglyph {skull}")
eq(db.icGlyph, "{skull}", "/tt icglyph takes a raid marker")
StartCast(90001)
Tick(0.25)
eq(MarkerFor(plate).text:GetText(), "|T137008:0|t", "and the marker draws the skull icon")
EndCast()
Tick(0.25)
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
