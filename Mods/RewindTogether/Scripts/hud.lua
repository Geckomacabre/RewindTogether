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

    WHAT IN YOUR HANDS AND WHAT YOU LOOK AT (the GameMode stand-in)

    Money, clock and XP are fed from here. The panel for the product in your
    hands, the hints for what you are looking at and the crosshair style are
    drawn by the game's own Blueprints, through the UI_Player_Interface_C
    function library: GetGameMode -> UI_Interface_C -> Core_Gamemode_C, which
    forwards to its "UI Game Interface" widget. On a guest GetGameMode is null
    and all of it silently does nothing.

    RewindNative.dll can answer exactly those calls with Core_Gamemode_C's
    class default object (native.lua, RewindNative.cpp "THE HUD STAND-IN").
    This file points that object's "UI Game Interface" at the guest's widget
    and arms the DLL with both. The DLL checks on every answer that both are
    still live and still linked, and disarms itself when not; the check
    below re-arms it. Map loads disarm it first thing (RegisterLoadMapPreHook)
    and the object's property is cleared, so nothing of an old world is ever
    handed to the next one. Config.GuestHudDetails = false turns it off.

    That is enough for what you LOOK at: the guest's pawn runs its own
    look-at every tick. It is not enough for what is in your HANDS. A pick-up
    happens on the host (guestinput.lua) and only its result replicates - the
    item attached to the pawn's hand socket. The pawn's "Object Hold", and
    "Set Object Hold", which is what draws the panel, never run on the guest
    (measured: the host had the guest holding the tape, the guest saw it in
    hand, and its own Object Hold stayed empty). So the hand socket is read
    here and the pawn's own Set Object Hold is called to match it: the game
    then gathers the product's details and draws the panel itself, through
    the stand-in. Everything Set Object Hold does is local - the variable,
    the attachment replication already made, the bring-up animation.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")
local Native = require("native")

local Hud = {}

local RISKY_OP   = "putting the store HUD on a guest's screen"
local WIDGET     = "UI_Player_Interface_C"
local SETTLE     = 8.0     -- seconds after the pawn appears: lets a local GameMode build it first

-- The stand-in. Paths read off the cooked assets (RetroRewind-decomp bp\):
-- the GameMode's class default, the interface the HUD calls go through, and
-- the function library that makes them. Two classes are named
-- UI_Player_Interface_C - the widget (core/widget/game_ui) and this library.
local GM_DEFAULT  = "/Game/VideoStore/core/gamemode/Core_Gamemode.Default__Core_Gamemode_C"
local UI_IFACE    = "/Game/VideoStore/core/blueprint/interface/Interface/UI_Interface.UI_Interface_C"
local HUD_LIBRARY = "/Game/VideoStore/core/blueprint/function/UI_Player_Interface.UI_Player_Interface_C"
local CHECK_EVERY = 2.0    -- seconds between "still armed?" checks
local RETRY_MAX   = 30.0   -- the longest wait between failed attempts to arm
-- Armed, it is on probation (Safety.probation) until it has answered this
-- many HUD calls: a run that dies before that switches it off next launch.
local STANDIN_OP  = "showing a guest what they hold and look at (the HUD stand-in)"
local TRUST_AFTER = 25

local cfg        = nil
local pawnSince  = nil
local created    = false
local gaveUp     = false
local widgetClassPath = nil   -- the HUD widget's class, by path: found again each time, never held
local gmOffsets  = nil   -- { frame, widget }: Core_Gamemode_C's UberGraphFrame and "UI Game Interface"

local widgetPath = nil   -- the widget, remembered by path and never held (ue.lua)
local nextWalk   = 0

local standIn = { off = false, nextCheck = 0, wait = CHECK_EVERY, armedOnce = false,
                  lastProblem = nil, touched = false, trusted = false, handedAtArm = 0 }

local HAND_EVERY = 0.25    -- seconds between looks at the hand socket
local hand = { next = 0, announced = false }

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

