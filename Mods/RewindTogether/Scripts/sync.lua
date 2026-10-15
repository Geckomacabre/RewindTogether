--[[
    Rewind Together - host-authoritative state sync

    The host owns the store simulation. Money, the day counter, XP and the
    rest live in Blueprint variables that were never marked Replicated, so the
    engine will not mirror them for us. We mirror them ourselves over the
    Steam P2P side-channel.

    Direction of travel is strictly one way: host -> guests. A guest never
    writes store state locally except to display what the host told it. That
    keeps a single source of truth and means a desync can always be resolved
    by trusting the host, which is also what the save file records.

    Guest actions travel the other way as *requests*, not results - see
    "interaction forwarding" below.
]]

local Log  = require("log")
local UE   = require("ue")
local P2P  = require("steamp2p")
local Chan = require("rpcchan")
local Net  = require("net")
local Hud  = require("hud")

local Sync = {}

local cfg = nil
local lastPush = 0
local announced = false
local warnedNoState = false
local mirrored = {}          -- label -> value, what a guest last heard
local applied  = {}          -- label -> value, what a guest last acted on
local guestClockStopped = false
local lastReassert = 0
-- The HUD is redrawn from the host's numbers at least this often even when
-- nothing changed. MEASURED in 1.7.0: a local GameMode built a few seconds
-- AFTER the first state message starts its own new game - $550, Monday 20:00
-- - and pushes those into the HUD itself. Pushing only on change meant the
-- host's numbers, already "applied", never went back on screen.
local REASSERT = 3.0
local discovery = {
    interactionFn = nil,     -- name of the "do the interaction" UFunction
    searched      = false,
}

--------------------------------------------------------------------------
-- What gets mirrored
--------------------------------------------------------------------------
--[[
    READ OFF THE GAME, NOT GUESSED. Until 1.7.0 this list lived in config.lua
    and named "Money" and "Experience" on the GameInstance and "Day" and
    "DayOfWeek" on the GameMode - none of which exist. 1.7.0 dumped the game's
    classes (UE4SS GenerateSDK, kept outside the repo) and found:

      Core_Gamemode_C   int64 Money (cents), int32 Level, Experience,
                        Lifetime Experience, Store Value
      WeatherSystem_C   int32 Day, Hour, Minute, Year; enums Season, DayTime,
                        Current Weather, Day of the week

    WeatherSystem_C is a level actor with its own one-minute timer, so a guest
    already HAS one - running its own clock from its own defaults. That is the
    "guest's world is at night while the host's reads 8:00 AM" in PROJECT.md
    10: two clocks, not a missing one. The guest's is stopped and driven from
    the host's instead.

    It moved into code because it is not a user setting - a wrong entry can
    only ever make sync worse - and because the installer keeps an old
    config.lua, which would have kept the wrong names forever.
]]
local STATE = {
    { object = "gamemode", property = "Money",               label = "Money" },
    { object = "gamemode", property = "Level",               label = "Level" },
    { object = "gamemode", property = "Experience",          label = "XP" },
    { object = "gamemode", property = "Lifetime Experience", label = "Lifetime XP" },
    { object = "gamemode", property = "Store Value",         label = "Store value" },
    { object = "weather",  property = "Day",                 label = "Day" },
    { object = "weather",  property = "Hour",                label = "Hour" },
    { object = "weather",  property = "Minute",              label = "Minute" },
    { object = "weather",  property = "Day of the week",     label = "Weekday" },
    { object = "weather",  property = "Season",              label = "Season" },
    { object = "weather",  property = "DayTime",             label = "Time of day" },
    { object = "weather",  property = "Current Weather",     label = "Weather" },
    { object = "weather",  property = "Year",                label = "Year" },
    { object = "weather",  property = "Days Passed",         label = "Days passed" },
    { object = "weather",  property = "Tomorrow Weather",    label = "Tomorrow" },
    { object = "weather",  property = "Snow Accumulation",   label = "Snow" },
    { object = "weather",  property = "Cloud Density",       label = "Clouds" },
}

local function resolveObject(kind)
    if kind == "gamemode" then
        local gm = UE.GetGameMode()
        -- The main menu's GameMode is a GameModeBase too, and has none of this.
        if UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C" then return gm end
        return nil
    end
    if kind == "weather" then
        local w = UE.findFirst("WeatherSystem_C")
        if UE.alive(w) then return w end
        return nil
    end
    return nil
end

--------------------------------------------------------------------------
-- Host: publish state
--------------------------------------------------------------------------

