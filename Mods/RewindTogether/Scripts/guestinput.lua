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
local SkinSync = require("skinsync")
local Hud    = require("hud")
local Replication = require("replication")
local TalkSync = require("talksync")

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
    -- Not a key of ours: the guest's own game left the till (its W is the
    -- machine's input binding, not the pawn's). Sent from tickGuest.
    [7] = { label = "leave the till", special = "leaveTill" },
    -- Not a key either: what the guest picked in the skin picker. The six
    -- floats carry the object's place, the tool and the choice.
    [8] = { label = "choose a skin", special = "skinChoice" },
    -- Space closes the cash drawer - the CheckOut's own input binding, like
    -- the till's W. Space is also jump, so it is only sent from the till.
    [9] = { key = "SpaceBar", label = "close the drawer (Space)", special = "closeDrawer",
            onlyAtTill = true },
    -- Not a key: the guest turned the furniture it carries (the mouse wheel
    -- turns the guest's own placement preview, build mode below). The six
    -- floats carry the new rotation.
    [10] = { label = "turn the furniture", special = "rotateGhost" },
    -- Not a key: the answer the guest clicked in a conversation (talksync.lua).
    -- Pitch carries the answer type.
    [11] = { label = "answer a conversation", special = "talkAnswer" },
}

local cfg = nil
local stats = { sent = 0, replayed = 0, failed = 0, redirected = 0, toolFixes = 0 }
local announced = false
local warnedNoNative = false
local lastLocalPress = -1e9   -- guest: when this player last pressed one of ours
local tillUser = nil          -- host: the guest controller at the till (the till, below)
local freeTill                -- host: let go of it (defined with the till)
local sendDrawer              -- host: the cash drawer, to the guests (defined with the till)
local sendBill                -- host: the register's screen, to the guests (defined with the till)
local sendGhost               -- host: a guest's placement preview, to that guest (build mode, below)
local rotateGhost             -- host: a guest turned the furniture it carries (build mode, below)
local hintsClearAt = nil      -- host: when to wipe the till's hints off the host's HUD

--- The till's hints ("W leave the register", the drawer's) are drawn on the
--- GameMode's one HUD - the host's - by steps that run after a guest's action
--- has returned: the drawer's open and close animations finish a moment
--- later on the host (CheckOut "Timeline Checkout Money Animation"). MEASURED:
--- the host's HUD kept "LEAVE THE REGISTER" after a guest's till session.
--- The setter itself cannot be called from Lua here (an array out-parameter
--- before another parameter); the host pawn's own Init Cursor and Interface
--- clears the box the game's way (protected hints included, @14452), and the
--- host's own look-at puts back whatever the host really looks at.
local function clearHostHints()
    local pawn = UE.GetPawn()
    if UE.alive(pawn) then UE.TryCall(pawn, "Init Cursor and Interface") end
end

--------------------------------------------------------------------------
-- Guest: notice a press, send it with the camera
--------------------------------------------------------------------------

--[[
    THE SKIN AND MESH TOOLS on a guest (B, then a click on a wall or a
    shelf). The click runs the pawn's own trace, which calls the object's
    Init Mesh Flow / Init Skin Flow, which asks GetGameMode for the HUD to
    open the picker on (bp/Wall.txt @1303, @2140). A guest has no GameMode:
    the picker never opened, on either screen (the host's replay hides the
    host's HUD from the game on purpose). The HUD stand-in (hud.lua) answers
    exactly that question, but only for the HUD library's own frames - so
    for the length of one call it answers the object's class instead, and the
    pawn's trace is run again under it. The picker opens on the guest's
    screen; what the guest picks goes to the host (tickGuest, action 8).
]]
local flowClassFor = {}   -- object class path -> path of the class whose graph has its skin flows

local function classPath(cls)
    local full = nil
    pcall(function() full = cls:GetFullName() end)
    return type(full) == "string" and full:match("^%S+%s+(.+)$") or nil
end

local function flowClass(actor)
    local cls = nil
    pcall(function() cls = actor:GetClass() end)
    local start = classPath(cls)
    if start and flowClassFor[start] then return UE.findObject(flowClassFor[start]) end
    for _ = 1, 16 do
        local path = classPath(cls)
        if not path then return nil end
        if UE.valid(StaticFindObject(path .. ":Init Skin Flow")) then
            if start then flowClassFor[start] = path end
            return cls
        end
        local up = nil
        pcall(function() up = cls:GetSuperStruct() end)
        cls = up
    end
    return nil
end

local function openSkinPicker()
    local pawn = UE.GetPawn()
    if not UE.alive(pawn) then return end
    local tool = UE.TryGet(pawn, "Current Tool in hand")
    if tool ~= 2 and tool ~= 3 then return end
    local target = UE.TryGet(pawn, "ref Object Look At")
    if not (UE.alive(target) and UE.valid(UE.TryGet(target, "AC_MeshSkin"))) then return end
    local library = flowClass(target)
    if not library then return end
    local trace = tool == 2 and "Trace from Camera for Mesh Tool" or "Trace from Camera for Skin Tool"
    local reach = (tonumber(UE.TryGet(pawn, "Skin Tool Trace - Distance")) or 400) + 50
    if Hud.withStandInFor(library, function()
        local accepted = {}
        pawn[trace](pawn, { X = 1.0, Y = 2.0, Z = 2.0 }, reach, 0, accepted)
        UE.releaseOut(accepted)
    end) then
        Log.debug("skin picker opened for %s", UE.ClassNameOf(target))
    end
end

local function onPress(code)
    if not UE.IsClient() then return end
    if cfg and cfg.ForwardGuestInteractions == false then return end
    -- A conversation is up (talksync.lua): the mouse is answering it.
    if TalkSync.guestTalking() then return end
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
    lastLocalPress = os.clock()
    if Chan.sendAction(code, loc, rot) > 0 then
        stats.sent = stats.sent + 1
        Log.debug("sent %s to the host", ACTIONS[code].label)
    end
    if code == 1 then openSkinPicker() end
end

--- Bind the game's own keys. Polled on the game thread (input.lua); the
--- game reads the same keys itself, which is the point - one press, both.
function GuestInput.bindKeys()
    for code, a in pairs(ACTIONS) do
        if a.key then
            Input.bind(a.key, "guest " .. a.label, function()
                if a.onlyAtTill and not GuestInput.atTill() then return end
                onPress(code)
            end)
        end
    end
end

--------------------------------------------------------------------------
-- Host: replay it on the guest's pawn
--------------------------------------------------------------------------

local tickStopped = {}
local toolSent = {}        -- guest controller name -> { tool, at }
local TOOL_RESEND = 2.0

--- A guest's placement preview is the GhostMesh actor of the guest's pawn ON
--- THE HOST - the one MovingBox Pickup sets up and Throw reads the placement
--- from. Left alone it drew a red standee and an arrow on the HOST's screen
--- wherever the guest was aiming (measured). Hidden as an actor: the
--- placement test reads the GhostMesh component's own bHiddenInGame
--- (bp/GhostMesh.txt @0), which this leaves alone. The NavCollisionZone child
--- actor is the hazard-stripe blocker that comes with it.
local function hideGhost(pawn)
    local ghost = UE.TryGet(pawn, "Ghost")
    if not UE.alive(ghost) then return end
    if UE.TryGet(ghost, "bHidden") ~= true then
        pcall(function() ghost:SetActorHiddenInGame(true) end)
    end
    -- A property: UChildActorComponent has no reflected GetChildActor (header dump).
    local child = UE.TryGet(UE.TryGet(ghost, "NavCollisionZone"), "ChildActor")
    if UE.alive(child) and UE.TryGet(child, "bHidden") ~= true then
        pcall(function() child:SetActorHiddenInGame(true) end)
    end
end

--- Which tool a guest holds is decided on the host: placing or selling a box
--- puts the guest's pawn back on the hand tool there (MovingBox Throw @3325,
--- @3932). The guest's own copy never hears of it - "Current Tool in hand"
--- is not replicated - and kept showing the move tool (measured). Each
--- guest is told its own tool; the guest adopts it (onMe below).
---
--- The same message says whether the host holds the till for this guest.
--- MEASURED: the host put a guest at the register while the guest's own
--- game did not follow - a customer queuing between the guest and the
--- register took the guest's own click, while the host's entry (below, the
--- till) went by where the guest stood and looked. The guest's game follows
--- the host's word either way (onMe).
local function sendTool(pc, pawn, now)
    local tool = UE.TryGet(pawn, "Current Tool in hand")
    if type(tool) ~= "number" then return end
    local key = pc:GetFullName()
    local till = (tillUser == key) and 1 or 0
    local last = toolSent[key]
    if last and last.tool == tool and last.till == till and (now - last.at) < TOOL_RESEND then return end
    if Chan.sendTo(pc, "me", { tool = tostring(tool), till = tostring(till) }) then
        toolSent[key] = { tool = tool, till = till, at = now }
    end
