--[[
    Rewind Together - the character screen

    REQUESTED (16 Oct 2026): "make the character select show all possible
    characters and let people pick one ... feel free to add new UI for the
    character selector/creator, make it like the developers made it
    themselves".

    So it is made of the game's own pieces:
      * The frame is the game's pause menu (UI_ESC-Menu_C), made a second
        time for this: its Construct is what the game does to open a menu -
        the mouse pointer, the menu's own key mapping (nothing walks or looks
        about while it is up), and on the host a pause, which is taken back at
        once (the store keeps running for everybody). Its blur is hidden and
        its buttons taken out; what goes in is a dark panel on the right with
        the game's font (the menu's own "last save" line's) and the game's own
        yellow buttons (UX_Button_ESC_C, as pausemenu.lua uses for "Back to
        the store").
      * The character stands in the store in front of you, a figure made for
        this screen only (an engine SkeletalMeshActor, not replicated) and
        dressed by bodies.lua the way every other body is, playing the town's
        own idle.
      * Rows: a REGULAR - your own, or one of the game's 14 named regulars
        (AI_Data_Membership-Unique) - then body, skin, hair and its colour,
        beard, glasses, top, bottom and shoes each with a colour, and height:
        every choice the game itself has (creator.lua, wardrobe.lua).
        RANDOM makes one the way the game makes a passer-by. DONE keeps it,
        CANCEL (or Escape) leaves everything as it was.
      * Closing is the menu's own "Close ESC": the game's own input mode and
        pointer back, as after the pause menu.

    Clicks: the buttons' shared click event (UX_Button_Base, hooked once,
    queued, acted on from the tick - never inside the hook).
]]

local Log     = require("log")
local UE      = require("ue")
local Creator = require("creator")

local Screen = {}

local ESC_CLASS   = "/Game/VideoStore/core/widget/game_ui/UI_ESC-Menu.UI_ESC-Menu_C"
local BTN_CLASS   = "/Game/VideoStore/core/widget/button/UX_Button_ESC.UX_Button_ESC_C"
local BTN_CLICKED = "/Game/VideoStore/core/widget/button/UX_Button_Base.UX_Button_Base_C:" ..
                    "BndEvt__UX_Button_Base_Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local WIDGETS     = "/Script/UMG.Default__WidgetBlueprintLibrary"
local FIGURE      = "/Script/Engine.SkeletalMeshActor"
local IDLE        = "/Game/VideoStore/asset/character/animation/idle/Anim_CHA_Idle_1.Anim_CHA_Idle_1"
local UMG = {
    text = "/Script/UMG.TextBlock", hbox = "/Script/UMG.HorizontalBox", vbox = "/Script/UMG.VerticalBox",
    border = "/Script/UMG.Border", size = "/Script/UMG.SizeBox",
}

local AHEAD      = 300.0    -- cm: the figure, in front of the camera
local LEFT       = 75.0     -- cm: and to the left, clear of the panel
local CHEST      = 100.0    -- cm above the floor: where the view looks
local ROW_WIDTH  = 680.0
local COLOUR_WIDTH = 200.0  -- the colour button, whatever colour it names ("ORIGINAL" the longest)
local COLOUR_TEXT  = 24     -- its words a size down from the button's own 32
local FACE_YAW   = 90.0     -- a character's mesh faces its +Y (bodies.lua)
local BEHIND     = 60.0     -- cm clear past the figure's spot
local NEAREST    = 160.0    -- cm: the figure never closer than this
-- Which ways to try, degrees from where you look, best first.
local TURNS      = { 0, 25, -25, 50, -50, 80, -80, 115, -115, 150, -150, 180 }
local VIEWS      = { "FRONT", "LEFT SIDE", "BACK", "RIGHT SIDE" }

-- What each row shows, and which rows have a colour button.
local ROWS = {
    { key = "body",   title = "BODY" },
    { key = "skin",   title = "SKIN" },
    { key = "hair",   title = "HAIR",    colour = "hairColour" },
    { key = "facial", title = "BEARD" },
    { key = "acc",    title = "GLASSES" },
    { key = "top",    title = "TOP",     colour = "topTint" },
    { key = "bottom", title = "BOTTOM",  colour = "bottomTint" },
    { key = "shoes",  title = "SHOES",   colour = "shoesTint" },
    { key = "height", title = "HEIGHT" },
    { key = "turn",   title = "TURN",    view = true },     -- the figure, not the look
}