--- Read every value that actually exists right now.
local function collectState()
    local payload, found = {}, 0
    local objs = {}
    for i, entry in ipairs(STATE) do
        local obj = objs[entry.object]
        if obj == nil then
            obj = resolveObject(entry.object) or false
            objs[entry.object] = obj
        end
        if obj then
            local v = UE.TryGet(obj, entry.property)
            if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                -- Key by index so the guest can map it back to the same row.
                payload["v" .. i] = tostring(v)
                found = found + 1
            end
        end
    end
    return payload, found
end

--- Called on the host every tick; rate-limits itself internally.
---
--- Sends over the engine's own connection (rpcchan). The gate is "is there a
--- guest", not "is a transport configured": requiring a Steam peer is what
--- kept this returning on its first line for five versions.
function Sync.tickHost(now)
    if not cfg then return end

    local haveRpc   = Chan.isReady()
    local haveSteam = P2P.isReady() and Net.peerCount() > 0
    if not (haveRpc or haveSteam) then return end

    local interval = 1.0 / math.max(1, cfg.StateSyncHz or 4)
    if now - lastPush < interval then return end
    lastPush = now

    local payload, found = collectState()
    if found == 0 then
        if not warnedNoState then
            warnedNoState = true
            Log.warn("there is a guest to send to and no store state to send - " ..
                     "no Core_Gamemode_C or WeatherSystem_C in this world")
        end
        return
    end
    warnedNoState = false

    if haveRpc   then Chan.broadcast("state", payload) end
    if haveSteam then P2P.broadcast(Net.peerIds(), "state", payload, false) end

    if not announced then
        announced = true
        Log.info("state sync is running: %d value(s) to the guest over the " ..
                 "game's own connection", found)
    end
end

--------------------------------------------------------------------------
-- Guest: receive state
--------------------------------------------------------------------------

local function changed(label, value)
    if applied[label] == value then return false end
    applied[label] = value
    return true
end

--- Stop the guest's own WeatherSystem clock, once. It runs on a one-minute
--- timer started at BeginPlay; left alone it drifts away from the host's
--- between messages and wins every race at a minute boundary.
local clockReported = false
local function stopGuestClock(weather)
    if guestClockStopped then return end
    -- Re-stopped on every reassert: a local GameMode starting its own new day
    -- can start the timer again.
    local ok = UE.TryCall(weather, "Stop or pause Timer - Add one minute")
    guestClockStopped = true
    if not clockReported then
        clockReported = true
        Log.info("guest clock: %s - the host's clock drives it from now on",
                 ok and "local timer stopped" or "could not stop the local timer")
    end
end

local function onState(fields)
    local now = os.clock()
    if now - lastReassert > REASSERT then
        lastReassert = now
        -- Forget everything but the weather: restarting the rain particles
        -- every few seconds would be visible, and nothing else redraws it.
        applied = { Weather = applied.Weather }
        guestClockStopped = false
    end
    local weather = nil
    local gm = UE.GetGameMode()   -- a local GameMode, if localgm.lua built one
    local values = {}

    for i, entry in ipairs(STATE) do
        local raw = fields["v" .. i]
        if raw ~= nil then
            local value = tonumber(raw)
            if value == nil then value = raw end
            mirrored[entry.label] = value
            values[entry.label] = value

            if entry.object == "weather" then
                if weather == nil then weather = resolveObject("weather") or false end
                if weather then UE.TrySet(weather, entry.property, value) end
            elseif entry.object == "gamemode" and UE.valid(gm)
                   and UE.ClassNameOf(gm) == "Core_Gamemode_C" then
                UE.TrySet(gm, entry.property, value)
            end
        end
    end

    if weather then stopGuestClock(weather) end

    -- The HUD and the lighting are driven only on change: these are Blueprint
    -- events with visible side effects, not property writes.
    local h, m = values["Hour"], values["Minute"]
    if h and m then
        local hc, mc = changed("Hour", h), changed("Minute", m)
        if hc or mc then
            Hud.setTime(h, m)
            -- No "Update Lighting" here any more: worldsync.lua copies the
            -- lights the HOST's Update Lighting produced, and the guest's own
            -- would fight it - its fill-light lists are empty (worldsync.lua).
        end
    end
    if values["Weekday"] and changed("Weekday", values["Weekday"]) then
        Hud.setWeekday(values["Weekday"])
    end
    if values["Weather"] and changed("Weather", values["Weather"]) and weather then
        UE.TryCall(weather, "Call Niagara System For Weather")
    end
    if values["Money"] and changed("Money", values["Money"]) then
        Hud.setMoney(values["Money"])
    end
    if values["XP"] and changed("XP", values["XP"]) then
        Hud.setXP(values["XP"])
    end