end

--- The host runs every guest pawn's Blueprint tick too, and that tick is a
--- look-at trace that calls PlayerIsLookingAt on whatever the GUEST's camera
--- points at - highlighting it, on the host's screen, and fighting the
--- host's own look-at. The game never checks IsLocallyControlled anywhere
--- (Player_Character.txt has no such call). A replay runs Look At Test
--- itself when it needs it.
function GuestInput.tickHost()
    if not UE.IsServer() then return end
    local now = os.clock()
    local tillUserHere = false
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        if UE.alive(pc) and not UE.IsLocalController(pc) then
            if tillUser and pc:GetFullName() == tillUser then tillUserHere = true end
            local pawn = UE.TryGet(pc, "Pawn")
            if UE.alive(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C" then
                local key = pawn:GetFullName()
                if not tickStopped[key] then
                    tickStopped[key] = true
                    pcall(function() pawn:SetActorTickEnabled(false) end)
                end
                hideGhost(pawn)
                sendTool(pc, pawn, now)
                sendGhost(pc, pawn, now)
            end
        end
    end
    -- A guest who left the game while ringing up customers.
    if tillUser and not tillUserHere then freeTill() end
    sendDrawer(now)
    sendBill(now)
end

--- Guest: the host says which tool this player's pawn holds there. Not in
--- the second after a press of our own: that answer may predate it.
local function onMe(fields)
    if not UE.IsClient() then return end
    local tool = tonumber(fields.tool)
    if not tool or (os.clock() - lastLocalPress) < 1.0 then return end
    local pawn = UE.GetPawn()
    if not UE.alive(pawn) then return end
    local mine = UE.TryGet(pawn, "Current Tool in hand")
    if type(mine) == "number" and mine ~= tool then
        -- The pawn's own event: the tool, the toolbar (where a HUD can be
        -- reached) and the design-mode material parameter, as on a key press.
        if UE.TryCall(pawn, "Change Tool", tool) then stats.toolFixes = stats.toolFixes + 1 end
    end
    -- The till: this game's own register follows the host's (sendTool). The
    -- register's own event, so the camera glides and W / Space are bound
    -- here exactly as when this player clicks it.
    local till = fields.till
    local m = UE.findFirst("MembershipMachine_C")
    if (till == "1" or till == "0") and UE.alive(m)
       and UE.TryGet(m, "Player is currently moving") ~= true then
        local on = UE.TryGet(m, "Player In Checkout Mode") == true
        if till == "1" and not on then
            UE.TryCall(m, "Toggle Checkout Mode", true)
        elseif till == "0" and on then
            UE.TryCall(m, "Toggle Checkout Mode", false)
        end
    end
end

local function copyVec(v) v = UE.vec(v) return v and { X = v.X, Y = v.Y, Z = v.Z } end
-- UE.rotArg, not { Pitch = .. }: the engine reads that as pitch 0 (ue.lua).
local function copyRot(r) return UE.rotArg(r) end

--- Run fn AS this guest: GetPlayerController(0) and friends answer with the
--- guest (native.lua), and the host's HUD is out of the game's reach.
---
--- Every HUD call the game makes goes to the GameMode's ONE widget, made
--- with no owning player (FINDINGS 3f) - the host's. Replaying a guest's
--- pick-up without this drew "RAIN WOMAN - Movie Drama" in the host's
--- product-in-hand panel (measured). For the length of the call the GameMode
--- has no widget, so those calls find nothing and do nothing.
---
--- The store's money and XP are the host's too, and with the widget hidden,
--- Change Money / Change XP write the number and skip the HUD
--- (bp/Core_Gamemode.txt Change Money @403, @430). MEASURED: a guest sold a
--- standee, the money went up $10.00, and the host's HUD kept the old total
--- while the guest's showed the new one. So afterwards the host's widget is
--- given what changed, through the same two setters the GameMode calls.
local function asGuest(pc, fn)
    local gm = UE.GetGameMode()
    local hostHud, money0, xp0 = nil, nil, nil
    if UE.valid(gm) then
        hostHud = UE.TryGet(gm, "UI Game Interface")
        if UE.valid(hostHud) then UE.TrySet(gm, "UI Game Interface", nil) end
        money0, xp0 = UE.TryGet(gm, "Money"), UE.TryGet(gm, "Experience")
    end

    local ok, swaps, err = Native.asPlayer(pc, fn)

    if UE.valid(gm) and UE.valid(hostHud) then
        UE.TrySet(gm, "UI Game Interface", hostHud)
        local money1, xp1 = UE.TryGet(gm, "Money"), UE.TryGet(gm, "Experience")
        if type(money1) == "number" and type(money0) == "number" and money1 ~= money0 then
            UE.TryCall(hostHud, "Change Money Value", money1 - money0, money1)
        end
        if type(xp1) == "number" and type(xp0) == "number" and xp1 ~= xp0 then
            UE.TryCall(hostHud, "Change XP Value", xp1 - xp0, xp1)
        end
    end
    return ok, swaps, err
end

--- The end-of-day summary is up on the host: Core_Gamemode "End of the day"
--- makes it and keeps it in "End of Day Interface" (bp/Core_Gamemode.txt
--- @8475) until the next day closes it. The store is shut by then, and about
--- four seconds in the game makes the front door usable again (OpenSign's
--- delayed "Store Open Status change"), so a guest shutting it would start a
--- SECOND end of the day on the host: another +100 XP and a second summary
--- over the first. Guests wait for the next day.
local function dayIsOver()
    local gm = UE.GetGameMode()
    local w = UE.valid(gm) and UE.TryGet(gm, "End of Day Interface") or nil
    if not UE.valid(w) then return false end
    local ok, on = pcall(function() return w:IsInViewport() end)
    return ok and on == true
end