local function offsetOf(prop)
    local ok, v = pcall(function() return prop:GetOffset_Internal() end)
    return ok and type(v) == "number" and v > 0 and v or nil
end

--- Read off Core_Gamemode_C's own properties: the HUD widget's class (the
--- declared class of "UI Game Interface" IS the class the game builds), and,
--- once per process, where that property and the UberGraphFrame sit - what
--- the DLL needs to check the stand-in on every answer. Returns the class,
--- for this tick only; its path is what is kept.
local function readGameModeClass()
    local gmClass = StaticFindObject(UE.Paths.GameMode)
    if not UE.valid(gmClass) then return nil end
    local offsets, cls = {}, nil
    pcall(function()
        gmClass:ForEachProperty(function(prop)
            local n = prop:GetFName():ToString()
            if n == "UI Game Interface" then
                local c = prop:GetPropertyClass()
                if UE.valid(c) then cls = c end
                offsets.widget = offsetOf(prop)
            elseif n == "UberGraphFrame" then
                offsets.frame = offsetOf(prop)
            end
        end)
    end)
    if offsets.widget and offsets.frame then gmOffsets = offsets end
    widgetClassPath = UE.pathOf(cls)
    return cls
end

--- The HUD widget's class, for this tick. A Blueprint class goes when its
--- package does, so it is looked up by path rather than held (ue.lua).
local function resolveClass()
    if widgetClassPath then
        local c = UE.findObject(widgetClassPath)
        if UE.valid(c) then return c end
        widgetClassPath = nil
    end
    return readGameModeClass()
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

--- Builds the HUD once, a few seconds after the guest has a pawn, if nothing
--- else has.
local function build(now)
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

--------------------------------------------------------------------------
-- The GameMode stand-in (see the header)
--------------------------------------------------------------------------

--- Let go of the widget on the GameMode's class default. StaticFindObject,
--- not findObject: this also runs while a map is starting to unload, and it
--- must call no engine function there.
local function releaseGameModeDefault()
    if not standIn.touched then return end
    standIn.touched = false
    local d = StaticFindObject(GM_DEFAULT)
    if UE.valid(d) then UE.TrySet(d, "UI Game Interface", nil) end
end

--- Point the GameMode's class default at the HUD widget and arm the DLL with
--- both. Returns true, or false, why not, and whether that is for good.
local function armStandIn()
    if not Native.installStandIn() then
        return false, Native.standInProblem() or "RewindNative.dll is not loaded", true
    end
    local w = Hud.find()
    if not w then return false, "the HUD widget is gone", false end
    if not gmOffsets then readGameModeClass() end
    if not gmOffsets then return false, "could not read Core_Gamemode_C's layout", true end

    -- Only while arming, so the 1-2 ms StaticFindObject fallback is affordable.
    local function find(path)
        local o = UE.findObject(path)
        if o then return o end
        o = StaticFindObject(path)
        return UE.valid(o) and o or nil
    end
    local gmDefault, iface, library = find(GM_DEFAULT), find(UI_IFACE), find(HUD_LIBRARY)
    if not (gmDefault and iface and library) then
        return false, ("not loaded yet:%s%s%s"):format(gmDefault and "" or " the GameMode default",
            iface and "" or " UI_Interface_C", library and "" or " the HUD library"), false
    end
    if not UE.TrySet(gmDefault, "UI Game Interface", w) then
        return false, "could not point the GameMode default at the HUD widget", false
    end
    standIn.touched = true
    -- Its own code runs in Hud.tick (the hand mirror calls Blueprints that
    -- reach it); the rest of the time it runs inside the engine's frame.
    if not standIn.trusted and not Safety.probation(STANDIN_OP, { "Hud.tick" }) then
        releaseGameModeDefault()
        return false, "it is switched off after an earlier crash (rt.safety)", true
    end
    local ok, why, forGood = Native.armStandIn(gmDefault, w, gmOffsets.frame, gmOffsets.widget,
                                               iface, library)
    if ok then
        local st = Native.standInStats()
        standIn.handedAtArm = st and st.handed or 0
        return true
    end
    -- Not armed, so nothing may reach the default through it: let go now.
    Safety.trusted(STANDIN_OP)
    releaseGameModeDefault()
    return false, why, forGood
