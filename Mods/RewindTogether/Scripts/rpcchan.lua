--[[
    Rewind Together - the side-channel, over the connection we already have

    WHY THIS EXISTS

    Everything this mod cannot yet do - money, the clock, prop contents, what
    a dropped movie looks like on the other machine - needs the host to tell
    the guest something the engine does not replicate on its own. Cooked
    Blueprints cannot be given new replicated properties and cannot be given
    RPCs, so the host has to carry that data itself.

    For five versions that meant SteamCore Pro's P2P API, and 1.5.7 measured
    that it cannot work on this build:

        SteamID struct is 'SteamID' but exposes no readable fields
        a live SteamID answers to NONE of the field names this mod knows

    FSteamID wraps a uint64, UE does not support uint64 as a UPROPERTY, so the
    plugin stores it as a plain C++ member with no reflection at all. A Lua
    table can never construct one. Twenty-two argument shapes were refused
    proving it. That channel is not "not working yet", it is impossible here.

    Meanwhile the two machines have had a live, reliable, ordered UNetConnection
    between them since the guest joined.

    THE CHANNEL

    APlayerController::ClientMessage(FString S, FName Type, float MsgLifeTime)
    is declared UFUNCTION(Reliable, Client) in Engine. Every APlayerController
    in every UE build has it. Called on the SERVER against a REMOTE player's
    controller, it executes on that player's machine and hands them the string.

    That is a reliable host -> guest data channel with no new transport, no
    Steam, no ports, no configuration, and nothing for a user to type. It works
    the moment somebody joins, because it IS the join.

    The guest receives by hooking the same function. It carries UFUNCTION data
    by definition - it is an RPC - so unlike PostLogin it is hookable
    (PROJECT.md 5).

    THE OTHER DIRECTION

    Guest -> host needs a Server RPC, and the stock ones on APlayerController
    are a poor menu: ServerNotifyLoadedWorld carries an FName, and FNames are
    interned permanently, so a few per second would grow the global name table
    for the whole session and never give it back.

    ServerSetSpectatorLocation(FVector NewLoc, FRotator NewRot) is the one that
    fits. It is UFUNCTION(unreliable, server, WithValidation), it carries six
    floats, and six floats is EXACTLY the payload the guest needs to send: the
    position and direction they interacted from, so the host can re-run the
    same trace with authority. Nothing is stringified, nothing is interned.

    It is safe to borrow here because this game has no spectators - the engine
    only calls it from spectator camera code, so on this build nothing else
    ever will. The host hooks it and treats an arrival as "this guest pressed
    use, here is where they were looking".

    Unreliable is acceptable for an interaction: a keypress sends it three
    times a few frames apart, and the host ignores repeats inside a short
    window. A dropped packet costs a retry, not a desync.

    WIRE FORMAT

    P2P.encode / P2P.decode, unchanged and already round-trip tested. The
    format was never the part that failed, and reusing it means a message
    reaching a handler looks identical whichever channel carried it.
]]

local Log    = require("log")
local UE     = require("ue")
local P2P    = require("steamp2p")
local Safety = require("safety")
local DevBridge = require("devbridge")

local Chan = {}

local handlers  = {}
local stats     = { sent = 0, failed = 0, received = 0 }
local hooked    = false
local hookFailed = false
local warnedNoFn = false
-- Set once a ClientMessage call has returned alive, after which the argument
-- shape is proven and no longer needs a breadcrumb around every packet.
local proven    = false

-- Renamed in 1.7.0 along with the fix below, so that a 1.6.1 install which
-- crashed here - and therefore has this operation switched off in
-- RewindTogether-disabled.txt - runs the fixed call instead of staying off.
local SEND_OP = "sending store state to a guest"

-- The FName handed to ClientMessage as its Type. The stock implementation
-- passes it to the HUD, which this game does not use for it; naming it makes
-- the traffic identifiable if it ever does surface somewhere.
local MSG_TYPE = "RewindTogether"
local msgTypeFName = nil

-- Built once and kept: an FName is interned for the life of the process, so
-- making it per packet would cost a lookup and save nothing.
local function msgTypeName()
    if not msgTypeFName then msgTypeFName = FName(MSG_TYPE) end
    return msgTypeFName
end

--------------------------------------------------------------------------
-- Sending (host)
--------------------------------------------------------------------------

