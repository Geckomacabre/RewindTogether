--[[
    Rewind Together - co-op multiplayer for Retro Rewind
    ====================================================

    Entry point. Wires the modules together and owns the tick loop.

    How this works, in one paragraph
    --------------------------------
    Retro Rewind is a single-player Unreal Engine 5.4 game, but the shipped
    binary contains the entire multiplayer stack: OnlineSubsystemSteamCore is
    the active online subsystem, SteamCoreSockets provides a relay-backed P2P
    net driver, and the player pawn derives from ACharacter, whose movement
    component already implements client prediction and server correction. The
    game simply never opens a session. This mod does: it travels the host into
    a listen server on their own save, turns on replication for the actors that
    matter, and mirrors the store simulation - which was never authored to
    replicate - over a Steam P2P side-channel that we own.

    Load order matters: config -> log -> engine helpers -> transport ->
    features -> commands.
]]

local Config      = require("config")
local Log         = require("log")
local Safety      = require("safety")

-- Check the configuration BEFORE the logger reads it, so a mistyped LogLevel
-- corrects itself rather than deciding how loudly it gets to complain about
-- itself. Nothing here writes to config.lua; it repairs values in memory and
-- reports what it did once logging is up.
Safety.checkConfig(Config)

Log.init(Config.LogLevel, Config.LogToFile)

local UE          = require("ue")
local P2P         = require("steamp2p")
local Net         = require("net")
local SteamJoin   = require("steamjoin")
local Replication = require("replication")
local Players     = require("players")
local Spawn       = require("spawn")
local Bodies      = require("bodies")
local Chan        = require("rpcchan")
local LocalGM     = require("localgm")
local Overlay     = require("overlay")
local Chat        = require("chat")
local Sync        = require("sync")
local Hud         = require("hud")
local World       = require("worldsync")
local SkinSync    = require("skinsync")
local NpcSync     = require("npcsync")
local GuestInput  = require("guestinput")
local DayEnd      = require("dayend")
local TalkSync    = require("talksync")
local MainMenu    = require("mainmenu")
local Commands    = require("commands")
local DevBridge   = require("devbridge")
local Launch      = require("launchfile")
local Native      = require("native")

--- Which part of the tick is about to run: into the crash record (safety.lua),
--- so a crash in a module's own code is put down to that module, and into the
--- dev bridge's trace when that is on.
local currentPhase = nil
local function phase(name)
    currentPhase = name
    DevBridge.phase(name)
    Safety.phase(name)
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

local started        = false
local lastNetMode    = -1
local lastSweep      = 0
local lastRosterPoll = 0
local lastDiscovery  = 0
local bootTime       = os.clock()
local autoJoinDone   = false

local TICK_MS          = 100     -- 10 Hz driver; sub-systems rate-limit themselves
local SWEEP_INTERVAL   = 2.0     -- seconds between replication slices: the whole list in ~14 s
local ROSTER_INTERVAL  = 2.0
local NAMETAG_INTERVAL = 0.25    -- 4 Hz is plenty and keeps FindAllOf off the hot path
local DISCOVERY_RETRY  = 3.0
local LISTEN_GRACE     = 8.0     -- seconds to wait before declaring a host attempt failed
local JOIN_GRACE       = 15.0    -- connecting crosses the internet, so allow longer

local CONNECT_POLL = 2.0     -- seconds between checks for a Steam join request

local lastNametag     = 0
local lastPlayerCount = 0
local lastConnectPoll = 0