end

--- Keep it armed while there is a HUD: the DLL disarms itself the moment
--- anything it relies on stops being live, and this puts it back.
local function standInTick(now)
    if standIn.off or now < standIn.nextCheck then return end
    if cfg and cfg.GuestHudDetails == false then
        standIn.off = true
        Log.info("guest HUD: what you hold and look at is not shown (Config.GuestHudDetails = false)")
        return
    end
    local st = Native.standInStats()
    if st and st.armed then
        if not standIn.trusted and (st.handed - standIn.handedAtArm) >= TRUST_AFTER then
            standIn.trusted = true
            Safety.trusted(STANDIN_OP)
            Log.info("guest HUD: the GameMode stand-in has answered %d HUD calls - off probation",
                     st.handed - standIn.handedAtArm)
        end
        standIn.wait = CHECK_EVERY
        standIn.nextCheck = now + CHECK_EVERY
        return
    end

    local ok, why, forGood = armStandIn()
    if ok then
        if not standIn.armedOnce then
            Log.info("guest HUD: what you hold and what you look at now show here too " ..
                     "(GameMode stand-in armed)")
        else
            Log.debug("guest HUD: GameMode stand-in re-armed")
        end
        standIn.armedOnce, standIn.lastProblem, standIn.wait = true, nil, CHECK_EVERY
    elseif forGood then
        standIn.off = true
        Log.warn("guest HUD: what you hold and what you look at cannot be shown - %s", tostring(why))
    else
        if why ~= standIn.lastProblem then
            Log.info("guest HUD: details not shown yet - %s (trying again)", tostring(why))
        end
        standIn.lastProblem = why
        standIn.wait = math.min(standIn.wait * 2, RETRY_MAX)
    end
    standIn.nextCheck = now + standIn.wait
end

--- What replication has attached to the pawn's hand socket ("AttachObject
--- Socket", where Set Object Hold puts things), or nil. The second result is
--- false when the socket could not be read at all.
local function inHand(pawn)
    local socket = UE.TryGet(pawn, "AttachObject Socket")
    if not UE.valid(socket) then return nil, false end
    local n = 0
    pcall(function() n = socket:GetNumChildrenComponents() end)
    for i = 0, (tonumber(n) or 0) - 1 do
        local owner = nil
        pcall(function() owner = socket:GetChildComponent(i):GetOwner() end)
        if UE.alive(owner) and not UE.sameObject(owner, pawn) then return owner, true end
    end
    return nil, true
end

--- Keep the pawn's own Object Hold in step with its hand socket, so the game
--- draws the product panel. Only while the stand-in is armed: without it the
--- panel cannot appear, and the pawn is better left exactly as it was.
local function handTick(now)
    if now < hand.next then return end
    hand.next = now + HAND_EVERY
    local st = Native.standInStats()
    if not (st and st.armed) then return end
    local pawn = UE.GetPawn()
    if not (UE.alive(pawn) and UE.ClassNameOf(pawn) == "Player_Character_C") then return end
    local held, readable = inHand(pawn)
    if not readable then return end
    local mine = UE.TryGet(pawn, "Object Hold")
    if not UE.valid(mine) then mine = nil end
    if held == nil and mine == nil then return end
    if held ~= nil and mine ~= nil and UE.sameObject(held, mine) then return end
    -- Not UE.TryCall: it packs its arguments in a table, and a lone nil (an
    -- empty hand) would vanish instead of reaching the engine as null.
    if pcall(function() pawn["Set Object Hold"](pawn, held) end) then
        if not hand.announced and held then
            hand.announced = true
            Log.info("guest HUD: you are holding %s - shown on your HUD", UE.ClassNameOf(held))
        end
        Log.debug("guest HUD: hand now %s", held and UE.ClassNameOf(held) or "empty")
    end
end

