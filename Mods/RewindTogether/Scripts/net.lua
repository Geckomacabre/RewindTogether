--[[
    Rewind Together - hosting and joining

    Hosting turns the running single-player game into a listen server *in
    place*: we travel to the map the player is already standing in, with
    "?listen" appended. The host keeps their save, their store, their money -
    from their point of view they carry on playing, and other people can now
    walk in.

    Joining connects to a host by Steam ID (relayed, no port forwarding) or by
    IP for LAN, depending on which transport profile is installed.
]]

local Log  = require("log")
local UE   = require("ue")
local P2P  = require("steamp2p")

local Net = {}

-- Keep in step with VERSION.txt. Sent in the hello so that two people running
-- different builds of the mod find out from the mod instead of from an hour
-- of confusion: Unreal refuses mismatched GAME builds loudly, but a mismatched
-- MOD is completely invisible - the session comes up, and then some features
-- work in one direction only.
Net.VERSION = "1.9.2"

local cfg = nil
local versionWarned = {}      -- peer id -> already told them about a mismatch
local ownIdWarned   = false

Net.state = {
    hosting     = false,
    joined      = false,
    hostSteamId = nil,
    localSteamId= nil,
    peers       = {},      -- steamId -> { name = , joinedAt = }
    lastError   = nil,
}

--------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------

local USER_CANDIDATES    = { "SteamProUser", "SteamCoreUser" }
local FRIENDS_CANDIDATES = { "SteamProFriends", "SteamCoreFriends" }

local function steamObject(candidates)
    for _, name in ipairs(candidates) do
        local o = FindFirstOf(name)
        if UE.valid(o) then return o end
        local cdo = StaticFindObject("/Script/SteamCorePro.Default__" .. name)
        if UE.valid(cdo) then return cdo end
    end
    return nil
end

--- Read the most recently logged-in SteamID64 out of Steam's own config.
---
--- This exists because SteamCore returns IDs as an opaque struct whose layout
--- is not published. loginusers.vdf is plain text, is written by Steam itself,
--- and is correct regardless of what the plugin does - so it is a dependable
--- backstop when struct probing comes up empty.
local function steamIdFromLoginUsers()
    local roots = {
        os.getenv("ProgramFiles(x86)") and (os.getenv("ProgramFiles(x86)") .. "\\Steam") or nil,
        os.getenv("ProgramFiles") and (os.getenv("ProgramFiles") .. "\\Steam") or nil,
        "C:\\Steam",
        "D:\\Steam",
    }
    for _, root in ipairs(roots) do
        if root then
            local path = root .. "\\config\\loginusers.vdf"
            local ok, fh = pcall(io.open, path, "r")
            if ok and fh then
                local text = fh:read("*a")
                fh:close()
                -- Entries look like:  "76561198012345678" { ... "MostRecent" "1" ... }
                local best, current = nil, nil
                for line in text:gmatch("[^\r\n]+") do
                    local id = line:match('^%s*"(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)"%s*$')
                    if id then current = id end
                    if current and line:match('"MostRecent"%s*"1"') then
                        best = current
                    end
                    if current and not best and line:match('"mostrecent"%s*"1"') then
                        best = current
                    end
                end
                if best then return best, path end
                -- No MostRecent flag: fall back to the only account present.
                local only = text:match('"(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)"')
                if only then return only, path end
            end
        end
    end
    return nil, nil
end

--- Our own SteamID64 as a string, or nil if Steam is not up yet.
function Net.getLocalSteamId()
    if Net.state.localSteamId then return Net.state.localSteamId end

    local candidate, candidateHow = nil, nil

    local user = steamObject(USER_CANDIDATES)
    if UE.valid(user) then
        for _, fn in ipairs({ "GetSteamID", "GetSteamId", "GetLocalSteamID", "GetSteamID_Pure" }) do
            local ok, raw = UE.TryCall(user, fn)
            if ok and raw ~= nil then
                local id, how = UE.ExtractSteamId(raw)
                if id then
                    if how:find("IMPRECISE") then
                        -- Keep it only as a last resort; a rounded id is worse
                        -- than useless because it looks plausible.
                        candidate, candidateHow = id, ("%s:%s"):format(fn, how)
                        Log.debug("%s gave an imprecise id, preferring Steam's own config", fn)
                    else
                        Net.state.localSteamId = id
                        Log.info("local SteamID: %s (via %s:%s)", id, fn, how)
                        return id
                    end
                else
                    Log.debug("%s returned an id we could not read: %s", fn, tostring(how))
                end
            end
        end
    end

    -- Steam writes this file itself, as text, so it is always exact.
    local id, path = steamIdFromLoginUsers()
    if id then
        Net.state.localSteamId = id
        Log.info("local SteamID: %s (from %s)", id, path)
        return id
    end

    if candidate then
        Net.state.localSteamId = candidate
        Log.warn("local SteamID: %s (%s) - this may be a few digits off; " ..
                 "if friends cannot join, pass your real ID to rt.join manually",
                 candidate, candidateHow)
        return candidate
    end

    Log.debug("local SteamID not available yet")
    return nil
end

function Net.getFriendName(steamId)
    local friends = steamObject(FRIENDS_CANDIDATES)
    if UE.valid(friends) then
        for _, fn in ipairs({ "GetFriendPersonaName", "GetPersonaName" }) do
            local ok, name = UE.TryCall(friends, fn, steamId)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
    end
    return "Player " .. tostring(steamId):sub(-4)
end

--------------------------------------------------------------------------
-- Current level
--------------------------------------------------------------------------

--- True for the boot/menu/loading shells, where there is no player yet and so
--- nothing that can host or travel.
function Net.isMenuMap(map)
    return map == "L_Boot" or map == "L_MainMenu"
        or map == "L_Loading" or map == "L_Empty-Engine"
end