end

--- Back to single player: forget what was applied, so the next session
--- re-applies everything to a fresh world.
function Sync.reset()
    applied, mirrored = {}, {}
    guestClockStopped = false
    clockReported = false
    announced = false
end

--- What the guest last heard from the host, for the overlay.
function Sync.mirroredState()
    return mirrored
end

--------------------------------------------------------------------------
-- Interaction forwarding
--------------------------------------------------------------------------
--[[
    A guest pressing "use" runs the interaction Blueprint on their own machine
    only, which would change nothing for anyone else and desync their view.

    Rather than trying to replicate the *result* of an interaction, we forward
    the *intent*: the guest sends the host the camera position and direction
    they interacted from, and the host re-runs the same trace with authority.
    Whatever the host hits is then interacted with for real, and the outcome
    reaches the guest through normal actor replication.

    This is deliberately conservative. It cannot desync the save, because the
    host performs every state change exactly as it would in single player.
]]

--- Look for the Blueprint function that performs an interaction.
--- Names here are the ones this build uses; the search is logged so an
--- unexpected build can be diagnosed from RewindTogether.log.
local INTERACTION_FN_CANDIDATES = {
    "Accept Interaction",
    "AcceptInteraction",
    "Interaction",
    "Interact",
    "Use",
}

local function findInteractionFunction(actor)
    for _, name in ipairs(INTERACTION_FN_CANDIDATES) do
        local ok, fn = pcall(function() return actor[name] end)
        if ok and fn ~= nil then return name end
    end
    return nil
end

--- Guest side: ask the host to interact on our behalf.
---
--- WIRED TO A KEYBIND, because nothing else can reach it. Until 1.5.2 this
--- function had zero callers - it was written, documented, switched on by
--- default in Config.ForwardGuestInteractions, and never once invoked. That is
--- the same shape of bug as Net.addPeer in 1.5.0, and it had the same effect:
--- a feature that reads as implemented and has never run.
---
--- Why a keybind rather than a hook on the game's own interact function: we do
--- not know that function's name. The self test reports zero matching
--- functions on Core_Player_Controller_C, because the candidate list is
--- guesswork. rt.funcs reads the real table off the running game; until
--- somebody has run it, a key the player presses is the only trigger we can
--- rely on.
---
--- The guest's own client still runs its local interaction as well. That is
--- unavoidable - we cannot suppress the game's input - and mostly harmless:
--- their local result is cosmetic and gets overwritten by the host's
--- authoritative one arriving through normal replication.
function Sync.requestInteract()
    if not UE.IsClient() then return false end

    local pc = UE.GetPlayerController()
    if not UE.valid(pc) then return false end

    local loc, rot
    local ok = pcall(function()
        loc, rot = pc:GetPlayerViewPoint()
    end)
    if not ok or not loc then
        -- Fall back to the pawn's transform.
        local pawn = UE.GetPawn()
        if not UE.valid(pawn) then return false end
        pcall(function()
            loc = pawn:K2_GetActorLocation()
            rot = pawn:K2_GetActorRotation()
        end)
    end
    loc, rot = UE.vec(loc), UE.rot(rot)
    if not loc or not rot then return false end

    -- Over the game's own connection. No Steam ID needed from anybody, which
    -- is the whole reason this path never worked before: it required both
    -- players to have typed the other's ID into config.lua, and it refused
    -- outright when they had not.
    if Chan.sendUpstream(loc, rot) > 0 then
        Log.debug("forwarded an interaction to the host")
        return true
    end

    -- The Steam channel as a fallback, on the vanishing chance it works on
    -- some build where the RPC does not.
    local host = P2P.isReady() and Net.hostId() or nil
    if host then
        P2P.send(host, "interact", {
            x  = ("%.1f"):format(loc.X),
            y  = ("%.1f"):format(loc.Y),
            z  = ("%.1f"):format(loc.Z),
            p  = ("%.2f"):format(rot.Pitch),
            yw = ("%.2f"):format(rot.Yaw),
            r  = ("%.2f"):format(rot.Roll),
        }, true)
        return true
    end
    return false
end