--- Guest side, every tick: the HUD, then what it shows about your hands.
function Hud.tick(now)
    if not UE.IsClient() then return end
    if not (created or gaveUp) then build(now) end
    if created then
        standInTick(now)
        handTick(now)
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

--- A short message where the game shows its own ("Can't place that here"):
--- the HUD's UI_Error child, which floats the text up and fades it out after
--- about 0.04 s per character (1 s at least). Its Display Error takes an
--- FString, so no FText is ever written; "{br}" is its line break. Red when
--- isError. `seconds` keeps it up longer than that: its timer ticks every
--- 0.01 s and Display Error has just set "Animation Time" in ticks. Measured on
--- the real game: a centred dark box, gold text. False when there is no HUD
--- (main menu, loading screens).
function Hud.notice(text, isError, seconds)
    local w = Hud.find(true)
    if not w then return false end
    local box = UE.TryGet(w, "UI_Error")
    if not alive(box) then return false end
    local ok = UE.TryCall(box, "Display Error", tostring(text), isError == true)
    if ok and seconds then
        local ticks = math.floor(seconds * 100)
        if (tonumber(UE.TryGet(box, "Animation Time")) or 0) < ticks then
            UE.TrySet(box, "Animation Time", ticks)
        end
    end
    return ok
end

--- Run fn with the stand-in answering ANOTHER Blueprint class for the length
--- of one call, then the HUD library again. For the skin picker
--- (guestinput.lua): a wall's or a shelf's own Init Mesh Flow / Init Skin
--- Flow is GetGameMode -> ToInterface<UI_Interface_C> -> Generate Skin UI -
--- the HUD library's shape exactly, from that class's ubergraph - and the DLL
--- already takes the class it answers as an argument. The skin flows were
--- left out of the stand-in because a guest would re-skin things only they
--- could see; guestinput.lua now sends the choice to the host. Only while the
--- stand-in is armed: never without the DLL, or with GuestHudDetails off.
--- Returns whether fn ran.
function Hud.withStandInFor(library, fn)
    local st = Native.standInStats()
    if standIn.off or not (st and st.armed) or not gmOffsets then return false end
    local w = Hud.find()
    local gmDefault, iface = UE.findObject(GM_DEFAULT), UE.findObject(UI_IFACE)
    local hudLibrary = UE.findObject(HUD_LIBRARY)
    if not (w and gmDefault and iface and hudLibrary and UE.valid(library)) then return false end
    if not Native.armStandIn(gmDefault, w, gmOffsets.frame, gmOffsets.widget, iface, library) then
        armStandIn()
        return false
    end
    local ok, err = pcall(fn)
    if not Native.armStandIn(gmDefault, w, gmOffsets.frame, gmOffsets.widget, iface, hudLibrary) then
        armStandIn()
    end
    if not ok then Log.debug("guest HUD: %s", tostring(err)) end
    return ok
end

--- Back to single player, or a map is about to load: the next world decides
--- afresh. The stand-in goes first - Blueprints of the next world run before
--- this mod ticks again.
function Hud.reset()
    Native.disarmStandIn()
    Safety.trusted(STANDIN_OP)      -- switched off cleanly: nothing left to blame it for
    releaseGameModeDefault()
    created, gaveUp, pawnSince = false, false, nil
    widgetPath, nextWalk = nil, 0
    questHidden = false
    standIn.nextCheck, standIn.wait, standIn.lastProblem = 0, CHECK_EVERY, nil
    hand.next = 0
end

function Hud.init(config)
    cfg = config
    -- Inside UEngine::LoadMap, before the old world is torn down: polling
    -- from the tick would be a frame late, and the widget dies with that
    -- world. Without this hook the DLL's own liveness check still refuses a
    -- dead widget; this keeps it from ever having to.
    if type(RegisterLoadMapPreHook) == "function" then
        local ok = pcall(RegisterLoadMapPreHook, function()
            Log.guard("map load (guest HUD)", Hud.reset)
        end)
        if not ok then Log.debug("guest HUD: RegisterLoadMapPreHook refused") end
    end
end

return Hud