--- The map the player is standing in, without the streaming prefix.
---
--- Returns (name, detected). `detected` is false when the lookup failed and
--- the store level is being assumed. That distinction matters: the guess is
--- deliberately kept for hosting, where being wrong is recoverable and losing
--- the ability to host is not - but anything deciding "is the player really in
--- their store" must not treat a guess as fact. The self test did, and so ran
--- at the main menu and reported the menu's GameMode.
function Net.getCurrentMapName()
    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    if UE.valid(gs) and UE.valid(w) then
        local ok, name = pcall(function() return gs:GetCurrentLevelName(w, true) end)
        if ok and type(name) == "string" and name ~= "" then return name, true end
    end
    return "L_Player_Store_01", false
end

--- True when the player is standing in a real gameplay level.
---
--- Judged from the PAWN, not the level name. GetCurrentLevelName does not
--- resolve on this build - it always falls through to the guess - so a check
--- that demanded a detected map name was false forever. That silently disabled
--- both the self test and JoinOnLoad, which is why a correctly configured
--- guest sat in their own store and never attempted to travel.
---
--- The pawn is unambiguous: the store puts you in Player_Character_C, and the
--- menus do not.
function Net.inRealLevel()
    local pawn = UE.GetPawn()
    if UE.valid(pawn) and UE.ClassNameOf(pawn):find("Player_Character") then
        return true
    end

    -- Secondary: a level name, but only if it was genuinely read.
    local name, detected = Net.getCurrentMapName()
    if detected and not Net.isMenuMap(name) then return true end

    return false
end

--------------------------------------------------------------------------
-- Hosting
--------------------------------------------------------------------------

--- Start a co-op session on the map the host is currently in.
function Net.host()
    if Net.state.hosting then
        Log.warn("already hosting")
        return false
    end

    local map = Net.getCurrentMapName()

    -- Refuse to host from the menus - travelling from there would drop the
    -- player's save context and land everyone in an empty shell.
    if Net.isMenuMap(map) then
        Net.state.lastError = "Load your save and be inside your store before hosting."
        Log.error("%s (current map: %s)", Net.state.lastError, map)
        return false
    end

    -- Select the transport in memory right before travelling. The config file
    -- this used to rely on does not survive a launch.
    Net.applyTransport(cfg.Transport)

    -- ?Port= is passed for documentation value only - it does NOT move the
    -- listen port. FURL reads the port from the host:port part of an address,
    -- not from an option, so the listen server binds whatever the packaged
    -- DefaultEngine.ini says ([URL] Port=27015 on this build) regardless.
    -- Measured, not assumed: with the game hosting, the process had exactly
    -- one UDP socket open and it was 27015 while this said 7777.
    --
    -- It stays because it costs nothing and makes the intended port visible in
    -- the log next to the port that was actually used, which is precisely the
    -- comparison that caught the mistake.
    local options = ("listen?MaxPlayers=%d?Port=%d"):format(cfg.MaxPlayers, cfg.Port)
    Log.info("hosting: map=%s options=%s", map, options)

    -- Prefer UGameplayStatics::OpenLevel. It is a real BlueprintCallable
    -- UFunction, so it is guaranteed present in a Shipping build, whereas the
    -- "open" console command goes through an exec path that games are free to
    -- strip or intercept.
    local travelled = false
    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    if UE.valid(gs) and UE.valid(w) then
        travelled = pcall(function()
            gs:OpenLevel(w, FName(map), true, options)
        end)
        if travelled then Log.info("travel issued via GameplayStatics.OpenLevel") end
    end

    if not travelled then
        Log.warn("OpenLevel unavailable, falling back to the console")
        travelled = UE.Exec(("open %s?%s"):format(map, options))
    end

    if not travelled then
        Net.state.lastError = "Could not start travel; is the game fully loaded?"
        return false
    end

    Net.state.hosting = true
    Net.state.hostSteamId = Net.getLocalSteamId()
    Net.state.listenPending = true
    Net.state.listenRequestedAt = os.clock()

    -- The listen server does not exist yet at this point - travel is async.
    -- The post-travel work (player cap, replication sweep) is driven from
    -- main.lua's world-load hook.
    return true
end

--- Everything that must happen once the listen server is actually up.
function Net.onListenServerReady(replication)
    Net.state.listenPending = false
    replication.raisePlayerCap(cfg.MaxPlayers)
    replication.sweep()

    Net.tuneNetDriver()
    Log.info("net driver: %s", UE.DescribeNetDriver())
    Net.checkTransport()

    Net.announce()
end

--- Print the address a guest should actually type. Deliberately does NOT offer
--- the Steam ID unless the Steam relay really came up: handing someone an
--- address that cannot work is worse than handing them nothing, and that is
--- what sent both players round in circles.
function Net.announce()
    local nd = UE.GetNetDriver()
    local steamActive = UE.valid(nd) and UE.ClassNameOf(nd):find("Steam") ~= nil

    Log.info("=====================================================")
    if steamActive then
        local id = Net.getLocalSteamId()
        Log.info(" Co-op session live (Steam relay).")
        if id then Log.info("   Friends join with:  rt.join %s", id) end
    else
        Log.info(" Co-op session live (direct IP) on UDP port %d.", cfg.Port)
        Log.info("")
        Log.info("   Same house / same wifi:   rt.join <your-lan-ip>")
        Log.info("   Over the internet:        rt.join <your-public-ip>")
        Log.info("                             (needs UDP %d forwarded, or a VPN)", cfg.Port)
        Log.info("")
        Log.info("   Run 'Extras\\CHECK CONNECTION - Double click me.bat' to see your")
        Log.info("   address and confirm the game really is listening on %d.", cfg.Port)
        Log.info("")
        Log.info("   Your friend must ALSO have Config.Port = %d", cfg.Port)
    end
    Log.info("=====================================================")
end

