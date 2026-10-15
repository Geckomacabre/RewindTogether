--[[
    Rewind Together - the store HUD on a guest's screen

    WHY A GUEST HAS NONE

    The money, the clock, the XP bar and the toolbar are one widget,
    UI_Player_Interface_C, and the only thing that ever creates it is
    Core_Gamemode_C ("Init UI Game Interface", read off the class in 1.7.0).
    A GameMode exists on the server only, so a guest never gets one and never
    gets a HUD - which is the "guest has no HUD at all" in PROJECT.md 10.

    WHAT THIS DOES

    Finds that widget if something already built it (a local GameMode, a
    future game update), and otherwise builds it the way the GameMode does:
    WidgetBlueprintLibrary::Create, then AddToViewport. Then it is fed the
    host's numbers through the widget's own setters - Change Money Value,
    Change Time, Change Week Day, Change XP Value - so it draws exactly what
    the host's does, in the game's own style.

    The widget's class is read off Core_Gamemode_C's "UI Game Interface"
    property rather than typed in as a path: the property's declared class IS
    the class the game builds, and a path is a guess about where a cooked
    asset happens to live.

    Creating a widget is a native call, so the first one goes behind a crash
    breadcrumb like everything else in this mod that can fault.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Hud = {}

local RISKY_OP   = "putting the store HUD on a guest's screen"
local WIDGET     = "UI_Player_Interface_C"
local SETTLE     = 8.0     -- seconds after the pawn appears: lets a local GameMode build it first

local cfg        = nil
local pawnSince  = nil
local created    = false
local gaveUp     = false
local widgetClass = nil

local widgetPath = nil   -- the widget, remembered by path and never held (ue.lua)
local nextWalk   = 0

local function alive(o) return UE.alive(o) end

--- The widget, if one exists in this process right now. Found again by its
--- path each time (0.03 ms). The 15 ms walk only happens while the path is
--- not known, and then at most every few seconds unless `force` says now:
--- every setter below asks, and a sync update calls up to four of them.
function Hud.find(force)
    if widgetPath then
        local w = UE.findObject(widgetPath)
        if alive(w) then return w end
        widgetPath = nil
    end
    local t = os.clock()
    if not force and t < nextWalk then return nil end
    nextWalk = t + 5
    local w = FindFirstOf(WIDGET)
    if alive(w) then
        widgetPath = UE.pathOf(w)
        return w
    end
    return nil
end

local function resolveClass()
    if widgetClass and UE.valid(widgetClass) then return widgetClass end
    local gmClass = StaticFindObject(UE.Paths.GameMode)
    if not UE.valid(gmClass) then return nil end
    pcall(function()
        gmClass:ForEachProperty(function(prop)
            if widgetClass then return end
            local n = prop:GetFName():ToString()
            if n == "UI Game Interface" then
                local c = prop:GetPropertyClass()
                if UE.valid(c) then widgetClass = c end
            end
        end)
    end)
    return widgetClass
end

local function create()
    local cls = resolveClass()
    if not cls then
        Log.warn("guest HUD: could not find the HUD widget's class on " ..
                 "Core_Gamemode_C - money and the clock will show in rt.status only")
        return nil
    end
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local world, pc = UE.GetWorld(), UE.GetPlayerController()
    if not (UE.valid(wbl) and UE.valid(world) and alive(pc)) then return nil end

    local ran, widget = Safety.guard(RISKY_OP, function()
        local w = nil
        pcall(function() w = wbl:Create(world, cls, pc) end)
        if not UE.valid(w) then return nil end
        pcall(function() w:AddToViewport(0) end)
        return w
    end)
    if not ran then
        Log.warn("guest HUD is switched off after an earlier crash (rt.safety)")
        return nil
    end
    return widget
end

--- The quest panel shows the GUEST's own quests - and a guest whose local
--- GameMode started a fresh game gets the tutorial ("Access the catalogue
--- located in the office 0/1", measured in 1.7.0). The host's quests are not
--- mirrored, so a guest seeing quests at all is seeing the wrong ones.
local questHidden = false
local function hideGuestQuests(w)
    if questHidden then return end
    local panel = UE.TryGet(w, "Quest_Global-Interface_UI")
    if UE.valid(panel) and UE.TryCall(panel, "SetVisibility", 1) then   -- Collapsed
        questHidden = true
        Log.info("guest HUD: quest panel hidden (it shows your quests, not the host's)")
    end
end

--- Guest side, every tick. Builds the HUD once, a few seconds after the
--- guest has a pawn, if nothing else has.
function Hud.tick(now)
    if created or gaveUp or not UE.IsClient() then return end
    if cfg and cfg.GuestHud == false then gaveUp = true return end

    if not UE.valid(UE.GetPawn()) then pawnSince = nil return end
    pawnSince = pawnSince or now
    if (now - pawnSince) < SETTLE then return end

    local existing = Hud.find(true)
    if existing then
        created = true
        hideGuestQuests(existing)
        Log.info("guest HUD: the game's own HUD is already up")
        return
    end

    local w = create()
    if w then
        widgetPath = UE.pathOf(w)
        hideGuestQuests(w)
        created = true
        Log.info("guest HUD: built %s - it shows the host's money and clock",
                 UE.ClassNameOf(w))
    else
        gaveUp = true
        Log.warn("guest HUD: could not be built - rt.status still shows the " ..
                 "host's money and time")
    end
end

--- Feed a value to the widget through its own setter. Quiet when there is no
--- widget: that is normal on the host for half a second after travel.
local function call(fn, ...)
    local w = Hud.find()
    if not w then return false end
    local ok = UE.TryCall(w, fn, ...)
    return ok
end

function Hud.setMoney(v)      return call("Change Money Value", 0, v) end
function Hud.setXP(v)         return call("Change XP Value", 0, v) end
function Hud.setTime(h, m)    return call("Change Time", h, m) end
function Hud.setWeekday(d)    return call("Change Week Day", d) end

--- Back to single player: the next session decides afresh.
function Hud.reset()
    created, gaveUp, pawnSince = false, false, nil
    widgetPath, nextWalk = nil, 0
    questHidden = false
end

function Hud.init(config) cfg = config end

return Hud