--- Host side: replay a guest's interaction with authority.
local function performInteractAt(x, y, z, pitch, yaw, who)
    if not UE.IsServer() then return end

    local ksl, w = UE.GetKismetSystemLibrary(), UE.GetWorld()
    if not (UE.valid(ksl) and UE.valid(w)) then return end

    if not (x and y and z and pitch and yaw) then return end
    local fromId = who

    -- Rebuild the guest's look direction.
    local rad = math.pi / 180.0
    local cp, sp = math.cos(pitch * rad), math.sin(pitch * rad)
    local cy, sy = math.cos(yaw * rad),   math.sin(yaw * rad)
    local REACH = 250.0
    local ex = x + (cp * cy) * REACH
    local ey = y + (cp * sy) * REACH
    local ez = z + (sp)      * REACH

    local hit = nil
    local ok = pcall(function()
        local outHit = {}
        local didHit = ksl:LineTraceSingle(
            w,
            { X = x,  Y = y,  Z = z  },
            { X = ex, Y = ey, Z = ez },
            0,                     -- ETraceTypeQuery::TraceTypeQuery1 (Visibility)
            false, {}, 0,          -- complex, ignore list, draw debug
            outHit, true, {}, {}, 0
        )
        if didHit and outHit.HitActor then hit = outHit.HitActor end
    end)

    if not ok or not UE.valid(hit) then
        Log.debug("guest %s interaction hit nothing", tostring(fromId))
        return
    end

    if not discovery.searched then
        discovery.interactionFn = findInteractionFunction(hit)
        discovery.searched = true
        if discovery.interactionFn then
            Log.info("interaction function resolved: %s", discovery.interactionFn)
        else
            -- Loud, and with the command that answers it. The candidate list
            -- is guesswork; the running game holds the real names.
            Log.error("=====================================================")
            Log.error(" A guest interacted, the trace hit %s,", UE.ClassNameOf(hit))
            Log.error(" and none of the interaction function names this mod")
            Log.error(" guesses at exist on it - so nothing happened.")
            Log.error("")
            Log.error(" Find the real name with:")
            Log.error("   rt.funcs %s", UE.ClassNameOf(hit))
            Log.error("   rt.funcs %s interact", UE.ClassNameOf(hit))
            Log.error("")
            Log.error(" Then add it to INTERACTION_FN_CANDIDATES in sync.lua.")
            Log.error("=====================================================")
        end
    end

    local fnName = discovery.interactionFn
    if not fnName then return end

    -- Interact as though the host were doing it. The host's pawn is the
    -- instigator the Blueprint expects; store state therefore changes exactly
    -- as it would in single player.
    -- No arguments. 1.6.x passed the host's pawn first, but the interface
    -- this game uses is Interaction(bool& Accept Interaction) - read off the
    -- class in 1.7.0 - and handing a UObject to a bool out-parameter is a
    -- marshalling step UE4SS may fault on natively rather than refuse.
    UE.TryCall(hit, fnName)
    Log.debug("replayed guest interaction on %s", UE.ClassNameOf(hit))
end

--- Arriving over the Steam channel: string fields.
local function onInteract(fields, fromId)
    performInteractAt(tonumber(fields.x), tonumber(fields.y), tonumber(fields.z),
                      tonumber(fields.p), tonumber(fields.yw), fromId)
end

--- Arriving over the game's own connection: engine structs, straight off the
--- RPC. Read defensively - these come out of a hook parameter, not out of a
--- string this mod wrote, so nothing about their shape is guaranteed.
local function onUpstreamInteract(pc, loc, rot)
    local x, y, z, pitch, yaw
    -- Through UE.vec/UE.rot: the engine hands FRotator back with "pitch"
    -- in lower case on this build, and rot.Pitch was simply nil.
    local v, r = UE.vec(loc), UE.rot(rot)
    if v then x, y, z = v.X, v.Y, v.Z end
    if r then pitch, yaw = r.Pitch, r.Yaw end
    if not (x and pitch) then
        Log.debug("upstream interaction arrived with an unreadable transform")
        return
    end
    performInteractAt(x, y, z, pitch, yaw,
                      UE.valid(pc) and UE.PlayerNameOf(pc) or "a guest")
end

--------------------------------------------------------------------------

function Sync.init(config)
    cfg = config

    -- Both channels feed the same handler, so a message looks identical
    -- whichever one carried it.
    local state = function(fields) Log.guard("onState", onState, fields) end
    P2P.on("state", state)
    Chan.on("state", state)

    -- Checked with ~= false so a config.lua predating the option still gets
    -- it. A guest who cannot interact with anything is not a working co-op
    -- mod, so this is on unless somebody deliberately turned it off.
    if config.ForwardGuestInteractions ~= false then
        P2P.on("interact", onInteract)
        Chan.onUpstream(onUpstreamInteract)
    end
end

return Sync
