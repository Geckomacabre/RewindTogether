--[[ Rewind Together - logging ]]

local Log = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }
local threshold = LEVELS.info
local fileHandle = nil
local PREFIX = "[RewindTogether] "

-- Lines logged while devbridge.lua runs a command, so the output can be handed
-- back to whoever asked for it. nil in every normal install: the bridge only
-- exists when its enable file does.
local capture = nil

local LOG_PATH     = "RewindTogether.log"
local MAX_LOG_BYTES = 4 * 1024 * 1024

--- Start a fresh log if the old one has got out of hand.
---
--- This file is appended to across every launch, which is what makes it worth
--- keeping - the crash that ended 1.5.0 was only readable because the previous
--- session was still in it. But one runaway failure took it to 18 MB, and at
--- that size nobody opens it and nothing can be found in it. Roll it over
--- instead of truncating, so the evidence survives one more launch.
local function rotateIfHuge()
    local ok, fh = pcall(io.open, LOG_PATH, "r")
    if not (ok and fh) then return end
    local size = fh:seek("end")
    fh:close()
    if not size or size < MAX_LOG_BYTES then return end
    os.remove(LOG_PATH .. ".old")
    os.rename(LOG_PATH, LOG_PATH .. ".old")
end

function Log.init(levelName, toFile)
    threshold = LEVELS[levelName or "info"] or LEVELS.info
    if toFile then
        rotateIfHuge()
        -- UE4SS runs with the game's CWD; put the log beside UE4SS.log.
        local ok, handle = pcall(io.open, LOG_PATH, "a")
        if ok and handle then
            fileHandle = handle
            fileHandle:write(("\n===== session start %s =====\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
            fileHandle:flush()
        end
    end
end

-- Repeat suppression.
--
-- A failure inside the tick loop repeats at tick rate, and each write is
-- flushed to disk on the game thread. One such failure produced 15,000 stack
-- traces and an 18 MB log file in a single session - the logging cost more
-- than the bug did. Safety.guard now retires an operation that keeps throwing,
-- which is the real fix; this is the backstop for everything that does not go
-- through it.
--
-- Identical consecutive messages are counted rather than written, and the
-- count is reported when something different finally happens - so nothing is
-- silently lost, it is just not written down a thousand times.
local lastLine   = nil
local repeatCount = 0
local REPEAT_LIMIT = 3

local function write(line)
    if capture then capture[#capture + 1] = line end
    print(line .. "\n")
    if fileHandle then
        fileHandle:write(("%s %s\n"):format(os.date("%H:%M:%S"), line))
        fileHandle:flush()
    end
end

local function flushRepeats()
    if repeatCount > REPEAT_LIMIT then
        write(("%s[WARN] (the message above repeated %d more times)")
              :format(PREFIX, repeatCount - REPEAT_LIMIT))
    end
    repeatCount = 0
end

local function emit(level, fmt, ...)
    if LEVELS[level] > threshold then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local line = ("%s[%s] %s"):format(PREFIX, level:upper(), msg)

    if line == lastLine then
        repeatCount = repeatCount + 1
        if repeatCount > REPEAT_LIMIT then return end
    else
        flushRepeats()
        lastLine = line
        repeatCount = 1
    end

    write(line)
end

function Log.error(fmt, ...) emit("error", fmt, ...) end
function Log.warn(fmt, ...)  emit("warn",  fmt, ...) end
function Log.info(fmt, ...)  emit("info",  fmt, ...) end
function Log.debug(fmt, ...) emit("debug", fmt, ...) end

--- Run fn, log any error instead of letting it kill the mod.
--- UE4SS will silently stop executing a Lua callback that throws, so every
--- hook and timer in this mod goes through here.
function Log.guard(name, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        Log.error("%s failed: %s", name, tostring(result))
        return nil
    end
    return result
end

--- Run fn and also collect every line logged while it runs. Used by the dev
--- bridge to hand a command's output back to whoever asked for it.
function Log.capture(fn, ...)
    local prev, lines = capture, {}
    capture = lines
    local ok, err = pcall(fn, ...)
    capture = prev
    if prev then for _, l in ipairs(lines) do prev[#prev + 1] = l end end
    if not ok then lines[#lines + 1] = "error: " .. tostring(err) end
    return lines
end

--- Prefix every line with a tag. Only the dev bridge sets one.
function Log.setTag(tag)
    PREFIX = tag and ("[RewindTogether:%s] "):format(tag) or "[RewindTogether] "
end

function Log.shutdown()
    if fileHandle then
        fileHandle:write("===== session end =====\n")
        fileHandle:close()
        fileHandle = nil
    end
end

return Log
