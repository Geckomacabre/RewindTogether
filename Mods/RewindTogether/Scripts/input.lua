--[[
    Rewind Together - keys, read on the game thread

    UE4SS's RegisterKeyBind calls back on UE4SS's own thread. Even a callback
    that only hands work to the game thread runs Lua there first, in the same
    Lua state the game thread may be executing at that moment - and 1.7.0
    measured what that costs (MODLOG: crashes inside the garbage collector,
    gone once nothing of ours ran off the game thread).

    So keys are polled instead: APlayerController::IsInputKeyDown(FKey) is a
    reflected UFunction (verified live: returns cleanly for F7 and LeftShift),
    asked 30 times a second from a game-thread loop, with edge detection so a
    held key fires once. A tap shorter than one poll (33 ms) can be missed;
    nobody taps a function key that fast.

    Config.Keys still uses UE4SS's key names ("F7", "TAB", "NUM_ONE"); they are
    translated to the engine's FKey names here.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Input = {}

local binds = {}
local polling = false

-- UE4SS Key.* name -> engine FKey name, for the ones that differ.
local RENAME = {
    TAB = "Tab", SPACE = "SpaceBar", RETURN = "Enter", ESCAPE = "Escape",
    BACKSPACE = "BackSpace", LEFT_SHIFT = "LeftShift", RIGHT_SHIFT = "RightShift",
    LEFT_CONTROL = "LeftControl", RIGHT_CONTROL = "RightControl",
    HOME = "Home", END = "End", INS = "Insert", DEL = "Delete",
    PAGE_UP = "PageUp", PAGE_DOWN = "PageDown",
    NUM_ZERO = "NumPadZero", NUM_ONE = "NumPadOne", NUM_TWO = "NumPadTwo",
    NUM_THREE = "NumPadThree", NUM_FOUR = "NumPadFour", NUM_FIVE = "NumPadFive",
    NUM_SIX = "NumPadSix", NUM_SEVEN = "NumPadSeven", NUM_EIGHT = "NumPadEight",
    NUM_NINE = "NumPadNine",
    ZERO = "Zero", ONE = "One", TWO = "Two", THREE = "Three", FOUR = "Four",
    FIVE = "Five", SIX = "Six", SEVEN = "Seven", EIGHT = "Eight", NINE = "Nine",
}

local function engineKeyName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if RENAME[name] then return RENAME[name] end
    if name:match("^F%d%d?$") then return name end      -- F1..F12
    if name:match("^%u$") then return name end           -- A..Z
    return name
end

--- Is the game-thread loop available? Without it, keys stay on RegisterKeyBind.
function Input.available()
    return type(LoopInGameThreadWithDelay) == "function"
end

--- Register a key. Returns false when polling is not available, so the caller
--- can fall back to RegisterKeyBind. onUp, if given, runs when the key is let
--- go (machines.lua: the end of a drag).
function Input.bind(keyName, label, fn, onUp)
    if not Input.available() then return false end
    local fkey = engineKeyName(keyName)
    if not fkey then return true end
    binds[#binds + 1] = { name = fkey, key = nil, label = label, fn = fn, onUp = onUp, down = false }
    return true
end

--- Was this key down at the last poll? Only for a key that is bound.
function Input.isDown(keyName)
    local fkey = engineKeyName(keyName)
    for _, b in ipairs(binds) do
        if b.name == fkey and b.down then return true end
    end
    return false
end

local function poll()
    -- Whatever the 10 Hz tick resolved: no object-array walk at 30 Hz.
    local pc = UE.peekPlayerController()
    if not pc then return end
    for _, b in ipairs(binds) do
        b.key = b.key or { KeyName = FName(b.name) }
        local ok, down = pcall(function() return pc:IsInputKeyDown(b.key) end)
        down = ok and down == true
        if down and not b.down then
            -- In the crash record (safety.lua): this runs between ticks, where
            -- an unmarked crash would read as the engine's own.
            Safety.phase("key " .. b.label)
            Log.guard("key " .. b.label, b.fn)
            Safety.phase(Safety.IDLE)
        elseif b.down and not down and b.onUp then
            Safety.phase("key up " .. b.label)
            Log.guard("key up " .. b.label, b.onUp)
            Safety.phase(Safety.IDLE)
        end
        b.down = down
    end
end

--- Start the 30 Hz poll, once, after every key is bound.
function Input.start()
    if polling or #binds == 0 or not Input.available() then return end
    polling = true
    local ok = pcall(LoopInGameThreadWithDelay, 33, function()
        Log.guard("key poll", poll)
        return false
    end)
    if ok then
        Log.info("keys: %d binding(s), read on the game thread", #binds)
    else
        polling = false
        Log.warn("keys: could not start the game-thread poll")
    end
end

return Input
