--------------------------------------------------------------------------------
-- Tank Tools -- alert sounds
--
-- The sounds the lost-mob alert (Threat.lua) picks from. Kept out of that
-- module because a sound list is data plus one play function, not threat
-- logic, and because the next audible alert should pick from the same list.
--
-- The important-cast marker used to be the second consumer. It has no sound
-- any more: its answer is secret inside instances, and no sound call accepts
-- a secret (see the header of Modules/ImportantCasts.lua).
--
-- A setting stores the entry's *key*, never a sound id. Ids are an
-- implementation detail that has already changed once under DBM (see its
-- CoreOptions "soundkit to FileData ID" migration); a key that stops matching
-- anything falls back to the default instead of going silent, and silence is
-- the failure that matters -- it reads exactly like the alert not firing.
--
-- Two kinds of entry, because the client has two ways in:
--
--   kit   a SOUNDKIT constant name, played with PlaySound. Looked up by name at
--         play time, so a constant that disappears costs that one entry.
--   file  a FileDataID, played with PlaySoundFile. How DBM plays its alarms,
--         and the only door to the game's Midnight alert sounds.
--
-- Every file id below is one DBM's retail options offer, which is the evidence
-- it resolves on the live client. RAID_BOSS_EMOTE_WARNING and
-- UI_RAID_BOSS_WHISPER_WARNING are deliberately absent: DBM mutes both files
-- outright (MuteSoundFile) when its "hide boss emotes" option is on, so for
-- anyone running it that way they would be an option that plays nothing.
--
-- Always the Master channel: the SFX channel is the one people turn down, and
-- an alert that respects "quieter spell effects" is an alert you miss.
--------------------------------------------------------------------------------

local _, ns = ...

local PlaySound, PlaySoundFile = PlaySound, PlaySoundFile

local DEFAULT = "warning"

-- Display order is list order. Labels are short on purpose: the settings page
-- shows every one of them at once, three to a row.
local SOUNDS = {
    { key = "warning",  text = "Warning",  kit  = "RAID_WARNING" },   -- what the alert always played
    { key = "bell",     text = "Bell",     file = 566558 },           -- DBM: "Night Elf Bell"
    { key = "flag",     text = "PvP flag", file = 569200 },           -- DBM: "PvP Flag"
    { key = "low",      text = "Low",      file = 7670699 },          -- DBM: "Blizzard: Low"
    { key = "medium",   text = "Medium",   file = 7670701 },          -- DBM: "Blizzard: Medium"
    { key = "critical", text = "Critical", file = 7670697 },          -- DBM: "Blizzard: Critical"
}

local byKey = {}
for _, s in ipairs(SOUNDS) do byKey[s.key] = s end

ns.DEFAULT_ALERT_SOUND = DEFAULT

-- The entry for `key`, or nil when there is none -- for a command validating
-- what was typed. Playing goes through ns.PlayAlertSound, which falls back.
function ns.FindAlertSound(key)
    return key and byKey[key] or nil
end

function ns.PlayAlertSound(key)
    local s = byKey[key] or byKey[DEFAULT]
    if s.file then
        PlaySoundFile(s.file, "Master")
        return
    end
    local id = SOUNDKIT and SOUNDKIT[s.kit]
    if not id and s.key ~= DEFAULT then
        id = SOUNDKIT and SOUNDKIT[byKey[DEFAULT].kit]
    end
    if id then PlaySound(id, "Master") end
end

-- Options in the shape ui.Segmented takes.
function ns.AlertSoundOptions()
    local out = {}
    for i, s in ipairs(SOUNDS) do out[i] = { text = s.text, value = s.key } end
    return out
end

-- "warning | bell | ..." for a usage line.
function ns.AlertSoundKeys()
    local keys = {}
    for i, s in ipairs(SOUNDS) do keys[i] = s.key end
    return table.concat(keys, " | ")
end
