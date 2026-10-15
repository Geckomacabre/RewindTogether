--[[
    Rewind Together - Steam presence, invites and one-click joining

    The goal here is that nobody ever types a Steam ID.

    Three routes in, all standard Steam behaviour:

      1. Steam friends list -> "Join Game".
         The host publishes a rich-presence "connect" string. Steam shows
         Join Game to friends automatically. When they click it, Steam
         launches the game with "+connect steam.<hostid>" on the command
         line, which we read at startup and act on.

      2. Steam's own invite dialog.
         ActivateGameOverlayInviteDialogConnectString opens the real Steam
         overlay invite window. The host clicks a friend, the friend gets a
         normal Steam invite popup.

      3. In-game friend list.
         We ask Steam which friends are in Retro Rewind with a "connect"
         key set, i.e. currently hosting, and offer them as buttons.

    Route 1 covers the cold-start case, route 3 covers the already-running
    case, and route 2 lets the host start the conversation.
]]

local Log = require("log")
local UE  = require("ue")

local SteamJoin = {}

local cfg = nil
local api = {
    friends     = nil,
    matchmaking = nil,
    utils       = nil,
    apps        = nil,
    ready       = false,
}

local lobbyId        = nil
local pendingConnect = nil   -- a "steam.<id>" we should join once loaded
local pendingLauncherJoin = nil
local lastCmdline    = nil   -- last command line acted on, to avoid re-joining

-- Steam's reserved rich-presence key. Setting it is what makes "Join Game"
-- appear in a friend's Steam client; the value is handed back to us verbatim.
local CONNECT_KEY = "connect"
local STATUS_KEY  = "status"

--------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------

local function steamObject(names)
    for _, n in ipairs(names) do
        local o = FindFirstOf(n)
        if UE.valid(o) then return o end
        for _, pkg in ipairs({ "SteamCorePro", "SteamCoreShared" }) do
            local cdo = StaticFindObject("/Script/" .. pkg .. ".Default__" .. n)
            if UE.valid(cdo) then return cdo end
        end
    end
    return nil
end

function SteamJoin.discover()
    if api.ready then return true end

    api.friends     = steamObject({ "SteamProFriends", "SteamCoreFriends" })
    api.matchmaking = steamObject({ "SteamProMatchmaking", "SteamCoreMatchmaking" })
    api.utils       = steamObject({ "SteamProUtils", "SteamCoreUtils" })
    api.apps        = steamObject({ "SteamProApps", "SteamCoreApps" })

    if not UE.valid(api.friends) then
        Log.debug("Steam friends API not up yet")
        return false
    end

    api.ready = true
    Log.info("Steam presence API bound")
    return true
end

function SteamJoin.isReady() return api.ready end

--------------------------------------------------------------------------
-- Hosting: publish presence so friends see "Join Game"
--------------------------------------------------------------------------

local function setRichPresence(key, value)
    if not UE.valid(api.friends) then return false end
    local ok = UE.TryCall(api.friends, "SetRichPresence", key, value)
    if ok then Log.debug("rich presence %s = %s", key, value) end
    return ok
end

--- Call once the listen server is live.
function SteamJoin.publishHosting(hostSteamId, storeName)
    if not api.ready or not hostSteamId then return false end

    local connect = "+connect steam." .. tostring(hostSteamId)
    setRichPresence(CONNECT_KEY, connect)
    setRichPresence(STATUS_KEY, storeName or "Running a video store")
    setRichPresence("steam_display", "#Status")

    -- A Steam lobby is not required for Join Game to work, but it gives
    -- Steam a joinable object to hang the invite on and makes the friend
    -- list entry look like a normal multiplayer session.
    if UE.valid(api.matchmaking) then
        -- ESteamLobbyType: 0 Private, 1 FriendsOnly, 2 Public, 3 Invisible
        local ok, id = UE.TryCall(api.matchmaking, "CreateLobby", 1, cfg.MaxPlayers)
        if ok and id ~= nil then
            lobbyId = id
            UE.TryCall(api.matchmaking, "SetLobbyJoinable", id, true)
            UE.TryCall(api.matchmaking, "SetLobbyData", id, "connect", connect)
            UE.TryCall(api.matchmaking, "SetLobbyData", id, "host", tostring(hostSteamId))
            UE.TryCall(api.matchmaking, "SetLobbyMemberLimit", id, cfg.MaxPlayers)
            Log.info("Steam lobby created")
        end
    end

    Log.info("Friends can now click 'Join Game' next to your name in Steam.")
    return true
end

function SteamJoin.clearHosting()
    if not api.ready then return end
    UE.TryCall(api.friends, "ClearRichPresence")
    if lobbyId and UE.valid(api.matchmaking) then
        UE.TryCall(api.matchmaking, "LeaveLobby", lobbyId)
        lobbyId = nil
    end
end

--- Open Steam's real invite dialog. This is the least surprising way for a
--- host to invite someone: it is the same window every other Steam game uses.
function SteamJoin.openInviteDialog(hostSteamId)
    if not api.ready then return false end
    local connect = "+connect steam." .. tostring(hostSteamId)
    for _, fn in ipairs({ "ActivateGameOverlayInviteDialogConnectString",
                          "ActivateGameOverlayInviteDialog" }) do
        local ok = UE.TryCall(api.friends, fn, connect)
        if ok then
            Log.info("opened Steam invite dialog")
            return true
        end
    end
    Log.warn("could not open the Steam invite dialog (is the Steam overlay enabled?)")
    return false
