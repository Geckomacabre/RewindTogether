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

    Everything degrades: no DLL, no package.loadlib, or a failed hook just
    means guests cannot act as player one, and the log says so once.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Native = {}

local LOAD_OP = "loading RewindNative.dll (lets a guest act in the store)"
local HOOK_OP = "hooking GetPlayerController for guests (RewindNative.dll)"
local EXPORTS = { "rt_version", "rt_hook_return", "rt_redirect_begin",
                  "rt_redirect_end", "rt_unhook_all", "rt_stats", "rt_read_ptr" }
local TARGETS = {
    "/Script/Engine.GameplayStatics:GetPlayerController",
    "/Script/Engine.GameplayStatics:GetPlayerCharacter",
    "/Script/Engine.GameplayStatics:GetPlayerPawn",
    "/Script/Engine.GameplayStatics:GetPlayerCameraManager",
}

local fns = {}
local state = { loaded = false, failed = nil, hooked = false, hookFailed = nil,
                version = nil, path = nil }

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

    fns.rt_redirect_begin(table.unpack(pairs_))
    local ok, err = pcall(fn)
    local swaps = fns.rt_redirect_end()
    return ok, swaps, err
end

function Native.status()
    local lines = {}
    lines[#lines + 1] = ("loaded: %s%s"):format(tostring(state.loaded),
        state.failed and (" (" .. state.failed .. ")") or "")
    if state.loaded then
        local ok, hooked, off, calls, swaps = pcall(fns.rt_stats)
        if ok then
            lines[#lines + 1] = ("player-0 functions wrapped: %d (Func at +0x%X)"):format(hooked, off)
            lines[#lines + 1] = ("calls inside guest windows: %d, answers redirected: %d"):format(calls, swaps)
        end
    end
    if state.hookFailed then lines[#lines + 1] = "hook: " .. state.hookFailed end
    return lines
end

function Native.isReady() return state.hooked end

-- For the dev bridge only.
Native._fns = fns

return Native