--------------------------------------------------------------------------
-- The till (MembershipMachine_C)
--------------------------------------------------------------------------
--[[
    A player rings a customer up at the register (bp/MembershipMachine.txt):
    a click on it runs its Interaction, which asks "Can Player use the
    machine?" and then Toggle Checkout Mode(true) - player 0 goes into
    checkout mode, its camera glides to the register's PlayerView on a
    timeline, and from then on every click is the pawn's own trace from that
    view: scan each product, take change from the drawer, close it. W leaves.

    For a guest, replaying the click was not enough, for three reasons read
    off the Blueprint:
      1. "Can Player use the machine?" reads player 0's "Walking Mapping
         Context is Enable", which only a LOCAL controller ever sets (it needs
         a local player subsystem). Inside a guest's replay, player 0 is the
         guest's remote controller: false, so the click did nothing.
      2. The glide is a timeline whose update moves GetPlayerPawn(0) every
         frame - after the replay has returned and player 0 is the host
         again. It would drag the HOST into the register.
      3. W is the machine's own input binding (EnableInput), not the pawn's,
         so the host never heard a guest leave: the guest's pawn would stay in
         MOVE_None with collision off there, and the till taken.

    So the host enters checkout mode for a guest who clicks the register from
    up close (a click on a product on the counter does the same in the
    game), inside a guest window like any replay; stops the glide before it
    runs a frame - the guest's own game glides the guest's own camera - and
    runs the glide's finishing step as the guest. When the guest's own game
    leaves checkout mode, the guest sends action 7 and the host leaves it the
    same way.
]]
local TILL       = "MembershipMachine_C"
local TILL_REACH = 300.0     -- cm from the guest's camera to the register
local TILL_AIM   = 0.85      -- cos of the widest angle that still counts as "at it"

local function tillMachine()
    local m = UE.findFirst(TILL)
    if UE.alive(m) then return m end
    return nil
end

--- Is this camera close to the register and looking at it?
local function aimsAtTill(machine, loc, rot)
    local at = nil
    pcall(function() at = UE.vec(machine:K2_GetActorLocation()) end)
    if not at then return false end
    local dx, dy, dz = at.X - loc.X, at.Y - loc.Y, at.Z - loc.Z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d > TILL_REACH or d < 1 then return false end
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local fx, fy, fz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
    return (fx * dx + fy * dy + fz * dz) / d >= TILL_AIM
end

local function gliding(machine, timeline)
    local tl = UE.TryGet(machine, timeline)
    local on = false
    if UE.valid(tl) then pcall(function() on = tl:IsPlaying() end) end
    return on == true
end

--- Stop one of the register's glides before it moves anybody, and run its
--- finishing step as the guest (it clears "Player is currently moving",
--- without which the till never lets anyone leave - @10123).
local function settleGlide(pc, machine, timeline, finished)
    local tl = UE.TryGet(machine, timeline)
    if not UE.valid(tl) then return end
    pcall(function() tl:Stop() end)
    asGuest(pc, function() machine[finished](machine) end)
end

local function enterTill(pc, machine)
    asGuest(pc, function() machine["Toggle Checkout Mode"](machine, true) end)
    if UE.TryGet(machine, "Player In Checkout Mode") ~= true then return end
    tillUser = pc:GetFullName()
    settleGlide(pc, machine, "Timeline Move User to Membership",
                "Timeline Move User to Membership__FinishedFunc")
    Log.info("till: %s is ringing up customers", UE.PlayerNameOf(pc) or "a guest")
end

--- Who holds the till, when this Lua state never saw them take it (a hot
--- reload, a rejoin): if it is in checkout mode and the host is not - the
--- host's own controller still walks - it is the guest asking.
local function adoptTill(pc, machine)
    if tillUser ~= nil or not machine then return end
    if UE.TryGet(machine, "Player In Checkout Mode") ~= true then return end
    local hostPc = UE.GetPlayerController()
    if UE.TryGet(hostPc, "Walking Mapping Context is Enable") == true then
        tillUser = pc:GetFullName()
    end
end

local function leaveTill(pc)
    local machine = tillMachine()
    adoptTill(pc, machine)
    if not machine or tillUser ~= pc:GetFullName() then return end
    asGuest(pc, function() machine["Toggle Checkout Mode"](machine, false) end)
    settleGlide(pc, machine, "Timeline Move User out Membership",
                "Timeline Move User out Membership__FinishedFunc")
    tillUser = nil
    clearHostHints()
    hintsClearAt = os.clock() + 1.0
    Log.info("till: %s left the register", UE.PlayerNameOf(pc) or "a guest")
end

--- A guest who left the game while at the till: free it without anybody's
--- camera gliding anywhere (Toggle Checkout Mode would move the host).
function freeTill()
    local machine = tillMachine()
    if machine then
        UE.TrySet(machine, "Player In Checkout Mode", false)
        UE.TrySet(machine, "Player is currently moving", false)
        UE.TryCall(machine, "Toggle Checkout Mode Triggers", true)
        UE.TryCall(machine, "Set Rest Screen", true)
    end
    tillUser = nil
    clearHostHints()
end

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

    -- A conversation is answered even while the host's end-of-day summary is
    -- up: it was started before, and nothing else can close it.
    if action.special == "talkAnswer" then
        local r = UE.rot(rot)
        if r and TalkSync.answer(pc, math.floor(r.Pitch + 0.5), asGuest) then
            stats.replayed = stats.replayed + 1
        end
        return
    end
    if dayIsOver() then
        Log.debug("ignored a guest's %s: the day is over on the host", action.label)
        return
    end

    if action.special == "leaveTill" then return leaveTill(pc) end
    if action.special == "closeDrawer" then
        local co = UE.findFirst("CheckOut_C")
        adoptTill(pc, tillMachine())
        if UE.alive(co) and tillUser == pc:GetFullName() then
            asGuest(pc, function() co["Close Cash Drawer"](co) end)
        end
        return
    end
    if action.special == "skinChoice" then
        local at, r = UE.vec(loc), UE.rot(rot)
        if at and r then
            local tool, id = math.floor(r.Pitch + 0.5), math.floor(r.Yaw + 0.5)
            if not SkinSync.choose(at, tool, id) then
                Log.debug("a guest's skin choice found nothing at %.0f,%.0f,%.0f", at.X, at.Y, at.Z)
            end
        end
        return
    end
    if action.special == "rotateGhost" then return rotateGhost(pawn, UE.rot(rot)) end

    loc, rot = UE.vec(loc), UE.rot(rot)
    if not (loc and rot) then return end
    rot.Roll = 0.0
    local aim = rot
    -- Both casings of the field names. MEASURED: built as { Pitch = .. } the
    -- engine took pitch 0, and every replay looked dead level - a guest could
    -- take a tape at eye height and could not reach anything on the floor.
    rot = UE.rotArg(rot)

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

    local ok, swaps, err = asGuest(pc, function()
        pawn["Look At Test"](pawn)
        pawn[action.event](pawn, {}, 0.0, 0.0, nil)
        -- Do not leave an outline on the host's screen for what the guest
        -- was looking at.
        pcall(function() pawn["Trace from Camera Stop looking At"](pawn, true, true) end)
    end)

    -- The register, while nobody is at it (see the till, above).
    if ok and (code == 1 or code == 2) and tillUser == nil then
        local machine = tillMachine()
        if machine and UE.TryGet(machine, "Player In Checkout Mode") == true then
            -- The click entered checkout mode itself: a product on the
            -- counter does (Move player is in Checkout Mode if he is not,
            -- @8876), and the glide that would drag the host has started.
            if gliding(machine, "Timeline Move User to Membership") then
                tillUser = pc:GetFullName()
                settleGlide(pc, machine, "Timeline Move User to Membership",
                            "Timeline Move User to Membership__FinishedFunc")
                Log.info("till: %s is ringing up customers", UE.PlayerNameOf(pc) or "a guest")
            end
        elseif machine and UE.TryGet(pawn, "Current Tool in hand") == 0
               and aimsAtTill(machine, loc, aim) then
            enterTill(pc, machine)
        end
    end

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