end

--------------------------------------------------------------------------
-- Joining: who is hosting right now?
--------------------------------------------------------------------------

--- Returns { { name =, steamId =, connect = }, ... } for friends currently
--- hosting a Rewind Together session.
function SteamJoin.friendsHosting()
    local out = {}
    if not api.ready then return out end

    local count = 0
    local ok, n = UE.TryCall(api.friends, "GetFriendCount", 4) -- k_EFriendFlagImmediate
    if ok and type(n) == "number" then count = n end
    if count == 0 then
        local ok2, list = UE.TryCall(api.friends, "GetFriendsList")
        if ok2 and list ~= nil then
            pcall(function()
                for i = 1, list:GetArrayNum() do
                    local f = list[i]
                    local id = UE.TryGet(f, "Value") or UE.TryGet(f, "SteamID") or f
                    local entry = SteamJoin.inspectFriend(id)
                    if entry then out[#out + 1] = entry end
                end
            end)
        end
        return out
    end

    for i = 0, count - 1 do
        local okf, friend = UE.TryCall(api.friends, "GetFriendByIndex", i, 4)
        if okf and friend ~= nil then
            local id = UE.TryGet(friend, "Value") or UE.TryGet(friend, "SteamID") or friend
            local entry = SteamJoin.inspectFriend(id)
            if entry then out[#out + 1] = entry end
        end
    end
    return out
end

--- Is this friend hosting? Returns an entry table or nil.
function SteamJoin.inspectFriend(steamId)
    if steamId == nil then return nil end

    -- Ask Steam to refresh their presence, then read the connect key.
    UE.TryCall(api.friends, "RequestFriendRichPresence", steamId)

    local ok, connect = UE.TryCall(api.friends, "GetFriendRichPresence", steamId, CONNECT_KEY)
    if not ok or type(connect) ~= "string" or connect == "" then return nil end
    if not connect:find("steam%.") then return nil end

    local name = "Friend"
    local okn, n = UE.TryCall(api.friends, "GetFriendPersonaName", steamId)
    if okn and type(n) == "string" and n ~= "" then name = n end

    return { name = name, steamId = tostring(steamId), connect = connect }
end

--------------------------------------------------------------------------
-- Command line: Steam "Join Game" on a cold start
--------------------------------------------------------------------------

--- Look for a "+connect steam.<id>" handed to us by Steam.
---
--- This must be polled, not read once at startup. Steam only puts the connect
--- string on the process command line when it *launches* the game for a join.
--- If the game is already running - which is the normal case when a friend
--- clicks "Join Game" - Steam instead updates the value returned by
--- ISteamApps::GetLaunchCommandLine and raises a callback. Reading it a single
--- time at boot therefore misses every join by an already-running client,
--- which is exactly what happened in testing: the guest was dropped at the
--- main menu and nothing was logged, because nothing was ever asked.
function SteamJoin.checkLaunchCommandLine()
    local cmdline = nil

    -- Preferred: ask Steam directly, which works even when the launcher
    -- swallowed the arguments on relaunch (this game sets bRelaunchInSteam).
    if UE.valid(api.apps) then
        local ok, s = UE.TryCall(api.apps, "GetLaunchCommandLine")
        if ok and type(s) == "string" and s ~= "" then cmdline = s end
    end

    if not cmdline then
        local ksl = UE.GetKismetSystemLibrary()
        if UE.valid(ksl) then
            local ok, s = pcall(function() return ksl:GetCommandLine() end)
            if ok and type(s) == "string" then cmdline = s end
        end
    end

    if not cmdline or cmdline == "" then return nil end

    -- Only react to a value we have not already acted on, otherwise the same
    -- connect string would retrigger a join every poll.
    if cmdline == lastCmdline then return nil end
    lastCmdline = cmdline

    -- The launcher's route (docs/LAUNCHER_CONTRACT.md 5): a host's launcher
    -- publishes "+rt_join <SteamID64>", Steam's Join Game hands it to the GAME,
    -- and the game asks the launcher to carry the connection over Steam's
    -- relay. Exactly 17 digits or nothing: this string comes from a friend's
    -- rich presence and ends up on a command line.
    local rtJoin = cmdline:match("%+rt_join%s+(%d+)")
    if rtJoin and #rtJoin == 17 then
        Log.info("Steam asked us to join %s through the launcher", rtJoin)
        pendingLauncherJoin = rtJoin
        return rtJoin
    end

    local target = cmdline:match("%+connect%s+steam%.(%d+)")
    if not target then
        target = cmdline:match("%+connect%s+([%d%.:]+)")
    end

    if target then
        Log.info("Steam asked us to join %s", target)
        pendingConnect = target
        return target
    end
    return nil
end

--- A Steam "Join Game" that the launcher must carry. Taken once.
function SteamJoin.takePendingLauncherJoin()
    local id = pendingLauncherJoin
    pendingLauncherJoin = nil
    return id
end

--- Fallback for when Steam gives us nothing: if exactly one friend is hosting
--- right now, that is almost certainly who the invite came from.
function SteamJoin.soleHostingFriend()
    local list = SteamJoin.friendsHosting()
    if #list == 1 then return list[1] end
    return nil
end

function SteamJoin.takePendingConnect()
    local t = pendingConnect
    pendingConnect = nil
    return t
end

function SteamJoin.hasPendingConnect()
    return pendingConnect ~= nil
end

function SteamJoin.init(config)
    cfg = config
end

return SteamJoin
