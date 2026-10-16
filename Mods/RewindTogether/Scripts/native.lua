--[[
    Rewind Together - the native half (native\RewindNative.dll)

    One job for now: let the host run a piece of the game's own Blueprint
    logic AS a guest. Every interaction in this single-player game finds "the
    player" with GameplayStatics GetPlayerController(0) / GetPlayerCharacter(0)
    / GetPlayerPawn(0) / GetPlayerCameraManager(0), and on a listen server
    those always answer with the host. Inside Native.asPlayer(guestPC, fn)
    they answer with the guest instead, and only inside it.

    Why native: a Lua hook cannot replace a native function's return value,
    and these four are called by Blueprints every frame, so even a Lua
    callback that did nothing would cost something on every one of them. The
    DLL swaps each UFunction's implementation pointer for a thunk that calls
    the original and, while a window is open, substitutes from a small table.
    native\RewindNative\RewindNative.cpp explains the rest, including how it
    gets in without UE4SS's private C++ SDK: package.loadlib, plus the Lua
    wrapper UE4SS exports.

    A second job, on a GUEST: the HUD stand-in. The game's HUD calls ask
    GetGameMode for something to talk to, and a guest has no GameMode, so
    the panel for what is in your hands and the hints for what you look at
    never appear there. The DLL can answer those calls - and only those -
    with Core_Gamemode_C's class default object, whose "UI Game Interface"
    hud.lua points at the guest's widget. RewindNative.cpp ("THE HUD
    STAND-IN") says exactly when it answers and why it is safe; this file
    wraps GetGameMode and arms it.

    A third job, on both sides, from the first tick: emptying UE4SS's own
    member-name cache when this Lua state starts and when it closes. UE4SS
    remembers each name used on an engine object (obj.Mesh, obj:Possess()) by
    a pointer into the Lua string it arrived as, without copying it; a UE4SS
    hot reload frees every one of those strings, and the next new name makes
    UE4SS re-hash them all - a guest crashed exactly there in 1.7.0
    (UE4SS.dll+0x22ba30, "Bodies.tick"). RewindNative.cpp ("THE UE4SS NAME
    CACHE") has the measurements and how the cache is found and checked.

    Everything degrades: no DLL, no package.loadlib, or a failed hook just
    means guests cannot act as player one, and the log says so once.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Native = {}

local LOAD_OP    = "loading RewindNative.dll (lets a guest act in the store)"
local HOOK_OP    = "hooking GetPlayerController for guests (RewindNative.dll)"
local STANDIN_OP = "hooking GetGameMode for the guest's HUD (RewindNative.dll)"
local NAMECACHE_OP = "emptying UE4SS's member-name cache (RewindNative.dll)"
local EXPORTS = { "rt_version", "rt_hook_return", "rt_redirect_begin",
                  "rt_redirect_end", "rt_unhook_all", "rt_stats", "rt_read_ptr" }
-- Newer than the first DLL. One without them still loads and still lets a
-- guest act; it just cannot give a guest's HUD its details (rt.native says).
local STANDIN_EXPORTS = { "rt_hook_null", "rt_standin_arm", "rt_standin_disarm",
                          "rt_standin_stats" }
-- Newer again (RewindNative 3). Without them nothing repairs UE4SS's name
-- cache, which only matters across a hot reload.
local NAMECACHE_EXPORTS = { "rt_namecache", "rt_namecache_purge", "rt_crashes_since", "rt_pid",
                            "rt_pid_alive" }
local TARGETS = {
    "/Script/Engine.GameplayStatics:GetPlayerController",
    "/Script/Engine.GameplayStatics:GetPlayerCharacter",
    "/Script/Engine.GameplayStatics:GetPlayerPawn",
    "/Script/Engine.GameplayStatics:GetPlayerCameraManager",
}
local GAMEMODE_FN = "/Script/Engine.GameplayStatics:GetGameMode"

-- What rt_standin_arm's refusals mean (RewindNative.cpp, arm_stand_in).
local ARM_REFUSED = {
    [-1] = "an address or offset was missing",
    [-2] = "the GameMode default or the HUD widget is not a live object",
    [-3] = "the GameMode default has no event frame",
    [-4] = "the GameMode default does not hold the HUD widget",
    [-5] = "UE4SS's object-table exports were not found",
}

local fns = {}
local state = { loaded = false, failed = nil, hooked = false, hookFailed = nil,
                version = nil, path = nil, hasStandIn = false,
                standInHooked = false, standInFailed = nil }

--- Where the DLL lives: Mods\RewindTogether\native\, beside Scripts\. Taken
--- from package.cpath, which UE4SS sets to this mod's Scripts folder.
local function dllPath()
    for p in tostring(package.cpath):gmatch("[^;]+") do
        local dir = p:match("^(.-[/\\][Mm]ods[/\\]RewindTogether)[/\\]Scripts[/\\]%?%.dll$")
        if dir then return dir .. "/native/RewindNative.dll" end
    end
    return "ue4ss/Mods/RewindTogether/native/RewindNative.dll"
end

function Native.load()
    if state.loaded then return true end
    if state.failed then return false end

    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        state.failed = "this UE4SS build has no package.loadlib"
    else
        state.path = dllPath()
        local fh = io.open(state.path, "rb")
        if not fh then
            state.failed = "RewindNative.dll is not installed (" .. state.path .. ")"
        else
            fh:close()
            local ran, err = Safety.guard(LOAD_OP, function()
                for _, name in ipairs(EXPORTS) do
                    local f, msg = package.loadlib(state.path, name)
                    if not f then return tostring(msg) end
                    fns[name] = f
                end
                local all = true
                for _, name in ipairs(STANDIN_EXPORTS) do
                    local f = package.loadlib(state.path, name)
                    fns[name] = f or nil
                    all = all and f ~= nil
                end
                state.hasStandIn = all
                for _, name in ipairs(NAMECACHE_EXPORTS) do
                    fns[name] = package.loadlib(state.path, name) or nil
                end
                return nil
            end)
            if not ran then
                state.failed = "switched off after an earlier crash (rt.safety)"
            elseif err then
                state.failed = err
            else
                local ok, v, desc = pcall(fns.rt_version)
                if ok and type(v) == "number" then
                    state.loaded, state.version = true, v
                    Log.info("native: %s", tostring(desc))
                else
                    state.failed = "RewindNative.dll did not answer (the UE4SS build may differ)"
                end
            end
        end
    end

    if state.failed then
        Log.warn("native: %s - guests can walk and watch, but not act in the store", state.failed)
        return false
    end
    return true
end

--- Wrap the four "who is the player" functions. Host-side, once.
function Native.installRedirect()
    if state.hooked then return true end
    if state.hookFailed or not Native.load() then return false end

    local ran, result = Safety.guard(HOOK_OP, function()
        local done, problems = 0, {}
        for _, path in ipairs(TARGETS) do
            local fn = StaticFindObject(path)
            if not UE.valid(fn) then
                problems[#problems + 1] = path:match(":(.+)$") .. " not found"
            else
                local r = fns.rt_hook_return(fn:GetAddress())
                if type(r) == "number" and r > 0 then
                    done = done + 1
                else
                    problems[#problems + 1] = ("%s refused (%s)"):format(path:match(":(.+)$"), tostring(r))
                end
            end
        end
        return { done = done, problems = problems }
    end)

    if not ran then
        state.hookFailed = "switched off after an earlier crash (rt.safety)"
    elseif result.done == 0 then
        state.hookFailed = table.concat(result.problems, "; ")
    end
    if state.hookFailed then
        Log.warn("native: could not hook GetPlayerController - %s", state.hookFailed)
        return false
    end
    state.hooked = true
    Log.info("native: %d of %d player-0 functions wrapped%s", result.done, #TARGETS,
             #result.problems > 0 and (" (" .. table.concat(result.problems, "; ") .. ")") or "")
    return true
end

--- Run fn with the given guest answering to "player 0". Returns ok, the
--- number of answers that were redirected, and fn's error if it failed. The
--- window is always closed, error or not: a window left open would hand the
--- host's own HUD and input to the guest for the rest of the session.
function Native.asPlayer(guestPC, fn)
    if not Native.installRedirect() then return false, 0, "native redirect unavailable" end
    local hostPC = UE.GetPlayerController()
    if not (UE.alive(hostPC) and UE.alive(guestPC)) then return false, 0, "no controller" end

    local pairs_ = {}
    local function add(from, to)
        if UE.alive(from) and UE.alive(to) then
            pairs_[#pairs_ + 1] = from:GetAddress()
            pairs_[#pairs_ + 1] = to:GetAddress()
        end
    end
    add(hostPC, guestPC)
    add(UE.TryGet(hostPC, "Pawn"), UE.TryGet(guestPC, "Pawn"))
    add(UE.TryGet(hostPC, "PlayerCameraManager"), UE.TryGet(guestPC, "PlayerCameraManager"))

    local outer = state.playingAs
    state.playingAs = guestPC
    fns.rt_redirect_begin(table.unpack(pairs_))
    local ok, err = pcall(fn)
    local swaps = fns.rt_redirect_end()
    state.playingAs = outer
    return ok, swaps, err
end

--- The guest a Native.asPlayer window is open for right now, or nil: what
--- the game starts inside it, it starts for that guest (talksync.lua).
function Native.playingAs()
    return UE.alive(state.playingAs) and state.playingAs or nil
end

--------------------------------------------------------------------------
-- The HUD stand-in (guest)
--------------------------------------------------------------------------

--- Wrap GameplayStatics.GetGameMode, once per process. Until armStandIn the
--- wrapper only calls the original, and on a machine with a real GameMode
--- (the host, single player) it never does anything else.
function Native.installStandIn()
    if state.standInHooked then return true end
    if state.standInFailed or not Native.load() then return false end
    if not state.hasStandIn then
        state.standInFailed = "this RewindNative.dll is older than the mod - reinstall it"
    else
        local ran, err = Safety.guard(STANDIN_OP, function()
            local fn = StaticFindObject(GAMEMODE_FN)
            if not UE.valid(fn) then return "GetGameMode not found" end
            local r = fns.rt_hook_null(fn:GetAddress())
            if type(r) == "number" and r > 0 then return nil end
            return ("GetGameMode refused (%s)"):format(tostring(r))
        end)
        if not ran then
            state.standInFailed = "switched off after an earlier crash (rt.safety)"
        elseif err then
            state.standInFailed = err
        end
    end
    if state.standInFailed then
        -- The caller (hud.lua) tells the player, once, in its own words.
        Log.debug("native: no HUD stand-in - %s", state.standInFailed)
        return false
    end
    state.standInHooked = true
    Log.info("native: GetGameMode wrapped (the guest HUD stand-in)")
    return true
end

local function address(o)
    if not UE.valid(o) then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and type(a) == "number" and a ~= 0 and a or nil
end

--- Arm the stand-in: from now on the HUD library's GetGameMode calls that
--- would get null get `standIn` (Core_Gamemode_C's class default), as long as
--- it and `widget` stay live and standIn's "UI Game Interface" holds widget.
--- The offsets are standIn's UberGraphFrame and "UI Game Interface";
--- uiInterface is UI_Interface_C and hudLibrary the UI_Player_Interface_C
--- function library. Returns true, or false, why not, and whether that can
--- change in this process (the DLL lacking the stand-in, or the object
--- having no event frame, cannot).
function Native.armStandIn(standIn, widget, frameOffset, widgetOffset, uiInterface, hudLibrary)
    if not Native.installStandIn() then return false, state.standInFailed, true end
    local a, w = address(standIn), address(widget)
    local i, l = address(uiInterface), address(hudLibrary)
    if not (a and w and i and l) then return false, ARM_REFUSED[-1], false end
    if type(frameOffset) ~= "number" or type(widgetOffset) ~= "number" then
        return false, ARM_REFUSED[-1], false
    end
    local ok, r = pcall(fns.rt_standin_arm, a, w, frameOffset, widgetOffset, i, l)
    if ok and r == 1 then return true end
    if not ok then return false, tostring(r), false end
    return false, ARM_REFUSED[r] or ("refused (" .. tostring(r) .. ")"), r == -3 or r == -5
end

--- Stop answering at once. Safe to call at any time, armed or not, loaded or
--- not - it is what runs as a map starts to unload.
function Native.disarmStandIn()
    if state.loaded and state.hasStandIn and fns.rt_standin_disarm then
        pcall(fns.rt_standin_disarm)
    end
end

--- { armed, asked, scoped, handed, stale } or nil without the DLL. `armed`
--- goes false by itself when an object it relied on stops being live.
function Native.standInStats()
    if not (state.loaded and state.hasStandIn and fns.rt_standin_stats) then return nil end
    local ok, armed, asked, scoped, handed, stale = pcall(fns.rt_standin_stats)
    if not ok or type(armed) ~= "number" then return nil end
    return { armed = armed == 1, asked = asked, scoped = scoped, handed = handed, stale = stale }
end

function Native.standInProblem() return state.standInFailed end

function Native.status()
    local lines = {}
    lines[#lines + 1] = ("loaded: %s%s"):format(tostring(state.loaded),
        state.failed and (" (" .. state.failed .. ")") or "")
    if state.loaded then
        local ok, hooked, off, calls, swaps = pcall(fns.rt_stats)
        if ok then
            lines[#lines + 1] = ("functions wrapped: %d (Func at +0x%X)"):format(hooked, off)
            lines[#lines + 1] = ("calls inside guest windows: %d, answers redirected: %d"):format(calls, swaps)
        end
    end
    if state.hookFailed then lines[#lines + 1] = "hook: " .. state.hookFailed end
    local st = Native.standInStats()
    if st then
        lines[#lines + 1] = ("HUD stand-in: %s; Blueprint GetGameMode calls answered null %d, " ..
            "from the HUD library %d, given the stand-in %d, refused as stale %d"):format(
            st.armed and "ARMED" or (state.standInHooked and "not armed" or "not installed"),
            st.asked, st.scoped, st.handed, st.stale)
    end
    if state.standInFailed then lines[#lines + 1] = "HUD stand-in: " .. state.standInFailed end
    local nc = Native.nameCacheStats()
    if nc then
        lines[#lines + 1] = nc.state == 1
            and ("UE4SS name cache: %d name(s), %d buckets; %d dropped in %d repair(s) " ..
                 "this process"):format(nc.names, nc.buckets, nc.dropped, nc.purges)
            or ("UE4SS name cache: %s"):format(nc.state == 0 and "not on this UE4SS build"
                                               or "found, but not as expected - left alone")
    end
    return lines
end

function Native.isReady() return state.hooked end

--------------------------------------------------------------------------
-- UE4SS's member-name cache (both sides)
--------------------------------------------------------------------------

-- What rt_namecache_purge's refusals mean.
local NAMECACHE_REFUSED = {
    [-1] = "this UE4SS build has no such cache - nothing to repair",
    [-2] = "it did not look the way it should, so it was left alone",
}

--- Empty UE4SS's member-name cache. Run as the mod starts, before anything
--- indexes an engine object, and again (silently) as this Lua state closes.
--- Returns the names dropped, or nil and why not.
function Native.repairNameCache()
    if not Native.load() then return nil, state.failed end
    if not fns.rt_namecache_purge then
        return nil, "this RewindNative.dll is older than the mod - reinstall it"
    end
    local ran, dropped = Safety.guard(NAMECACHE_OP, function() return fns.rt_namecache_purge() end)
    if not ran then return nil, "switched off after an earlier crash (rt.safety)" end
    if type(dropped) ~= "number" then return nil, "RewindNative.dll did not answer" end
    if dropped < 0 then
        local why = NAMECACHE_REFUSED[dropped] or ("refused (" .. tostring(dropped) .. ")")
        if dropped == -2 then Log.warn("native: UE4SS's name cache - %s", why)
        else Log.info("native: UE4SS's name cache - %s", why) end
        return nil, why
    end
    Log.info("native: UE4SS's member-name cache emptied (%d name(s)) - it keeps pointers " ..
             "into Lua strings, which a hot reload frees", dropped)
    return dropped
end

--------------------------------------------------------------------------
-- Crash reports (safety.lua asks)
--------------------------------------------------------------------------

--- This process's id, or nil without the DLL.
function Native.pid()
    if not (state.loaded and fns.rt_pid) then return nil end
    local ok, pid = pcall(fns.rt_pid)
    return ok and math.type(pid) == "integer" and pid > 0 and pid or nil
end

--- Is process `pid` a running copy of the game? true, false, or nil when that
--- cannot be told. A crash record that still looks fresh can belong to a
--- copy that was killed a moment ago and started straight again.
function Native.pidAlive(pid)
    if not (state.loaded and fns.rt_pid_alive) or math.type(pid) ~= "integer" then return nil end
    local ok, r = pcall(fns.rt_pid_alive, pid)
    if not ok or r == -1 then return nil end
    return r == 1
end

--- How many crash reports the engine wrote at or after `since` (Unix
--- seconds), about process `pid` if given; nil when that cannot be told
--- (no DLL, or the folder could not be read). A crash writes one before the
--- process dies; a closed window, Steam's Stop or a killed process does not.
function Native.crashesSince(since, pid)
    if not (state.loaded and fns.rt_crashes_since) then return nil end
    if math.type(since) ~= "integer" then return nil end
    local ok, n = pcall(fns.rt_crashes_since, since, math.type(pid) == "integer" and pid or 0)
    if not ok or math.type(n) ~= "integer" or n < 0 then return nil end
    return n
end

--- { state, names, buckets, dropped, purges } or nil without the DLL. state:
--- 1 found, 0 not on this UE4SS build, -1 found but not as expected.
function Native.nameCacheStats()
    if not (state.loaded and fns.rt_namecache) then return nil end
    local ok, st, names, buckets, dropped, purges = pcall(fns.rt_namecache)
    if not ok or type(st) ~= "number" then return nil end
    return { state = st, names = names, buckets = buckets, dropped = dropped, purges = purges }
end

-- As this Lua state closes (a UE4SS hot reload), while its strings still
-- exist: Lua runs every finalizer in lua_close before it frees anything. Kept
-- in the module table so it lives exactly as long as the state does. No
-- logging and no record: the log file may already be closed.
Native._onClose = setmetatable({}, { __gc = function()
    if state.loaded and fns.rt_namecache_purge and not Safety.isBlocked(NAMECACHE_OP) then
        pcall(fns.rt_namecache_purge)
    end
end })

-- For the dev bridge only.
Native._fns = fns

--- Tests only: behave as if RewindNative.dll had loaded with these exports
--- (test/smoke.lua fakes them; the real DLL cannot run outside the game).
function Native._fake(exports)
    for k in pairs(fns) do fns[k] = nil end
    for k, v in pairs(exports or {}) do fns[k] = v end
    state.loaded, state.failed, state.version = exports ~= nil, nil, exports and 2 or nil
    state.hooked, state.hookFailed = false, nil
    state.standInHooked, state.standInFailed = false, nil
    local all = exports ~= nil
    for _, name in ipairs(STANDIN_EXPORTS) do all = all and fns[name] ~= nil end
    state.hasStandIn = all
end

return Native
