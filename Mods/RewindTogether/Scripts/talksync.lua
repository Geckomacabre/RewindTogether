--[[
    Rewind Together - a guest's conversations, on the guest's screen

    THE TALK SYSTEM (bp/TalkSystem.txt, bp/UI_Talk.txt, bp/UI_Talk-Answer.txt)

    Talking to the staff member (a raise, a sick day), a customer's fee at the
    till, a customer asking for help, the telephone: the game spawns a
    TalkSystem_C actor for the player it was handed - GetPlayerPawn(0) at the
    moment of the click, which during a guest's replayed click (guestinput.lua)
    is the guest's pawn. Its BeginPlay turns that player's camera to the NPC
    over half a second (a timeline that asks GetPlayerPawn(0) again on every
    frame) and draws UI_Talk: the NPC's line, the NPC's name and its answer
    buttons (UI_Talk-Answer: an answer type, a text, a number). A click on one
    broadcasts the answer type to whoever spawned the talk, which draws the
    next line into the same widget or ends the talk.

    REPORTED: a guest's right click on the staff member at the till opened the
    dialog on the HOST's screen. All of the above runs on the host: the widget
    went into the host's viewport, and the camera turn - asking for player 0
    long after the replay had ended - would swing the host's view at the NPC.
    The guest saw nothing and could not answer.

    WHAT THIS DOES

    Host: a hook on TalkSystem_C's BeginPlay (a hook on a Blueprint function
    runs after it) stops the camera turn and takes the widget out of the
    host's viewport when the talk's player is a guest's pawn. The widget stays
    alive and bound to the talk - the game keeps drawing each next line into
    it - and the host reads what it shows and sends it to that guest.

    Guest: the same widget, built and filled with the host's words and answer
    buttons, with the mouse; the guest's key presses are not sent to the host
    while it is up. A click on an answer goes back as guest action 11, and the
    host clicks the same answer on its hidden widget, as the guest. A talk
    that ends on the host closes on the guest.

    Not mirrored: the extra content a few talks add under the line (a film's
    poster for a customer's request), and the camera turn on the guest's side.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local TalkSync = {}

local TALK_PATH  = "/Game/VideoStore/core/blueprint/talksystem/TalkSystem.TalkSystem_C"
local BEGIN_FN   = TALK_PATH .. ":ReceiveBeginPlay"
local END_FN     = TALK_PATH .. ":End Talk System"
local TALK_UI    = "/Game/VideoStore/core/blueprint/talksystem/UI_Talk.UI_Talk_C"
local ANSWER_UI  = "/Game/VideoStore/core/blueprint/talksystem/UI_Talk-Answer.UI_Talk-Answer_C"
local ANSWER_FN  = ANSWER_UI .. ":Button Clicked Event"
TalkSync.ANSWER_CODE = 11       -- guest action (guestinput.lua ACTIONS)
local HOST_EVERY = 0.2
local RESEND     = 3.0
local CLICK_GAP  = 0.4          -- guest: one answer per click, not one per frame
local GUEST_TIMEOUT = 10.0     -- guest: the host says the talk again every RESEND s;
                               -- silence this long means it is over (a host reload, a lost message)
local RISKY_OP   = "showing a conversation on a guest's screen"

local cfg = nil
local stats = { hidden = 0, sent = 0, shown = 0, answered = 0, replayed = 0 }

local function paramValue(p)
    local v = p
    pcall(function() v = p:get() end)
    return v
end

local function stringOf(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or ""
end

local function widgetText(w)
    if not UE.valid(w) then return "" end
    local s = nil
    pcall(function() s = w:GetText():ToString() end)
    if type(s) == "string" then return s end
    return stringOf(UE.TryGet(w, "Text"))
end

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

--- Hook a function once, and again when its class was loaded anew (a new
--- world): a hook belongs to the function object it was put on.
local hooked = {}               -- path -> the address it was hooked at
local function hookOnce(path, fn)
    local f = StaticFindObject(path)
    if not UE.valid(f) then return false end
    local addr = addressOf(f)
    if not addr or hooked[path] == addr then return hooked[path] == addr end
    local ok = pcall(function()
        RegisterHook(path, function(...)
            local args = { ... }
            Log.guard("conversation hook", function() fn(table.unpack(args)) end)
        end)
    end)
    if ok then hooked[path] = addr end
    return ok
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local talks = {}                -- talk path -> { pc = controller path, sig, at, ended }
local nextHost, nextHook = 0, 0

local function guestPlayerOf(talk)
    local player = UE.TryGet(talk, "Player")
    if not UE.valid(player) then return nil end
    local isLocal = true
    pcall(function() isLocal = player:IsLocallyControlled() end)
    if isLocal then return nil end
    local pc = nil
    pcall(function() pc = player:GetController() end)
    return UE.alive(pc) and pc or nil, player
end

local function hideWidget(talk)
    local w = UE.TryGet(talk, "Widget Talk")
    if not UE.valid(w) then return end
    local shown = false
    pcall(function() shown = w:IsInViewport() end)
    if shown then pcall(function() w:RemoveFromParent() end) end
end

local function onTalkBegin(ctx)
    if not UE.IsServer() or (cfg and cfg.GuestConversations == false) then return end
    local talk = paramValue(ctx)
    if not UE.valid(talk) then return end
    local pc = guestPlayerOf(talk)
    if not pc then return end
    -- Before the next frame: the turn would be the host's camera, the
    -- dialog the host's screen.
    UE.TryCall(talk, "Force Stop LookAt")
    hideWidget(talk)
    local path, pcPath = UE.pathOf(talk), UE.pathOf(pc)
    if path and pcPath then
        talks[path] = { pc = pcPath, sig = nil, at = -1e9 }
        stats.hidden = stats.hidden + 1
        Log.info("conversation: %s is talking - shown on their screen, not here",
                 UE.PlayerNameOf(pc) or "a guest")
    end
end

local function onTalkEnd(ctx)
    if not UE.IsServer() then return end
    local path = UE.pathOf(paramValue(ctx))
    if path and talks[path] then talks[path].ended = true end
end

--- What the hidden widget shows, as sent: the line, the name, the answers.
local function read(talk)
    local w = UE.TryGet(talk, "Widget Talk")
    if not UE.valid(w) then return nil end
    local f = { s = "1", t = widgetText(UE.TryGet(w, "txt_talk")) }
    local name = UE.TryGet(w, "txt_NameClient")
    f.n = widgetText(name)
    f.nv = tostring(math.floor(tonumber(UE.TryGet(name, "Visibility")) or 1))
    local zone = UE.TryGet(w, "Zone_ButtonAnswer")
    local n = 0
    if UE.valid(zone) then pcall(function() n = zone:GetChildrenCount() end) end
    local count = 0
    for i = 0, (tonumber(n) or 0) - 1 do
        local b = nil
        pcall(function() b = zone:GetChildAt(i) end)
        if UE.valid(b) then
            count = count + 1
            f["a" .. count] = ("%d\t%d\t%s"):format(math.floor(tonumber(UE.TryGet(b, "Answer Type")) or 0),
                math.floor(tonumber(UE.TryGet(b, "Number Text")) or count), stringOf(UE.TryGet(b, "Button Text")))
        end
    end
    f.c = tostring(count)
    return f
end

local function signature(f)
    local parts = { f.t or "", f.n or "", f.nv or "" }
    for i = 1, tonumber(f.c) or 0 do parts[#parts + 1] = f["a" .. i] or "" end
    return table.concat(parts, "\n")
end

--- The host is walking about: no register, no menu, no cursor.
local function hostIsWalking()
    local pc = UE.GetPlayerController()
    return UE.alive(pc) and UE.TryGet(pc, "Walking Mapping Context is Enable") == true
           and UE.TryGet(pc, "bShowMouseCursor") ~= true
end

function TalkSync.tickHost(now)
    if not UE.IsServer() then return end
    if now >= nextHook then
        nextHook = now + 5
        hookOnce(BEGIN_FN, onTalkBegin)
        hookOnce(END_FN, onTalkEnd)
    end
    if next(talks) == nil or now < nextHost then return end
    nextHost = now + HOST_EVERY
    for path, t in pairs(talks) do
        local talk, pc = UE.findObject(path), UE.findObject(t.pc)
        if not UE.alive(pc) then
            -- The guest has gone mid-conversation: nobody will answer it, and
            -- whoever started it (the staff member) would wait for good. Its
            -- own "quit" answer (type 1: Quit or Cancel) ends it - but ending a
            -- talk runs its "Set Player In Game Mode" on player 0, which is now
            -- the host (walking controls on, game-only input, cursor off). So
            -- only while the host is simply walking, where that changes nothing;
            -- at the register or in a menu it waits.
            local w = UE.alive(talk) and not t.ended and UE.TryGet(talk, "Widget Talk") or nil
            if not UE.valid(w) then
                talks[path] = nil
            elseif hostIsWalking() then
                UE.TryCall(w, "Clicked on Answer Button Event", 1)
                talks[path] = nil
            end
        elseif t.ended or not UE.alive(talk) then
            t.endTries = (t.endTries or 0) + 1
            if Chan.sendTo(pc, "talk", { e = "1" }) or t.endTries > 10 then talks[path] = nil end
        else
            hideWidget(talk)                     -- in case anything put it back
            local f = read(talk)
            local sig = f and signature(f) or nil
            if sig and (sig ~= t.sig or now - t.at > RESEND) then
                if Chan.sendTo(pc, "talk", f) then
                    t.sig, t.at = sig, now
                    stats.sent = stats.sent + 1
                end
            end
        end
    end
end

--- Guest action 11 (guestinput.lua): the guest clicked an answer. Clicked on
--- this player's hidden widget, as them - what follows (the next line, the
--- talk's end, a raise) is the game's, and GetPlayerController(0) inside it
--- answers with the guest. Returns true when there was a talk to answer.
function TalkSync.answer(pc, answer, asGuest)
    if type(answer) ~= "number" or not UE.alive(pc) then return false end
    local mine = addressOf(UE.TryGet(pc, "Pawn"))
    for path, t in pairs(talks) do
        local talk = UE.findObject(path)
        local player = UE.alive(talk) and UE.TryGet(talk, "Player") or nil
        if mine and UE.valid(player) and addressOf(player) == mine and not t.ended then
            local w = UE.TryGet(talk, "Widget Talk")
            if not UE.valid(w) then return false end
            asGuest(pc, function() w["Clicked on Answer Button Event"](w, answer) end)
            stats.replayed = stats.replayed + 1
            t.at = -1e9                          -- say the next line at once
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local guest = { path = nil, answers = nil, lastClick = -1e9, heardAt = 0 }

local function libraries()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"),
           StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
end

local function guestWidget()
    if not guest.path then return nil end
    local w = UE.findObject(guest.path)
    if UE.valid(w) then return w end
    guest.path, guest.answers = nil, nil
    return nil
end

--- The mouse for the dialog, and back (Player_Input_GameOrUI's two
--- functions, which are these calls on player 0).
local function uiInput(w, on)
    local pc = UE.GetPlayerController()
    local wbl = libraries()
    if not (UE.alive(pc) and UE.valid(wbl)) then return end
    UE.TrySet(pc, "bShowMouseCursor", on)
    if on then
        pcall(function() wbl:SetInputMode_UIOnlyEx(pc, w, 0, true) end)
    else
        pcall(function() wbl:SetInputMode_GameOnly(pc, false) end)
    end
end

local function closeGuest()
    local w = guestWidget()
    guest.path, guest.answers = nil, nil
    if not w then return end
    pcall(function() w:RemoveFromParent() end)
    uiInput(nil, false)
end

local onAnswerClicked                    -- below; hooked once the class exists

local function createGuest()
    local cls = UE.load(TALK_UI)
    local wbl = libraries()
    local world, pc = UE.GetWorld(), UE.GetPlayerController()
    if not (UE.valid(cls) and UE.valid(wbl) and UE.valid(world) and UE.alive(pc)) then return nil end
    local ran, w = Safety.guard(RISKY_OP, function()
        local made = nil
        pcall(function() made = wbl:Create(world, cls, pc) end)
        if not UE.valid(made) then return nil end
        pcall(function() made:AddToViewport(20) end)
        return made
    end)
    if not (ran and UE.valid(w)) then return nil end
    guest.path, guest.answers = UE.pathOf(w), nil
    UE.load(ANSWER_UI)
    hookOnce(ANSWER_FN, onAnswerClicked)
    uiInput(w, true)
    stats.shown = stats.shown + 1
    Log.info("conversation: on your screen - answer with the mouse")
    return w
end

--- The answer buttons, made the way UI_Talk makes them (Draw New Talk
--- Structure, @537-@973): Create, the three properties, AddChild.
local function fillAnswers(w, f)
    local list = {}
    for i = 1, tonumber(f.c) or 0 do list[#list + 1] = f["a" .. i] or "" end
    local sig = table.concat(list, "\n")
    if sig == guest.answers then return end
    local zone = UE.TryGet(w, "Zone_ButtonAnswer")
    local cls = UE.load(ANSWER_UI)
    local wbl, ksl = libraries()
    local world, pc = UE.GetWorld(), UE.GetPlayerController()
    if not (UE.valid(zone) and UE.valid(cls) and UE.valid(wbl) and UE.valid(ksl)) then return end
    pcall(function() zone:ClearChildren() end)
    for _, line in ipairs(list) do
        local kind, num, text = line:match("^(%d+)\t(%d+)\t(.*)$")
        if kind then
            local b = nil
            pcall(function() b = wbl:Create(world, cls, pc) end)
            if UE.valid(b) then
                pcall(function() ksl:SetBytePropertyByName(b, FName("Answer Type"), tonumber(kind)) end)
                pcall(function() ksl:SetStringPropertyByName(b, FName("Button Text"), text) end)
                pcall(function() ksl:SetIntPropertyByName(b, FName("Number Text"), tonumber(num)) end)
                pcall(function() zone:AddChild(b) end)
            end
        end
    end
    guest.answers = sig
end

local function onTalk(fields)
    if UE.IsServer() then return end
    if fields.e == "1" then closeGuest() return end
    if fields.s ~= "1" then return end
    guest.heardAt = os.clock()
    local w = guestWidget() or createGuest()
    if not w then return end
    local line = UE.TryGet(w, "txt_talk")
    if UE.valid(line) and widgetText(line) ~= (fields.t or "") then
        pcall(function() line:SetText(FText(fields.t or "")) end)
    end
    local name = UE.TryGet(w, "txt_NameClient")
    if UE.valid(name) then
        if widgetText(name) ~= (fields.n or "") then pcall(function() name:SetText(FText(fields.n or "")) end) end
        local vis = tonumber(fields.nv)
        if vis and tonumber(UE.TryGet(name, "Visibility")) ~= vis then pcall(function() name:SetVisibility(vis) end) end
    end
    fillAnswers(w, fields)
end

--- A click on one of this guest's answer buttons (a hook on the button's own
--- click event, which broadcasts to nothing here: the guest's widget is bound
--- to no talk).
function onAnswerClicked(ctx)
    if UE.IsServer() or not guestWidget() then return end
    local t = os.clock()
    if t - guest.lastClick < CLICK_GAP then return end
    local b = paramValue(ctx)
    local kind = tonumber(UE.TryGet(b, "Answer Type"))
    if not kind then return end
    guest.lastClick = t
    if Chan.sendAction(TalkSync.ANSWER_CODE, { X = 0, Y = 0, Z = 0 },
                       { Pitch = kind, Yaw = tonumber(UE.TryGet(b, "Number Text")) or 0, Roll = 0 }) > 0 then
        stats.answered = stats.answered + 1
    end
end

--- Guest, every tick: a conversation the host has stopped saying is over.
--- Without this a lost "it ended" (or a host's hot reload, which forgets its
--- talks) left the dialog up and the guest's mouse in it for good.
function TalkSync.tickGuest()
    if guest.path and os.clock() - guest.heardAt > GUEST_TIMEOUT then
        Log.info("conversation: the host stopped answering - closed")
        closeGuest()
    end
end

--- True while a conversation is up on this guest's screen: its key presses
--- are its own (guestinput.lua does not send them).
function TalkSync.guestTalking()
    if not (UE.IsClient() and guest.path ~= nil) then return false end
    if os.clock() - guest.heardAt > GUEST_TIMEOUT then closeGuest() return false end
    return guestWidget() ~= nil
end

--------------------------------------------------------------------------

function TalkSync.stats() return stats end

--- Tests: pretend the host last spoke this many seconds ago.
function TalkSync._ageGuest(seconds) guest.heardAt = os.clock() - seconds end

function TalkSync.reset()
    talks, nextHost, nextHook = {}, 0, 0
    if guest.path then closeGuest() end
    guest = { path = nil, answers = nil, lastClick = -1e9, heardAt = 0 }
end

function TalkSync.init(config)
    cfg = config
    Chan.on("talk", function(f) Log.guard("conversation", onTalk, f) end)
end

return TalkSync
