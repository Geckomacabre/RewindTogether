--[[
    Rewind Together - in-game text overlay

    Shipping builds strip the usual ways a mod puts text on screen:
    PrintString, DrawDebugString and the debug canvas are all compiled out.
    UMG is available but building a widget tree from Lua against a cooked game
    is fragile.

    So the overlay is a TextRenderComponent parented to the local camera at a
    fixed offset. It is ordinary world geometry that happens to sit a few
    centimetres in front of the view, which means it renders in Shipping
    exactly like any other mesh, needs no widget assets, and follows the camera
    for free.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Overlay = {}

-- Named so it reads sensibly when it appears in a crash report and in
-- rt.safety. If constructing the panel takes the game down, this string is
-- what the next launch sees and switches off.
local RISKY_OP = "creating the on-screen overlay (Config.ShowOverlay)"

-- `pawnKey` is the pawn's NAME, not the pawn. Holding the actor would mean
-- comparing against a pointer that can be freed between frames; a string
-- cannot be, and comparing names answers the same question.
local panel = { comp = nil, pawnKey = nil }
local lines = {}
local dirty = false
local visible = true
local enabled = true

--- Set from config; when off, the overlay stores text but never creates a
--- render component. Used by SafeMode.
function Overlay.setEnabled(on)
    enabled = on and true or false
    if not enabled then Overlay.destroy() end
end

-- Sits in front of the camera. Close enough to read, far enough not to clip
-- through the first-person arms.
local OFFSET  = { X = 60.0, Y = -26.0, Z = 15.0 }
local SIZE    = 1.6
local MAXLINE = 10

local function cameraComponent()
    local pawn = UE.GetPawn()
    if not UE.valid(pawn) then return nil, nil end

    -- The first-person template names its camera "FirstPersonCamera"; fall
    -- back to any CameraComponent on the pawn.
    local cam = nil
    pcall(function()
        local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.CameraComponent"))
        if comps and comps:GetArrayNum() > 0 then cam = comps[1] end
    end)
    if not UE.valid(cam) then
        local all = FindAllOf("CameraComponent")
        if all then
            for _, c in ipairs(all) do
                if UE.valid(c) and c:GetOuter() == pawn then
                    cam = c
                    break
                end
            end
        end
    end
    return cam, pawn
end

local function ensurePanel()
    local pawn = UE.GetPawn()
    if not UE.alive(pawn) then return nil end

    local pawnKey = nil
    pcall(function() pawnKey = pawn:GetFullName() end)

    if UE.alive(panel.comp) and panel.pawnKey == pawnKey then
        return panel.comp
    end

    local cls = StaticFindObject("/Script/Engine.TextRenderComponent")
    if not UE.valid(cls) then return nil end

    local cam = cameraComponent()
    local attachTo = UE.valid(cam) and cam or pawn.RootComponent
    if not UE.valid(attachTo) then return nil end

    -- Everything from here to RegisterComponent is the part that has taken the
    -- game down before, so it runs behind a breadcrumb: if the process dies in
    -- here, the next launch finds the crumb and never tries again.
    local ran, comp = Safety.guard(RISKY_OP, function()
        local c = UE.NewComponent(cls, pawn, FName("RT_Overlay"))
        if not UE.valid(c) then return nil end
        c:RegisterComponent()
        c:K2_AttachToComponent(attachTo, FName(""), 0, 0, 0, false)
        return c
    end)

    if not ran then
        -- Switched off after an earlier crash. Say so once, then stop asking.
        if enabled then
            Log.warn("the on-screen overlay is off after an earlier crash " ..
                     "(rt.safety) - status still prints to this console")
        end
        enabled = false
        return nil
    end
    if not UE.valid(comp) then
        Log.debug("overlay: could not construct text component")
        return nil
    end

    -- Cosmetic setup, each step on its own so one unavailable call cannot
    -- silently skip the rest of them.
    local function step(name, fn)
        if not pcall(fn) then Log.debug("overlay: %s is not callable here", name) end
    end
    step("K2_SetRelativeLocation", function()
        UE.withHit(function(hit) comp:K2_SetRelativeLocation(OFFSET, false, hit, false) end)
    end)
    step("K2_SetRelativeRotation", function()
        UE.withHit(function(hit)
            comp:K2_SetRelativeRotation({ Pitch = 0.0, Yaw = 180.0, Roll = 0.0 }, false, hit, false)
        end)
    end)
    step("SetWorldSize",           function() comp:SetWorldSize(SIZE) end)
    step("SetHorizontalAlignment", function() comp:SetHorizontalAlignment(0) end)  -- EHTA_Left
    step("SetVerticalAlignment",   function() comp:SetVerticalAlignment(0) end)    -- EVRTA_TextTop
    step("SetTextRenderColor",     function()
        comp:SetTextRenderColor({ R = 235, G = 235, B = 235, A = 255 })
    end)
    step("SetCastShadow",          function() comp:SetCastShadow(false) end)

    panel.comp    = comp
    panel.pawnKey = pawnKey
    dirty = true
    Log.info("overlay panel created")
    return comp
end

--------------------------------------------------------------------------

--- Replace the whole overlay contents.
function Overlay.set(newLines)
    lines = {}
    for i, l in ipairs(newLines) do
        if i > MAXLINE then break end
        lines[#lines + 1] = tostring(l)
    end
    dirty = true
end

--- Append one line, scrolling the oldest off the top.
function Overlay.push(line)
    lines[#lines + 1] = tostring(line)
    while #lines > MAXLINE do table.remove(lines, 1) end
    dirty = true
end

function Overlay.clear()
    lines = {}
    dirty = true
end

function Overlay.setVisible(v)
    visible = v and true or false
    dirty = true
end

function Overlay.toggle()
    visible = not visible
    dirty = true
    return visible
end

function Overlay.isVisible()
    return visible
end

--- False while SafeMode (or Config.ShowOverlay = false) keeps it off: text set
--- then is stored but never drawn.
function Overlay.isEnabled()
    return enabled
end

--- Called from the mod's tick. Only touches the engine when something changed.
function Overlay.tick()
    if not enabled then return end
    -- Nothing to draw, nothing to build: avoids constructing a component
    -- during single player where it serves no purpose.
    if #lines == 0 and not UE.alive(panel.comp) then return end

    local comp = ensurePanel()
    if not UE.alive(comp) then return end

    if not dirty then return end
    dirty = false

    pcall(function()
        comp:SetVisibility(visible and #lines > 0, false)
        if visible and #lines > 0 then
            comp:SetText(table.concat(lines, "\n"))
        end
    end)
end

function Overlay.destroy()
    if UE.alive(panel.comp) then
        pcall(function() panel.comp:K2_DestroyComponent(panel.comp) end)
    end
    panel.comp, panel.pawnKey = nil, nil
end

return Overlay
