--[[
    Rewind Together - give a guest a local GameMode

    THE IDEA, AND WHY IT IS WORTH TESTING

    A guest has no GameMode. AGameMode is server-only by engine design and
    never replicates, so on the client the object simply does not exist - which
    is why a guest has no HUD, no clock, no money and none of the store
    simulation. rt.state on a guest prints "GameMode: not available here".

    It is easy to read that as "therefore this cannot work", and that reading
    is wrong. Somebody else's mod for this game has both windows showing a live
    HUD with identical money and time, so it is plainly achievable. The engine
    forbids *replicating* a GameMode; it does not forbid a client from having
    a perfectly ordinary actor of that class sitting in its own world.

    And the class is known on the client for free: AGameStateBase replicates
    GameModeClass, so the guest is already told exactly what to build. Measured
    on this build - the guest's rt.state shows
    "GameModeClass = Core_Gamemode_C" while GameMode itself is missing.

    WHAT THIS IS NOT

    A local GameMode is not authoritative and must never be treated as such.
    It exists so the guest's own HUD and store Blueprints have the object they
    expect to read from. The host stays the single source of truth; whatever
    ends up mirroring money and time writes INTO this object.

    HONESTLY UNCERTAIN

    Constructing one runs its BeginPlay, and nobody knows what this game's
    GameMode does there - it may load the guest's own save and build their own
    store, which would be wrong but informative. It may do nothing. It may take
    the process down.

    WHY IT RUNS BY ITSELF NOW

    It was a command, deliberately, so that a human decided when to take that
    risk. Three test sessions later it had never once been run - because it
    needs somebody to alt-tab into a console mid-session and type it, and there
    is always something more urgent happening in a two-machine test. A safety
    measure that prevents the experiment from ever happening is not buying
    safety, it is buying nothing.

    The risk it was protecting against is exactly what safety.lua is for: it
    goes behind a crash breadcrumb, so if it does take the process down, the
    next launch switches it off, says so in words, and co-op carries on
    without it. That is one bad launch, once, in exchange for an answer to the
    question underneath the guest's missing HUD, missing clock, missing money
    and dead store terminals.

    Config.GuestLocalGameMode = false turns it off. rt.localgm still works by
    hand.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local LocalGM = {}

local RISKY_OP  = "building a local GameMode on a guest (rt.localgm)"
local STRIPES_OP = "removing the build-mode overlay from the store " ..
                   "(Config.ClearBuildModeOverlay)"

local cfg        = nil
local tried      = false
local pawnSince  = nil

-- How long a guest must have had a pawn before this fires. The level is still
-- streaming in for the first second or two after a pawn appears, and building
-- a rules object into a half-built world is a worse experiment than waiting.
local SETTLE = 5.0

--- The class the server says this world's GameMode should be.
--- Replicated on AGameStateBase, so it is correct by construction rather than
--- looked up by a hard-coded path that a game patch could move.
local function gameModeClass()
    local gs = UE.GetGameState()
    if UE.valid(gs) then
        local cls = UE.TryGet(gs, "GameModeClass")
        if UE.valid(cls) then return cls, "GameState.GameModeClass (replicated)" end
    end
    local cls = StaticFindObject(UE.Paths.GameMode)
    if UE.valid(cls) then return cls, "the hard-coded path" end
    return nil, nil
end

--- Report lines: what exists, what does not, and what could be built.
function LocalGM.reportLines()
    local lines = {}
    local function add(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and s or tostring(fmt)
    end

    add("mode: %s", UE.NetModeName())
    local gm = UE.GetGameMode()
    add("GameMode present here: %s", UE.valid(gm) and UE.ClassNameOf(gm) or "NO")

    local cls, how = gameModeClass()
    add("GameMode class to build:  %s%s",
        UE.valid(cls) and UE.ClassNameOf(cls) or "<unknown>",
        how and ("   (from " .. how .. ")") or "")

    local gs = UE.GetGameState()
    add("GameState: %s", UE.valid(gs) and UE.ClassNameOf(gs) or "<none>")
    return lines
end

--- Build one. Client-side only; returns the actor or nil.
function LocalGM.create()
    if not UE.IsClient() then
        Log.warn("rt.localgm is for guests - the host already has a GameMode")
        return nil
    end

    local existing = UE.GetGameMode()
    if UE.valid(existing) then
        Log.info("this machine already has a GameMode (%s) - nothing to do",
                 UE.ClassNameOf(existing))
        return existing
    end

    local cls, how = gameModeClass()
    if not UE.valid(cls) then
        Log.error("cannot work out which GameMode class to build")
        return nil
    end

    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    if not (UE.valid(gs) and UE.valid(w)) then
        Log.error("no world to build it in")
        return nil
    end

    Log.info("building a local %s (class from %s)...", UE.ClassNameOf(cls), how)

    local ran, actor = Safety.guard(RISKY_OP, function()
        -- Spawned at the origin: a GameMode has no meaningful transform, it is
        -- a rules object rather than a thing in the world.
        local xform = {
            Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
            Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
            Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        local a = nil
        -- AlwaysSpawn (1): there is nothing to collide with at the origin and
        -- refusing would only be confusing.
        pcall(function()
            a = gs:BeginDeferredActorSpawnFromClass(w, cls, xform, 1, nil, 0)
        end)
        if not UE.valid(a) then
            pcall(function()
                a = gs:BeginDeferredActorSpawnFromClass(w, cls, xform, 1, nil)
            end)
        end
        if not UE.valid(a) then return nil end
        pcall(function() gs:FinishSpawningActor(a, xform, 0) end)
        return a
    end)

    if not ran then
        Log.warn("this is switched off after an earlier crash - rt.safety")
        return nil
    end
    if not UE.valid(actor) then
        Log.error("the GameMode could not be built")
        return nil
    end

    Log.info("built %s", UE.ClassNameOf(actor))

    -- Point the world at it, so anything asking the engine "what is the game
    -- mode" gets an answer instead of nil. Best effort: on a client this
    -- property is not normally written, and it may well be read-only here.
    if UE.TrySet(w, "AuthorityGameMode", actor) then
        Log.info("world's AuthorityGameMode now points at it")
    else
        Log.info("could not set World.AuthorityGameMode - the actor exists " ..
                 "anyway, and Blueprints that search for it by class will " ..
                 "still find it")
    end

    Log.info("=====================================================")
    Log.info(" Look at your screen NOW and report what changed:")
    Log.info("   - is there a HUD (money, clock) that was not there?")
    Log.info("   - did the store fill in, stay bare, or change?")
    Log.info("   - anything obviously wrong or duplicated?")
    Log.info("")
    Log.info(" Then run  rt.state  so the numbers can be compared with")
    Log.info(" the host's. This is an experiment, not a fix - what it")
    Log.info(" tells us decides which way the state sync gets built.")
    Log.info("=====================================================")

    return actor
end

--------------------------------------------------------------------------
-- Automatic
--------------------------------------------------------------------------

--- Build one on a guest, once, a few seconds after they have a pawn.
---
--- Gated on the pawn rather than on the map name, because GetCurrentLevelName
--- does not resolve on this build and Player_Character_C existing is the only
--- reliable "we are actually in the store" signal there is (PROJECT.md 5).
---
--- Deliberately fires exactly once per session either way. If it crashes, the
--- breadcrumb retires it and the next launch explains itself; if it merely
--- does not help, retrying on a timer would only produce a second GameMode.
function LocalGM.tick(now)
    if tried then return end
    -- OPT-IN since 1.7.0 (checked with == true, so an old config.lua that
    -- never mentions it gets it OFF). Measured on two instances: the local
    -- GameMode does build the HUD, and it also starts a complete new game on
    -- the guest - the tutorial, a quest, a $550 till, the store sign reset to
    -- "RETRO REWIND", every expansion re-locked a few seconds after it was
    -- opened, and a "close the door to finish the day" prompt. It loads and
    -- would save GameInstance."Save Slot", which is whatever the guest last
    -- played - so it could write the host's money into the guest's own save.
    -- hud.lua now builds the HUD directly, which is the part that was wanted.
    if not (cfg and cfg.GuestLocalGameMode == true) then return end
    if not UE.IsClient() then return end
    if UE.valid(UE.GetGameMode()) then tried = true return end

    if not UE.valid(UE.GetPawn()) then pawnSince = nil return end
    pawnSince = pawnSince or now
    if (now - pawnSince) < SETTLE then return end

    tried = true
    Log.info("=====================================================")
    Log.info(" No GameMode on this machine. Building one.")
    Log.info("")
    Log.info(" A guest has no GameMode - AGameMode is server-only by")
    Log.info(" engine design and never replicates - which is why there")
    Log.info(" is no HUD, no clock, no money and why the store's own")
    Log.info(" terminals do nothing. This is the experiment that finds")
    Log.info(" out whether giving the client its own changes that.")
    Log.info("")
    Log.info(" Config.GuestLocalGameMode = false turns this off.")
    Log.info("=====================================================")

    LocalGM.create()
end

function LocalGM.init(config)
    cfg = config
end

--------------------------------------------------------------------------
-- The hazard stripes
--------------------------------------------------------------------------

local stripesDone = false

--- Take the build-mode overlay off the guest's store, if that is what it is.
---
--- From the guest's screenshot: the counter's price signs are readable, the
--- door mullions and window frames are intact, the counter is the right blue -
--- and yellow-and-black hazard stripes are drawn OVER all of it. An actor
--- drawing an unconfigured default would show a WRONG appearance, not a
--- correct one with stripes on top, which is what rules out the theory this
--- project shipped in 1.5.7.
---
--- UE5 draws exactly that with UPrimitiveComponent::OverlayMaterial. Clearing
--- it is local, cosmetic and unsynchronised by definition - an overlay pass is
--- decoration, and nothing about it was ever sent anywhere - so there is
--- nothing to desync and no reason to make the player ask for it.
---
--- If the count is zero, this was the wrong theory and the log says so plainly
--- rather than staying quiet and leaving somebody to wonder.
function LocalGM.stripesTick()
    if stripesDone then return end
    if not UE.IsClient() then return end
    if cfg and cfg.ClearBuildModeOverlay == false then stripesDone = true return end
    if not UE.valid(UE.GetPawn()) then return end

    stripesDone = true

    -- Behind a breadcrumb because it is a component sweep, and a component
    -- sweep is what crashed the host in 1.6.0. Capped inside as well; this is
    -- the belt to that braces.
    local Inspect = require("inspect")
    -- Safety.guard hands back ONE result, so the three counts travel in a
    -- table. Unpacking them straight off guard() left two of them nil, and
    -- "failed > 0" threw on every guest in 1.6.1 - measured in 1.7.0's first
    -- two-instance run ("attempt to compare number with nil").
    local ran, counts = Safety.guard(STRIPES_OP, function()
        local c, f, t = Inspect.clearOverlays()
        return { cleared = c or 0, failed = f or 0, total = t or 0 }
    end)
    counts = counts or { cleared = 0, failed = 0, total = 0 }
    local cleared, failed, total = counts.cleared, counts.failed, counts.total
    if not ran then
        Log.warn("clearing the build-mode overlay is off after an earlier crash " ..
                 "(rt.safety). The store may render in yellow hazard stripes.")
        return
    end
    if total == 0 then
        Log.info("no overlay materials on this machine - if the store still " ..
                 "renders in yellow hazard stripes, it is NOT an OverlayMaterial " ..
                 "and that theory is dead. Say so.")
        return
    end

    Log.info("removed %d of %d build-mode overlay material(s)%s - the yellow " ..
             "hazard stripes should be gone", cleared, total,
             failed > 0 and (", " .. failed .. " refused") or "")
end

return LocalGM
