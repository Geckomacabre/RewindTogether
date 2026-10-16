--[[
    Rewind Together - a guest at one of the store's machines

    REPORTED (live test, 16 Oct 2026): "the return desk doesn't work" for a
    guest.

    WHAT A MACHINE IS (bp/MachineActor.txt). Twenty-three MachineActor_C
    classes: the return desk, the popcorn, slushie and cotton-candy machines,
    the snack shelves, the office computer, the catalogue, the staff book...
    A click on one runs its Interaction: "Can Player use the machine?" (player
    0's "Walking Mapping Context is Enable", which only a LOCAL controller ever
    sets), then Toggle Machine(true): "In Machine Mode", player 0's camera
    glides to the machine on a timeline, the machine's input goes to player 0.
    Then one of two kinds, read off each class default:
      * Worked with the mouse pointer ("Hide Cursor Interface while Using"):
        a UI on the player's own screen - the computer, catalogue, staff book,
        calendar, store expansion and level, store name, sidewalk sign,
        console rental mat, custom movie station, repair station. A guest's
        clicks there stay on the guest's screen (computer.lua mirrors the
        computer).
      * Worked by looking around ("Enable Move Camera"): every click is the
        pawn's own trace from its camera - the return desk, the popcorn,
        slushie and cotton-candy machines, the snack shelves. What they work
        on is on the host (the drop box's tapes, the cups, the stock), so a
        guest's own game has nothing to work with there.

    For a machine of the second kind:
      1. The guest's own game sits down (its camera, its hints) and tells the
         host (guest action 14 with the machine's place, Pitch 1), and again
         every few seconds while it stays.
      2. The host sits the guest down at ITS machine the way it does at the
         till (guestinput.lua): Toggle Machine(true) inside a guest window,
         the glide stopped before it moves anybody - the guest's own game
         glides the guest's own camera - and its finishing step run as the
         guest. On the host the machine is then the guest's, and its parts
         (the scanner, the rewinder, the cups) take the guest's clicks the
         way they take a local player's.
      3. The guest's clicks there go to the host again (1.7.4 kept every click
         at a machine on the guest's screen: right for the computer, wrong
         here) and are replayed from the guest's camera like any other.
      4. Drags. Some steps are hold-and-drag - the tape into the rewinder, a
         cup out of the slushie machine. A Cursor-Movement_Distance_C traces
         from its player's Camera on every frame the left button is held: its
         own Main-Trigger input events, Started (@2639), Triggered (@4017),
         Completed (@10). The guest sends the camera while the button is held
         (action 16) and the release (action 15); the host puts the guest's
         pawn's Camera where the guest's is and runs those events on the
         guest's cursors, as the guest.
         A cursor takes its player when it spawns (BeginPlay -> Toggle Input:
         player 0's controller gets its input, player 0's pawn is its "ref As
         Player Character"). One spawned outside a guest window - after an
         animation, on a timer - is the HOST's: it would follow the host's
         camera and the host's mouse. It is handed to the guest with its own
         Toggle Input: off for the host, on again as the guest.
      5. The guest gets up (Pitch 0), stops saying so, walks away or leaves
         the game: the host gets the guest up the same way, or frees the
         machine.
]]

local Log  = require("log")
local UE   = require("ue")
local Chan = require("rpcchan")

local Machines = {}

local ACTION_SIT     = 14
local ACTION_RELEASE = 15
local ACTION_DRAG    = 16
local MACHINE = "MachineActor_C"
local CURSOR  = "Cursor-Movement_Distance_C"

local REACH        = 150.0   -- cm: a machine named by its place is the nearest one within this
local WALKED_AWAY  = 500.0   -- cm: a seated guest's pawn this far from its machine has got up
local CURSOR_REACH = 400.0   -- cm: a cursor this near a guest's machine works for it
local SIT_EVERY    = 3.0     -- guest: say so again while seated
local SIT_TIMEOUT  = 10.0    -- host: a seated guest not heard from for this long has got up
local DRAG_EVERY   = 0.1     -- guest: the camera, while the button is held

-- The base class's glides (MachineActor_C), in and out.
local GLIDE_IN_TL   = "Timeline Moving player to the SlushMachine"
local GLIDE_IN_END  = "Timeline Moving player to the SlushMachine__FinishedFunc"
local GLIDE_OUT_TL  = "Timeline Moving player out of SlushMachine"
local GLIDE_OUT_END = "Timeline Moving player out of SlushMachine__FinishedFunc"

local stats = { seated = 0, upAgain = 0, freed = 0, handedOver = 0, pressed = 0, dragged = 0, released = 0,
                refused = 0 }

--------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------

local function placeOf(actor)
    local v = nil
    pcall(function() v = UE.vec(actor:K2_GetActorLocation()) end)
    return v
end

local function distance(a, b)
    if not (a and b) then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function fullName(o)
    local n = nil
    pcall(function() n = o:GetFullName() end)
    return n
end

--- Worked with the mouse pointer: its UI is on the player's own screen.
local function pointerMachine(m)
    return UE.TryGet(m, "Hide Cursor Interface while Using") == true
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

-- Guest controller full name -> { machine = full name, cls, at = place,
-- heard = when, pawn = pawn full name }. Names, not objects: nothing engine
-- is held across ticks (PROJECT.md 5).
local seated = {}
local refusedOnce = {}

local function machineNear(loc)
    local best, bestD = nil, REACH
    for _, m in ipairs(UE.findAll(MACHINE) or {}) do
        if UE.alive(m) then
            local d = distance(placeOf(m), loc)
            if d < bestD then best, bestD = m, d end
        end
    end
    return best
end

local function machineNamed(name)
    if not name then return nil end
    for _, m in ipairs(UE.findAll(MACHINE) or {}) do
        if UE.alive(m) and fullName(m) == name then return m end
    end
    return nil
end

local function controllerNamed(name)
    for _, pc in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(pc) and fullName(pc) == name then return pc end
    end
    return nil
end

--- Nobody on it any more, without anybody's camera gliding anywhere.
local function freeMachine(m)
    UE.TrySet(m, "Player is currently moving", false)
    UE.TrySet(m, "In Machine Mode", false)
    UE.TrySet(m, "Interactable", true)
    UE.TryCall(m, "Set Collision For Machine", true)
    stats.freed = stats.freed + 1
end

--- This guest's drag cursors on the host: the ones whose player is its pawn.
local function cursorsOf(pawn)
    local mine, out = fullName(pawn), {}
    if not mine then return out end
    for _, c in ipairs(UE.findAll(CURSOR) or {}) do
        if UE.alive(c) then
            local who = UE.TryGet(c, "ref As Player Character")
            if UE.valid(who) and fullName(who) == mine then out[#out + 1] = c end
        end
    end
    return out
end

--- Put the pawn's Camera where the guest's camera is (the cursors trace from
--- it), run fn, and put it back: its relative transform is the spring arm's
--- to own. The same aim a replayed press takes (guestinput.lua).
local function aimed(pc, pawn, loc, rot, fn)
    loc, rot = UE.vec(loc), UE.rot(rot)
    if not (loc and rot) then return false end
    rot.Roll = 0.0
    rot = UE.rotArg(rot)
    local cam = UE.TryGet(pawn, "Camera")
    local savedLoc, savedRot = nil, nil
    if UE.valid(cam) then
        local v = UE.vec(UE.TryGet(cam, "RelativeLocation"))
        savedLoc = v and { X = v.X, Y = v.Y, Z = v.Z }
        savedRot = UE.rotArg(UE.TryGet(cam, "RelativeRotation"))
        pcall(UE.withHit, function(hit) cam:K2_SetWorldLocation(loc, false, hit, false) end)
        pcall(UE.withHit, function(hit) cam:K2_SetWorldRotation(rot, false, hit, false) end)
    end
    pcall(function() pc:SetControlRotation(rot) end)
    local ok = require("guestinput").asGuest(pc, fn)
    if UE.valid(cam) then
        if savedLoc then pcall(UE.withHit, function(hit) cam:K2_SetRelativeLocation(savedLoc, false, hit, false) end) end
        if savedRot then pcall(UE.withHit, function(hit) cam:K2_SetRelativeRotation(savedRot, false, hit, false) end) end
    end
    return ok
end

local function endDrags(pc, pawn)
    local cursors = cursorsOf(pawn)
    if #cursors == 0 then return end
    require("guestinput").asGuest(pc, function()
        for _, c in ipairs(cursors) do
            pcall(function() c["Force End of Main Trigger"](c) end)
        end
    end)
end

local function getUp(pc, why)
    local key = fullName(pc)
    local s = key and seated[key]
    if not s then return end
    seated[key] = nil
    local m = machineNamed(s.machine)
    if not m or UE.TryGet(m, "In Machine Mode") ~= true then return end
    local G = require("guestinput")
    local pawn = UE.TryGet(pc, "Pawn")
    if UE.alive(pawn) then endDrags(pc, pawn) end
    -- Toggle Machine(false) waits for a glide that never ran on the host.
    UE.TrySet(m, "Player is currently moving", false)
    G.asGuest(pc, function() m["Toggle Machine"](m, false) end)
    G.settleGlide(pc, m, GLIDE_OUT_TL, GLIDE_OUT_END)
    if UE.TryGet(m, "In Machine Mode") == true then freeMachine(m) end
    G.clearHostHints()
    stats.upAgain = stats.upAgain + 1
    Log.info("machines: %s got up from the %s (%s)", UE.PlayerNameOf(pc) or "a guest", s.cls, why)
end

local function sitDown(pc, pawn, loc)
    local key = fullName(pc)
    if not key then return end
    local m = machineNear(loc)
    if not m then return end
    local name = fullName(m)
    local s = seated[key]
    if s and s.machine == name then
        s.heard = os.clock()
        return
    end
    if s then getUp(pc, "sat down elsewhere") end
    if pointerMachine(m) then return end            -- its UI is on the guest's screen
    if UE.TryGet(m, "In Machine Mode") == true then
        -- The host is at it, or another guest. The guest's own game sits there
        -- alone; the host's is not taken from whoever has it.
        if not refusedOnce[key .. name] then
            refusedOnce[key .. name] = true
            stats.refused = stats.refused + 1
            Log.info("machines: %s sat at the %s, which somebody else is using on the host",
                     UE.PlayerNameOf(pc) or "a guest", UE.ClassNameOf(m))
        end
        return
    end
    local G = require("guestinput")
    G.asGuest(pc, function() m["Toggle Machine"](m, true) end)
    if UE.TryGet(m, "In Machine Mode") ~= true then
        Log.warn("machines: the host could not sit %s down at the %s", UE.PlayerNameOf(pc) or "a guest",
                 UE.ClassNameOf(m))
        return
    end
    G.settleGlide(pc, m, GLIDE_IN_TL, GLIDE_IN_END)
    G.clearHostHints()
    seated[key] = { machine = name, cls = UE.ClassNameOf(m), at = placeOf(m), heard = os.clock(),
                    pawn = fullName(pawn) }
    refusedOnce[key .. name] = nil
    stats.seated = stats.seated + 1
    Log.info("machines: %s sat down at the %s", UE.PlayerNameOf(pc) or "a guest", UE.ClassNameOf(m))
end

--- Host: guest actions 14-16 (guestinput.lua routes them here).
function Machines.onGuest(pc, pawn, what, loc, rot)
    if not UE.IsServer() then return end
    if what == "machine" then
        local r = UE.rot(rot)
        if r and r.Pitch > 0.5 then
            sitDown(pc, pawn, UE.vec(loc))
        else
            getUp(pc, "the guest got up")
        end
        return
    end
    local key = fullName(pc)
    if not (key and seated[key]) then return end
    seated[key].heard = os.clock()
    local cursors = cursorsOf(pawn)
    if #cursors == 0 then return end
    if what == "drag" then
        aimed(pc, pawn, loc, rot, function()
            for _, c in ipairs(cursors) do
                if UE.TryGet(c, "Started Testing") == true then
                    pcall(function()
                        c["InpActEvt_Input_Main-Trigger_K2Node_EnhancedInputActionEvent_0"](c, {}, 0.0, 0.0, nil)
                    end)
                end
            end
        end)
        stats.dragged = stats.dragged + 1
    elseif what == "release" then
        aimed(pc, pawn, loc, rot, function()
            for _, c in ipairs(cursors) do
                pcall(function()
                    c["InpActEvt_Input_Main-Trigger_K2Node_EnhancedInputActionEvent_3"](c, {}, 0.0, 0.0, nil)
                end)
            end
        end)
        stats.released = stats.released + 1
    end
end

--- Host, inside a replayed left click (already aimed and as the guest): the
--- guest's cursors at its machine hear the button go down.
function Machines.pressed(pc, pawn)
    local key = fullName(pc)
    if not (key and seated[key]) then return end
    for _, c in ipairs(cursorsOf(pawn)) do
        pcall(function()
            c["InpActEvt_Input_Main-Trigger_K2Node_EnhancedInputActionEvent_1"](c, {}, 0.0, 0.0, nil)
        end)
        stats.pressed = stats.pressed + 1
    end
end

--- A machine the host's own player sits at (not one of the guests').
local function hostMachines()
    local guests = {}
    for _, s in pairs(seated) do guests[s.machine] = true end
    local out = {}
    for _, m in ipairs(UE.findAll(MACHINE) or {}) do
        if UE.alive(m) and UE.TryGet(m, "In Machine Mode") == true and not guests[fullName(m) or ""] then
            out[#out + 1] = placeOf(m)
        end
    end
    return out
end

--- Cursors a guest's machine spawned outside a guest window are the host's:
--- hand them over (see the top).
local function handOver(pc, pawn, s)
    local hostPawn = UE.GetPawn()
    local hostName = UE.valid(hostPawn) and fullName(hostPawn) or nil
    if not hostName then return end
    local mine = nil
    for _, c in ipairs(UE.findAll(CURSOR) or {}) do
        if UE.alive(c) then
            local who = UE.TryGet(c, "ref As Player Character")
            if UE.valid(who) and fullName(who) == hostName then
                local at = placeOf(c)
                local d = distance(at, s.at)
                if d < CURSOR_REACH then
                    mine = mine or hostMachines()
                    local nearer = false
                    for _, h in ipairs(mine) do if distance(at, h) < d then nearer = true end end
                    if not nearer then
                        pcall(function() c["Toggle Input"](c, false) end)     -- off the host's controller
                        require("guestinput").asGuest(pc, function() c["Toggle Input"](c, true) end)
                        stats.handedOver = stats.handedOver + 1
                        Log.info("machines: a drag at the %s handed to %s", s.cls, UE.PlayerNameOf(pc) or "a guest")
                    end
                end
            end
        end
    end
end

function Machines.tickHost(now)
    if not UE.IsServer() or next(seated) == nil then return end
    for key, s in pairs(seated) do
        local pc = controllerNamed(key)
        local pawn = pc and UE.TryGet(pc, "Pawn") or nil
        if not (pc and UE.alive(pawn)) then
            -- Left the game (or lost the pawn): nobody to get up.
            seated[key] = nil
            local m = machineNamed(s.machine)
            if m then freeMachine(m) end
            Log.info("machines: the %s freed - its guest is gone", s.cls)
        elseif (now - s.heard) > SIT_TIMEOUT then
            getUp(pc, "not heard from")
        else
            -- Away three looks running, and only on a position actually read:
            -- MEASURED, a guest at the return desk was got up once on a read
            -- that failed (an unknown place counted as infinitely far).
            local here = placeOf(pawn)
            if here and s.at and distance(here, s.at) > WALKED_AWAY then
                s.away = (s.away or 0) + 1
            else
                s.away = 0
            end
            if s.away >= 3 then
                getUp(pc, "walked away")
            else
                handOver(pc, pawn, s)
            end
        end
    end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local sitting = nil      -- the place of the machine the host was told about
local sitNext = 0
local dragNext = 0

local function cameraOf()
    local pc = UE.GetPlayerController()
    local cm = UE.alive(pc) and UE.TryGet(pc, "PlayerCameraManager") or nil
    if not UE.valid(cm) then return nil end
    local loc, rot = nil, nil
    pcall(function()
        loc = UE.vec(cm:GetCameraLocation())
        rot = UE.rot(cm:GetCameraRotation())
    end)
    if loc and rot then return loc, rot end
    return nil
end

--- A machine of the kind the host works for its guests (see the top).
local function worldMachine()
    local m = require("guestinput").machine()
    if m and not m.pointer and not m.localPlay and m.at then return m end
    return nil
end

function Machines.tickGuest(now)
    if not UE.IsClient() then return end
    local m = worldMachine()
    if m then
        if not sitting or now >= sitNext or distance(sitting, m.at) > 1 then
            if Chan.sendAction(ACTION_SIT, m.at, { Pitch = 1, Yaw = 0, Roll = 0 }) > 0 then
                sitting, sitNext = m.at, now + SIT_EVERY
            end
        end
        if now >= dragNext and require("input").isDown("LeftMouseButton") then
            local loc, rot = cameraOf()
            if loc then
                Chan.sendAction(ACTION_DRAG, loc, rot)
                dragNext = now + DRAG_EVERY
            end
        end
    elseif sitting then
        Chan.sendAction(ACTION_SIT, sitting, { Pitch = 0, Yaw = 0, Roll = 0 })
        sitting = nil
    end
end

--- Guest: the left button was let go (input.lua).
function Machines.released()
    if not (UE.IsClient() and worldMachine()) then return end
    local loc, rot = cameraOf()
    if loc then Chan.sendAction(ACTION_RELEASE, loc, rot) end
end

--------------------------------------------------------------------------

function Machines.report()
    local n = 0
    for _ in pairs(seated) do n = n + 1 end
    return { ("Machines: %d guest(s) seated now; seated %d, got up %d, freed %d, refused %d;"
              .. " drags: %d pressed, %d moved, %d let go, %d cursor(s) handed over")
        :format(n, stats.seated, stats.upAgain, stats.freed, stats.refused, stats.pressed, stats.dragged,
                stats.released, stats.handedOver) }
end

function Machines.reset()
    seated, refusedOnce = {}, {}
    sitting, sitNext, dragNext = nil, 0, 0
end

--- Host: is any guest seated at a machine right now?
function Machines.anySeated() return next(seated) ~= nil end

-- For the tests.
Machines._seated = function() return seated end

return Machines
