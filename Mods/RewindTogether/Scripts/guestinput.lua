--[[
    Rewind Together - a guest's hands

    THE PROBLEM

    Only the host has authority, and this game's Blueprints have no server
    RPCs: a guest pressing a button runs the Blueprint on their own machine
    and the host never hears of it. Picking up a tape, stocking a shelf,
    ringing up a customer - none of it reaches the store everyone shares.

    WHAT THE GAME ACTUALLY DOES ON A PRESS (read off its Blueprints in 1.7.0,
    RetroRewind-decomp\bp\Player_Character.txt):

      RMB  (Secondary-Trigger, Started, event _23) -> Trace from Camera for
           Interaction: a box trace from the pawn's own Camera component, then
           the Interaction interface on whatever it hits. This is "use / pick up".
      LMB  (Main-Trigger, Started, _20) -> per tool in hand: the hand tool
           traces for physics (or, holding something, for interaction - place
           it); the move / skin / mesh tools run their own traces.
      E    (Use, _1) -> back to the hand tool.   V / B -> move / skin tool.
      K    (Sell, _0) -> sell what is in hand.

    WHAT THIS DOES

    The guest's client sends WHICH action and EXACTLY where its camera was
    (six numbers, over the engine RPC rpcchan.lua already borrows). The host
    puts the guest's server-side camera at that view and fires the same input
    event on the guest's own pawn - so `self` in all that Blueprint is the
    guest, items land in the GUEST's hands, and every result replicates to
    everyone the normal way.

    That leaves "the player" as the game finds it - GetPlayerController(0)
    and friends, which on a listen server always answer "the host". The
    native helper (native.lua) makes them answer "this guest" for exactly the
    duration of the call.

    The guest's own client still runs the press locally as well. That cannot
    be suppressed from here, and mostly it agrees with what the host then
    replicates. Where it does not, the host wins.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Native = require("native")
local Input  = require("input")

local GuestInput = {}

-- Code -> what the guest pressed and the event that handles it on the pawn.
local ACTIONS = {
    [1] = { key = "LeftMouseButton",  label = "primary (LMB)",
            event = "InpActEvt_Input_Main-Trigger_K2Node_EnhancedInputActionEvent_20" },
    [2] = { key = "RightMouseButton", label = "use / pick up (RMB)",
            event = "InpActEvt_Input_Secondary-Trigger_K2Node_EnhancedInputActionEvent_23" },
    [3] = { key = "E", label = "hand tool (E)",
            event = "InpActEvt_Input_Use_K2Node_EnhancedInputActionEvent_1" },
    [4] = { key = "V", label = "move tool (V)",
            event = "InpActEvt_Input_Tool-Move_K2Node_EnhancedInputActionEvent_2" },
    [5] = { key = "B", label = "skin tool (B)",
            event = "InpActEvt_Input_Tool-Skin_K2Node_EnhancedInputActionEvent_3" },
    [6] = { key = "K", label = "sell (K)",
            event = "InpActEvt_Input_Sell_K2Node_EnhancedInputActionEvent_0" },
}

local cfg = nil
local stats = { sent = 0, replayed = 0, failed = 0, redirected = 0 }
local announced = false
local warnedNoNative = false

--------------------------------------------------------------------------
-- Guest: notice a press, send it with the camera
--------------------------------------------------------------------------

local function onPress(code)
    if not UE.IsClient() then return end
    if cfg and cfg.ForwardGuestInteractions == false then return end
    local pc = UE.GetPlayerController()
    if not UE.alive(pc) or not UE.valid(UE.GetPawn()) then return end
    local cm = UE.TryGet(pc, "PlayerCameraManager")
    if not UE.valid(cm) then return end
    local loc, rot = nil, nil
    pcall(function()
        loc = UE.vec(cm:GetCameraLocation())
        rot = UE.rot(cm:GetCameraRotation())
    end)
    if not (loc and rot) then return end
    if Chan.sendAction(code, loc, rot) > 0 then
        stats.sent = stats.sent + 1
        Log.debug("sent %s to the host", ACTIONS[code].label)
    end
end

--- Bind the game's own keys. Polled on the game thread (input.lua); the
--- game reads the same keys itself, which is the point - one press, both.
function GuestInput.bindKeys()
    for code, a in pairs(ACTIONS) do
        Input.bind(a.key, "guest " .. a.label, function() onPress(code) end)
    end
end

--------------------------------------------------------------------------
-- Host: replay it on the guest's pawn
--------------------------------------------------------------------------

local tickStopped = {}

--- The host runs every guest pawn's Blueprint tick too, and that tick is a
--- look-at trace that calls PlayerIsLookingAt on whatever the GUEST's camera
--- points at - highlighting it, on the host's screen, and fighting the
--- host's own look-at. The game never checks IsLocallyControlled anywhere
--- (Player_Character.txt has no such call). A replay runs Look At Test
--- itself when it needs it.
function GuestInput.tickHost()
    if not UE.IsServer() then return end
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        if UE.alive(pc) and not UE.IsLocalController(pc) then
            local pawn = UE.TryGet(pc, "Pawn")
            if UE.alive(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C" then
                local key = pawn:GetFullName()
                if not tickStopped[key] then
                    tickStopped[key] = true
                    pcall(function() pawn:SetActorTickEnabled(false) end)
                end
            end
        end
    end
end

local function copyVec(v) v = UE.vec(v) return v and { X = v.X, Y = v.Y, Z = v.Z } end
local function copyRot(r) r = UE.rot(r) return r and { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end

local function replay(pc, code, loc, rot)
    local action = ACTIONS[code]
    if not action then return end
    if cfg and cfg.ForwardGuestInteractions == false then return end
    local pawn = UE.TryGet(pc, "Pawn")
    if not (UE.alive(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C") then return end

    if not Native.installRedirect() then
        if not warnedNoNative then
            warnedNoNative = true
            Log.warn("a guest pressed %s, but without RewindNative.dll the game would " ..
                     "hand the result to the host - ignored (rt.native)", action.label)
        end
        return
    end

    loc, rot = UE.vec(loc), UE.rot(rot)
    if not (loc and rot) then return end
    rot.Roll = 0.0

    -- Aim: the trace starts from the pawn's Camera component, so put that
    -- exactly where the guest's camera was, and put it back afterwards (its
    -- relative transform is the spring arm's to own).
    local cam = UE.TryGet(pawn, "Camera")
    local savedLoc, savedRot = nil, nil
    if UE.valid(cam) then
        savedLoc = copyVec(UE.TryGet(cam, "RelativeLocation"))
        savedRot = copyRot(UE.TryGet(cam, "RelativeRotation"))
        pcall(UE.withHit, function(hit) cam:K2_SetWorldLocation(loc, false, hit, false) end)
        pcall(UE.withHit, function(hit) cam:K2_SetWorldRotation(rot, false, hit, false) end)
    end
    pcall(function() pc:SetControlRotation(rot) end)

    -- Every HUD call the game makes goes to the GameMode's ONE widget, made
    -- with no owning player (FINDINGS 3f) - the host's. Replaying a guest's
    -- pick-up without this drew "RAIN WOMAN - Movie Drama" in the host's
    -- product-in-hand panel (measured). For the length of the replay the
    -- GameMode has no widget, so those calls find nothing and do nothing.
    local gm = UE.GetGameMode()
    local hostHud = nil
    if UE.valid(gm) then
        hostHud = UE.TryGet(gm, "UI Game Interface")
        if UE.valid(hostHud) then UE.TrySet(gm, "UI Game Interface", nil) end
    end

    local ok, swaps, err = Native.asPlayer(pc, function()
        pawn["Look At Test"](pawn)
        pawn[action.event](pawn, {}, 0.0, 0.0, nil)
        -- Do not leave an outline on the host's screen for what the guest
        -- was looking at.
        pcall(function() pawn["Trace from Camera Stop looking At"](pawn, true, true) end)
    end)

    if UE.valid(gm) and UE.valid(hostHud) then UE.TrySet(gm, "UI Game Interface", hostHud) end

    if UE.valid(cam) then
        if savedLoc then pcall(UE.withHit, function(hit) cam:K2_SetRelativeLocation(savedLoc, false, hit, false) end) end
        if savedRot then pcall(UE.withHit, function(hit) cam:K2_SetRelativeRotation(savedRot, false, hit, false) end) end
    end

    if ok then
        stats.replayed = stats.replayed + 1
        stats.redirected = stats.redirected + (swaps or 0)
    else
        stats.failed = stats.failed + 1
        Log.warn("a guest's %s failed on the host: %s", action.label, tostring(err))
    end
    if not announced and ok then
        announced = true
        Log.info("guest actions: %s from %s replayed on the host (%d player-0 answer(s) redirected)",
                 action.label, UE.PlayerNameOf(pc) or "a guest", swaps or 0)
    end
    Log.debug("replayed %s for %s: redirected %d", action.label, UE.PlayerNameOf(pc) or "?", swaps or 0)
end

function GuestInput.stats() return stats end

function GuestInput.reset()
    tickStopped = {}
    announced = false
end

function GuestInput.init(config)
    cfg = config
    Chan.onAction(function(pc, code, loc, rot) Log.guard("guest action", replay, pc, code, loc, rot) end)
    GuestInput.bindKeys()
end

return GuestInput
