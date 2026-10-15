--[[
    Rewind Together - main menu integration

    Adds a "PLAY CO-OP" entry to the game's own main menu, built from the
    game's own button widget (Widget_Menu_Button_C) so it inherits the real
    font, hover animation and click sound rather than looking bolted on.

    Clicking it swaps the menu for a list of friends who are hosting right
    now, one button each. Picking one connects. Nobody types an ID.

    Why clicks are detected by hover + mouse key rather than by binding the
    widget's OnClicked delegate: binding a Blueprint multicast delegate to a
    Lua function is not something UE4SS can do reliably across builds.
    Polling IsHovered() on our own injected widgets is boring, has no failure
    mode, and gives identical behaviour.
]]

local Log       = require("log")
local UE        = require("ue")
local Net       = require("net")
local SteamJoin = require("steamjoin")
local Safety    = require("safety")

local MainMenu = {}

local cfg = nil

local BUTTON_CLASS_PATH = "/Game/core/MainMenu/widget/Widget_Menu_Button.Widget_Menu_Button_C"
local BUTTON_CLASS_NAME = "Widget_Menu_Button_C"
local MENU_CLASS_CANDIDATES = { "UX_Boot_Menu_C", "UI_MainMenu_C", "UX_Boot_StartOption_C" }
local ANCHOR_BUTTON     = "btn_Start"

local state = {
    menu      = nil,     -- the menu widget or panel we injected into
    panel     = nil,     -- its button container
    injected  = {},      -- our buttons, in display order
    ours      = {},      -- full names of widgets we created, to skip when anchoring
    page      = "root",  -- "root" | "friends"
    lastScan  = 0,
    friends   = {},
    notice    = nil,
}

--------------------------------------------------------------------------
-- Widget construction
--------------------------------------------------------------------------

local function buttonClass()
    return StaticFindObject(BUTTON_CLASS_PATH)
end

local function widgetLibrary()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

--- Build one menu button carrying the game's own styling.
---
--- Every step logs before it runs. Constructing UMG widgets at runtime and
--- parenting them into a cooked menu is the one part of this mod that has
--- taken the game down, so when it is enabled at all we want the log to name
--- the exact call that died rather than just stopping.
local function makeButton(label, onClick)
    Log.debug("makeButton: resolving button class")
    local cls = buttonClass()
    if not UE.valid(cls) then
        Log.warn("menu button class not found (%s)", BUTTON_CLASS_PATH)
        return nil
    end

    Log.debug("makeButton: resolving widget library")
    local lib = widgetLibrary()
    if not UE.valid(lib) then
        Log.warn("WidgetBlueprintLibrary not found")
        return nil
    end

    local pc = UE.GetPlayerController()
    if not UE.valid(pc) then
        Log.debug("makeButton: no player controller yet")
        return nil
    end

    Log.debug("makeButton: creating widget")
    local w = nil
    local ok = pcall(function() w = lib:Create(pc, cls, pc) end)
    if not ok or not UE.valid(w) then
        Log.warn("WidgetBlueprintLibrary.Create failed for the menu button")
        return nil
    end

    Log.debug("makeButton: setting text")
    if not UE.TryCall(w, "SetText", label) then
        UE.TrySet(w, "Text", label)
    end

    Log.debug("makeButton: built '%s'", label)
    return { widget = w, label = label, onClick = onClick }
end

-- Container widgets that genuinely accept arbitrary extra children. Anything
-- else (SizeBox, Border, ScaleBox and friends take exactly one child) is
-- refused rather than risking an engine-side assert.
local MULTI_CHILD_PANELS = {
    VerticalBox = true, HorizontalBox = true, Overlay = true,
    UniformGridPanel = true, WrapBox = true, ScrollBox = true,
    GridPanel = true, CanvasPanel = true, StackBox = true,
}

local function clearInjected()
    for _, entry in ipairs(state.injected) do
        pcall(function()
            if UE.valid(entry.widget) then entry.widget:RemoveFromParent() end
        end)
    end
    state.injected = {}
    state.ours = {}
end

