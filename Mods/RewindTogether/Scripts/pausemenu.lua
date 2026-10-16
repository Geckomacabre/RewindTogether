--[[
    Rewind Together - the pause menu: one for guests, and "Back to the store"

    REPORTED (live test, 15 Oct 2026, the guest's own recording): the guest got
    off the office computer and stood outside the map behind the store, with
    no way back in. The cause is fixed (guestinput.lua, leaving a machine), but
    the user asked for a way out of anything like it: a button in the pause
    menu. Doing that turned up a second gap.

    A GUEST HAS NO PAUSE MENU. Escape is the pawn's own input event
    (bp/Player_Character.txt @11942), and its first step is GetGameMode cast
    to Core_Gamemode_C (@12121) - which on a guest is null, so the press ends
    right there and nothing opens. The rest of that event is a few lines: when
    the pawn already has a menu, close it; otherwise WidgetBlueprintLibrary
    Create(UI_ESC-Menu_C) and AddToViewport. The menu needs nothing else from a
    GameMode (bp/UI_ESC-Menu.txt): its Construct hides the last-save line when
    it finds none, and SetGamePaused does nothing on a client. Resume removes
    it, "Return to menu" opens L_Boot - which for a guest is leaving.
    So on a guest, Escape (polled, input.lua) does those few lines here.

    "BACK TO THE STORE". The menu keeps its buttons in a VerticalBox: Resume,
    Options (20 px above), Return to menu (20), then the last-save line (10).
    Each is a UX_Button_ESC_C, whose click is the base class's bound event
    (bp/UX_Button_Base.txt @312) broadcasting "Button Clicked" to the menu.
    When a menu is built (its Construct, hooked), one more of the same widget
    goes in above "Return to menu", and that click event is listened to for
    that button alone. Pressing it:
      guest - asks the host to put them beside the host (guestinput.lua,
              action 12: the move rt.bring makes);
      host  - stands the host at the register's exit spot, inside the store.
    rt.unstuck does the same from the console.

    Hooks only queue; the tick (which runs while the host's game is paused:
    the engine still ticks) does the work, between frames like the rest.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")
local Input  = require("input")
local GuestInput = require("guestinput")

local PauseMenu = {}

local ESC_CLASS     = "/Game/VideoStore/core/widget/game_ui/UI_ESC-Menu.UI_ESC-Menu_C"
local ESC_CONSTRUCT = ESC_CLASS .. ":Construct"
local BTN_CLASS     = "/Game/VideoStore/core/widget/button/UX_Button_ESC.UX_Button_ESC_C"
local BTN_CLICKED   = "/Game/VideoStore/core/widget/button/UX_Button_Base.UX_Button_Base_C:" ..
                      "BndEvt__UX_Button_Base_Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local WIDGETS       = "/Script/UMG.Default__WidgetBlueprintLibrary"

local LABEL         = "Back to the store"
local CHAR_LABEL    = "Character"
local OP_GUEST_MENU = "the pause menu on a guest"
local OP_BUTTON     = "the Back to the store button"

local cfg = nil
local hooked = { construct = false, click = false }
local nextHook = 0
local built = {}       -- menus whose Construct ran, waiting for our button
local clicked = {}     -- menus whose button was pressed, waiting to act
local ours = {}        -- our buttons' addresses -> the menu they are in
local guestMenu = nil  -- the menu this module opened on a guest
local stats = { menus = 0, buttons = 0, pressed = 0, guestOpened = 0 }

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

local function enabled()
    return not (cfg and cfg.PauseMenuBackToStore == false)
end

--------------------------------------------------------------------------
-- Hooks: queue only
--------------------------------------------------------------------------

local function hookAll(now)
    if (hooked.construct and hooked.click) or now < nextHook then return end
    nextHook = now + 5
    -- RegisterHook needs the function to exist: the classes load with the
    -- pawn, which references the menu.
    if not hooked.construct and UE.valid(StaticFindObject(ESC_CONSTRUCT)) then
        hooked.construct = pcall(function()
            RegisterHook(ESC_CONSTRUCT, function(ctx)
                local menu = ctx
                pcall(function() menu = ctx:get() end)
                if #built < 8 then built[#built + 1] = menu end
            end)
        end)
    end
    if not hooked.click and UE.valid(StaticFindObject(BTN_CLICKED)) then
        hooked.click = pcall(function()
            RegisterHook(BTN_CLICKED, function(ctx)
                local button = ctx
                pcall(function() button = ctx:get() end)
                local entry = ours[addressOf(button)]
                if entry and #clicked < 4 then clicked[#clicked + 1] = entry end
            end)
        end)
    end
    if hooked.construct and hooked.click then
        Log.info("pause menu: \"%s\" goes in every pause menu", LABEL)
    end
end

--------------------------------------------------------------------------
-- The button
--------------------------------------------------------------------------

local function pad(slot, top)
    if not UE.valid(slot) then return end
    pcall(function() slot:SetPadding({ Left = 0.0, Top = top, Right = 0.0, Bottom = 0.0 }) end)
end

--- Put our button in one menu, above "Return to menu". Returns true when added.
local function addButton(menu)
    if not UE.valid(menu) then return false end
    local quit = UE.TryGet(menu, "UX_Button_Quit")
    local last = UE.TryGet(menu, "TextBlock_lastSave")
    if not UE.valid(quit) then return false end
    local box = nil
    pcall(function() box = quit:GetParent() end)
    if not UE.valid(box) then return false end
    local count = 0
    pcall(function() count = box:GetChildrenCount() end)
    if count > 4 then return false end   -- ours is in already

    local cls, lib = StaticFindObject(BTN_CLASS), StaticFindObject(WIDGETS)
    if not (UE.valid(cls) and UE.valid(lib)) then
        Log.warn("pause menu: the button's class is not loaded - no \"%s\" this time", LABEL)
        return false
    end
    local button = nil
    pcall(function() button = lib:Create(menu, cls, UE.GetPlayerController()) end)
    if not UE.valid(button) then
        Log.warn("pause menu: could not make the button")
        return false
    end
    pcall(function() button["Set Text"](button, FText(LABEL)) end)
    -- "Character": the character screen (character.lua), above it.
    local charButton = nil
    pcall(function() charButton = lib:Create(menu, cls, UE.GetPlayerController()) end)
    if UE.valid(charButton) then pcall(function() charButton["Set Text"](charButton, FText(CHAR_LABEL)) end) end

    -- Resume, Options, [Character], [Back to the store], Return to menu, the
    -- last-save line: the panel can only append, so the two after ours come
    -- out and go back in.
    pcall(function() box:RemoveChild(quit) end)
    if UE.valid(last) then pcall(function() box:RemoveChild(last) end) end
    local slot = nil
    if UE.valid(charButton) then
        pcall(function() slot = box:AddChild(charButton) end)
        pad(slot, 20.0)
    end
    pcall(function() slot = box:AddChild(button) end)
    pad(slot, 20.0)
    pcall(function() slot = box:AddChild(quit) end)
    pad(slot, 20.0)
    if UE.valid(last) then
        pcall(function() slot = box:AddChild(last) end)
        pad(slot, 10.0)
    end

    local a = addressOf(button)
    if a then ours[a] = { menu = menu, kind = "back" } end
    local c = UE.valid(charButton) and addressOf(charButton) or nil
    if c then ours[c] = { menu = menu, kind = "character" } end
    stats.buttons = stats.buttons + 1
    return true
end

--------------------------------------------------------------------------
-- Back to the store
--------------------------------------------------------------------------

--- The register's exit spot: inside the store, on the floor the host's own
--- navigation knows (the till's "PlayerLocation", guestinput.lua).
local function storeSpot()
    local till = UE.findFirst("MembershipMachine_C")
    if not UE.alive(till) then return nil end
    local spot = nil
    pcall(function() spot = UE.vec(UE.TryGet(till, "PlayerLocation"):K2_GetComponentLocation()) end)
    return spot
end

--- Do it for this player. Returns a line saying what happened.
function PauseMenu.backToStore()
    stats.pressed = stats.pressed + 1
    if UE.IsClient() then
        if GuestInput.backToStore() then
            return "Asked the host to put you beside them."
        end
        return "Could not reach the host - are you still connected?"
    end
    local pawn = UE.GetPawn()
    if not UE.valid(pawn) then return "You have no character to move - are you in the store?" end
    local spot = storeSpot()
    if not spot then
        Log.warn("back to the store: no register in this level to stand by")
        return "No register found to stand you next to."
    end
    pcall(function() pawn:SetActorEnableCollision(true) end)
    local move = UE.TryGet(pawn, "CharacterMovement")
    if UE.valid(move) and UE.TryGet(move, "MovementMode") == 0 then
        pcall(function() move:SetMovementMode(1, 0) end)
    end
    pcall(UE.withHit, function(hit)
        pawn:K2_SetActorLocation({ X = spot.X, Y = spot.Y, Z = spot.Z + 92.0 }, false, hit, true)
    end)
    Log.info("back to the store: put at the register's exit (%.0f, %.0f, %.0f)", spot.X, spot.Y, spot.Z)
    return "Put you by the register."
end

--------------------------------------------------------------------------
-- A guest's Escape
--------------------------------------------------------------------------

local function inViewport(w)
    local yes = false
    if UE.valid(w) then pcall(function() yes = w:IsInViewport() end) end
    return yes == true
end

--- Escape on a guest: what the pawn's own event does after its GameMode check.
local function guestEscape()
    if not UE.IsClient() or not enabled() then return end
    -- The character screen closes itself on Escape (character.lua).
    local C = require("character")
    if C.isOpen() or C.escapedRecently() then return end
    local pawn = UE.GetPawn()
    if not (UE.valid(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C") then return end
    -- The game keeps the one it opened in the pawn's "UI ESC MENU"; ours is here.
    if inViewport(guestMenu) then
        UE.TryCall(guestMenu, "Close ESC")
        guestMenu = nil
        return
    end
    if inViewport(UE.TryGet(pawn, "UI ESC MENU")) then return end
    -- Not over the till, a machine's screen or a conversation: each has its
    -- own input mode, which the menu's closing (SetInputMode_GameOnly) would
    -- take away from under it. W gets out of those.
    if GuestInput.atTill() or GuestInput.inMachine() or require("talksync").guestTalking() then return end
    -- The game opens it only with the hand tool, switching to it when the
    -- hands are empty. A guest's tool is the host's business (the E the key
    -- poll sends), so the menu just opens; it changes nothing in the store.
    Safety.guard(OP_GUEST_MENU, function()
        local cls, lib = StaticFindObject(ESC_CLASS), StaticFindObject(WIDGETS)
        if not (UE.valid(cls) and UE.valid(lib)) then
            Log.warn("pause menu: its class is not loaded yet")
            return
        end
        local menu = nil
        pcall(function() menu = lib:Create(pawn, cls, nil) end)
        if not UE.valid(menu) then
            Log.warn("pause menu: could not open it on this guest")
            return
        end
        pcall(function() menu:AddToViewport(0) end)
        guestMenu = menu
        stats.guestOpened = stats.guestOpened + 1
        Log.info("pause menu: opened on this guest (the game's own needs a GameMode)")
    end)
end

--------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------

function PauseMenu.tick(now)
    if not enabled() then built, clicked = {}, {} return end
    hookAll(now)
    if #built > 0 then
        local batch = built
        built = {}
        for _, menu in ipairs(batch) do
            stats.menus = stats.menus + 1
            Safety.guard(OP_BUTTON, addButton, menu)
        end
    end
    if #clicked > 0 then
        local batch = clicked
        clicked = {}
        local back, character = false, false
        for _, entry in ipairs(batch) do
            if entry.kind == "character" then character = true else back = true end
            if UE.valid(entry.menu) then UE.TryCall(entry.menu, "Close ESC") end
            if guestMenu == entry.menu then guestMenu = nil end
        end
        if back then
            local said = PauseMenu.backToStore()
            Log.info("back to the store (pause menu): %s", said)
        end
        -- Once the menu has finished closing (its Close ESC ends a tick later).
        if character then require("character").chooseSoon() end
    end
end

function PauseMenu.report()
    return {
        ("pause menu: hooks %s, %d menu(s) seen, %d button(s) added, pressed %d time(s), opened on a guest %d time(s)"):format(
            (hooked.construct and hooked.click) and "on" or "not yet", stats.menus, stats.buttons,
            stats.pressed, stats.guestOpened),
    }
end

function PauseMenu.reset()
    built, clicked, ours, guestMenu = {}, {}, {}, nil
end

function PauseMenu.init(config)
    cfg = config
    -- Polled on the game thread; only a guest acts on it (the host's own
    -- game opens its menu).
    Input.bind("ESCAPE", "pause menu (guest)", guestEscape)
end

-- For the smoke test.
PauseMenu._addButton = addButton
PauseMenu._guestEscape = guestEscape
PauseMenu._queue = function() return built, clicked, ours end

return PauseMenu
