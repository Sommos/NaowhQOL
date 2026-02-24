local addonName, ns = ...
if not ns then return end

ns.Media = {}

local LSM  -- lazily resolved
local ADDON_FONT_DIR = "Interface\\AddOns\\NaowhQOL\\Assets\\Fonts\\"

-- Default font / bar / sound names (stored as LSM names, not paths)
ns.Media.DEFAULT_FONT    = "Naowh"
ns.Media.DEFAULT_BAR     = "Solid"
ns.Media.DEFAULT_SOUND   = "Raid Warning"
local FALLBACK_FONT_PATH = "Fonts\\FRIZQT__.TTF"  -- always-available WoW font
local FALLBACK_BAR_PATH  = [[Interface\Buttons\WHITE8X8]]
local FALLBACK_SOUND_ID  = 8959

local function RegisterMedia()
    LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then return end

    local koKR    = LSM.LOCALE_BIT_koKR or 0
    local ruRU    = LSM.LOCALE_BIT_ruRU or 0
    local zhCN    = LSM.LOCALE_BIT_zhCN or 0
    local zhTW    = LSM.LOCALE_BIT_zhTW or 0
    local western = LSM.LOCALE_BIT_western or 0

    local FONT = LSM.MediaType.FONT

    -- Naowh font – western + ruRU variant
    LSM:Register(FONT, "Naowh",
        ADDON_FONT_DIR .. "Naowh.ttf", ruRU + western)
    -- Naowh font – Asian variant
    LSM:Register(FONT, "Naowh",
        ADDON_FONT_DIR .. "NaowhAsia.ttf", koKR + zhCN + zhTW)

    -- Additional bundled fonts (no locale split needed)
    LSM:Register(FONT, "Metropolis ExtraBold",
        ADDON_FONT_DIR .. "Metropolis-ExtraBold.otf")

    -- Statusbar
    LSM:Register(LSM.MediaType.STATUSBAR, "Solid",
        [[Interface\Buttons\WHITE8X8]])
end

RegisterMedia()

---@param nameOrPath string|nil  stored db value
---@return string path
function ns.Media.ResolveFont(nameOrPath)
    if not nameOrPath then
        return ns.Media.ResolveFont(ns.Media.DEFAULT_FONT)
    end

    if not LSM then LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end

    -- If it looks like an LSM name (no path separators), fetch from LSM
    if LSM and not nameOrPath:find("\\") and not nameOrPath:find("/") then
        local path = LSM:Fetch("font", nameOrPath)
        if path then return path end
    end

    -- It's already a file path (legacy) – use as-is
    return nameOrPath
end

--- Resolve a statusbar texture setting to a file path.
---@param nameOrPath string|nil
---@return string path
function ns.Media.ResolveBar(nameOrPath)
    if not nameOrPath then
        return FALLBACK_BAR_PATH
    end

    if not LSM then LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end

    if LSM and not nameOrPath:find("\\") and not nameOrPath:find("/") then
        local path = LSM:Fetch("statusbar", nameOrPath)
        if path then return path end
    end

    return nameOrPath
end

--- Resolve a sound setting to a playable value (number FileDataID or file path string).
---@param nameOrLegacy string|number|table|nil  stored db value
---@return number|string|nil  resolved value for PlaySound/PlaySoundFile
function ns.Media.ResolveSound(nameOrLegacy)
    if not nameOrLegacy then
        return FALLBACK_SOUND_ID
    end

    -- Already a number (legacy numeric ID) – use directly
    if type(nameOrLegacy) == "number" then
        return nameOrLegacy
    end

    -- Table (legacy {id=N} or {path="..."}) – extract directly
    if type(nameOrLegacy) == "table" then
        return nameOrLegacy.id or nameOrLegacy.path or FALLBACK_SOUND_ID
    end

    -- String – treat as LSM name
    if not LSM then LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end

    if LSM then
        local result = LSM:Fetch("sound", nameOrLegacy)
        if result then return result end
    end

    return FALLBACK_SOUND_ID
end

--- Build a reverse lookup: file path → LSM name
local function BuildReverseFontLookup()
    if not LSM then LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end
    if not LSM then return {} end

    local rev = {}
    local hashTable = LSM:HashTable("font")
    if hashTable then
        for name, path in pairs(hashTable) do
            rev[path] = name
            -- Normalise slashes so we catch both forms
            rev[path:gsub("/", "\\")] = name
            rev[path:gsub("\\", "/")] = name
        end
    end
    return rev
end

local function BuildReverseBarLookup()
    if not LSM then LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end
    if not LSM then return {} end

    local rev = {}
    local hashTable = LSM:HashTable("statusbar")
    if hashTable then
        for name, path in pairs(hashTable) do
            rev[path] = name
            rev[path:gsub("/", "\\")] = name
            rev[path:gsub("\\", "/")] = name
        end
    end
    return rev
end

--- Migrate a single db key from path → LSM name (font/bar).
---@param db table        the settings table
---@param key string      the key to check (e.g. "font", "rangeFont")
---@param mediaType string "font" or "statusbar"
local function MigrateKey(db, key, mediaType)
    local val = db[key]
    if type(val) ~= "string" then return end
    -- Already an LSM name (no path separators)? Nothing to do.
    if not val:find("\\") and not val:find("/") then return end

    -- Try reverse lookup
    local rev
    if mediaType == "font" then
        rev = BuildReverseFontLookup()
    else
        rev = BuildReverseBarLookup()
    end

    local name = rev[val] or rev[val:gsub("/", "\\")] or rev[val:gsub("\\", "/")]
    if name then
        db[key] = name
    end
    -- If lookup fails we leave the path as-is; ResolveFont handles raw paths.
end

--- Migrate a single db key from legacy sound format → LSM name.
--- Handles: number, {id=N}, {path="..."}, string path
local function MigrateSoundKey(db, key)
    local val = db[key]
    if val == nil then return end

    -- Already a name string (no path separators, not a number or table)
    if type(val) == "string" and not val:find("\\") and not val:find("/") then
        return  -- Already migrated
    end

    -- Use SoundList's reverse lookup (handles all legacy formats)
    if ns.SoundList and ns.SoundList.GetNameFromLegacy then
        local name = ns.SoundList.GetNameFromLegacy(val)
        if name then
            db[key] = name
            return
        end
    end
    -- If lookup fails, leave as-is; SoundList.Play handles legacy formats.
end

--- Migrate all known font/bar/sound keys in a module's db.
--- fontKeys, barKeys, soundKeys are arrays of key names.
function ns.Media.MigrateDB(db, fontKeys, barKeys, soundKeys)
    if not db then return end
    if fontKeys then
        for _, key in ipairs(fontKeys) do
            MigrateKey(db, key, "font")
        end
    end
    if barKeys then
        for _, key in ipairs(barKeys) do
            MigrateKey(db, key, "statusbar")
        end
    end
    if soundKeys then
        for _, key in ipairs(soundKeys) do
            MigrateSoundKey(db, key)
        end
    end
end