local function addButton(label, onClick)
    if not UE.valid(state.panel) then return false end

    local panelClass = UE.ClassNameOf(state.panel)
    if not MULTI_CHILD_PANELS[panelClass] then
        Log.warn("refusing to add a menu entry to a %s - it does not take " ..
                 "extra children; use rt.friends or Steam's Join Game instead",
                 panelClass)
        return false
    end

    local b = makeButton(label, onClick)
    if not b then return false end

    Log.debug("addButton: parenting '%s' into %s", label, panelClass)
    local ok = pcall(function()
        state.panel:AddChild(b.widget)
    end)
    if not ok then
        pcall(function() b.widget:RemoveFromParent() end)
        return false
    end
    state.injected[#state.injected + 1] = b
    pcall(function() state.ours[b.widget:GetFullName()] = true end)
    return true
end

--------------------------------------------------------------------------
-- Pages
--------------------------------------------------------------------------

local showRoot, showFriends

showRoot = function()
    clearInjected()
    state.page = "root"
    addButton("PLAY CO-OP", function()
        showFriends()
    end)
end

showFriends = function()
    clearInjected()
    state.page = "friends"

    state.friends = SteamJoin.friendsHosting()

    if #state.friends == 0 then
        addButton("NO FRIENDS HOSTING", function() end)
        addButton("REFRESH", function() showFriends() end)
    else
        for _, f in ipairs(state.friends) do
            local target = f.steamId
            addButton(("JOIN  %s"):format(f.name:upper()), function()
                Log.info("joining %s from the menu", f.name)
                Net.join(target)
                clearInjected()
            end)
        end
        addButton("REFRESH", function() showFriends() end)
    end

    addButton("BACK", function() showRoot() end)
end

--------------------------------------------------------------------------
-- Injection
--------------------------------------------------------------------------

--- Find the live main menu's button container.
---
--- The first build looked up the menu widget by class name and quietly did
--- nothing when that name did not match, which is why no button appeared.
--- Instead, anchor on the buttons themselves: find any live
--- Widget_Menu_Button_C, take its parent panel, and add ours alongside. That
--- works regardless of what the surrounding menu widget is called, and it
--- guarantees our entry lands in the same box with the same layout rules.
local function locateMenu()
    local buttons = FindAllOf(BUTTON_CLASS_NAME)
    if not buttons then
        -- Try the menu widget directly as a secondary route.
        for _, cls in ipairs(MENU_CLASS_CANDIDATES) do
            local menu = FindFirstOf(cls)
            if UE.valid(menu) then
                local anchor = UE.TryGet(menu, ANCHOR_BUTTON)
                if UE.valid(anchor) then
                    local panel = nil
                    if pcall(function() panel = anchor:GetParent() end) and UE.valid(panel) then
                        state.menu, state.panel, state.injected = menu, panel, {}
                        Log.info("main menu located via %s", cls)
                        return true
                    end
                end
            end
        end
        return false
    end

    -- Pick a button that is actually on screen and not one of ours.
    for _, btn in ipairs(buttons) do
        if UE.valid(btn) and not state.ours[btn:GetFullName()] then
            local panel = nil
            local ok = pcall(function() panel = btn:GetParent() end)
            if ok and UE.valid(panel) then
                if state.panel == panel and #state.injected > 0 then return true end
                state.menu     = panel
                state.panel    = panel
                state.injected = {}
                Log.info("main menu located; anchoring on %s inside %s",
                         UE.ClassNameOf(btn), UE.ClassNameOf(panel))
                return true
            end
        end
    end
    return false
end

--- Diagnostic: what menu-ish widgets exist right now.
function MainMenu.describe()
    local lines = {}
    local buttons = FindAllOf(BUTTON_CLASS_NAME)
    lines[#lines + 1] = ("Widget_Menu_Button_C instances: %d")
        :format(buttons and #buttons or 0)
    if buttons then
        for i, b in ipairs(buttons) do
            if i > 8 then break end
            local parent = nil
            pcall(function() parent = b:GetParent() end)
            lines[#lines + 1] = ("  [%d] parent=%s"):format(i, UE.ClassNameOf(parent))
        end
    end
    for _, cls in ipairs(MENU_CLASS_CANDIDATES) do
        local m = FindFirstOf(cls)
        lines[#lines + 1] = ("  %s: %s"):format(cls, UE.valid(m) and "present" or "absent")
    end
    lines[#lines + 1] = ("button class: %s")
        :format(UE.valid(buttonClass()) and "found" or "MISSING")
    lines[#lines + 1] = ("widget library: %s")
        :format(UE.valid(widgetLibrary()) and "found" or "MISSING")
    lines[#lines + 1] = ("injected entries: %d"):format(#state.injected)
    return lines
end

--- Called from the tick. Rate-limited: scanning for the menu every frame is
--- pointless, and the menu is only ever entered on a level change.
function MainMenu.tick(now)
    if not cfg or not cfg.ShowMainMenuButton then return end

    if (now - state.lastScan) < 1.0 then return end
    state.lastScan = now

    -- Our panel went away (level change): forget it.
    if state.panel ~= nil and not UE.valid(state.panel) then
        state.menu, state.panel, state.injected, state.ours = nil, nil, {}, {}
    end

    -- Already injected and still alive: nothing to do.
    if UE.valid(state.panel) and #state.injected > 0 then
        local alive = false
        for _, e in ipairs(state.injected) do
            if UE.valid(e.widget) then alive = true break end
        end
        if alive then return end
        state.injected, state.ours = {}, {}
    end

    -- Behind a breadcrumb, because this is the one feature in the mod that is
    -- *known* to crash: constructing a UMG widget and parenting it into the
    -- live boot menu took the game down reliably enough that the option has
    -- been off since 1.1.1. Anyone who turns it on now gets one bad launch and
    -- an explanation rather than a menu they cannot get past.
    Safety.guard("adding the PLAY CO-OP main menu button (Config.ShowMainMenuButton)",
        function()
            if locateMenu() then showRoot() end
        end)
end

--------------------------------------------------------------------------
-- Click handling
--------------------------------------------------------------------------

--- Bound to the left mouse button. Runs whichever injected entry is hovered.
function MainMenu.onMouseDown()
    if #state.injected == 0 then return end
    for _, entry in ipairs(state.injected) do
        if UE.valid(entry.widget) then
            local ok, hovered = UE.TryCall(entry.widget, "IsHovered")
            if ok and hovered == true then
                Log.debug("menu entry clicked: %s", entry.label)
                Log.guard("menu " .. entry.label, entry.onClick)
                return
            end
        end
    end
end

function MainMenu.init(config)
    cfg = config
    -- Only when the (experimental, off by default) menu button is on. Until
    -- 1.7.0 this was bound for everybody, so every left click anywhere in the
    -- game ran Lua on UE4SS's keybind thread to find out there was nothing to
    -- do - concurrently with the game thread. Nothing to do is not free.
    if not (cfg and cfg.ShowMainMenuButton == true) then return end
    local ok = pcall(function()
        RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
            ExecuteInGameThread(function()
                Log.guard("main menu click", MainMenu.onMouseDown)
            end)
        end)
    end)
    if not ok then
        Log.warn("could not bind the mouse for the main menu button; " ..
                 "use the launcher, or rt.join in the game's console (~) instead")
    end
end

return MainMenu