--- Send one message to one player controller.
---
--- Returns true only if the call was accepted. As everywhere else in this
--- project, a dispatch is not a delivery - the guest's `received` counter is
--- the only proof, which is why rt.chan prints both sides.
function Chan.sendTo(pc, msgType, payload)
    if not UE.alive(pc) then return false end

    local str = P2P.encode(msgType, payload)

    -- Full signature first, then the short form. MsgLifeTime and Type both
    -- have defaults in C++, but a default argument is a compiler feature and
    -- does not exist by the time UE4SS is calling through reflection - so
    -- whether the short form is accepted is a property of the build.
    --
    -- The FIRST call of a session goes behind a crash breadcrumb. Handing a
    -- Lua string to an FName parameter is a marshalling step, and a bad
    -- marshalling step is a native fault, which pcall does not catch. Once one
    -- call has come back alive the shape is proven and the guard is pointless
    -- overhead on every packet after it.
    --
    -- 1.6.1 passed MSG_TYPE as a plain Lua string. MEASURED in 1.7.0 on two
    -- instances: UE4SS does not convert a string into an FName parameter, it
    -- dereferences it as one - EXCEPTION_ACCESS_VIOLATION reading 0x70 inside
    -- UE4SS, the host gone sixty seconds after the guest joined, and the
    -- breadcrumb naming exactly this call. The same call with FName(...)
    -- returns cleanly. Every other FName parameter in this mod (OpenLevel,
    -- NetDriverDefinitions) was already wrapped; this one was missed.
    --
    -- The short form pc:ClientMessage(str) is gone too: what UE4SS does with
    -- a missing argument is the same question with a worse answer.
    local function attempt()
        DevBridge.phase("ClientMessage send")
        return pcall(function() pc:ClientMessage(str, msgTypeName(), 0.0) end)
    end

    local ok
    if proven then
        ok = attempt()
    else
        local ran, result = Safety.guard(SEND_OP, attempt)
        if not ran then
            if not warnedNoFn then
                warnedNoFn = true
                Log.warn("the host->guest channel is off after an earlier crash " ..
                         "(rt.safety). Money and the clock will not sync.")
            end
            return false
        end
        ok = result
        if ok then proven = true end
    end

    if ok then
        stats.sent = stats.sent + 1
    else
        stats.failed = stats.failed + 1
        if not warnedNoFn then
            warnedNoFn = true
            Log.error("=====================================================")
            Log.error(" PlayerController:ClientMessage would not accept a call.")
            Log.error(" That is the channel money, the clock and prop state")
            Log.error(" all ride on, so none of them will sync.")
            Log.error("")
            Log.error(" Find its real signature with:")
            Log.error("   rt.funcs PlayerController message")
            Log.error("=====================================================")
        end
    end
    return ok
end

--- Send to every connected guest. Server-side; a no-op anywhere else.
function Chan.broadcast(msgType, payload)
    if not UE.IsServer() then return 0 end
    local sent = 0
    for _, pc in ipairs(UE.GetAllPlayerControllers() or {}) do
        -- Only remote ones. ClientMessage on the host's own controller just
        -- runs locally and would have the host answering its own messages.
        if UE.alive(pc) and not UE.IsLocalController(pc) then
            if Chan.sendTo(pc, msgType, payload) then sent = sent + 1 end
        end
    end
    return sent
end

--------------------------------------------------------------------------
-- Receiving (guest)
--------------------------------------------------------------------------

--[[
    NOTHING IS APPLIED INSIDE THE HOOK. Both hooks below fire while the engine
    is dispatching network packets, and MEASURED in 1.7.0: applying host data
    right there - restyling an NPC's meshes and materials - raced an engine
    worker that was evaluating those same meshes. Four guest crashes, one
    instruction ("cmp byte ptr [rax+0x89]" on a pointer the worker read twice
    and got two different answers for), and in three of them the game thread
    was inside this mod's ClientMessage hook at the moment the worker died.

    So the hooks only queue. Chan.pump(), called from the mod's own tick on
    the game thread between engine frames, does the work.
]]
local inbox = {}            -- { msgType, fields } host -> guest messages
local actionInbox = {}      -- { pc, code, loc, rot } guest -> host presses
local INBOX_MAX = 256