--------------------------------------------------------------------------
-- Transport selection (runtime, not config)
--------------------------------------------------------------------------
--[[
    Retro Rewind does not keep a user Engine.ini. The file is wiped on launch -
    only GameUserSettings.ini survives - so the usual modding trick of dropping
    NetDriverDefinitions into Saved\Config\Windows\Engine.ini silently achieves
    nothing. That is why hosting always came up on IpNetDriver no matter what
    the config said, and why guests joining by Steam ID were bounced to the
    main menu with no error anywhere.

    UEngine::NetDriverDefinitions is a plain UPROPERTY array, and
    CreateNamedNetDriver reads it every time a net driver is made. Rewriting
    the GameNetDriver entry in memory just before we travel therefore does what
    the config file could not, and nothing can wipe it.
]]

local STEAM_DRIVER = "/Script/SteamCoreSockets.SteamCoreSocketsNetDriver"
local STEAM_CONN   = "/Script/SteamCoreSockets.SteamCoreSocketsNetConnection"
local IP_DRIVER    = "/Script/OnlineSubsystemUtils.IpNetDriver"
local IP_CONN      = "/Script/OnlineSubsystemUtils.IpConnection"

--- Dump UEngine.NetDriverDefinitions exactly as the engine currently holds it.
---
--- Exists to settle a question that was previously answered by assumption:
--- when hosting came up on IpNetDriver despite asking for Steam, that was put
--- down to the engine calling IsAvailable() on the Steam driver, getting
--- false, and substituting DriverClassNameFallback. But there is a second
--- explanation with identical symptoms - that the write into the definitions
--- array never landed at all, because UE4SS can hand back a COPY of a struct
--- element rather than a reference, in which case the assignment modifies a
--- temporary and is thrown away.
---
--- Those two need completely different fixes, so read the array back and see.
function Net.dumpNetDriverDefs(label)
    local engine = UE.GetEngine()
    if not UE.valid(engine) then
        Log.warn("netdriverdefs(%s): no engine", tostring(label))
        return nil
    end
    local defs = UE.TryGet(engine, "NetDriverDefinitions")
    if defs == nil then
        Log.warn("netdriverdefs(%s): not readable", tostring(label))
        return nil
    end

    local count = 0
    pcall(function() count = defs:GetArrayNum() end)
    Log.info("netdriverdefs(%s): %d entr(ies)", tostring(label), count)

    local seen = {}
    for _, base in ipairs({ 0, 1 }) do
        local ok = pcall(function()
            for i = base, count - 1 + base do
                local d = defs[i]
                if d ~= nil then
                    local name  = tostring(d.DefName:ToString())
                    local drv   = tostring(d.DriverClassName:ToString())
                    local fb    = tostring(d.DriverClassNameFallback:ToString())
                    if not seen[name] then
                        seen[name] = drv
                        Log.info("    [%d] %s = %s (fallback %s)", i, name, drv, fb)
                    end
                end
            end
        end)
        if ok and next(seen) then break end
    end
    return seen
end

--- Point the GameNetDriver definition at the requested transport.
--- Returns true if the definition was found and set.
function Net.applyTransport(which)
    local engine = UE.GetEngine()
    if not UE.valid(engine) then
        Log.warn("could not reach UEngine to set the net driver")
        return false
    end

    local defs = UE.TryGet(engine, "NetDriverDefinitions")
    if defs == nil then
        Log.warn("UEngine.NetDriverDefinitions is not readable")
        return false
    end

    local wantDriver = (which == "steam") and STEAM_DRIVER or IP_DRIVER
    local wantConn   = (which == "steam") and STEAM_CONN   or IP_CONN

    local count = 0
    pcall(function() count = defs:GetArrayNum() end)
    if count == 0 then
        Log.warn("NetDriverDefinitions is empty")
        return false
    end

    local changed = false
    -- UE4SS has used both 0- and 1-based indexing for TArray across versions;
    -- probe rather than assume, so this does not break on an update.
    for _, base in ipairs({ 1, 0 }) do
        for i = base, count - 1 + base do
            local ok = pcall(function()
                local d = defs[i]
                if d == nil then return end
                local name = tostring(d.DefName:ToString())
                if name == "GameNetDriver" then
                    d.DriverClassName         = FName(wantDriver)
                    d.DriverClassNameFallback = FName(IP_DRIVER)
                    changed = true
                end
            end)
            if not ok then break end
        end
        if changed then break end
    end

    if changed then
        -- Deliberately worded as a request, not an outcome. The engine calls
        -- IsAvailable() on the driver it builds from this definition and
        -- silently swaps in DriverClassNameFallback when that fails, so this
        -- line saying "set" previously read as success even in the runs where
        -- the driver that actually came up was IpNetDriver. The truth is only
        -- known after the driver exists - see Net.checkTransport().
        Log.info("requested net driver: %s (fallback %s)",
                 which == "steam" and "SteamCoreSockets (relay)" or "IpNetDriver (direct)",
                 "IpNetDriver")

        -- Read it straight back. "changed = true" only means the assignment
        -- did not throw; it does not mean the array now holds the new value.
        -- If UE4SS handed us a copy of the struct, this is where we find out,
        -- and it is a completely different problem from the driver refusing
        -- to start.
        local after = Net.dumpNetDriverDefs("after write")
        if after and after["GameNetDriver"] then
            local got = after["GameNetDriver"]
            if got == wantDriver then
                Log.info("write VERIFIED: GameNetDriver is now %s", got)
            else
                Log.error("=====================================================")
                Log.error(" The net driver write did NOT take.")
                Log.error(" asked for : %s", wantDriver)
                Log.error(" still says : %s", got)
                Log.error("")
                Log.error(" UE4SS returned a copy of the array element rather")
                Log.error(" than a reference, so the assignment was discarded.")
                Log.error(" The engine never saw the request at all - this is")
                Log.error(" NOT the driver refusing to start.")
                Log.error("=====================================================")
            end
        end
        -- The connection class lives on the driver's CDO.
        local cdo = StaticFindObject("/Script/SteamCoreSockets.Default__SteamCoreSocketsNetDriver")
        if UE.valid(cdo) then UE.TrySet(cdo, "NetConnectionClassName", wantConn) end
    else
        Log.warn("no GameNetDriver entry found in NetDriverDefinitions")
    end
    return changed