local open = nil            -- the screen while it is up (paths and state, no objects)
local buttons = {}          -- button address -> { what, row }
local queue = {}
local hooked = false
local stats = { opened = 0, done = 0, cancelled = 0, changes = 0 }

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

local function find(path) return path and UE.findObject(path) or nil end

local function make(clsPath, outer)
    local cls = StaticFindObject(clsPath)
    if not UE.valid(cls) then return nil end
    local w = nil
    pcall(function() w = StaticConstructObject(cls, outer) end)
    return UE.valid(w) and w or nil
end

local function setText(tb, s)
    if UE.valid(tb) then pcall(function() tb:SetText(FText(s)) end) end
end

local function pad(slot, l, t, r, b)
    if UE.valid(slot) then pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end) end
end

local function hookClicks()
    if hooked then return end
    hooked = pcall(function()
        RegisterHook(BTN_CLICKED, function(ctx)
            local button = ctx
            pcall(function() button = ctx:get() end)
            local b = buttons[addressOf(button) or 0]
            if b and #queue < 16 then queue[#queue + 1] = b end
        end)
    end)
end

--------------------------------------------------------------------------
-- Where the figure stands
--------------------------------------------------------------------------

--- How far a line runs level from `from` before something solid (a wall, a
--- shelf, a car), up to `far`. A trace that starts in your own capsule does
--- not stop on it (measured).
local function freeAlong(from, dx, dy, far)
    local ksl, w = UE.GetKismetSystemLibrary(), UE.GetWorld()
    if not (UE.valid(ksl) and UE.valid(w)) then return far end
    local out, hit = {}, false
    pcall(function()
        hit = ksl:LineTraceSingle(w, { X = from.X, Y = from.Y, Z = from.Z },
            { X = from.X + dx * far, Y = from.Y + dy * far, Z = from.Z }, 0, false, {}, 0, out, true, {}, {}, 0)
    end)
    local d = (hit == true) and tonumber(out.Distance) or nil
    UE.releaseOut(out)
    return d or far
end

--- The floor under a spot, from `fromZ` down; nil when there is none near.
local function floorAt(x, y, fromZ)
    local ksl, w = UE.GetKismetSystemLibrary(), UE.GetWorld()
    if not (UE.valid(ksl) and UE.valid(w)) then return nil end
    local out, hit, z = {}, false, nil
    pcall(function()
        hit = ksl:LineTraceSingle(w, { X = x, Y = y, Z = fromZ }, { X = x, Y = y, Z = fromZ - 400.0 },
            0, false, {}, 0, out, true, {}, {}, 0)
    end)
    if hit == true then pcall(function() z = tonumber(out.ImpactPoint.Z) end) end
    UE.releaseOut(out)
    return z
end