-- Join-on-load state. `readyAt` is when the player first appeared in a real
-- level; the travel happens a moment later so the game can settle.
local joinOnLoadDone  = false
local joinOnLoadReady = nil
local hostedThisRun   = false
local selfTestDone    = false
local lastJoinOnLoadNag = 0

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function onEnteredSession()
    local mode = UE.NetModeName()
    Log.info("net mode changed -> %s", mode)

    Replication.setActive(true)
    Replication.sweepAll()

    -- Clear the GameMode flags that would stop an arriving player from ever
    -- being given a pawn, before anybody can arrive.
    Spawn.onSessionStart()

    if UE.IsHosting() then
        Net.state.hosting = true
        Net.state.listenRequestedAt = nil
        -- Whatever config says, someone who has started hosting must never be
        -- auto-joined into somebody else's store.
        hostedThisRun = true
        Net.onListenServerReady(Replication)

        -- Make the session visible to friends in Steam, so joining is a
        -- right-click in the friends list rather than a copied ID.
        if Config.PublishSteamPresence then
            SteamJoin.publishHosting(Net.getLocalSteamId(), "Running a video store")
        end
    elseif UE.IsClient() then
        Net.state.joined = true
        -- The join worked. Without clearing this, losing the host later was
        -- reported as "Join FAILED - nothing connected", fifteen seconds after
        -- a session that had been running fine (seen in 1.7.0's tests).
        Net.state.joinRequestedAt = nil
        Log.info("connected to host")
        Replication.sweep()
    end

    -- Publish our Steam persona so the other side sees a real name.
    local id = Net.getLocalSteamId()
    if id then
        Players.setLocalName(Net.getFriendName(id))
    end

    -- Now, while somebody is actually looking at the console, say what is
    -- still missing. Saying it at boot would be six minutes too early.
    Net.reportSetupNeeded()

    Players.clearNametags()
    Overlay.push("Rewind Together: " .. Net.statusLine())
end

--- Server-side: a guest finished logging in.
local function onPostLogin(gameMode, newPlayer)
    -- HandleStartingNewPlayer also fires for the local player in single
    -- player, where none of this applies.
    if not (UE.IsHosting() or UE.IsClient()) then return end
    -- Giving a pawnless guest a body calls HandleStartingNewPlayer, which
    -- lands straight back here. Nothing below is harmful twice, but it would
    -- announce a second arrival for a player who never left.
    if Spawn.reentrant then return end
    Log.guard("PostLogin", function()
        Replication.raisePlayerCap(Config.MaxPlayers)
        Replication.sweep()
        Players.refreshRoster()

        local n = Net.connectedPlayers()
        Log.info("a player joined (%d connected)", n)
        Overlay.push(("A player joined (%d in store)"):format(n))
    end)
end

--- Server-side: a guest disconnected.
local function onLogout()
    if not (UE.IsHosting() or UE.IsClient()) then return end
    Log.guard("Logout", function()
        Players.refreshRoster()
        Players.clearNametags()
        local n = Net.connectedPlayers()
        Log.info("a player left (%d connected)", n)
        Overlay.push(("A player left (%d in store)"):format(n))
    end)
end

--------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------

local function installHooks()
    local installed, failed = 0, 0

    local function hook(path, fn)
        local inner = fn
        fn = function(...)
            -- A hook can fire inside the tick or between ticks; whichever it
            -- was, that is what the record says again once it has returned.
            local was = currentPhase
            phase("hook " .. path)
            local results = table.pack(inner(...))
            phase(was or Safety.IDLE)
            return table.unpack(results, 1, results.n)
        end
        local ok, err = pcall(function() RegisterHook(path, fn) end)
        if ok then
            installed = installed + 1
        else
            failed = failed + 1
            Log.debug("hook failed for %s: %s", path, tostring(err))
        end
    end

    -- Player join/leave.
    --
    -- AGameModeBase::PostLogin and ::Logout are plain C++ virtuals with no
    -- UFUNCTION, so they carry no reflection data and cannot be hooked - that
    -- is what "2 unavailable" meant in the first run's log. The Blueprint-
    -- facing K2_ variants and HandleStartingNewPlayer *are* UFUNCTIONs.
    -- We register all of them and let whichever exist fire; join detection
    -- also has a polling fallback in tick(), so this is belt and braces.
    hook("/Script/Engine.GameModeBase:K2_PostLogin", function() onPostLogin() end)
    hook("/Script/Engine.GameModeBase:K2_OnLogout", function() onLogout() end)
    hook("/Script/Engine.GameModeBase:HandleStartingNewPlayer", function() onPostLogin() end)
    hook("/Script/Engine.GameMode:K2_PostLogin", function() onPostLogin() end)
    hook("/Script/Engine.GameMode:K2_OnLogout", function() onLogout() end)

    -- Fires locally once the world is up and the pawn is ours to drive.
    hook("/Script/Engine.PlayerController:ClientRestart", function()
        Log.guard("ClientRestart", function()
            Replication.sweep()
            Players.refreshRoster()
        end)
    end)

    Log.info("installed %d engine hook(s), %d unavailable", installed, failed)
end

--------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------

local function tick()
    local now = os.clock()
    UE.beginFrame()

    -- Does nothing unless RewindTogether.devbridge exists (see devbridge.lua).
    DevBridge.tick(now)

    -- The launcher's requests and our heartbeat for it (launchfile.lua).
    phase("Launch.tick") Launch.tick(now, Config.Port)

    -- Resolve the net mode once, up front: several blocks below need it, and
    -- it is the cheapest possible read now that it comes from the cached net
    -- driver rather than a scan.
    local mode = UE.GetNetMode()
    local inSession = (mode == 2 or mode == 3)

    -- Keep trying to bind the Steam API until it comes up; Steam initialises
    -- after the game window, so this will not succeed on the first tick.
    --
    -- The Steam P2P half is OFF unless Config.UseSteamP2P == true. 1.5.7
    -- measured that it cannot send on this build (FSteamID has no reflected
    -- fields), and leaving it bound meant every guest was shown a large
    -- "money, day and chat will not sync" error that has been false since
    -- 1.6.0 moved all of that onto the game's own connection (rpcchan.lua).
    local wantP2P = Config.UseSteamP2P == true
    if ((wantP2P and not P2P.isReady()) or not SteamJoin.isReady())
       and (now - lastDiscovery) > DISCOVERY_RETRY then
        lastDiscovery = now
        if wantP2P and P2P.discover() then
            Net.getLocalSteamId()
        end
        SteamJoin.discover()
    end

    -- Poll for a Steam join request. Steam only puts "+connect" on the process
    -- command line when it launches the game for a join; when the client is
    -- already running it updates GetLaunchCommandLine instead. Reading once at
    -- startup therefore misses every invite accepted by a running client,
    -- which is what left the guest sitting at the main menu.
    if Config.AutoJoinFromSteam and SteamJoin.isReady() and not inSession
       and (now - lastConnectPoll) > CONNECT_POLL then
        lastConnectPoll = now
        phase("SteamJoin.checkLaunchCommandLine") SteamJoin.checkLaunchCommandLine()
    end

    -- A Steam Join Game for a launcher-hosted session: hand it to the launcher.
    if Config.AutoJoinFromSteam and not inSession then
        local viaLauncher = SteamJoin.takePendingLauncherJoin()
        if viaLauncher then Launch.askLauncherToJoin(viaLauncher) end
    end

    -- Act on a join request once the game has settled.
    if Config.AutoJoinFromSteam and not inSession
       and SteamJoin.hasPendingConnect()
       and (now - bootTime) > Config.AutoJoinDelay then
        local target = SteamJoin.takePendingConnect()
        Log.info("auto-joining %s (Steam invite)", tostring(target))
        Net.join(target)
    end

    -- Optional: walk straight into a friend's store with no keypress at all.
    if Config.AutoJoinFriend and not autoJoinDone and not inSession
       and SteamJoin.isReady()
       and (now - bootTime) > Config.AutoJoinDelay then
        autoJoinDone = true
        local friend = SteamJoin.soleHostingFriend()
        if friend then
            Log.info("auto-joining %s (they are hosting)", friend.name)
            Net.join(friend.steamId)
        end
    end

    -- The moment there is a real player in a real level, ask the build what it
    -- actually supports and write it to the log. Runs once, needs no console,
    -- no keypress and no second player - so a wrong assumption is caught on
    -- one machine instead of costing a round trip through the other person.
    if not selfTestDone and not inSession
       and UE.valid(UE.GetPlayerController()) and UE.valid(UE.GetPawn())
       and Net.inRealLevel() then
        selfTestDone = true
        Log.guard("selfTest", Net.selfTest)
    end

    -- Load a save, land in your friend's store.
    --
    -- This is the guest's real entry point, and it exists because the obvious
    -- one does not work: joining is implemented as travel, travel needs a
    -- PlayerController, and there is no PlayerController until a level has
    -- loaded. So a keypress at the main menu could never do anything. Waiting
    -- until the player is genuinely standing in their own store means the
    -- precondition is satisfied by construction.
    --
    -- No save data is read or written to achieve this - see Config.JoinOnLoad.
    if Config.JoinOnLoad and not inSession and not joinOnLoadDone
       and not hostedThisRun and not Net.state.listenPending
       and type(Config.JoinTarget) == "string" and Config.JoinTarget ~= "" then
        local ready = UE.valid(UE.GetPlayerController())
                      and UE.valid(UE.GetPawn())
                      and Net.inRealLevel()
        if ready then
            if not joinOnLoadReady then
                joinOnLoadReady = now
                Log.info("save loaded - joining %s in %.0fs (Config.JoinOnLoad)",
                         Config.JoinTarget, Config.JoinOnLoadDelay)
            elseif (now - joinOnLoadReady) > Config.JoinOnLoadDelay then
                joinOnLoadDone = true
                Log.info("joining %s", Config.JoinTarget)
                Net.join(Config.JoinTarget)
            end
        else
            joinOnLoadReady = nil
            -- Say why we are not joining yet. Without this, an auto-join that
            -- never becomes ready is indistinguishable from the mod not being
            -- installed - which is exactly how a broken readiness check went
            -- unnoticed while the guest sat in their store doing nothing.
            if (now - lastJoinOnLoadNag) > 15.0 then
                lastJoinOnLoadNag = now
                local pc   = UE.valid(UE.GetPlayerController())
                local pawn = UE.GetPawn()
                Log.warn("JoinOnLoad is waiting: controller=%s pawn=%s level=%s",
                         pc and "yes" or "NO",
                         UE.valid(pawn) and UE.ClassNameOf(pawn) or "NO",
                         Net.inRealLevel() and "yes" or "NO")
                Log.warn("  (target %s - press F5 to join now)", tostring(Config.JoinTarget))
            end
        end
    end

    phase("MainMenu.tick") MainMenu.tick(now)

    -- Detect entering/leaving a session.
    if mode ~= lastNetMode then
        lastNetMode = mode
        Replication.setActive(inSession)
        if inSession then
            phase("onEnteredSession") onEnteredSession()
        else
            if Net.state.joined then
                Log.warn("the connection to the host ended - you are back in single player")
            end
            Net.state.joined = false
            -- Back to single player: drop everything we created.
            Players.clearNametags()
            Overlay.clear()
            Net.state.peers = {}
            lastPlayerCount = 0
            Sync.reset()
            Hud.reset()
            World.reset()
            SkinSync.reset()
            NpcSync.reset()
            Replication.resetGuest()
            GuestInput.reset()
            DayEnd.reset()
            TalkSync.reset()
        end
    end

    -- A host attempt that never produced a net driver is a silent failure
    -- otherwise; say so instead of leaving the player wondering.
    if Net.state.listenRequestedAt and not inSession
       and (now - Net.state.listenRequestedAt) > LISTEN_GRACE then
        Net.state.listenRequestedAt = nil
        phase("Net.checkListenFailed") Net.checkListenFailed()
    end

    -- Same for joining. A travel route that dispatches but does nothing used
    -- to be indistinguishable from success.
    if Net.state.joinRequestedAt and not inSession
       and (now - Net.state.joinRequestedAt) > JOIN_GRACE then
        Net.state.joinRequestedAt = nil
        phase("Net.checkJoinFailed") Net.checkJoinFailed()
    end

    if not inSession then return end

    -- The receive side of the engine-connection channel. Installed here rather
    -- than at boot because the hook only matters once there is a session, and
    -- installing it costs nothing to retry.
    phase("Chan.installReceiver") Chan.installReceiver()
    -- Deliver what the RPC hooks queued - here, between engine frames, never
    -- inside the hooks (rpcchan.lua, above dispatch()).
    phase("Chan.pump") Chan.pump()
    if UE.IsServer() then phase("Chan.installUpstreamReceiver") Chan.installUpstreamReceiver() end

    if Config.UseSteamP2P == true then
        P2P.poll()
        Net.helloTick(now)
    end
    phase("Replication.drainPending") Replication.drainPending()
    if UE.IsClient() then
        phase("Replication.patchGuestMovement") Replication.patchGuestMovement()
    end

    -- A connected player with no pawn sees nothing but black, and neither end
    -- reports anything wrong, so this has to be noticed rather than waited on.
    phase("Spawn.tickHost") Spawn.tickHost(now)
    phase("Spawn.tickClient") Spawn.tickClient(now)

    -- Purely local: each machine puts a borrowed body on the pawns it can see
    -- and skips its own, so this needs no authority and no agreement with the
    -- other side.
    phase("Bodies.tick") Bodies.tick(now)

    -- Guest-side, once: the client has no GameMode, which is the one object
    -- the HUD, the clock, the money and every store terminal read from. Build
    -- one and find out. Behind a crash breadcrumb; see localgm.lua.
    phase("LocalGM.tick") LocalGM.tick(now)
    -- The build-mode stripes on a guest (worldsync.lua). LocalGM.stripesTick
    -- swept for OverlayMaterials, a theory 1.7.0 measured and disproved.
    phase("World.guestTick") World.guestTick(now, Config)
    -- Walls, floors, ceilings and furniture in the host's skins (skinsync.lua).
    phase("SkinSync.tickGuest") SkinSync.tickGuest(now)
    -- The town's NPCs: no strays of the guest's own, bubbles facing it (npcsync.lua).
    phase("NpcSync.tickGuest") NpcSync.tickGuest(now)
    -- What the guest's own game does that the host must hear about (the till).
    phase("GuestInput.tickGuest") GuestInput.tickGuest()
    -- A conversation the host stopped saying closes (talksync.lua).
    phase("TalkSync.tickGuest") TalkSync.tickGuest()

    -- Guest-side: the money/clock HUD only a GameMode ever builds. hud.lua.
    phase("Hud.tick") Hud.tick(now)

    if UE.IsServer() then
        phase("World.tickHost") World.tickHost(now)
        phase("SkinSync.tickHost") SkinSync.tickHost(now)
        phase("NpcSync.tickHost") NpcSync.tickHost(now)
        phase("GuestInput.tickHost") GuestInput.tickHost()
        -- Trust in a guest's position, back after the host moved them (replication.lua).
        phase("Replication.restoreTrust") Replication.restoreTrust()
        -- The end-of-day summary, to the guests (dayend.lua).
        phase("DayEnd.tickHost") DayEnd.tickHost(now)
        -- A guest's conversations, on the guest's screen (talksync.lua).
        phase("TalkSync.tickHost") TalkSync.tickHost(now)
        phase("Sync.tickHost") Sync.tickHost(now)
    end

    if (now - lastSweep) > SWEEP_INTERVAL then
        lastSweep = now
        phase("Replication.sweep") Replication.sweep()
    end

    if (now - lastRosterPoll) > ROSTER_INTERVAL then
        lastRosterPoll = now
        phase("Players.refreshRoster") Players.refreshRoster()

        -- Poll-based join/leave. The engine's PostLogin/Logout are plain C++
        -- virtuals with no reflection data, so they cannot be hooked; counting
        -- controllers is dull but always works.
        local n = Net.connectedPlayers()
        if n ~= lastPlayerCount then
            if lastPlayerCount > 0 and n > lastPlayerCount then
                Log.info("a player joined (%d connected)", n)
                Overlay.push(("A player joined (%d in store)"):format(n))
                phase("Replication.sweepAll") Replication.sweepAll()
            elseif lastPlayerCount > 0 and n < lastPlayerCount then
                -- This is the ONLY place a departure gets reported. The engine's
                -- Logout is a plain C++ virtual with no reflection data, and the
                -- K2_ variant does not fire on this build, so the hook that was
                -- supposed to say this never runs. Pushing it to the overlay
                -- alone meant that with SafeMode on - the default - a player
                -- leaving produced no record anywhere, which is exactly the gap
                -- that made a crash during a guest's departure hard to read.
                Log.info("a player left (%d connected)", n)
                Overlay.push(("A player left (%d in store)"):format(n))
                Players.clearNametags()
            end
            lastPlayerCount = n
        end
    end

    if (now - lastNametag) > NAMETAG_INTERVAL then
        lastNametag = now
        phase("Players.updateNametags") Players.updateNametags()
    end

    phase("Overlay.tick") Overlay.tick()
end

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------

local function start()
    if started then return end
    started = true

    Log.info("Rewind Together %s loading...", Net.VERSION)

    -- Did the last run die inside something we are about to do again? This has
    -- to happen before any of it runs, and it is the difference between a
    -- player hitting the same crash forever and the game simply coming up with
    -- one cosmetic feature switched off.
    Safety.init()

    -- Before anything indexes an engine object: UE4SS's member-name cache may
    -- still hold pointers into the strings of a Lua state a hot reload closed,
    -- and the next name it learns would make it read them (native.lua).
    Native.repairNameCache()

    -- With RewindNative up, ask the engine's crash reports whether the last
    -- run really crashed before anything is switched off for it: a closed
    -- window leaves the same record behind as a crash (safety.lua).
    Safety.setPid(Native.pid())
    Safety.settle(Native.crashesSince, Native.pidAlive)
    Safety.report()
    Safety.reportConfig()

    if Config.SafeMode then
        Log.warn("SafeMode is on: nametags and the in-game overlay are disabled.")
    end
    Overlay.setEnabled(Config.ShowOverlay and not Config.SafeMode)

    Net.init(Config)
    SteamJoin.init(Config)
    Replication.init(Config)
    Players.init(Config)
    Spawn.init(Config)
    Bodies.init(Config)
    LocalGM.init(Config)
    Sync.init(Config)
    Hud.init(Config)
    World.init()
    SkinSync.init(Config)
    NpcSync.init(Config)
    GuestInput.init(Config)
    DayEnd.init()
    TalkSync.init(Config)
    Chat.init()
    MainMenu.init(Config)
    Commands.init(Config)
    require("input").start()
    DevBridge.init(Commands)

    Replication.installSpawnHooks()
    installHooks()

    Log.info("Rewind Together ready. Press %s to host, or type rt.help in this console.",
             tostring(Config.Keys.HostGame))

    -- Engine work must happen on the game thread.
    --
    -- LoopAsync runs its callback on UE4SS's own async thread, so even the
    -- tiny "queue this for the game thread" closure below executes Lua there,
    -- ten times a second, while the game thread may be running this mod's
    -- Lua at the same moment. A Lua state is not thread-safe. 1.7.0's first
    -- two-instance runs crashed the host three times inside Lua's garbage
    -- collector on a garbage pointer - a corrupted heap, not a bad call - and
    -- that is what a race between two threads in one Lua state looks like.
    --
    -- So: when this UE4SS has the delayed-action system's game-thread loop,
    -- use it, and no Lua of ours ever runs off the game thread.
    local function body()
        Log.guard("tick", tick)
        -- Whatever the tick found is only good for this frame (ue.lua).
        UE.endFrame()
        phase(Safety.IDLE)
    end
    if type(LoopInGameThreadWithDelay) == "function"
       and pcall(LoopInGameThreadWithDelay, TICK_MS, function() body() return false end) then
        Log.info("tick loop: on the game thread (LoopInGameThreadWithDelay)")
    else
        LoopAsync(TICK_MS, function()
            ExecuteInGameThread(body)
            return false   -- keep looping
        end)
        Log.info("tick loop: LoopAsync + ExecuteInGameThread (older UE4SS)")
    end
end

-- Every engine accessor in this mod re-resolves and is guarded, so it is safe
-- to start immediately: the first few ticks simply find nothing and retry
-- while the engine finishes booting.
start()