--------------------------------------------------------------------------
-- Guest: what the guest's own game does that the host must hear about
--------------------------------------------------------------------------

--[[
    THE CHANGE COUNTED ONTO THE COUNTER (CheckOut_C "Array of Spawned Money on
    table ref"). Every bill or coin taken from the drawer is a new actor the
    CheckOut spawns on the host and slides onto the counter (Event - Player
    click on money with Left Click, @3313); a right click slides it back and
    destroys it, the end of the sale clears them all. Money_Base_C does not
    replicate, so a guest counting change saw nothing land on the counter.
    Those actors - only those: the drawer's own stacks are the same classes and
    exist on every machine already - are made to replicate the way the sweep
    does it (Replication.patchActor), so the engine sends each one, its slide
    and its removal.
]]
local function replicateTableMoney(co)
    local arr = UE.TryGet(co, "Array of Spawned Money on table ref")
    if arr == nil then return end
    local list = {}
    pcall(function()
        for i = 1, #arr do
            local m = arr[i]
            if type(m) == "userdata" and m.get then
                local ok, v = pcall(function() return m:get() end)
                if ok then m = v end
            end
            if UE.alive(m) then list[#list + 1] = m end
        end
    end)
    for _, m in ipairs(list) do Replication.patchActor(m) end
end

--[[
    THE CASH DRAWER (CheckOut_C, bp/CheckOut.txt). When the customer pays,
    the host's drawer slides open (its "cash drawer" component, Y 0 -> 35,
    with the bills and coins riding on it) and its little screen shows the
    bill, what was received and the change due. None of that replicates.
    MEASURED: a guest took a customer's $20 for an $11 bill; on the host the
    drawer opened with $9.00 due, on the guest it stayed shut - every bill the
    guest could aim at sat 35 cm from where the host's trace looked for it.
    The host sends the drawer and the five numbers; the guest puts its own
    drawer where the host's is (no animation: the game's own would also hand
    the guest's controller the drawer's input) and redraws the screen with
    the drawer's own Refresh Display.
]]
local DRAWER_FIELDS = { a = "Actual Payback", r = "Money receive", p = "Money to Payback",
                        t = "Total of bill" }
local drawerSent, drawerSentAt = nil, 0

function sendDrawer(now)
    local co = UE.findFirst("CheckOut_C")
    if not UE.alive(co) then return end
    replicateTableMoney(co)
    local fields = { o = UE.TryGet(co, "Checkout Draw is open") == true and "1" or "0",
                     c = UE.TryGet(co, "User can close the Cash Drawer") == true and "1" or "0" }
    for k, prop in pairs(DRAWER_FIELDS) do fields[k] = tostring(UE.TryGet(co, prop) or 0) end
    local sig = table.concat({ fields.o, fields.c, fields.a, fields.r, fields.p, fields.t }, ";")
    if tillUser and drawerSent and fields.o ~= drawerSent:sub(1, 1) then
        hintsClearAt = now + 1.0       -- after the drawer's animation has finished
    end
    if hintsClearAt and now >= hintsClearAt then
        hintsClearAt = nil
        clearHostHints()
    end
    if sig == drawerSent and (now - drawerSentAt) < 5.0 then return end
    if Chan.broadcast("till", fields) > 0 then drawerSent, drawerSentAt = sig, now end
end

local function onDrawer(fields)
    if not UE.IsClient() then return end
    local co = UE.findFirst("CheckOut_C")
    if not UE.alive(co) then return end
    local open = fields.o == "1"
    if (UE.TryGet(co, "Checkout Draw is open") == true) ~= open then
        local drawer = UE.TryGet(co, "cash drawer")
        if UE.valid(drawer) then
            pcall(UE.withHit, function(hit)
                drawer:K2_SetRelativeLocation({ X = 0.0, Y = open and 35.0 or 0.0, Z = 0.0 }, false, hit, false)
            end)
        end
        UE.TrySet(co, "Checkout Draw is open", open)
    end
    for k, prop in pairs(DRAWER_FIELDS) do
        local v = tonumber(fields[k])
        if v then UE.TrySet(co, prop, math.floor(v)) end
    end
    UE.TrySet(co, "User can close the Cash Drawer", fields.c == "1")
    UE.TryCall(co, "Refresh Display")
end

--[[
    THE REGISTER'S SCREEN (MembershipMachine_C, bp/MembershipMachine.txt and
    UI_Screen_Membership_Widget.txt). The monitor shows a render target: the
    machine's "Widget" component holds a UI_Screen_Membership_Widget_C that is
    never drawn on screen, and a SceneCaptureComponent2D copies it into the
    texture the screen's material shows - after each change (Refresh Monitor)
    and 30 times a second while somebody is at the till. While nobody is, the
    screen wears the screensaver material instead (Set Rest Screen).

    The bill is put into that widget by the scanner and the customer's
    checkout, which run on the host: "UI - Start A New Bill And Membership"
    (the member's name and number), "Add Product Scanned to the list" per
    product, "Add Fees to the list", "Switch Widget Page". A guest's widget
    heard none of it, so a guest at the till looked at the desktop page while
    ringing customers up. Its desktop page was blank as well: Construct Desktop
    fills in the date and the store's name from the GameMode (@30), and waits
    for one forever on a guest.

    The host sends what its widget shows - the page, the member, every line,
    the desktop's two texts, whether the screen is on - and the guest's widget
    is given the same lines through the same functions, then captured again.
]]
local BILL_EVERY  = 0.5     -- host: look at the screen
local BILL_RESEND = 5.0     -- host: say it again even when nothing changed
local billNext, billQuick, billSent, billSentAt = 0, nil, nil, 0

local function screenWidget(machine)
    local comp = UE.TryGet(machine, "Widget")
    if not UE.valid(comp) then return nil end
    local w = nil
    pcall(function() w = comp:GetWidget() end)
    return UE.valid(w) and w or nil
end

--- What a text widget shows. Read off its "Text" property: a UFunction
--- returning an FText would leak one each call (ue.lua, UE.findObject).
local function textOf(widget)
    if not UE.valid(widget) then return "" end
    local v = UE.TryGet(widget, "Text")
    if v == nil then return "" end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or ""
end

--- Is the screen showing the bill (true) or the screensaver (false)? Set Rest
--- Screen swaps material slot 1 of the register's mesh between the two.
local function screenOn(machine)
    local mesh = UE.TryGet(machine, "LA_CashRegister_A_03")
    local mat, name = nil, nil
    pcall(function() mat = mesh:GetMaterial(1) end)
    if UE.valid(mat) then pcall(function() name = mat:GetFName():ToString() end) end
    if type(name) ~= "string" then return nil end
    return name:find("SaveScreen", 1, true) == nil
end