--- Where the other players stand (they do not stop a trace, but they would
--- stand between you and the figure all the same).
local function otherPlayers()
    local out, mine = {}, UE.GetPawn()
    for _, p in ipairs(UE.findAll("Player_Character_C") or {}) do
        if UE.alive(p) and not UE.sameObject(p, mine) then
            local at = nil
            pcall(function() at = UE.vec(p:K2_GetActorLocation()) end)
            if at then out[#out + 1] = at end
        end
    end
    return out
end

--- Which way to look, and how much of the usual distance the figure can
--- stand at: straight ahead when there is room, else the clearest way round
--- (along an aisle, down the street), so no shelf, wall or friend stands
--- before it.
local function findStage(eye, yaw, floorZ)
    local reach = math.sqrt(AHEAD * AHEAD + LEFT * LEFT)
    local side = math.atan(LEFT / AHEAD)         -- the figure is a little to the left
    local need = reach + BEHIND
    local best, bestFree = yaw, -1.0
    local others = otherPlayers()
    for _, t in ipairs(TURNS) do
        local a = math.rad(yaw + t) - side
        local dx, dy = math.cos(a), math.sin(a)
        local free = need
        for _, z in ipairs({ floorZ + 40.0, floorZ + 110.0, eye.Z }) do
            free = math.min(free, freeAlong({ X = eye.X, Y = eye.Y, Z = z }, dx, dy, need))
        end
        for _, o in ipairs(others) do
            local px, py = o.X - eye.X, o.Y - eye.Y
            local along, across = px * dx + py * dy, math.abs(px * dy - py * dx)
            if along > 0 and across < 70.0 then free = math.min(free, along - 50.0) end
        end
        if free >= need then return yaw + t, 1.0 end
        if free > bestFree then best, bestFree = yaw + t, free end
    end
    return best, math.max(NEAREST, bestFree - BEHIND) / reach
end

--------------------------------------------------------------------------
-- Building the panel
--------------------------------------------------------------------------

local function newButton(menu, label, what, row)
    local lib, cls = StaticFindObject(WIDGETS), StaticFindObject(BTN_CLASS)
    if not (UE.valid(lib) and UE.valid(cls)) then return nil end
    local b = nil
    pcall(function() b = lib:Create(menu, cls, UE.GetPlayerController()) end)
    if not UE.valid(b) then return nil end
    pcall(function() b["Set Text"](b, FText(label)) end)
    local a = addressOf(b)
    if a then buttons[a] = { what = what, row = row } end
    return b
end

--- A text line in the game's font (the menu's own "last save" line's), at a size.
local function newText(menu, font, s, size, centre)
    local tb = make(UMG.text, menu.WidgetTree)
    if not tb then return nil end
    pcall(function() tb.Font = font end)
    if size then pcall(function() tb.Font.Size = size end) end
    pcall(function() tb:SetFont(tb.Font) end)
    if centre then pcall(function() tb:SetJustification(1) end) end
    setText(tb, s)
    return tb
end

--- One row: [<] LABEL [>] [COLOUR], a fixed width.
local function newRow(menu, font, panel, title, key, colourKey)
    local size = make(UMG.size, menu.WidgetTree)
    local row = make(UMG.hbox, menu.WidgetTree)
    if not (size and row) then return nil end
    pcall(function() size:SetWidthOverride(ROW_WIDTH) end)
    pcall(function() size:AddChild(row) end)
    local slot = nil
    pcall(function() slot = panel:AddChild(size) end)
    pad(slot, 0, 4, 0, 4)

    local prev = newButton(menu, "<", "prev", key)
    local label = newText(menu, font, title, 20, true)
    local nxt = newButton(menu, ">", "next", key)
    for _, w in ipairs({ prev, label, nxt }) do
        local s = nil
        pcall(function() s = row:AddChild(w) end)
        pcall(function() s:SetVerticalAlignment(2) end)
        if w == label then
            pcall(function() s:SetSize({ SizeRule = 1, Value = 1.0 }) end)
            pad(s, 8, 0, 8, 0)
        end
    end
    -- The colour's own name on a button of its own (BLACK, GREEN...), a fixed
    -- width so nothing moves as the names change. A row without one keeps the
    -- room empty, so every row's arrows line up.
    local box = make(UMG.size, menu.WidgetTree)
    local colourButton = colourKey and newButton(menu, "COLOUR", "next", colourKey) or nil
    pcall(function() box:SetWidthOverride(COLOUR_WIDTH) end)
    if colourButton then pcall(function() box:AddChild(colourButton) end) end
    local s = nil
    pcall(function() s = row:AddChild(box) end)
    pcall(function() s:SetVerticalAlignment(2) end)
    pad(s, 8, 0, 0, 0)
    local txt = colourButton and UE.TryGet(colourButton, "txt") or nil
    if UE.valid(txt) then
        pcall(function() txt.Font.Size = COLOUR_TEXT end)
        pcall(function() txt:SetFont(txt.Font) end)
    end
    return UE.pathOf(label), colourButton and UE.pathOf(colourButton) or nil
end

local function build(menu)
    local tree = menu.WidgetTree
    local column = UE.TryGet(menu, "UX_Button_Resume")
    pcall(function() column = column:GetParent() end)
    local last = UE.TryGet(menu, "TextBlock_lastSave")
    if not (UE.valid(column) and UE.valid(last)) then return false end
    local font = last.Font
    -- The blur behind the menu's column, and the menu's own buttons, out.
    pcall(function()
        local overlay = column:GetParent()
        local n = overlay:GetChildrenCount()
        for i = 0, n - 1 do
            local w = overlay:GetChildAt(i)
            if UE.ClassNameOf(w) == "BackgroundBlur" then w:SetVisibility(1) end
        end
    end)
    local panelFont = nil
    pcall(function() panelFont = font end)
    local border = make(UMG.border, tree)
    local panel = make(UMG.vbox, tree)
    if not (border and panel) then return false end
    pcall(function() border:SetBrushColor({ R = 0.02, G = 0.02, B = 0.03, A = 0.72 }) end)
    pcall(function() border:SetPadding({ Left = 28.0, Top = 22.0, Right = 28.0, Bottom = 22.0 }) end)
    pcall(function() border:AddChild(panel) end)

    local kids = {}
    pcall(function()
        for i = 0, column:GetChildrenCount() - 1 do kids[#kids + 1] = column:GetChildAt(i) end
    end)
    local fontCopy = newText(menu, panelFont, "", 20)    -- keeps a copy of the font before its source goes
    for _, w in ipairs(kids) do pcall(function() w:RemoveFromParent() end) end
    local slot = nil
    pcall(function() slot = column:AddChild(border) end)
    -- The column to the right of the screen, the figure to the left.
    pcall(function()
        local overlaySlot = column.Slot
        overlaySlot:SetHorizontalAlignment(3)
        overlaySlot:SetVerticalAlignment(2)
        overlaySlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 90.0, Bottom = 0.0 })
    end)
    pcall(function()
        local outer = column:GetParent():GetParent()   -- the menu's centred box
        outer.Slot:SetHorizontalAlignment(3)
        outer.Slot:SetSize({ SizeRule = 1, Value = 1.0 })
    end)
    font = UE.valid(fontCopy) and fontCopy.Font or font

    local title = newText(menu, font, "CHOOSE YOUR CHARACTER", 34, true)
    local s = nil
    pcall(function() s = panel:AddChild(title) end)
    pad(s, 0, 0, 0, 4)
    local sub = newText(menu, font, "how the others see you", 16, true)
    pcall(function() s = panel:AddChild(sub) end)
    pad(s, 0, 0, 0, 14)

    open.labels, open.colours = {}, {}
    open.labels.preset = newRow(menu, font, panel, "YOUR OWN", "preset")
    for _, r in ipairs(ROWS) do
        open.labels[r.key], open.colours[r.key] = newRow(menu, font, panel, r.title, r.key, r.colour)
    end
    open.subtitle = UE.pathOf(sub)

    local foot = make(UMG.hbox, tree)
    pcall(function() s = panel:AddChild(foot) end)
    pad(s, 0, 16, 0, 0)
    pcall(function() s:SetHorizontalAlignment(2) end)
    for _, b in ipairs({ { "RANDOM", "random" }, { "DONE", "done" }, { "CANCEL", "cancel" } }) do
        local w = newButton(menu, b[1], b[2])
        local fs = nil
        pcall(function() fs = foot:AddChild(w) end)
        pad(fs, 8, 0, 8, 0)
    end
    return true