end

--- Raise bandwidth limits on the live driver. The stock 10 KB/s cap starves a
--- store full of replicated props. Set after creation because the config that
--- would normally do this does not survive.
function Net.tuneNetDriver()
    local nd = UE.GetNetDriver()
    if not UE.valid(nd) then return end
    UE.TrySet(nd, "MaxClientRate", 100000)
    UE.TrySet(nd, "MaxInternetClientRate", 100000)
    UE.TrySet(nd, "NetServerMaxTickRate", 60)
    Log.debug("net driver bandwidth limits raised")
end

--- Is the Steam socket net driver class present in this build at all?
--- Distinguishes "the config did not apply" from "the plugin cannot provide
--- this driver", which need completely different fixes.
function Net.steamDriverAvailable()
    for _, path in ipairs({
        "/Script/SteamCoreSockets.SteamCoreSocketsNetDriver",
        "/Script/SteamCoreSockets.Default__SteamCoreSocketsNetDriver",
    }) do
        if UE.valid(StaticFindObject(path)) then return true, path end
    end
    return false, nil
end

--- Warn when we asked for Steam relay but ended up on plain IP. Without this
--- the failure is completely silent: hosting "works", and only the guest sees
--- anything wrong (they get bounced to the main menu, because a steam.<id>
--- URL means nothing to IpNetDriver).
function Net.checkTransport()
    local nd = UE.GetNetDriver()
    if not UE.valid(nd) then return end
    local cls = UE.ClassNameOf(nd)

    if cfg.Transport == "steam" and not cls:find("Steam") then
        local available, path = Net.steamDriverAvailable()
        Log.error("=====================================================")
        Log.error(" Steam relay is NOT active - you are on %s.", cls)
        Log.error("")
        Log.error(" Friends CANNOT join by Steam ID or 'Join Game' while")
        Log.error(" this is the case; they will land back at the main menu.")
        Log.error("")
        if available then
            Log.error(" The Steam driver class IS present (%s),", path)
            Log.error(" but the engine called IsAvailable() on it, got false, and")
            Log.error(" silently fell back to IpNetDriver. That is an engine")
            Log.error(" behaviour we cannot override from Lua - the Steam socket")
            Log.error(" subsystem this driver needs is not initialised in this")
            Log.error(" build. Use the direct-IP route below; it is the one that")
            Log.error(" actually works here. Set Config.Transport = \"ip\" to stop")
            Log.error(" seeing this message.")
        else
            Log.error(" The Steam driver class is NOT loadable in this build,")
            Log.error(" so Steam relay cannot be used at all.")
        end
        Log.error("")
        Log.error(" WHAT WORKS RIGHT NOW: direct IP. The listen server is up.")
        Log.error("   - Same house/LAN: friend runs  rt.join <your-lan-ip>")
        Log.error("   - Over internet: use a VPN (Radmin, ZeroTier, Tailscale)")
        Log.error("     and join that VPN address - no port forwarding needed.")
        Log.error("   - Or forward UDP %d to this PC.", cfg.Port)
        Log.error("=====================================================")
    elseif cls:find("Steam") then
        Log.info("Steam relay transport active - friends can join by ID.")
    end
end

--- Called a few seconds after a host attempt. If the world never gained a net
--- driver the listen failed, which is silent otherwise and looks like the mod
--- doing nothing - so say so plainly and suggest the fix.
function Net.checkListenFailed()
    if not Net.state.listenPending then return end
    Net.state.listenPending = false

    if UE.IsHosting() then return end

    Net.state.lastError = "the listen server did not start"
    Log.error("=====================================================")
    Log.error(" Hosting FAILED - the map loaded but no net driver was")
    Log.error(" created, so nobody can connect.")
    Log.error("")
    Log.error(" Net driver: %s", UE.DescribeNetDriver())
    Log.error("")
    Log.error(" Most likely the Steam socket driver could not start.")
    Log.error(" Try the direct-IP profile instead - re-run the installer")
    Log.error(" with:  -Transport ip   then host again.")
    Log.error("=====================================================")
end

--------------------------------------------------------------------------
-- Joining
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Self test
--------------------------------------------------------------------------
--[[
    Ask the running game which things actually exist, instead of assuming.

    This exists because an assumption cost a whole evening: the code called
    APlayerController::ClientTravel believing it was BlueprintCallable, when
    only the ClientTravelInternal variant carries reflection data. It threw on
    every guest attempt, fell through to a console command that Shipping builds
    compile out, and that command *dispatched without error* - so the mod
    reported a successful join while doing nothing at all.

    Nothing here guesses. Every line is a question put to this build, answered
    from the log, on one machine, without a second player.
]]

--- Does `obj` expose a callable member of this name?
local function hasMember(obj, name)
    if not UE.valid(obj) then return false end
    local ok, v = pcall(function() return obj[name] end)
    return ok and v ~= nil
end