local function children(panel)
    local out = {}
    if not UE.valid(panel) then return out end
    local kids = nil
    pcall(function() kids = panel:GetAllChildren() end)
    if kids == nil then return out end
    pcall(function()
        for i = 1, #kids do
            local c = kids[i]
            if type(c) == "userdata" and c.get then
                local ok, v = pcall(function() return c:get() end)
                if ok then c = v end
            end
            if UE.valid(c) then out[#out + 1] = c end
        end
    end)
    return out
end

--- One line of the bill: "p" product or "f" fee, then name, price, product
--- type or fee kind, and the tag line (OLD / NEW / ...) as drawn.
local function billLine(c)
    local cls = UE.ClassNameOf(c)
    local kind = cls == "UI_Screen_ProductScan_C" and "p" or cls == "UI_Screen_Checkout_Fees_C" and "f" or nil
    if not kind then return nil end
    local name = UE.TryGet(c, "Name")
    local ok, s = pcall(function() return name:ToString() end)
    name = ok and type(s) == "string" and s or (type(name) == "string" and name or "")
    local price = tonumber(UE.TryGet(c, "Price")) or 0
    local sort = tonumber(UE.TryGet(c, kind == "p" and "ProductType" or "Fees Error Type")) or 0
    local tag = ""
    if kind == "p" then
        local t = UE.TryGet(c, "txt_Tag")
        if UE.valid(t) and UE.TryGet(t, "Visibility") ~= 1 then tag = textOf(t) end    -- 1: Collapsed
    end
    return table.concat({ kind, name, ("%.2f"):format(price), tostring(math.floor(sort)), tag }, "\t")
end

--- Host: the register's screen, every half second, to every guest when it
--- changed (and every few seconds regardless, for a guest who just came).
function sendBill(now)
    if now < billNext then return end
    billNext = now + BILL_EVERY
    local m = tillMachine()
    if not m then return end
    local w = screenWidget(m)
    if not w then return end
    local box = UE.TryGet(w, "ScrollBox_ScanProduct")
    local count = 0
    pcall(function() count = box:GetChildrenCount() end)
    local switcher = UE.TryGet(w, "WidgetSwitcher")
    local page = tonumber(UE.TryGet(switcher, "ActiveWidgetIndex")) or 0
    local on = screenOn(m)
    -- Lines are only ever added or cleared, so these few numbers say whether
    -- anything changed; the lines themselves are read when they do.
    local quick = table.concat({ tostring(on), page, count, tostring(UE.TryGet(w, "Price Total")),
                                 textOf(UE.TryGet(w, "txt_Member-name_checkoutpage")) }, ";")
    if quick == billQuick and (now - billSentAt) < BILL_RESEND then return end
    billQuick = quick

    local fields = { s = on == nil and "" or (on and "1" or "0"), g = tostring(page),
        n = textOf(UE.TryGet(w, "txt_Member-name_checkoutpage")),
        m = textOf(UE.TryGet(w, "txt_Member-Membership_checkoutpage")),
        d = textOf(UE.TryGet(w, "txt_desktop_date")),
        k = textOf(UE.TryGet(w, "TextBlock_StoreName")) }
    local n = 0
    for _, c in ipairs(children(box)) do
        local line = billLine(c)
        if line then
            n = n + 1
            fields["l" .. n] = line
        end
    end
    fields.c = tostring(n)
    local parts = {}
    for _, k in ipairs({ "s", "g", "n", "m", "d", "k", "c" }) do parts[#parts + 1] = fields[k] end
    for i = 1, n do parts[#parts + 1] = fields["l" .. i] end
    local sig = table.concat(parts, "\n")
    if sig == billSent and (now - billSentAt) < BILL_RESEND then return end
    if Chan.broadcast("bill", fields) > 0 then billSent, billSentAt = sig, now end
end

local billShown = { lines = nil }

local function setText(widget, s)
    if type(s) ~= "string" or not UE.valid(widget) or textOf(widget) == s then return false end
    return (pcall(function() widget:SetText(FText(s)) end))
end

local PRODUCT_LINE = "/Game/VideoStore/asset/prop/CheckOut/UI_Screen_ProductScan.UI_Screen_ProductScan_C"

--[[
    A product's line is built here, the way "Add Product Scanned to the list"
    builds it (UI_Screen_Membership_Widget @16-@255): create the line widget,
    give it its name, price and type, add it to the scroll box - and its own
    Construct draws them. Not by calling that function: its tags are a TSet
    parameter, and MEASURED, handed nil for it (UE4SS documents an empty set),
    the line came out with the price $0.00 and the wrong product type, and the
    guest's game hung on the game thread half a minute later. A TSet never
    crosses from Lua now. The line keeps its own empty tag set; the tag text
    the host's line drew (OLD / NEW RELEASE / ...) is put on it afterwards.
    Fees have no set ("Add Fees to the list" takes a name, a price and a
    kind) and still go through the widget's own function.
]]
local function addProductLine(w, name, price, sort, tag)
    local cls = UE.load(PRODUCT_LINE)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ksl = UE.GetKismetSystemLibrary()
    local pc = UE.GetPlayerController()
    local box = UE.TryGet(w, "ScrollBox_ScanProduct")
    if not (UE.valid(cls) and UE.valid(wbl) and UE.valid(ksl) and UE.valid(box)) then return false end
    local line = nil
    pcall(function() line = wbl:Create(w, cls, pc) end)
    if not UE.valid(line) then return false end
    -- The setters the game's own function uses (KismetSystemLibrary *ByName).
    pcall(function() ksl:SetStringPropertyByName(line, FName("Name"), name) end)
    pcall(function() ksl:SetDoublePropertyByName(line, FName("Price"), price) end)
    pcall(function() ksl:SetBytePropertyByName(line, FName("ProductType"), sort) end)
    if not pcall(function() box:AddChild(line) end) then return false end
    if tag ~= "" then
        local t = UE.TryGet(line, "txt_Tag")
        pcall(function() ksl:SetStringPropertyByName(line, FName("Tag text"), tag) end)
        if UE.valid(t) then
            pcall(function() t:SetText(FText(tag)) end)
            pcall(function() t:SetVisibility(0) end)   -- Visible: Construct collapsed it, finding no tags
        end
    end
    return true
end

--- Guest: one line of the host's bill. Returns its price, or nil.
local function addBillLine(w, line)
    local kind, name, price, sort, tag = line:match("^([pf])\t(.-)\t([%d%.%-]+)\t(%d+)\t(.*)$")
    if not kind then return nil end
    price, sort = tonumber(price), tonumber(sort)
    if kind == "f" then
        return UE.TryCall(w, "Add Fees to the list", name, price, sort) and price or nil
    end
    return addProductLine(w, name, price, sort, tag) and price or nil
end

local function onBill(fields)
    if not UE.IsClient() then return end
    local m = tillMachine()
    if not m then return end
    local w = screenWidget(m)
    if not w then return end
    local changed = false

    local list = {}
    for i = 1, tonumber(fields.c) or 0 do list[i] = fields["l" .. i] or "" end
    local sig = table.concat(list, "\n")
    if sig ~= billShown.lines then
        UE.TryCall(w, "Clear Scan Product list")
        local total, any = 0, false
        for _, line in ipairs(list) do
            local price = addBillLine(w, line)
            if price then total, any = total + price, true end
        end
        -- What the game's function does after each line: the total, at the
        -- bottom, and the bill's page.
        UE.TrySet(w, "Price Total", total)
        UE.TryCall(w, "Set Price Total to interface", total)
        if any then UE.TryCall(w, "Switch Widget Page", 1) end
        billShown.lines = sig
        changed = true
    end
    -- After the lines: adding one switches to the bill's page itself.
    local page = tonumber(fields.g)
    local switcher = UE.TryGet(w, "WidgetSwitcher")
    if page and tonumber(UE.TryGet(switcher, "ActiveWidgetIndex")) ~= page then
        UE.TryCall(w, "Switch Widget Page", page)
        changed = true
    end
    for name, key in pairs({ ["txt_Member-name_checkoutpage"] = "n", ["txt_Member-Membership_checkoutpage"] = "m",
                             txt_desktop_date = "d", TextBlock_StoreName = "k" }) do
        if setText(UE.TryGet(w, name), fields[key]) then changed = true end
    end

    -- The screen itself. A guest at the till has it on already (its own
    -- Toggle Checkout Mode); it only follows the host's while it is not.
    local on, mine = fields.s == "1", screenOn(m)
    if (fields.s == "1" or fields.s == "0") and mine ~= nil and mine ~= on
       and (on or not GuestInput.atTill()) then
        UE.TryCall(m, "Set Rest Screen", not on)
        changed = true
    end
    if changed then UE.TryCall(m, "Refresh Monitor") end
end

local tillWasOn = false
local exitFix = nil   -- where this guest should be once the register lets go of them

--- Is this guest's own game in checkout mode at the register?
function GuestInput.atTill() return tillWasOn end

--- Leaving the register glides the player to its "PlayerLocation" projected
--- onto the navigation mesh (K2_ProjectPointToNavigation @7197), and when the
--- projection fails the Blueprint takes the zero vector instead. A guest has
--- no navigation mesh - it is built on the host - so MEASURED: every guest
--- leaving the register landed at the world origin, (0, 0, 92), outside the
--- store. Once the glide is over, a guest who is not near the register's exit
--- spot is put on it. (The guest's own movement is what the host follows.)
local function fixTillExit(m)
    if not exitFix then return end
    if os.clock() > exitFix.untilT then exitFix = nil return end
    if gliding(m, "Timeline Move User out Membership") then return end
    local pawn = UE.GetPawn()
    local at = nil
    pcall(function() at = UE.vec(pawn:K2_GetActorLocation()) end)
    if at then
        local dx, dy = at.X - exitFix.X, at.Y - exitFix.Y
        if math.sqrt(dx * dx + dy * dy) > 300 then
            pcall(UE.withHit, function(hit)
                pawn:K2_SetActorLocation({ X = exitFix.X, Y = exitFix.Y, Z = exitFix.Z + 92.0 }, false, hit, true)
            end)
            Log.info("till: left the register at the world origin (no navigation mesh on a guest) - " ..
                     "put back at the register's exit")
        end
    end
    exitFix = nil
end

--[[
    THE SKIN PICKER. When it opens on a guest's screen, what the guest picks
    is applied by the picker itself, UI_SkinMode "Material Selected_Event"
    (@4798) calling Set new Skin / Set new Mesh on the object - on the
    guest's own copy, which nobody else sees and the host's next skin list
    would undo. So the choice also goes to the host as action 8 (the object's
    place, the tool, the choice), where the same two setters run on the
    host's copy and skinsync.lua sends the result to everyone.
]]
local SKIN_PICKED = "/Game/VideoStore/core/widget/skin/UI_SkinMode.UI_SkinMode_C:Material Selected_Event"
local pickHooked, nextPickHook = false, 0
local picked = {}

local function hookSkinPicker(now)
    if pickHooked or now < nextPickHook then return end
    nextPickHook = now + 5
    -- RegisterHook needs the function to exist: the widget's class loads
    -- with the HUD that references it.
    if not UE.valid(StaticFindObject(SKIN_PICKED)) then return end
    pickHooked = pcall(function()
        RegisterHook(SKIN_PICKED, function(ctx, idParam)
            Log.guard("skin picker hook", function()
                local w = ctx
                pcall(function() w = ctx:get() end)
                local id = idParam
                pcall(function() id = idParam:get() end)
                local target = UE.TryGet(w, "To Which Actor the Skin UI is Apply")
                local tool = UE.TryGet(w, "Tool in use")
                local at = nil
                pcall(function() at = UE.vec(target:K2_GetActorLocation()) end)
                -- Only queued here: sent from the tick, like every hook's work.
                if at and type(id) == "number" and type(tool) == "number" and #picked < 16 then
                    picked[#picked + 1] = { loc = at, tool = tool, id = id }
                end
            end)
        end)
    end)
    if pickHooked then Log.info("skin picker: what a guest picks goes to the host") end
end

--------------------------------------------------------------------------
-- Build mode: a guest's placement preview
--------------------------------------------------------------------------
--[[
    THE PLACEMENT PREVIEW (bp/Player_Character.txt "Ghost Tick" @22384,
    bp/GhostMesh.txt, bp/MovingBox.txt Pickup @17551). Carrying packed
    furniture, a player sees a see-through copy of it where it would land,
    green or red. That is the pawn's own GhostMesh actor ("Ghost", spawned by
    every machine for itself at BeginPlay): MovingBox Pickup gives it the
    furniture's mesh, where it may stand (floor / wall / ceiling), its
    footprint and a starting rotation, and every frame the pawn's Look At
    Test asks the box "Does Show Ghost?" and runs Ghost Tick - a trace from
    the camera, Set Visibility of Ghost, and the placement test that turns it
    red or green and puts the "place" hint on the HUD.

    A guest saw none of it. The pick-up runs on the host (the replays above),
    so it was the HOST's copy of the guest's ghost that got the mesh, hidden
    there (hideGhost). And the guest's own pawn cannot drive its own ghost:
    the box answers every Ghost_C question from what it holds ("Objects in
    Inventory", a Blueprint variable that never replicates - empty on a
    guest), so Does Show Ghost? is false and Look At Test never reaches Ghost
    Tick. Filling the guest's box is no way out: its own Throw (a guest's
    click also runs locally) would then move the guest's copy of the
    furniture, and packed pieces all wait at one spot (0, 0, -5000, MovingBox
    "Store the Object"), so the right copy cannot be told from the others.

    So the host tells this guest what its pick-up gave the host's copy of the
    ghost - the mesh, the floor / wall / ceiling flags, the footprint, the
    rotation - and the furniture's class. The guest gives its own ghost the
    same, and while it carries the box runs the pawn's own Ghost Tick every
    frame, right after the pawn's tick (a hook on its ReceiveTick: a
    Blueprint function's hook runs after the function). Ghost Tick asks the
    object it is handed whether to snap to the grid and how to tilt the trace
    (a shelf aims 5 degrees lower); handed the furniture class's default
    object, the preview lands where the host will put the piece. The mouse
    wheel turns the guest's preview (the box's Rotate runs locally); that
    rotation goes to the host (action 10), which is where it is placed.
]]
local ghostSent = {}        -- host: guest controller name -> { sig, at }
local GHOST_RESEND = 2.0
-- Look At Test's reach for each tool (Player_Character @23988).
local TRACE_REACH = { [0] = "Hand Tool Trace - Distance", [1] = "Move Tool Trace - Distance" }
local GHOST_FN = "/Game/VideoStore/core/pawn/Player_Character.Player_Character_C:ReceiveTick"

--- Host: the furniture packed in the box a guest's pawn holds.
local function carriedFurniture(pawn)
    local hold = UE.TryGet(pawn, "Object Hold")
    if not UE.alive(hold) then return nil end
    local inv = UE.TryGet(hold, "Objects in Inventory")
    if inv == nil then return nil end
    local item = nil
    pcall(function()
        if #inv > 0 then
            item = inv[1]
            if type(item) == "userdata" and item.get then item = item:get() end
        end
    end)
    return UE.alive(item) and item or nil
end

--- Host: what this guest's preview should be, to that guest when it changes.
function sendGhost(pc, pawn, now)
    local key = pc:GetFullName()
    local fields = { h = "0" }
    local item = carriedFurniture(pawn)
    local g = UE.TryGet(pawn, "Ghost")
    if item and UE.alive(g) then
        local mesh = UE.pathOf(UE.TryGet(g, "Mesh"))
        local cls = nil
        pcall(function() cls = item:GetClass() end)
        local clsPath = classPath(cls)
        if mesh and clsPath then
            local r = UE.rot(UE.TryGet(g, "Ghost Rotation")) or { Pitch = 0, Yaw = 0, Roll = 0 }
            local function flag(prop) return UE.TryGet(g, prop) == true and "1" or "0" end
            fields = { h = "1", m = mesh, c = clsPath,
                       p = flag("Can be place on Floor") .. flag("Can be place on Wall") .. flag("Can be place on Ceilling"),
                       r = ("%.2f,%.2f,%.2f"):format(r.Pitch, r.Yaw, r.Roll) }
            -- The footprint: the furniture's own navigation blocker, copied
            -- onto the ghost by the pick-up (Set NavCollision Zone).
            local zone = UE.TryGet(g, "NavCollisionZone")
            local l = UE.vec(UE.TryGet(zone, "RelativeLocation"))
            local zr = UE.rot(UE.TryGet(zone, "RelativeRotation"))
            local s = UE.vec(UE.TryGet(zone, "RelativeScale3D"))
            if l and zr and s then
                fields.z = ("%d;%.2f,%.2f,%.2f;%.2f,%.2f,%.2f;%.3f,%.3f,%.3f"):format(
                    UE.TryGet(zone, "bVisible") == true and 1 or 0,
                    l.X, l.Y, l.Z, zr.Pitch, zr.Yaw, zr.Roll, s.X, s.Y, s.Z)
            end
        end
    end
    local sig = table.concat({ fields.h, fields.m or "", fields.c or "", fields.p or "",
                               fields.r or "", fields.z or "" }, "|")
    local last = ghostSent[key]
    local every = fields.h == "1" and GHOST_RESEND or 10.0
    if last and last.sig == sig and (now - last.at) < every then return end
    if Chan.sendTo(pc, "ghost", fields) then ghostSent[key] = { sig = sig, at = now } end
end

--- Host: the guest turned the furniture (action 10). Its Throw reads the
--- ghost's rotation, so that is what is set; sendGhost tells the guest back.
function rotateGhost(pawn, r)
    local g = UE.TryGet(pawn, "Ghost")
    if not (r and UE.alive(g)) then return end
    pcall(function()
        g["Set Rotation of Ghost"](g, UE.rotArg({ Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0 }))
    end)
end

-- Guest ---------------------------------------------------------------------

local ghost = {
    want = nil,          -- the host's last word on this player's preview
    applied = nil,       -- what this player's ghost was given (mesh, flags, footprint)
    drive = false,       -- the frame hook runs Ghost Tick
    pawnAddr = nil,      -- this player's pawn, by address (never held across frames)
    cdo = nil, cdoUntil = 0,   -- the furniture's class default and how long it may be used
    agreedYaw = nil, turnedAt = -1e9,
    hooked = false, hookTried = -1e9, firedAt = -1e9, driveSince = 0,
    errors = 0, off = false, loadFailed = {},
}

local function yawDiff(a, b)
    local d = (a - b) % 360
    return d > 180 and 360 - d or d
end

local function parseRot(s)
    local p, y, r = (s or ""):match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
    if not p then return nil end
    return { Pitch = tonumber(p), Yaw = tonumber(y), Roll = tonumber(r) }
end

--- The frame hook: right after this player's pawn ticked (its own Look At
--- Test included), the pawn's own Ghost Tick. Everything in pcall - a hook
--- callback that throws is dropped by UE4SS for good.
local function onPawnTick(ctx)
    ghost.firedAt = os.clock()
    if not ghost.drive then return end
    pcall(function()
        local pawn = ctx
        pcall(function() pawn = ctx:get() end)
        if pawn:GetAddress() ~= ghost.pawnAddr then return end
        local hold = pawn["Object Hold"]
        if not (hold and hold:IsValid()) then return end
        -- First what Look At Test asks before it draws a preview (@24110):
        -- looking at something one could use instead (a shelf's slot, the
        -- counter) there is none - and the host, asking the same, would throw
        -- the box rather than place it there. MEASURED: without this the
        -- guest saw green on the counter where the host refused.
        local show = {}
        local tool = pawn["Current Tool in hand"]
        local reach = pawn[TRACE_REACH[tool] or "Skin Tool Trace - Distance"] or 200
        local looked = pawn["ref Object Look At"]
        if looked and looked:IsValid() then reach = reach + 50 end
        pawn["Trace from Camera for LookAt Ghost"](pawn, { X = 1.0, Y = 2.0, Z = 2.0 }, reach, 0, show)
        UE.releaseOut(show)
        if UE.field(show, "Show Ghost") ~= true then
            pawn.Ghost["Set Visibility of Ghost"](pawn.Ghost, false)
            return
        end
        local arg = hold
        if ghost.cdo and os.clock() < ghost.cdoUntil then arg = ghost.cdo end
        if pcall(function() pawn["Ghost Tick"](pawn, arg) end) then
            ghost.errors = 0
        else
            ghost.errors = ghost.errors + 1
            if ghost.errors > 30 then
                ghost.drive, ghost.off = false, true
            end
        end
    end)
end

--- Hook the pawn's ReceiveTick once, and again if the class was reloaded
--- (a new world): a hook that stopped firing belongs to a function that
--- is gone.
local function hookPawnTick(now)
    if ghost.hooked and (now - ghost.firedAt) < 3 then return true end
    if ghost.hooked and (now - ghost.driveSince) < 3 then return true end   -- give it a moment
    if now - ghost.hookTried < 5 then return ghost.hooked end
    ghost.hookTried = now
    if not UE.valid(StaticFindObject(GHOST_FN)) then return false end
    ghost.hooked = pcall(RegisterHook, GHOST_FN, onPawnTick)
    ghost.firedAt = now
    if ghost.hooked then Log.debug("build mode: placement preview hooked to the pawn's tick") end
    return ghost.hooked
end

--- The footprint the host's ghost wears (Set NavCollision Zone takes an
--- FTransform; this sets the same parts one by one). The placement test
--- reads it, so red and green come out as on the host.
local function setFootprint(g, z)
    local zone = UE.TryGet(g, "NavCollisionZone")
    if not UE.valid(zone) then return end
    local vis, lx, ly, lz, rp, ry, rr, sx, sy, sz = (z or ""):match(
        "^([01]);([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);([%d%.%-]+),([%d%.%-]+),([%d%.%-]+);([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
    local on = vis == "1"
    if on then
        pcall(UE.withHit, function(hit)
            zone:K2_SetRelativeLocationAndRotation({ X = tonumber(lx), Y = tonumber(ly), Z = tonumber(lz) },
                UE.rotArg({ Pitch = tonumber(rp), Yaw = tonumber(ry), Roll = tonumber(rr) }), false, hit, true)
        end)
        pcall(function() zone:SetRelativeScale3D({ X = tonumber(sx), Y = tonumber(sy), Z = tonumber(sz) }) end)
    end
    pcall(function() zone:SetVisibility(on, false) end)
    local child = UE.TryGet(zone, "ChildActor")
    if UE.alive(child) then pcall(function() child:SetActorEnableCollision(on) end) end
end

local function stopGhost(pawn)
    if ghost.drive or ghost.applied then
        local g = UE.alive(pawn) and UE.TryGet(pawn, "Ghost") or nil
        if UE.alive(g) then UE.TryCall(g, "Set Visibility of Ghost", false) end
    end
    ghost.drive, ghost.applied, ghost.cdo, ghost.agreedYaw = false, nil, nil, nil
end

--- Guest, every tick: set this player's ghost up as the host's is, keep the
--- frame hook fed, and send a turn of the furniture to the host.
local function tickGhost(now)
    local pawn = UE.GetPawn()
    local want = ghost.want
    local hold = UE.alive(pawn) and UE.TryGet(pawn, "Object Hold") or nil
    local g = UE.alive(pawn) and UE.TryGet(pawn, "Ghost") or nil
    if ghost.off or (cfg and cfg.GuestBuildPreview == false)
       or not (want and want.h == "1" and UE.alive(hold) and UE.alive(g)) then
        stopGhost(pawn)
        return
    end
    pcall(function() ghost.pawnAddr = pawn:GetAddress() end)
    if not ghost.drive then ghost.driveSince = now end
    if not hookPawnTick(now) then return end

    -- Set up as MovingBox Pickup does it on the host.
    local sig = table.concat({ want.m or "", want.p or "", want.z or "" }, "|")
    if ghost.applied ~= sig then
        local mesh = nil
        if (now - (ghost.loadFailed[want.m] or -1e9)) > 10 then
            mesh = UE.load(want.m)
            if not mesh then ghost.loadFailed[want.m] = now end
        end
        if not mesh then return end
        pcall(function() g["Set Ghost Mesh"](g, mesh) end)
        local p = want.p or "000"
        UE.TryCall(g, "Set placement", p:sub(1, 1) == "1", p:sub(2, 2) == "1", p:sub(3, 3) == "1")
        setFootprint(g, want.z)
        ghost.applied = sig
        if not ghost.announced then
            ghost.announced = true
            Log.info("build mode: your placement preview is drawn here (%s)", tostring(want.m):match("([^%./]+)$"))
        end
    end

    -- The furniture's class default, for the frames until the next tick. Used
    -- only while a live piece of that class is in the world: that pins the
    -- class, and so its default, until it is looked for again.
    ghost.cdo = nil
    local short = (want.c or ""):match("%.([^%.]+)$")
    if short then
        UE.knowClass(short, want.c)
        local inst = UE.findFirst(short)
        local cdo = nil
        if inst then
            pcall(function() cdo = inst:GetClass():GetCDO() end)
            -- By path where UE4SS has no GetCDO (once a tick, memoized).
            if not UE.valid(cdo) then cdo = UE.findObject((want.c:gsub("%.([^%.]+)$", ".Default__%1"))) end
        end
        if UE.valid(cdo) then ghost.cdo, ghost.cdoUntil = cdo, os.clock() + 0.35 end
    end

    -- The rotation: the host's, unless this player has just turned it here.
    local hostR = parseRot(want.r)
    local mine = UE.rot(UE.TryGet(g, "Ghost Rotation"))
    if hostR and mine then
        local function setRot(r)
            pcall(function() g["Set Rotation of Ghost"](g, UE.rotArg(r)) end)
            ghost.agreedYaw = r.Yaw
        end
        if ghost.agreedYaw == nil then
            setRot(hostR)
        elseif yawDiff(mine.Yaw, ghost.agreedYaw) > 0.5 then
            if now - ghost.turnedAt > 0.2 then
                Chan.sendAction(10, { X = 0, Y = 0, Z = 0 }, { Pitch = mine.Pitch, Yaw = mine.Yaw, Roll = 0 })
                ghost.agreedYaw, ghost.turnedAt = mine.Yaw, now
            end
        elseif yawDiff(hostR.Yaw, ghost.agreedYaw) > 0.5 and now - ghost.turnedAt > 1.0 then
            setRot(hostR)
        end
    end
    ghost.drive = true
end

local function onGhost(fields)
    if not UE.IsClient() then return end
    ghost.want = fields
end

--- What the guest's own game did that the host must hear about: it left the
--- till (W is the machine's binding, not the pawn's), or the player picked a
--- skin.
function GuestInput.tickGuest()
    if not UE.IsClient() then
        tillWasOn = false
        return
    end
    local m = tillMachine()
    local on = m ~= nil and UE.TryGet(m, "Player In Checkout Mode") == true
    if tillWasOn and not on then
        onPress(7)
        local spot = nil
        pcall(function() spot = UE.vec(UE.TryGet(m, "PlayerLocation"):K2_GetComponentLocation()) end)
        if spot then exitFix = { X = spot.X, Y = spot.Y, Z = spot.Z, untilT = os.clock() + 5 } end
    end
    tillWasOn = on
    if m then fixTillExit(m) end

    hookSkinPicker(os.clock())
    if #picked > 0 then
        local batch = picked
        picked = {}
        for _, p in ipairs(batch) do
            Chan.sendAction(8, p.loc, { Pitch = p.tool, Yaw = p.id, Roll = 0 })
        end
    end

    -- Carrying furniture: the placement preview (build mode, above).
    Log.guard("placement preview", tickGhost, os.clock())
end

function GuestInput.stats() return stats end

-- For the dev bridge only: a press exactly as the key poll makes it.
GuestInput._onPress = onPress

function GuestInput.reset()
    tickStopped = {}
    toolSent = {}
    announced = false
    lastLocalPress = -1e9
    tillUser, tillWasOn, exitFix = nil, false, nil
    drawerSent, drawerSentAt = nil, 0
    billNext, billQuick, billSent, billSentAt = 0, nil, nil, 0
    billShown = { lines = nil }
    picked = {}
    ghostSent = {}
    -- The ReceiveTick hook stays registered (UE4SS keeps it); the rest starts over.
    ghost.want, ghost.applied, ghost.drive, ghost.cdo, ghost.agreedYaw = nil, nil, false, nil, nil
    ghost.errors, ghost.off, ghost.loadFailed = 0, false, {}
end

function GuestInput.init(config)
    cfg = config
    Chan.onAction(function(pc, code, loc, rot) Log.guard("guest action", replay, pc, code, loc, rot) end)
    Chan.on("me", function(fields) Log.guard("guest tool", onMe, fields) end)
    Chan.on("till", function(fields) Log.guard("cash drawer", onDrawer, fields) end)
    Chan.on("bill", function(fields) Log.guard("register screen", onBill, fields) end)
    Chan.on("ghost", function(fields) Log.guard("placement preview", onGhost, fields) end)
    GuestInput.bindKeys()
end

return GuestInput