local function dispatch(str)
    local msgType, fields = P2P.decode(str)
    -- Not ours. The engine and the game are both entitled to use
    -- ClientMessage for their own purposes and this hook sees all of it.
    if not msgType then return end

    stats.received = stats.received + 1
    if #inbox >= INBOX_MAX then table.remove(inbox, 1) end
    inbox[#inbox + 1] = { msgType, fields }
end

local function deliver(msgType, fields)
    local fn = handlers[msgType]
    if fn then
        Log.guard("rpc channel " .. msgType, fn, fields)
    else
        Log.debug("rpc channel: no handler for '%s'", msgType)
    end
end

--- Hook ClientMessage so a guest can read what the host sent.
---
--- Installed once, for everybody. On the host the hook simply never sees an
--- RT1 string, because the host does not send to itself.
function Chan.installReceiver()
    if hooked or hookFailed then return hooked end

    local ok = pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ClientMessage",
            function(_, sParam)
                DevBridge.phase("hook ClientMessage (rpcchan)")
                Log.guard("ClientMessage hook", function()
                    if sParam == nil then return end
                    local raw = sParam
                    -- UE4SS hands hook parameters over as wrappers; older
                    -- builds hand the value straight through. Accept both
                    -- rather than depending on which one this is.
                    if type(sParam) == "userdata" or type(sParam) == "table" then
                        local got, v = pcall(function() return sParam:get() end)
                        if got then raw = v end
                    end
                    local s = UE.ToStr(raw)
                    if type(s) == "string" and s ~= "" then dispatch(s) end
                end)
            end)
    end)

    if ok then
        hooked = true
        Log.info("rpc channel: listening on PlayerController::ClientMessage")
    else
        hookFailed = true
        Log.error("=====================================================")
        Log.error(" Could not hook PlayerController::ClientMessage, so this")
        Log.error(" machine cannot RECEIVE anything the host sends - money,")
        Log.error(" the clock and prop state will all stay local.")
        Log.error("=====================================================")
    end
    return hooked
end

--------------------------------------------------------------------------
-- Upstream: guest -> host, six floats
--------------------------------------------------------------------------

local upstreamHandler = nil
local upHooked, upHookFailed = false, false
local upWarned = false
local lastUpstream = 0

-- A keypress sends this many times, a few frames apart, because the RPC is
-- unreliable. The host collapses repeats inside COLLAPSE seconds so three
-- packets are one interaction.
local UPSTREAM_REPEATS = 3
local COLLAPSE = 0.35

-- Ours carry this Roll; nothing else does.
--
-- MEASURED in 1.7.0: the host counted two "interactions" on every join with
-- nobody pressing anything. A guest is briefly a SPECTATOR while it logs in,
-- and the engine's spectator code calls ServerSetSpectatorLocation by itself
-- - this game does have spectators after all, for about a second. Every one
-- of those was replayed as "the guest pressed use, here is where they were
-- looking", which runs a trace and calls into whatever Blueprint it hits.
--
-- A player's view never rolls, so the engine always sends Roll 0. FRotator
-- travels compressed to 16 bits per axis (0.0055 degrees), hence the margin.
local UPSTREAM_MARK = 77.25
local MARK_TOLERANCE = 0.05

-- Guest actions ride the same RPC with Roll = ACTION_BASE + code (1..ACTION_MAX),
-- far from both 0 and the legacy mark. Sent twice; repeats of the same action
-- from the same guest inside ACTION_COLLAPSE are one press.
local ACTION_BASE     = 100
local ACTION_MAX      = 40
local ACTION_REPEATS  = 2
local ACTION_COLLAPSE = 0.12
local actionHandler   = nil
local lastAction      = {}

--- Guest side: tell the host where we are looking.
--- Returns the number of sends that were accepted.
function Chan.sendUpstream(loc, rot)
    local pc = UE.GetPlayerController()
    if not UE.alive(pc) then return 0 end
    if not (loc and rot) then return 0 end

    local sent = 0
    for _ = 1, UPSTREAM_REPEATS do
        local ok = pcall(function()
            pc:ServerSetSpectatorLocation(
                { X = loc.X, Y = loc.Y, Z = loc.Z },
                UE.rotArg({ Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = UPSTREAM_MARK }))
        end)
        if ok then sent = sent + 1 end
    end

    if sent > 0 then
        stats.sent = stats.sent + sent
    else
        stats.failed = stats.failed + 1
        if not upWarned then
            upWarned = true
            Log.error("=====================================================")
            Log.error(" PlayerController:ServerSetSpectatorLocation would not")
            Log.error(" accept a call, so this guest cannot ask the host to")
            Log.error(" interact with anything. Picking things up will not work.")
            Log.error("")
            Log.error("   rt.funcs PlayerController spectator")
            Log.error("=====================================================")
        end
    end
    return sent
end