end

--------------------------------------------------------------------------
-- The figure
--------------------------------------------------------------------------

local function figure() return find(open and open.figure) end

local function spawnFigure()
    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    local cls = UE.staticFind(FIGURE)
    if not (UE.valid(gs) and UE.valid(w) and UE.valid(cls)) then return nil end
    local h = math.rad((open.faceYaw + (open.turn or 0) * 90.0) * 0.5)
    local xform = { Rotation = { X = 0.0, Y = 0.0, Z = math.sin(h), W = math.cos(h) },
                    Translation = { X = open.at.X, Y = open.at.Y, Z = open.floor },
                    Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local f = nil
    pcall(function() f = gs:BeginDeferredActorSpawnFromClass(w, cls, xform, 1, nil, 0) end)
    if not UE.valid(f) then return nil end
    pcall(function() f:SetReplicates(false) end)      -- this screen only
    pcall(function() gs:FinishSpawningActor(f, xform, 0) end)
    if not UE.valid(f) then return nil end
    pcall(function() f:SetActorEnableCollision(false) end)
    open.figure = UE.pathOf(f)
    return f
end

--- Dress the figure in the spec as it is now, and update the rows.
local function show()
    local f = figure() or spawnFigure()
    local look = Creator.compose(open.spec)
    if UE.valid(f) and look then
        local mesh = UE.TryGet(f, "SkeletalMeshComponent")
        if UE.valid(mesh) and require("bodies").dressFigure(f, mesh, look) then
            local cs = tonumber(look.cs) or 1.0
            pcall(function() f:SetActorScale3D({ X = cs, Y = cs, Z = cs }) end)
            -- A new body is a new anim instance, and a shipping build keeps no
            -- note of what it played (AnimationData is editor-only): the idle
            -- again after every body, or it stands in its bind pose.
            if open.animated ~= look.m then
                local idle = UE.findObject(IDLE)
                if not UE.valid(idle) and LoadAsset then pcall(function() idle = LoadAsset(IDLE) end) end
                if UE.valid(idle) then
                    pcall(function() mesh:PlayAnimation(idle, true) end)
                    open.animated = look.m
                end
            end
        end
    end
    open.look = look
    local L, C = open.labels or {}, open.colours or {}
    setText(find(L.preset), open.preset and ("REGULAR:  " .. open.preset:upper()) or "YOUR OWN")
    setText(find(open.subtitle), open.preset and ("one of the store's regulars - or make your own")
            or "how the others see you")
    local woman = Creator.label(open.spec, "body"):upper():find("WOMAN") ~= nil
    for _, r in ipairs(ROWS) do
        local text = r.view and (r.title .. "   " .. VIEWS[(open.turn or 0) + 1])
                     or (r.title .. "   " .. Creator.label(open.spec, r.key):upper())
        if r.key == "facial" and woman then text = r.title .. "   -" end
        setText(find(L[r.key]), text)
        local b = find(C[r.key])
        if UE.valid(b) then
            pcall(function() b["Set Text"](b, FText(Creator.label(open.spec, r.colour):upper())) end)
        end
    end
end

--------------------------------------------------------------------------
-- Open, act, close
--------------------------------------------------------------------------

local function close(done)
    if not open then return end
    local o = open
    open = nil
    buttons = {}
    queue = {}
    local f = find(o.figure)
    if UE.valid(f) then
        require("bodies").dropFigure(f)
        pcall(function() f:K2_DestroyActor() end)
    end
    local menu = find(o.menu)
    local pawn = UE.GetPawn()
    if UE.valid(pawn) and UE.valid(menu) then
        pcall(function()
            if UE.sameObject(pawn["UI ESC MENU"], menu) then pawn["UI ESC MENU"] = nil end
        end)
    end
    if UE.valid(menu) then
        local inView = false
        pcall(function() inView = menu:IsInViewport() end)
        if inView then UE.TryCall(menu, "Close ESC") end
    end
    local pc = UE.GetPlayerController()
    if UE.valid(pc) and o.view then pcall(function() pc:SetControlRotation(UE.rotArg(o.view)) end) end
    if done then
        stats.done = stats.done + 1
        if o.onDone and o.look then o.onDone(o.look, Creator.copy(o.spec)) end
    else
        stats.cancelled = stats.cancelled + 1
        if o.onCancel then o.onCancel() end
    end
end

--- Open the screen on this spec. onDone(look, spec) when DONE; onCancel().
function Screen.open(spec, onDone, onCancel)
    if open then return true end
    local pc, pawn = UE.GetPlayerController(), UE.GetPawn()
    local cm = UE.alive(pc) and UE.TryGet(pc, "PlayerCameraManager") or nil
    local lib, cls = StaticFindObject(WIDGETS), StaticFindObject(ESC_CLASS)
    if not (UE.alive(pawn) and UE.valid(cm) and UE.valid(lib) and UE.valid(cls)) then return false end
    local eye, rot, feet = nil, nil, nil
    pcall(function()
        eye = UE.vec(cm:GetCameraLocation())
        rot = UE.rot(pc:GetControlRotation())
        feet = UE.vec(pawn:K2_GetActorLocation())
    end)
    if not (eye and rot and feet) then return false end
    local half = 88.0
    local capsule = UE.TryGet(pawn, "CapsuleComponent")
    if UE.valid(capsule) then pcall(function() half = capsule:GetScaledCapsuleHalfHeight() end) end
    local floorZ = feet.Z - half
    local yaw, k = findStage(eye, rot.Yaw, floorZ)
    local y = math.rad(yaw)
    local fx, fy, rx, ry = math.cos(y), math.sin(y), -math.sin(y), math.cos(y)
    local at = { X = eye.X + (fx * AHEAD - rx * LEFT) * k, Y = eye.Y + (fy * AHEAD - ry * LEFT) * k }
    open = { spec = Creator.fit(Creator.copy(spec)), start = Creator.copy(spec), onDone = onDone, onCancel = onCancel,
             yaw = yaw, view = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0.0 }, at = at, dist = AHEAD * k,
             floor = floorAt(at.X, at.Y, eye.Z) or floorZ, presetIndex = 0, turn = 0,
             -- Facing you: the mesh looks along its +Y, so the actor turns a quarter less.
             faceYaw = math.deg(math.atan(eye.Y - at.Y, eye.X - at.X)) - FACE_YAW }
    hookClicks()

    local menu = nil
    pcall(function() menu = lib:Create(pc, cls, pc) end)
    if not UE.valid(menu) then open = nil return false end
    pcall(function() menu:AddToViewport(40) end)
    -- The menu's Construct pauses the host's game: the store keeps going.
    pcall(function() UE.GetGameplayStatics():SetGamePaused(UE.GetWorld(), false) end)
    open.menu = UE.pathOf(menu)
    -- The game's own Escape closes "the menu the pawn has": this one, on the host.
    pcall(function() pawn["UI ESC MENU"] = menu end)
    if not build(menu) then
        Log.warn("character screen: could not lay out the menu - closing it")
        close(false)
        return false
    end
    -- Look at the figure: its chest, from where you stand.
    local pitch = -math.deg(math.atan((eye.Z - (open.floor + CHEST)) / open.dist))
    pcall(function() pc:SetControlRotation(UE.rotArg({ Pitch = pitch, Yaw = open.yaw, Roll = 0.0 })) end)
    show()
    stats.opened = stats.opened + 1
    Log.info("character screen: open")
    return true
