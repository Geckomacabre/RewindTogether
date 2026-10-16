--[[
    Rewind Together - developer bridge (OFF unless switched on)

    Lets a script outside the game run rt.* commands and small Lua snippets in
    a live session and read the result back, without anybody typing into the
    UE4SS console. That is what makes a two-instance co-op test on ONE machine
    repeatable: a test script drives both games through files, and every claim
    about what the other side received is read off the other side.

    It exists only when RewindTogether.devbridge exists beside the game's exe
    (Binaries\Win64). Release packages never contain that file, so in a normal
    install this module checks for it once at boot and does nothing else, ever.

    Files, all in Binaries\Win64 (the game's working directory):

      RewindTogether.devbridge         enable switch; contents ignored
      RewindTogether.bridge.<S>.beat   heartbeat for slot S (A, B, ...)
      RewindTogether.bridge.<S>.in     commands, one per line; removed when read
      RewindTogether.bridge.<S>.out    results, appended

    Two instances on one machine share that directory - and the log file - so
    each claims the first slot whose heartbeat has gone stale and tags its log
    lines with the slot letter.

    A line is either
      rt.<anything>         exactly as typed in the console, or
      lua <code>            run in this mod's Lua state; `return` values and
                            P(...) calls become output.
    and may start with "@<id> ", echoed in the end marker so the caller can
    tell which answer is whose.
]]

local Log = require("log")

local Bridge = {}

local ENABLE_FILE = "RewindTogether.devbridge"
local SLOTS       = { "A", "B", "C", "D" }
local STALE_AFTER = 6      -- seconds without a heartbeat before a slot is free
local BEAT_EVERY  = 2.0
local POLL_EVERY  = 0.2

local enabled  = false
local slot     = nil
local inPath, outPath, beatPath
local lastBeat, lastPoll = 0, 0
local commands = nil
local pendingSince = nil

local function readAll(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("a")
    fh:close()
    return s
end

local function writeAll(path, text, mode)
    local fh = io.open(path, mode or "w")
    if not fh then return false end
    fh:write(text)
    fh:close()
    return true
end

local function claimSlot()
    local now = os.time()
    for _, s in ipairs(SLOTS) do
        local beat = tonumber(readAll(("RewindTogether.bridge.%s.beat"):format(s)) or "")
        if not beat or (now - beat) > STALE_AFTER then
            return s
        end
    end
    return nil
end

-- Every snippet ever compiled, kept. Its member names (x.Mesh, x:Possess())
-- are constants of the chunk; UE4SS remembers each name by a pointer into
-- that string, so a collected chunk would leave it pointing at freed memory
-- (ue.lua, UE.pin). Dev only, a few kilobytes a session.
local kept = {}

local function runLua(code)
    local out = {}
    local env = setmetatable({
        P = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            out[#out + 1] = table.concat(parts, "\t")
        end,
    }, { __index = _G })
    local chunk, err = load(code, "bridge", "t", env)
    if not chunk then
        out[#out + 1] = "compile error: " .. tostring(err)
        return out
    end
    kept[#kept + 1] = chunk
    local res = table.pack(pcall(chunk))
    if not res[1] then
        out[#out + 1] = "error: " .. tostring(res[2])
    else
        for i = 2, res.n do out[#out + 1] = "=> " .. tostring(res[i]) end
    end
    return out
end

local function handle(line)
    local id, body = line:match("^@(%S+)%s+(.*)$")
    if not id then id, body = "-", line end

    -- In the crash record (safety.lua): this runs before the tick's first
    -- phase, where it would otherwise read as the engine's own time.
    require("safety").phase("dev bridge: " .. body:sub(1, 60))

    local lines
    if body:sub(1, 4) == "lua " then
        local luaOut
        lines = Log.capture(function() luaOut = runLua(body:sub(5)) end)
        for _, l in ipairs(luaOut or {}) do lines[#lines + 1] = l end
    else
        local dev = { Log = function(_, text) end }   -- out() already logs every line
        local known
        lines = Log.capture(function() known = commands.run(body, dev) end)
        if not known then lines[#lines + 1] = "unknown command: " .. body end
    end

    local buf = { (">>> %s %s"):format(id, body) }
    for _, l in ipairs(lines) do buf[#buf + 1] = l end
    buf[#buf + 1] = ("<<< %s"):format(id)
    writeAll(outPath, table.concat(buf, "\n") .. "\n", "a")
end

function Bridge.init(cmds)
    commands = cmds
    if not readAll(ENABLE_FILE) then return end
    -- The slot is claimed a little later, from tick(). After a UE4SS hot
    -- reload (Ctrl+R) the previous Lua state's heartbeat is still fresh, and
    -- claiming at once would hand this same process a second slot.
    pendingSince = os.clock()
    Log.warn("dev bridge: switched on, claiming a slot in %ds", STALE_AFTER + 1)
end

local function start()
    pendingSince = nil
    slot = claimSlot()
    if not slot then
        Log.warn("dev bridge: every slot is taken, not starting")
        return
    end
    inPath   = ("RewindTogether.bridge.%s.in"):format(slot)
    outPath  = ("RewindTogether.bridge.%s.out"):format(slot)
    beatPath = ("RewindTogether.bridge.%s.beat"):format(slot)
    os.remove(inPath)
    writeAll(outPath, "")
    writeAll(beatPath, tostring(os.time()))
    enabled = true
    require("ue").trace = Bridge.sub
    Log.setTag(slot)
    Log.warn("dev bridge ON as slot %s (delete %s to turn it off)", slot, ENABLE_FILE)
end

--- Record what is about to run, so a native crash - which pcall cannot see
--- and which leaves nothing in the log - can be pinned to one phase of the
--- tick afterwards. One file per slot, rewritten in place: after a crash it
--- holds the last phase that started. Dev bridge only; a no-op otherwise.
local traceFh = nil
local lastPhase = "-"
local function trace(line)
    if not traceFh then
        traceFh = io.open(("RewindTogether.trace.%s"):format(slot), "w")
        if not traceFh then return end
    end
    -- Padded, so a shorter line rewritten in place leaves nothing of a longer
    -- one behind. (Lua's format widths stop at 99, hence the rep.)
    local text = ("%.3f %s"):format(os.clock(), line)
    if #text < 160 then text = text .. string.rep(" ", 160 - #text) end
    traceFh:seek("set", 0)
    traceFh:write(text .. "\n")
    traceFh:flush()
end

function Bridge.phase(name)
    if not enabled then return end
    lastPhase = name
    trace(name)
end

--- A finer step inside the current phase: ue.lua's engine calls (UE.trace).
--- MEASURED (15 Oct 2026): the host crashed twice inside UE4SS with only
--- "NpcSync.tickHost" and "World.tickHost" on the trace - the same native
--- stack both times, so something both phases share, and the phase alone
--- could not say what.
function Bridge.sub(what, arg)
    if not enabled then return end
    trace(lastPhase .. " > " .. what .. " " .. tostring(arg or ""))
end

function Bridge.isEnabled() return enabled end
function Bridge.slot() return slot end

--- Called every tick, on the game thread, before anything that can return
--- early - the bridge has to answer at the main menu too.
function Bridge.tick(now)
    if pendingSince and (os.clock() - pendingSince) > STALE_AFTER + 1 then start() end
    if not enabled then return end

    if now - lastBeat > BEAT_EVERY then
        lastBeat = now
        writeAll(beatPath, tostring(os.time()))
    end

    if now - lastPoll < POLL_EVERY then return end
    lastPoll = now

    local text = readAll(inPath)
    if not text then return end
    os.remove(inPath)
    for line in text:gmatch("[^\r\n]+") do
        if line:match("%S") then handle(line) end
    end
end

return Bridge