--- Host side: listen for it.
function Chan.installUpstreamReceiver()
    if upHooked or upHookFailed then return upHooked end

    local ok = pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ServerSetSpectatorLocation",
            function(ctx, locParam, rotParam)
                DevBridge.phase("hook ServerSetSpectatorLocation (rpcchan)")
                Log.guard("ServerSetSpectatorLocation hook", function()
                    if not (upstreamHandler or actionHandler) then return end

                    local function unwrap(p)
                        if p == nil then return nil end
                        if type(p) == "userdata" or type(p) == "table" then
                            local got, v = pcall(function() return p:get() end)
                            if got then return v end
                        end
                        return p
                    end

                    local loc, rot = unwrap(locParam), unwrap(rotParam)
                    if not (loc and rot) then return end

                    -- The engine's own spectator updates are not ours.
                    local roll = UE.field(rot, "Roll")
                    if type(roll) ~= "number" then return end

                    -- A guest action (guestinput.lua): Roll = ACTION_BASE + code.
                    local code = math.floor(roll - ACTION_BASE + 0.5)
                    if code >= 1 and code <= ACTION_MAX
                       and math.abs(roll - (ACTION_BASE + code)) <= MARK_TOLERANCE then
                        if not actionHandler then return end
                        local pc = unwrap(ctx)
                        -- Sent twice, unreliable: one press, per guest, per action.
                        local key = (UE.valid(pc) and pc:GetFullName() or "?") .. "#" .. code
                        local now = os.clock()
                        if (now - (lastAction[key] or -1)) < ACTION_COLLAPSE then return end
                        lastAction[key] = now
                        stats.received = stats.received + 1
                        -- Copied out of the hook's parameters: those are only
                        -- valid while the RPC is being processed.
                        local l, r = UE.vec(loc), UE.rot(rot)
                        if l and r and #actionInbox < INBOX_MAX then
                            actionInbox[#actionInbox + 1] = { pc = pc, code = code, loc = l, rot = r,
                                                              pcName = UE.valid(pc) and pc:GetFullName() or nil }
                        end
                        return
                    end

                    -- The pre-1.7.0 single "interact" packet (Roll 77.25) is no
                    -- longer acted on: it ran a trace and called into Blueprint
                    -- from inside this hook, and guestinput.lua replaces it.
                    if true then return end

                    -- Unreliable, sent in triplicate. One interaction.
                    local now = os.clock()
                    if (now - lastUpstream) < COLLAPSE then return end
                    lastUpstream = now

                    stats.received = stats.received + 1
                    upstreamHandler(unwrap(ctx), loc, rot)
                end)
            end)
    end)

    if ok then
        upHooked = true
        Log.info("rpc channel: listening for guest interactions on " ..
                 "PlayerController::ServerSetSpectatorLocation")
    else
        upHookFailed = true
        Log.error("could not hook ServerSetSpectatorLocation - guests will not " ..
                  "be able to interact with anything")
    end
    return upHooked
end

function Chan.onUpstream(fn) upstreamHandler = fn end

--- Guest side: one action (guestinput.lua) and the camera it was aimed from.
--- Returns the number of sends accepted.
function Chan.sendAction(code, loc, rot)
    local pc = UE.GetPlayerController()
    if not UE.alive(pc) or not (loc and rot) then return 0 end
    if code < 1 or code > ACTION_MAX then return 0 end
    local sent = 0
    -- Through UE.rotArg: a rotator built as { Pitch = .. } reaches the engine
    -- with pitch 0 on this build (ue.lua), and every action arrived on the
    -- host looking level until it did.
    local wire = UE.rotArg({ Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = ACTION_BASE + code })
    for _ = 1, ACTION_REPEATS do
        local ok = pcall(function()
            pc:ServerSetSpectatorLocation({ X = loc.X, Y = loc.Y, Z = loc.Z }, wire)
        end)
        if ok then sent = sent + 1 end
    end
    if sent > 0 then stats.sent = stats.sent + sent else stats.failed = stats.failed + 1 end
    return sent
end

--- Host side: function(pc, code, loc, rot) for each guest action.
function Chan.onAction(fn) actionHandler = fn end

--- Deliver everything the hooks queued. Game thread, from the mod's tick -
--- never from inside a hook (see the note above dispatch()).
function Chan.pump()
    if #inbox > 0 then
        local batch = inbox
        inbox = {}
        for _, m in ipairs(batch) do deliver(m[1], m[2]) end
    end
    if #actionInbox > 0 then
        local batch = actionInbox
        actionInbox = {}
        for _, a in ipairs(batch) do
            -- Re-resolve the controller by name: never hold an engine object
            -- across frames (PROJECT.md 5).
            local pc = nil
            if a.pcName then
                for _, c in ipairs(UE.GetAllPlayerControllers()) do
                    if UE.alive(c) and c:GetFullName() == a.pcName then pc = c break end
                end
            end
            if pc and actionHandler then actionHandler(pc, a.code, a.loc, a.rot) end
        end
    end
end

--------------------------------------------------------------------------

--- Register a handler. Same shape as P2P.on, so sync.lua can feed both.
function Chan.on(msgType, fn)
    handlers[msgType] = fn
end

function Chan.stats()
    return { sent = stats.sent, failed = stats.failed, received = stats.received,
             listening = hooked }
end

--- Is there anybody to send to? The gate sync.lua needs, and deliberately not
--- "is a transport configured" - this channel needs no configuration at all,
--- it needs a connection, and a connected guest IS the connection.
function Chan.isReady()
    if not UE.IsServer() then return hooked end
    for _, pc in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(pc) and not UE.IsLocalController(pc) then return true end
    end
    return false
end

return Chan