end

function Screen.isOpen() return open ~= nil end
function Screen.cancel() close(false) end

local function act(b)
    local presets = Creator.presets()
    if b.what == "done" then return close(true) end
    if b.what == "cancel" then return close(false) end
    if b.what == "random" then
        open.spec = Creator.random()
        open.preset = nil
    elseif b.row == "turn" then
        open.turn = (open.turn + (b.what == "prev" and -1 or 1)) % #VIEWS
        local f = figure()
        if UE.valid(f) then
            pcall(function()
                f:K2_SetActorRotation(UE.rotArg({ Pitch = 0.0, Yaw = open.faceYaw + open.turn * 90.0, Roll = 0.0 }), false)
            end)
        end
        stats.changes = stats.changes + 1
        return show()
    elseif b.row == "preset" then
        -- 0 is your own; 1..n the regulars.
        local n = #presets
        open.presetIndex = (open.presetIndex + (b.what == "prev" and -1 or 1)) % (n + 1)
        if open.presetIndex == 0 then
            open.spec, open.preset = Creator.fit(Creator.copy(open.own or open.start)), nil
        else
            if not open.preset then open.own = Creator.copy(open.spec) end
            local p = presets[open.presetIndex]
            open.spec, open.preset = Creator.fit(Creator.copy(p.spec)), p.name
        end
    else
        Creator.step(open.spec, b.row, b.what == "prev" and -1 or 1)
        open.preset, open.presetIndex = nil, 0
    end
    stats.changes = stats.changes + 1
    show()
end

function Screen.tick()
    if not open then return end
    -- Closed by the game (Escape on the host closes the pawn's menu - ours).
    local menu = find(open.menu)
    local inView = false
    if UE.valid(menu) then pcall(function() inView = menu:IsInViewport() end) end
    if not inView then return close(false) end
    if #queue == 0 then return end
    local batch = queue
    queue = {}
    for _, b in ipairs(batch) do
        if not open then break end
        local ok, err = pcall(act, b)
        if not ok then Log.warn("character screen: %s", tostring(err)) end
    end
end

function Screen.report()
    return { ("Character screen: %s; opened %d, done %d, cancelled %d, %d change(s)"):format(
        open and "open" or "closed", stats.opened, stats.done, stats.cancelled, stats.changes) }
end

function Screen.reset()
    -- A new world took the menu and the figure with it.
    open, buttons, queue = nil, {}, {}
end

-- For the tests.
Screen._act = function(b) if open then act(b) end end
Screen._state = function() return open end

return Screen
