--[[
    Rewind Together - player roster and nametags

    Nametags use UTextRenderComponent rather than a UMG overlay. That matters:
    the game is a Shipping build, so the usual debug-draw and PrintString paths
    are compiled out and render nothing. TextRenderComponent is ordinary
    renderable geometry that survives Shipping, and this game already ships the
    distance-field font it needs (RR_RobotoDistanceField / M_Font_Roboto), so
    we know the asset chain is present rather than hoping.

    The tag is attached to the remote pawn and re-oriented toward the local
    camera each tick, which is cheap for the handful of players a store holds.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Players = {}

-- Appears verbatim in rt.safety and in the "this crashed last time" message,
-- so it is written to be read by the person playing, not by a programmer.
local RISKY_OP = "creating a floating nametag (Config.ShowNametags)"

local cfg = nil
-- pawn full name -> { label = }. The tag component itself is never kept: it
-- dies with its pawn - which a guest's game destroys whenever the host walks
-- out of network range - so it is asked of the pawn, found this tick, each time.
local tags = {}
local roster = {}        -- playerState full name -> { name = , controller = }

local NAMETAG_HEIGHT = 105.0    -- just above the character's head

--------------------------------------------------------------------------
-- Roster
--------------------------------------------------------------------------

--- Every PlayerState the engine currently knows about, host and guests.
function Players.refreshRoster()
    roster = {}
    local states = UE.findAll("PlayerState")
    if not states then return roster end

    for _, ps in ipairs(states) do
        if UE.valid(ps) then
            -- PlayerNamePrivate is an FString, and on this build that arrives
            -- as userdata - so the old tostring() here put "FString: 000001305A..."
            -- in the roster, in rt.players, and above people's heads.
            local key = ps:GetFullName()
            roster[key] = { name = UE.PlayerNameOf(ps) or "Player" }
        end
    end
    return roster
end

function Players.list()
    local out = {}
    for _, entry in pairs(roster) do out[#out + 1] = entry.name end
    table.sort(out)
    return out
end

function Players.count()
    local n = 0
    for _ in pairs(roster) do n = n + 1 end
    return n
end

--- Put the player's Steam persona on their PlayerState so it shows up
--- everywhere the engine or the game surfaces a player name.
function Players.setLocalName(name)
    if not name or name == "" then return false end
    local pc = UE.GetPlayerController()
    if not UE.valid(pc) then return false end

    -- ServerChangeName is the engine's supported rename path and works from
    -- a client, so this is correct on both host and guest.
    local ok = UE.TryCall(pc, "ServerChangeName", name)
    if not ok then
        local ps = UE.TryGet(pc, "PlayerState")
        if UE.valid(ps) then
            UE.TrySet(ps, "PlayerNamePrivate", name)
        end
    end
    Log.info("player name set to %s", name)
    return true
end

--------------------------------------------------------------------------
-- Nametags
--------------------------------------------------------------------------

local textRenderClass = nil

local function getTextRenderClass()
    if textRenderClass == nil then
        textRenderClass = StaticFindObject("/Script/Engine.TextRenderComponent")
        if not UE.valid(textRenderClass) then
            Log.warn("TextRenderComponent class not found; nametags disabled")
            textRenderClass = false
        end
    end
    return textRenderClass or nil
end

local nametagsBlocked = false

local function makeTag(pawn, label)
    local cls = getTextRenderClass()
    if not cls then return nil end

    -- Construction plus registration is the dangerous half, so it runs behind
    -- a breadcrumb. If the process dies in here the next launch finds the
    -- crumb, switches nametags off and says so, instead of crashing again.
    local ran, comp = Safety.guard(RISKY_OP, function()
        local c = UE.NewComponent(cls, pawn, FName("RT_Nametag"))
        if not UE.valid(c) then return nil end
        c:RegisterComponent()
        local root = UE.TryGet(pawn, "RootComponent")
        if UE.valid(root) then
            c:K2_AttachToComponent(root, FName(""), 0, 0, 0, false)
        end
        return c
    end)

    if not ran then
        if not nametagsBlocked then
            nametagsBlocked = true
            Log.warn("nametags are off after an earlier crash (rt.safety) - " ..
                     "everything else is unaffected")
        end
        return nil
    end
    if not UE.valid(comp) then
        Log.debug("could not construct nametag component")
        return nil
    end

    -- Appearance, one call at a time, so a call this build does not have
    -- cannot silently skip the ones after it.
    local function step(name, fn)
        if not pcall(fn) then Log.debug("nametag: %s is not callable here", name) end
    end
    step("K2_SetRelativeLocation", function()
        UE.withHit(function(hit)
            comp:K2_SetRelativeLocation({ X = 0, Y = 0, Z = NAMETAG_HEIGHT }, false, hit, false)
        end)
    end)
    step("SetHorizontalAlignment", function() comp:SetHorizontalAlignment(1) end)  -- EHTA_Center
    step("SetVerticalAlignment",   function() comp:SetVerticalAlignment(0) end)    -- EVRTA_TextTop
    step("SetWorldSize",           function() comp:SetWorldSize(18.0) end)
    step("SetTextRenderColor",     function()
        comp:SetTextRenderColor({ R = 255, G = 245, B = 200, A = 255 })
    end)
    step("SetText",                function() comp:SetText(label) end)

    return comp
end

--- The nametag on this pawn, for this tick, or nil: the pawn's own
--- TextRenderComponent (players never have one of their own). The second
--- result is false when the pawn could not be asked at all - then a missing
--- tag is not a reason to make another one.
local function tagOf(pawn)
    local cls = getTextRenderClass()
    if not cls then return nil, false end
    local comp = nil
    local asked = pcall(function() comp = pawn:GetComponentByClass(cls) end)
    return UE.alive(comp) and comp or nil, asked
end

--- Create/refresh a nametag above every remote player.
function Players.updateNametags()
    if not cfg or not cfg.ShowNametags or cfg.SafeMode then return end
    -- Creating render components only makes sense inside a session.
    if UE.IsStandalone() then return end

    local localPawn = UE.GetPawn()
    local camLoc = nil
    local pc = UE.GetPlayerController()
    if UE.valid(pc) then
        pcall(function()
            local l, r = pc:GetPlayerViewPoint()
            camLoc = l
        end)
    end

    local pawns = UE.findAll("Player_Character_C")
    if not pawns then return end

    -- Which pawns exist right now, by name. Keeping a set of NAMES rather than
    -- a table of actors is the whole trick: the cleanup pass below then never
    -- has to ask a possibly-freed pawn whether it is still alive, which is the
    -- one thing this codebase has crashed on repeatedly.
    local present = {}

    for _, pawn in ipairs(pawns) do
        if UE.alive(pawn) and not UE.sameObject(pawn, localPawn) then
            local key = pawn:GetFullName()
            present[key] = true
            local entry = tags[key]
            local comp, asked = nil, true
            if entry then comp, asked = tagOf(pawn) end

            if not comp and asked then
                -- Resolve a display name from the owning controller's state.
                local label = UE.PlayerNameOf(UE.TryGet(pawn, "PlayerState")) or "Player"

                if makeTag(pawn, label) then
                    tags[key] = { label = label }
                    Log.debug("nametag created for %s", label)
                end
            elseif comp then
                -- Face the local camera and fade out beyond the configured range.
                if camLoc then
                    pcall(function()
                        local p = pawn:K2_GetActorLocation()
                        local dx, dy, dz = camLoc.X - p.X, camLoc.Y - p.Y, camLoc.Z - p.Z
                        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                        local visible = dist <= cfg.NametagMaxDistance
                        comp:SetVisibility(visible, false)
                        if visible then
                            local yaw = math.deg(math.atan(dy, dx))
                            UE.withHit(function(hit)
                                comp:K2_SetWorldRotation(
                                    { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, hit, false)
                            end)
                        end
                    end)
                end
            end
        end
    end

    -- Drop tags for pawns that are no longer in the world.
    --
    -- Note what this does NOT do: touch the departed pawn, or its tag. When an
    -- actor is destroyed the engine destroys its components with it, so the
    -- tag is already gone and calling DestroyComponent on it would be reaching
    -- into freed memory - which is not a Lua error and cannot be caught. (Earlier
    -- builds did exactly that, through a component kept from an earlier
    -- tick.) Absence from the name set is the entire test, and forgetting the
    -- entry is the entire cleanup.
    for key in pairs(tags) do
        if not present[key] then tags[key] = nil end
    end
end

--- Take every tag down: from the pawns that still exist this tick, asked
--- afresh; the rest went with their pawns.
function Players.clearNametags()
    if next(tags) then
        for _, pawn in ipairs(UE.findAll("Player_Character_C") or {}) do
            local key = nil
            pcall(function() key = pawn:GetFullName() end)
            local comp = key and tags[key] and UE.alive(pawn) and tagOf(pawn) or nil
            if comp then pcall(function() comp:K2_DestroyComponent(comp) end) end
        end
    end
    tags = {}
end

function Players.init(config)
    cfg = config
end

return Players