function Net.selfTest()
    Log.info("==== Rewind Together self test ====")

    local pc = UE.GetPlayerController()
    local w  = UE.GetWorld()
    local gs = UE.GetGameplayStatics()

    Log.info("  world:            %s", UE.valid(w) and "yes" or "NO")
    Log.info("  playercontroller: %s", UE.valid(pc) and UE.ClassNameOf(pc) or "NO")
    Log.info("  map:              %s", Net.getCurrentMapName())

    -- The travel routes, in the order Net.join tries them.
    Log.info("  -- travel routes (join uses the first that works) --")
    local openLevel = hasMember(gs, "OpenLevel")
    Log.info("    GameplayStatics.OpenLevel        %s",
             openLevel and "PRESENT  <- primary" or "MISSING")
    Log.info("    PlayerController.ClientTravelInternal  %s",
             hasMember(pc, "ClientTravelInternal") and "present" or "missing")
    Log.info("    PlayerController.ClientTravel          %s",
             hasMember(pc, "ClientTravel") and "present" or "missing (expected - not reflected)")
    Log.info("    PlayerController.ConsoleCommand        %s",
             hasMember(pc, "ConsoleCommand") and "present (but 'open' is stripped in Shipping)" or "missing")

    if not openLevel then
        Log.error("    OpenLevel is missing - joining CANNOT work. Report this.")
    end

    -- Dump the real signatures. Reflection data is the authority on what this
    -- build will accept; a parameter list that does not match the call is a
    -- bug we want to see here, on one machine, not on the guest's.
    Log.info("  -- actual signatures in this build --")
    for _, path in ipairs({
        "/Script/Engine.GameplayStatics:OpenLevel",
        "/Script/Engine.PlayerController:ClientTravelInternal",
        "/Script/Engine.PlayerController:ClientTravel",
        "/Script/Engine.PlayerController:ConsoleCommand",
    }) do
        local fn = StaticFindObject(path)
        local short = path:match("([^%.]+)$") or path
        if UE.valid(fn) then
            Log.info("    %-26s %s", short, UE.DescribeFunctionString(fn))
        else
            Log.info("    %-26s <not reflected - cannot be called>", short)
        end
    end

    -- Whether the host can accept an arriving player at all.
    Log.info("  -- host-side login path --")
    local gm = UE.GetGameMode()
    if UE.valid(gm) then
        Log.info("    GameMode:                      %s", UE.ClassNameOf(gm))
        for _, fn in ipairs({ "PreLogin", "Login", "PostLogin", "HandleStartingNewPlayer",
                              "SpawnDefaultPawnFor", "K2_PostLogin" }) do
            Log.info("    %-30s %s", fn, hasMember(gm, fn) and "present" or "missing")
        end
        local session = UE.TryGet(gm, "GameSession")
        Log.info("    GameSession:                   %s",
                 UE.valid(session) and UE.ClassNameOf(session) or "none")
    else
        Log.info("    GameMode: <not resolvable here> (normal on a client)")
    end

    -- Enumerate what the game's own classes actually expose.
    --
    -- This is the "read the source" step, done from reflection rather than by
    -- decompiling anything: a cooked Blueprint class carries its full function
    -- table, so the game will simply tell us what Core_Gamemode_C can do. The
    -- login path is the one remaining unknown in joining - a single-player
    -- GameMode has never had a second player arrive, and if it refuses one
    -- there is nothing the transport can do about it.
    local function listFunctions(obj, label, filter)
        if not UE.valid(obj) then
            Log.info("    %s: <not available here>", label)
            return
        end
        local cls = nil
        pcall(function() cls = obj:GetClass() end)
        if not UE.valid(cls) then
            Log.info("    %s: class not resolvable", label)
            return
        end

        local names, ok = {}, false
        ok = pcall(function()
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if not filter or n:lower():find(filter) then
                    names[#names + 1] = n
                end
            end)
        end)
        if not ok then
            Log.info("    %s: ForEachFunction unavailable in this UE4SS build", label)
            return
        end

        table.sort(names)
        Log.info("    %s (%s) - %d matching function(s):", label, UE.ClassNameOf(obj), #names)
        for _, n in ipairs(names) do Log.info("        %s", n) end
    end

    Log.info("  -- what the game's classes actually expose --")
    listFunctions(gm, "GameMode",
        "login|player|spawn|pawn|travel|restart|seamless|connect")
    listFunctions(pc, "PlayerController", "travel|connect|restart|login|seamless")

    -- The definitions array as the engine actually holds it, before anything
    -- has tried to change it.
    Net.dumpNetDriverDefs("at startup")
    Net.steamSocketsProbe()

    Log.info("  -- transport --")
    Log.info("    Config.Transport = %s, Config.Port = %d", tostring(cfg.Transport), cfg.Port)
    Log.info("    net driver now:  %s", UE.DescribeNetDriver())
    local steamOk = Net.steamDriverAvailable()
    Log.info("    Steam driver class present: %s (unusable on this build either way)",
             steamOk and "yes" or "no")

    Log.info("==== end self test ====")
end

--- Find everything this build exposes relating to Steam sockets.
---
--- The Steam relay driver reports itself unavailable, which normally means its
--- socket subsystem was never registered - something the plugin does in C++ at
--- module startup. That is out of reach from Lua *unless* the plugin also
--- exposes a Blueprint-callable initialiser, which some SteamCore builds do.
--- Rather than assume either way, enumerate what is actually here.
function Net.steamSocketsProbe()
    Log.info("==== Steam sockets probe ====")

    -- Known paths first - cheap and precise.
    for _, path in ipairs({
        "/Script/SteamCoreSockets.SteamCoreSocketsNetDriver",
        "/Script/SteamCoreSockets.Default__SteamCoreSocketsNetDriver",
        "/Script/SteamCoreSockets.SteamCoreSocketsNetConnection",
        "/Script/SteamCoreSockets.SteamCoreSocketsSubsystem",
        "/Script/SteamCorePro.Default__SteamProNetworking",
        "/Script/SteamCorePro.Default__SteamProUser",
        "/Script/SteamSockets.SteamSocketsNetDriver",
    }) do
        local o = StaticFindObject(path)
        Log.info("  %-62s %s", path, UE.valid(o) and "present" or "-")
    end

    -- A full ForEachUObject sweep used to live here. It is REMOVED and must not
    -- come back: walking the entire object array and calling GetFullName() on
    -- every entry touches objects that are mid-construction or already freed,
    -- and this game spawns and despawns constantly. It crashed the process on
    -- launch, the same failure this mod's replication code was rewritten to
    -- avoid, and pcall cannot catch it because it is a native fault.
    --
    -- It bought nothing anyway: the named lookups above already answered the
    -- question, and StaticFindObject is exact and safe.

    -- Anything that looks like it could start the subsystem.
    local cdo = StaticFindObject("/Script/SteamCoreSockets.Default__SteamCoreSocketsNetDriver")
    if UE.valid(cdo) then
        Log.info("  -- driver CDO members --")
        for _, fn in ipairs({ "IsAvailable", "InitBase", "InitListen", "InitConnect",
                              "Initialize", "IsNetResourceValid", "NetConnectionClassName" }) do
            local has = false
            pcall(function() has = cdo[fn] ~= nil end)
            Log.info("    %-24s %s", fn, has and "present" or "-")
        end
    end

    Log.info("==== end probe ====")
end

--- Can a Steam-ID-shaped address possibly connect right now?
---
--- On this build it cannot: the Steam relay driver never starts, so the game
--- falls back to IpNetDriver, which has no idea what a steam.<id> address is
--- and drops the player at the main menu with nothing logged. Refusing loudly
--- beats reproducing that dead end, so every route that can produce such an
--- address - rt.join, a Steam invite, quick join - funnels through here.
function Net.steamJoinUsable()
    if cfg.Transport == "steam" then return true end
    Log.error("=====================================================")
    Log.error(" Cannot join by Steam ID on this build.")
    Log.error("")
    Log.error(" The Steam relay net driver reports itself unavailable,")
    Log.error(" so the game falls back to plain IP networking, and a")
    Log.error(" Steam ID means nothing to that. Joining by ID would")
    Log.error(" just bounce you to the main menu.")
    Log.error("")
    Log.error(" Ask your friend for their IP ADDRESS instead - they get")
    Log.error(" it from 'Extras\\CHECK CONNECTION - Double click me.bat', or by")
    Log.error(" reading the 'Co-op session live' block after they host.")
    Log.error("")
    Log.error("   rt.join 192.168.1.42        (same house)")
    Log.error("   rt.join 203.0.113.44        (over the internet)")
    Log.error("=====================================================")
    Net.state.lastError = "joining by Steam ID is not supported on this build"
    return false
end

--- Connect to a host. `target` is a SteamID64 or an IP address.
function Net.join(target)
    if not target or target == "" then
        Log.error("rt.join needs a SteamID64 or an IP address")
        return false
    end

    target = target:gsub("^%s+", ""):gsub("%s+$", "")

    local addr
    if target:match("^%d+%.%d+%.%d+%.%d+") then
        addr = target
        if not target:find(":") then
            addr = addr .. ":" .. tostring(cfg.Port)
        end
    elseif target:match("^%d+$") then
        if not Net.steamJoinUsable() then return false end
        addr = "steam." .. target
    else
        addr = target
    end

    -- A Steam invite arrives already formatted as "steam.<id>", so it reaches
    -- here through the branch above rather than as a bare number. Catch that
    -- shape too: otherwise AutoJoinFromSteam walks straight into the same dead
    -- end by a different door.
    if addr:find("^steam%.") and not Net.steamJoinUsable() then return false end

    -- Joining by Steam ID needs the Steam driver; joining by IP needs the IP
    -- driver. Pick from the address rather than trusting the config.
    Net.applyTransport(addr:find("^steam%.") and "steam" or "ip")

    Log.info("joining: %s", addr)

    --[[
        Travel to the host.

        Route order here is the result of a live two-machine test, and it is
        not the obvious one:

          * UGameplayStatics::OpenLevel FIRST. It is a real BlueprintCallable
            UFunction, and it is *proven* on this exact build - it is what
            successfully travels the host into a listen server. Given a URL
            that is not a local map it skips map validation and calls
            GEngine->SetClientTravel, which is the engine's own browse path.
            So the same call that hosts also joins.

          * APlayerController::ClientTravel is NOT reflected. Only the
            ClientTravelInternal variant carries UFUNCTION data, so
            pc:ClientTravel(...) throws and can never work through UE4SS.
            This is what the guest hit on every attempt.

          * The "open <addr>" console command is LAST and is not trusted,
            because the travel exec commands are compiled out of Shipping
            builds. Critically, ConsoleCommand still *dispatches* it without
            complaining, so the old code saw success, told the player
            "Connecting to ...", and did absolutely nothing. A silent no-op
            that reports success is the worst possible failure, and it is why
            this looked unfixable for so long.
    ]]
    local how = nil

    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    if UE.valid(gs) and UE.valid(w) then
        if pcall(function() gs:OpenLevel(w, FName(addr), true, "") end) then
            how = "GameplayStatics.OpenLevel"
        end
    end

    if not how then
        local pc = UE.GetPlayerController()
        if UE.valid(pc) then
            -- The reflected variant. Executes locally on the owning client.
            if pcall(function() pc:ClientTravelInternal(addr, 0, false) end) then
                how = "PlayerController.ClientTravelInternal"
            elseif pcall(function() pc:ClientTravel(addr, 0, false) end) then
                how = "PlayerController.ClientTravel"
            end
        end
    end

    if not how then
        Log.warn("no reflected travel route worked - trying the console " ..
                 "(unreliable: 'open' is usually stripped from Shipping builds)")
        if UE.Exec("open " .. addr) then how = "console" end
    end

    if not how then
        -- Every route needs a PlayerController and a World, and at the
        -- boot/main menu there is neither.
        Net.state.lastError = "no PlayerController - not in a level yet"
        Log.error("=====================================================")
        Log.error(" Could not join: the game is not in a level yet.")
        Log.error("")
        Log.error(" Joining works by travelling your existing session to the")
        Log.error(" host, so there has to be a session to travel. At the title")
        Log.error(" or main menu there is no player yet and nothing happens.")
        Log.error("")
        Log.error(" LOAD YOUR OWN SAVE FIRST - get into your own store - and")
        Log.error(" then press F5 (or run rt.join %s).", addr)
        Log.error("=====================================================")
        return false
    end

    Log.info("travel issued via %s", how)

    -- Issuing travel is not arriving. Watch for the net mode actually turning
    -- into Client, so a route that dispatches but does nothing cannot be
    -- reported as a successful join ever again.
    Net.state.joinPending     = true
    Net.state.joinRequestedAt = os.clock()
    Net.state.joinAddr        = addr
    Net.state.joinHow         = how

    Net.state.joined = true
    Net.state.hostSteamId = target:match("^%d+$") and target or nil
    return true
end

--- Called a few seconds after a join attempt. If we never became a client the
--- travel did nothing, which is otherwise completely silent.
function Net.checkJoinFailed()
    if not Net.state.joinPending then return end
    Net.state.joinPending = false

    if UE.IsClient() then return end

    Net.state.joined = false
    Net.state.lastError = "the join did not connect"
    Log.error("=====================================================")
    Log.error(" Join FAILED - nothing connected.")
    Log.error("")
    Log.error(" Travel was issued via %s", tostring(Net.state.joinHow))
    Log.error(" to %s, but this game never became a client.", tostring(Net.state.joinAddr))
    Log.error("")
    Log.error(" Most likely causes, in order:")
    Log.error("   1. The host is not hosting right now. They must press F7")
    Log.error("      INSIDE their store and wait for it to reload first.")
    Log.error("   2. The host's port is not reachable from the internet -")
    Log.error("      they need UDP %d forwarded, or use a VPN.", cfg.Port)
    Log.error("   3. The address is wrong or their IP has changed.")
    Log.error("=====================================================")
end

--- One-keypress join.
---
--- Exists because the guest otherwise has no way in: the rt.* commands live
--- in the in-game console, and the main-menu button crashes this build. A
--- keybind needs no UI and no typing, and keybinds are already proven to work
--- here (F7 hosts reliably).
---
--- Tries, in order: an invite Steam handed us, the address saved in
--- config.lua, then any friend currently hosting.
function Net.quickJoin(steamJoin)
    -- 1. Steam invite we have not consumed yet.
    if steamJoin and steamJoin.hasPendingConnect() then
        local t = steamJoin.takePendingConnect()
        Log.info("quick join: using the Steam invite (%s)", tostring(t))
        return Net.join(t)
    end

    -- 2. Address saved in config.lua - the reliable, permanent option.
    local target = cfg.JoinTarget
    if type(target) == "string" then
        target = target:gsub("^%s+", ""):gsub("%s+$", "")
        if target ~= "" then
            Log.info("quick join: using Config.JoinTarget (%s)", target)
            return Net.join(target)
        end
    end

    -- 3. Whoever is hosting on the friends list.
    if cfg.QuickJoinFindsFriends and steamJoin then
        local list = steamJoin.friendsHosting()
        if #list == 1 then
            Log.info("quick join: %s is hosting", list[1].name)
            return Net.join(list[1].steamId)
        elseif #list > 1 then
            Log.warn("quick join: %d friends are hosting - pick one:", #list)
            for i, f in ipairs(list) do
                Log.warn("   rt.friends %d   (%s)", i, f.name)
            end
            return false
        end
    end

    Log.error("=====================================================")
    Log.error(" Nothing to join.")
    Log.error("")
    Log.error(" Ask your friend for their address, then EITHER:")
    Log.error("   - open config.lua and set")
    Log.error("       Config.JoinTarget = \"their-id-or-ip\"")
    Log.error("     then restart and press F5, or")
    Log.error("   - press ~ (or F10) in game and type")
    Log.error("       rt.join their-id-or-ip")
    Log.error("")
    Log.error(" config.lua is in this folder:")
    Log.error("   ...\\Binaries\\Win64\\ue4ss\\Mods\\RewindTogether\\Scripts\\")
    Log.error("=====================================================")
    return false
end

--- Leave the session and return to the main menu.
function Net.leave()
    Log.info("leaving session")
    UE.Exec("disconnect")
    Net.state.hosting = false
    Net.state.joined  = false
    Net.state.peers   = {}
    return true
end

--------------------------------------------------------------------------
-- Peer bookkeeping
--------------------------------------------------------------------------

function Net.addPeer(steamId, name)
    if not steamId then return end
    steamId = tostring(steamId)
    if not Net.state.peers[steamId] then
        Net.state.peers[steamId] = {
            name     = name or Net.getFriendName(steamId),
            joinedAt = os.time(),
        }
        Log.info("side-channel peer: %s (%s)", Net.state.peers[steamId].name, steamId)
        P2P.acceptSession(steamId)
    end

    -- On a client every peer is the host, by construction: a guest talks to
    -- nobody else. See Net.hostId for why this has to be inferred.
    if UE.IsClient() and not Net.state.hostSteamId then
        Net.state.hostSteamId = steamId
        Log.info("host's Steam ID learned from the side-channel: %s", steamId)
    end
end

function Net.removePeer(steamId)
    steamId = tostring(steamId)
    local p = Net.state.peers[steamId]
    if p then
        Log.info("%s left", p.name)
        Net.state.peers[steamId] = nil
    end
end

function Net.peerIds()
    local out = {}
    for id in pairs(Net.state.peers) do out[#out + 1] = id end
    return out
end

function Net.peerCount()
    local n = 0
    for _ in pairs(Net.state.peers) do n = n + 1 end
    return n
end

--- The host's SteamID, as seen from a guest.
---
--- Everything a guest sends upstream - chat, forwarded interactions - is
--- addressed to this, and it was nil for every guest that has ever played.
--- Net.state.hostSteamId was only ever set when the join target was itself a
--- Steam ID, and joining by Steam ID does not work on this build (§5), so the
--- only route that does work - joining by IP - never set it. Chat.say took its
--- "no host known" branch every single time.
---
--- An IP cannot reveal a SteamID64, so it has to be inferred, and on a client
--- the inference is sound: the only peer a guest can hear from is the host.
function Net.hostId()
    if Net.state.hostSteamId then return Net.state.hostSteamId end
    local ids = Net.peerIds()
    if #ids == 1 then return ids[1] end
    return nil
end

--- Count of player controllers the engine currently has, host included.
function Net.connectedPlayers()
    return #UE.GetAllPlayerControllers()
end

--------------------------------------------------------------------------
-- Peer discovery
--------------------------------------------------------------------------
--[[
    The side-channel needs SteamID64s, and joining by IP never reveals one.

    That gap is why the peer list was empty for the entire life of this mod:
    Net.addPeer existed and was called from nowhere, so peerCount() was always
    zero, so Sync.tickHost returned on its first line and chat broadcast to an
    empty list. Both features looked implemented and had never once run.

    Two things close it, and they work together:

      * ANY well-formed packet registers its sender as a peer (see
        P2P.onPeerSeen). That is the general case and needs no configuration.

      * Somebody has to send the first packet, and that needs an ID known in
        advance - hence Config.PeerSteamIds. Put the other player's ID there;
        the hello below reaches them, their reply registers them here, and
        from that point discovery is automatic in both directions.

    A hello costs one tiny packet every few seconds and stops the moment a
    peer answers, so leaving IDs configured is harmless.
]]

local lastHello = 0
local HELLO_INTERVAL = 4.0

--- Send a hello to every configured ID we have not yet heard from.
function Net.helloTick(now)
    if not cfg or not P2P.isReady() then return end
    if type(cfg.PeerSteamIds) ~= "table" or #cfg.PeerSteamIds == 0 then return end
    if (now - lastHello) < HELLO_INTERVAL then return end
    lastHello = now

    local me = Net.getLocalSteamId()
    for _, entry in ipairs(cfg.PeerSteamIds) do
        local id = tostring(entry):gsub("%s", "")
        if id ~= "" and id == me then
            -- Silently skipping this looks identical to a working setup, and
            -- "I put my Steam ID in like it said" is exactly the mistake
            -- somebody makes when both players are given the same instruction.
            if not ownIdWarned then
                ownIdWarned = true
                Log.warn("Config.PeerSteamIds contains YOUR OWN Steam ID (%s). " ..
                         "It needs your FRIEND's - they get theirs from rt.id.", me)
            end
        elseif id ~= "" and not Net.state.peers[id] then
            -- Steam wants the session accepted before packets flow.
            P2P.acceptSession(id)
            P2P.send(id, "hello", { from = tostring(me or "?"), v = Net.VERSION }, true)
        end
    end
end

--- Compare a peer's mod version with ours and say so, once, if they differ.
local function checkVersion(id, theirs)
    if not theirs or theirs == Net.VERSION then return end
    if versionWarned[id] then return end
    versionWarned[id] = true

    Log.error("=====================================================")
    Log.error(" You are running different versions of Rewind Together.")
    Log.error("")
    Log.error("   you:          %s", Net.VERSION)
    Log.error("   the other PC: %s", tostring(theirs))
    Log.error("")
    Log.error(" Things will half-work: a fix present on one machine and")
    Log.error(" not the other usually shows up as a feature that only")
    Log.error(" works in one direction.")
    Log.error("")
    Log.error(" Whoever is older should reinstall the mod from the same")
    Log.error(" folder the other one used.")
    Log.error("=====================================================")
end

function Net.init(config)
    cfg = config
    P2P.setChannel(config.P2PChannel)

    -- Every packet proves its sender exists and can reach us.
    P2P.onPeerSeen = function(fromId)
        local id = tostring(fromId)
        -- SteamCore may hand back a struct rather than a plain id.
        if not id:match("^%d+$") then
            local extracted = UE.ExtractSteamId(fromId)
            if extracted then id = extracted end
        end
        if id:match("^%d+$") then Net.addPeer(id) end
    end

    -- A hello needs an answer, or only one direction ever registers.
    P2P.on("hello", function(fields, fromId)
        Log.debug("hello from %s", tostring(fromId))
        local id = tostring(fields and fields.from or fromId)
        if id:match("^%d+$") then
            Net.addPeer(id)
            checkVersion(id, fields and fields.v)
            P2P.acceptSession(id)
            P2P.send(id, "hello_ack", {
                from = tostring(Net.getLocalSteamId() or "?"),
                v    = Net.VERSION,
            }, true)
        end
    end)

    P2P.on("hello_ack", function(fields, fromId)
        local id = tostring(fields and fields.from or fromId)
        if id:match("^%d+$") then
            Net.addPeer(id)
            checkVersion(id, fields and fields.v)
        end
    end)
end

--- Say, once per session, what still has to be set up by hand.
---
--- The side-channel needs the other player's SteamID64 and cannot discover it,
--- because you join by IP and an IP never carries one. With PeerSteamIds empty
--- the mod does exactly nothing about money, day or chat and says nothing
--- either - which is indistinguishable from those features being broken, and
--- is how they went unnoticed for the entire life of the project.
function Net.reportSetupNeeded()
    if type(cfg.PeerSteamIds) == "table" and #cfg.PeerSteamIds > 0 then return end

    local me = Net.getLocalSteamId()
    Log.warn("=====================================================")
    Log.warn(" Walking around and seeing the store works right now.")
    Log.warn(" Money, the day counter and chat DO NOT yet.")
    Log.warn("")
    Log.warn(" Those ride a Steam channel that needs each of you to")
    Log.warn(" know the other's Steam ID, and joining by IP cannot")
    Log.warn(" reveal one. It is a one-time edit, on BOTH machines:")
    Log.warn("")
    Log.warn("   1. Each of you runs  rt.id  and sends the other the")
    Log.warn("      number it prints.")
    if me then
        Log.warn("      Yours is:  %s", me)
    end
    Log.warn("   2. Open config.lua and put THEIR number here:")
    Log.warn("        Config.PeerSteamIds = { \"7656119...\" }")
    Log.warn("   3. Both restart the game.")
    Log.warn("")
    Log.warn(" config.lua lives in:")
    Log.warn("   ...\\Binaries\\Win64\\ue4ss\\Mods\\RewindTogether\\Scripts\\")
    Log.warn("=====================================================")
end

function Net.statusLine()
    local mode = UE.NetModeName()
    if mode == "ListenServer" then
        return ("Hosting - %d player(s)"):format(Net.connectedPlayers())
    elseif mode == "Client" then
        return "Connected to host"
    end
    return "Single player"
end

return Net
