--[[
    Rewind Together - console commands and keybinds

    Commands are typed into the game's own console: press ~ (or F10) twice,
    type the command, press Enter (UE4SS's ConsoleEnablerMod, on by default,
    switches it on). UE4SS's GUI console window takes them too, if a player
    turned it on - a fresh install has none. Every command is prefixed "rt."
    so it cannot collide with the game's own commands.
]]

local Log         = require("log")
local UE          = require("ue")
local Net         = require("net")
local Chat        = require("chat")
local Overlay     = require("overlay")
local Players     = require("players")
local Replication = require("replication")
local P2P         = require("steamp2p")
local SteamJoin   = require("steamjoin")
local Sync        = require("sync")
local Spawn       = require("spawn")
local Inspect     = require("inspect")
local Safety      = require("safety")
local Bodies      = require("bodies")
local LocalGM     = require("localgm")
local Chan        = require("rpcchan")
local Input       = require("input")
local Native      = require("native")
local Hud         = require("hud")

local Commands = {}

local cfg = nil

local HELP = {
    { "rt.host",           "Start a co-op session on your current save" },
    { "rt.quickjoin",      "Join using Config.JoinTarget or a hosting friend (same as F5)" },
    { "rt.invite",         "Open Steam's invite window (easiest way to invite)" },
    { "rt.friends",        "List friends currently hosting, and join one" },
    { "rt.join <id|ip>",   "Join a host by Steam ID (or IP on LAN)" },
    { "rt.leave",          "Leave the session and return to the menu" },
    { "rt.id",             "Show your Steam ID so friends can join you" },
    { "rt.status",         "Show connection, players and sync state" },
    { "rt.say <message>",  "Send a chat message" },
    { "rt.players",        "List everyone currently connected" },
    { "rt.pawns",          "Show who has a character and who is stuck on black" },
    { "rt.fixpawns",       "HOST: give every pawnless guest a character now" },
    { "rt.bring",          "HOST: pull everyone to you (fixes 'stuck under the map')" },
    { "rt.unstuck",        "Back to the store (same as the pause menu's button)" },
    { "rt.state",          "Show money/day/season/time as this machine sees them" },
    { "rt.props <what>",   "Dump an object's properties (gameinstance/gamemode/pawn/<Class>)" },
    { "rt.funcs <what>",   "Dump an object's functions - finds the real interaction name" },
    { "rt.why",            "Why can't we see each other - pawn and mesh check" },
    { "rt.bodies",         "Borrowed NPC bodies: what's here, what's missing" },
    { "rt.stripes",        "The yellow hazard stripes: what's overlaying the store (clear removes them)" },
    { "rt.localgm",        "GUEST: build a local GameMode (experiment - HUD/clock)" },
    { "rt.sweep",          "Re-run the replication pass (fixes invisible props)" },
    { "rt.overlay",        "Toggle the in-game overlay" },
    { "rt.menu",           "Diagnose the main-menu button injection" },
    { "rt.safety",         "What got switched off after a crash (reset to retry)" },
    { "rt.native [test]",  "The native helper (RewindNative.dll): status, or HOST: prove the guest redirect" },
    { "rt.config",         "Check config.lua for mistakes" },
    { "rt.diag",           "Dump diagnostics for bug reports" },
    { "rt.help",           "This list" },
}

local function out(dev, text)
    Log.info("%s", text)
    if dev then pcall(function() dev:Log(text) end) end
end

--------------------------------------------------------------------------

local handlers = {}

handlers["rt.help"] = function(_, dev)
    out(dev, "Rewind Together commands:")
    for _, h in ipairs(HELP) do
        out(dev, ("  %-20s %s"):format(h[1], h[2]))
    end
    return true
end

handlers["rt.host"] = function(_, dev)
    if Net.host() then
        out(dev, "Starting co-op session...")
        out(dev, "When the store has reloaded, the address to give your friend")
        out(dev, "is printed above - or run Extras\\CHECK CONNECTION.bat to see it.")
    else
        out(dev, "Could not host: " .. tostring(Net.state.lastError or "unknown error"))
    end
    return true
end

handlers["rt.quickjoin"] = function(_, dev)
    if not UE.IsStandalone() then
        out(dev, "Already in a session (" .. UE.NetModeName() .. ").")
        return true
    end
    Net.quickJoin(SteamJoin)
    return true
end

handlers["rt.invite"] = function(_, dev)
    local id = Net.getLocalSteamId()
    if not id then
        out(dev, "Steam is not ready yet - wait a moment and try again.")
        return true
    end
    if not UE.IsHosting() then
        out(dev, "You are not hosting yet. Press F7 (or rt.host) inside your store first.")
        return true
    end
    if SteamJoin.openInviteDialog(id) then
        out(dev, "Steam invite window opened - pick a friend.")
    else
        out(dev, "Could not open the Steam overlay. Enable it in Steam settings,")
        out(dev, "or send them:  rt.join " .. id)
    end
    return true
end

handlers["rt.friends"] = function(params, dev)
    local list = SteamJoin.friendsHosting()
    if #list == 0 then
        out(dev, "No friends are hosting a co-op store right now.")
        return true
    end
    local pick = tonumber(params[1])
    if pick and list[pick] then
        out(dev, "Joining " .. list[pick].name .. "...")
        Net.join(list[pick].steamId)
        return true
    end
    out(dev, "Friends hosting right now:")
    for i, f in ipairs(list) do
        out(dev, ("  %d. %s   (rt.friends %d to join)"):format(i, f.name, i))
    end
    return true
end

handlers["rt.join"] = function(params, dev)
    local target = params[1]
    if not target then
        out(dev, "Usage: rt.join <SteamID64 or IP>")
        return true
    end
    if Net.join(target) then
        -- Travel was issued, not completed. Saying "Connecting..." and nothing
        -- else is what made a no-op look like a success for so long; the
        -- watchdog in main.lua reports the real outcome a few seconds later.
        out(dev, "Connecting to " .. target .. "... (watch this console)")
    else
        out(dev, "Could not join: " .. tostring(Net.state.lastError or "unknown error"))
    end
    return true
end

handlers["rt.leave"] = function(_, dev)
    Net.leave()
    Players.clearNametags()
    Overlay.clear()
    out(dev, "Left the session.")
    return true
end

handlers["rt.id"] = function(_, dev)
    local id = Net.getLocalSteamId()
    if id then
        out(dev, "Your Steam ID: " .. id)
    else
        out(dev, "Steam ID not available (is Steam running and the overlay enabled?)")
    end
    -- Deliberately not offered as a join address. The Steam relay driver does
    -- not come up on this build, so "rt.join <steamid>" is a dead end that
    -- silently dumps the guest back at the main menu - which is precisely the
    -- loop both players were stuck in.
    out(dev, "NOTE: friends cannot join by Steam ID on this build.")
    out(dev, "Give them your IP instead - run Extras\\CHECK CONNECTION.bat to get it.")
    return true
end

handlers["rt.status"] = function(_, dev)
    out(dev, "---- Rewind Together " .. Net.VERSION .. " ----")
    out(dev, "  Mode:      " .. UE.NetModeName())
    out(dev, "  Status:    " .. Net.statusLine())
    out(dev, "  Map:       " .. Net.getCurrentMapName())
    out(dev, "  Transport: " .. tostring(cfg.Transport))
    -- "connected" used to be the whole story here, and it was misleading:
    -- the API being bound says nothing about whether a byte has ever moved.
    -- It had not, for the entire life of this mod, and this line said
    -- "connected" throughout.
    -- The channel money, the clock and chat actually ride (rpcchan.lua).
    -- Counted on both ends: a send is a dispatch, only the other machine's
    -- "received" proves anything arrived.
    local c = Chan.stats()
    out(dev, ("  Sync channel: sent %d, failed %d, received %d%s")
        :format(c.sent, c.failed, c.received, c.listening and "" or " (not listening yet)"))
    if not UE.IsStandalone() and c.sent == 0 and c.received == 0 then
        out(dev, "     nothing has crossed it yet - give it a few seconds after joining")
    end
    if cfg.UseSteamP2P == true then
        local p = P2P.stats()
        out(dev, ("  Steam P2P (legacy): %s, sent %d, failed %d, received %d")
            :format(P2P.isReady() and "bound" or "unavailable", p.sent, p.failed, p.received))
    end
    local st = Replication.stats()
    out(dev, ("  Replication: %d classes, %d instances"):format(st.classes, st.instances))
    -- What finding things has cost since the game started (ue.lua).
    local lk = UE.lookupStats()
    out(dev, ("  Lookups: %d by path, %d actor lists (%d actors), %d full walks")
        :format(lk.objects, lk.lists, lk.listed, lk.walks))
    if UE.IsClient() then
        local n = require("npcsync").stats()
        out(dev, ("  NPCs: %d from the host, %d paired here, %d looks known"):format(n.host, n.matched, n.looks))
    end
    local mirror = Sync.mirroredState()
    if next(mirror) then
        for label, v in pairs(mirror) do
            out(dev, ("  Host %s: %s"):format(label, tostring(v)))
        end
    end
    return true
end

handlers["rt.players"] = function(_, dev)
    Players.refreshRoster()
    local list = Players.list()
    if #list == 0 then
        out(dev, "No other players connected.")
    else
        out(dev, ("Connected (%d):"):format(#list))
        for _, n in ipairs(list) do out(dev, "  - " .. n) end
    end
    return true
end

handlers["rt.say"] = function(params, dev)
    local msg = table.concat(params, " ")
    if msg == "" then
        out(dev, "Usage: rt.say <message>")
    else
        Chat.say(msg)
    end
    return true
end

handlers["rt.pawns"] = function(_, dev)
    out(dev, "==== who has a character ====")
    for _, line in ipairs(Spawn.reportLines()) do out(dev, "  " .. line) end
    if UE.IsHosting() then
        out(dev, "  (rt.fixpawns retries anyone showing NONE)")
    end
    return true
end

handlers["rt.fixpawns"] = function(_, dev)
    if not UE.IsHosting() then
        out(dev, "Only the host can do this - spawning and possession are")
        out(dev, "authority-only. Ask whoever is hosting to run rt.fixpawns.")
        return true
    end
    local n = Spawn.retryNow()
    if n == 0 then
        out(dev, "Nobody is waiting for a character right now.")
        out(dev, "If a guest still sees black, run rt.pawns to check.")
    else
        out(dev, ("Retrying %d player(s) - watch this console for progress."):format(n))
    end
    return true
end

handlers["rt.state"] = function(_, dev)
    out(dev, "==== store state as THIS machine sees it ====")
    for _, line in ipairs(Inspect.stateSnapshot()) do out(dev, "  " .. line) end
    out(dev, "  Run this on BOTH machines. A value that differs and should not")
    out(dev, "  is one sync.lua's STATE list is missing.")
    return true
end

handlers["rt.props"] = function(params, dev)
    local what   = params[1] or "gameinstance"
    local filter = params[2] and tostring(params[2]):lower() or nil
    local obj, label = Inspect.resolve(what)
    if not UE.valid(obj) then
        out(dev, ("Could not find '%s'."):format(tostring(what)))
        out(dev, "Try: gameinstance | gamemode | gamestate | pawn | controller |")
        out(dev, "     playerstate | or any class name e.g. Shelve_C, Cartridge_Base_C")
        return true
    end
    out(dev, ("==== %s (%s) ===="):format(label, UE.ClassNameOf(obj)))
    for _, line in ipairs(Inspect.properties(obj, filter)) do out(dev, "  " .. line) end
    out(dev, "  (rt.props <what> <filter> narrows this to matching names)")
    return true
end

handlers["rt.funcs"] = function(params, dev)
    local what   = params[1] or "pawn"
    local filter = params[2] and tostring(params[2]):lower() or nil
    local obj, label = Inspect.resolve(what)
    if not UE.valid(obj) then
        out(dev, ("Could not find '%s'."):format(tostring(what)))
        out(dev, "Try: pawn | controller | gamemode | gameinstance |")
        out(dev, "     or any class name e.g. Shelve_C, Cartridge_Base_C")
        return true
    end
    out(dev, ("==== %s (%s) - functions ===="):format(label, UE.ClassNameOf(obj)))
    for _, line in ipairs(Inspect.functions(obj, filter)) do out(dev, "  " .. line) end
    out(dev, "  (rt.funcs <what> <filter> narrows this, e.g. rt.funcs pawn interact)")
    return true
end

handlers["rt.why"] = function(_, dev)
    out(dev, "==== can we see each other? ====")
    for _, line in ipairs(Inspect.visibility()) do out(dev, "  " .. line) end
    return true
end

handlers["rt.bodies"] = function(params, dev)
    if tostring(params[1] or ""):lower() == "retry" then
        Bodies.retry()
        out(dev, "Will try again now - watch this console.")
        return true
    end
    out(dev, "==== borrowed bodies ====")
    for _, line in ipairs(Bodies.reportLines()) do out(dev, "  " .. line) end
    out(dev, "  (rt.bodies retry forces another attempt)")
    return true
end

handlers["rt.stripes"] = function(params, dev)
    if tostring(params[1] or ""):lower() == "clear" then
        local cleared, failed, total = Inspect.clearOverlays()
        out(dev, ("cleared %d of %d overlay material(s), %d refused"):format(
            cleared, total, failed))
        if total == 0 then
            out(dev, "There were none. The stripes are not an overlay material,")
            out(dev, "so that theory is dead - say so rather than retrying this.")
        else
            out(dev, "LOOK AT THE STORE NOW. If the stripes are gone, that was it.")
        end
        return true
    end
    out(dev, "==== what is overlaying the store ====")
    for _, line in ipairs(Inspect.overlayReport()) do out(dev, "  " .. line) end
    return true
end

handlers["rt.localgm"] = function(params, dev)
    out(dev, "==== local GameMode ====")
    for _, line in ipairs(LocalGM.reportLines()) do out(dev, "  " .. line) end

    if tostring(params[1] or ""):lower() ~= "go" then
        out(dev, "")
        out(dev, "  A guest has no GameMode, which is why you have no HUD, no")
        out(dev, "  clock and no store logic. The engine refuses to REPLICATE")
        out(dev, "  one - it does not refuse to let this machine own one.")
        out(dev, "")
        out(dev, "  This is an experiment and it may do nothing, build your own")
        out(dev, "  store over the host's, or crash. It is worth one launch to")
        out(dev, "  find out, and a crash switches itself off afterwards.")
        out(dev, "")
        out(dev, "  Run:  rt.localgm go")
        return true
    end

    LocalGM.create()
    return true
end

handlers["rt.bring"] = function(_, dev)
    if not UE.IsHosting() then
        out(dev, "Only the host can move players. Ask them to run rt.bring.")
        return true
    end
    if not UE.valid(UE.GetPawn()) then
        out(dev, "You have no character to bring them to - are you in the store?")
        return true
    end
    local n = Spawn.bringEveryone()
    if n == 0 then
        out(dev, "Nobody to bring - no guests with characters right now.")
    else
        out(dev, ("Pulled %d player(s) to you."):format(n))
    end
    return true
end

-- The pause menu's "Back to the store", for when the menu itself is the problem.
handlers["rt.unstuck"] = function(_, dev)
    out(dev, require("pausemenu").backToStore())
    return true
end

handlers["rt.sweep"] = function(_, dev)
    local n = Replication.sweep()
    out(dev, ("Replication sweep: %d actor(s) updated."):format(n))
    return true
end

handlers["rt.overlay"] = function(_, dev)
    local v = Overlay.toggle()
    out(dev, "Overlay " .. (v and "shown" or "hidden"))
    return true
end

handlers["rt.menu"] = function(_, dev)
    out(dev, "==== main menu injection ====")
    local MainMenu = require("mainmenu")
    for _, line in ipairs(MainMenu.describe()) do out(dev, "  " .. line) end
    return true
end

handlers["rt.safety"] = function(params, dev)
    if tostring(params[1] or ""):lower() == "reset" then
        local n = Safety.reset()
        out(dev, ("Cleared %d block(s). Restart the game to try them again."):format(n))
        return true
    end

    -- A crash with nothing risky in flight switches nothing off; it is still
    -- worth being able to read back.
    local phase = Safety.lastCrashPhase()
    if phase then
        out(dev, ("The game crashed last time while the mod was running: %s"):format(phase))
        out(dev, "  (nothing risky of its own was in flight, so nothing was switched off)")
    end

    local list = Safety.blockedList()
    if #list == 0 then
        out(dev, phase and "Nothing is switched off."
                 or "Nothing is switched off - no crash has been recorded.")
        return true
    end

    out(dev, "==== switched off after a crash ====")
    for _, entry in ipairs(list) do
        out(dev, ("  %s"):format(entry.op))
        out(dev, ("      %s"):format(entry.why))
    end
    out(dev, "")
    out(dev, "  These are cosmetic; co-op itself is unaffected.")
    out(dev, "  Run  rt.safety reset  to try them again (after a mod update,")
    out(dev, "  say). If one crashes the game again it just switches off again.")
    return true
end

handlers["rt.config"] = function(_, dev)
    local list = Safety.configProblems()
    if #list == 0 then
        out(dev, "config.lua looks fine.")
    else
        out(dev, ("==== %d thing(s) to fix in config.lua ===="):format(#list))
        for _, p in ipairs(list) do out(dev, "  - " .. p) end
        out(dev, "")
        out(dev, "  Worked around for this session; fix the file to make it stick.")
    end
    out(dev, "  ...\\Binaries\\Win64\\ue4ss\\Mods\\RewindTogether\\Scripts\\config.lua")
    return true
end

handlers["rt.diag"] = function(_, dev)
    local p = P2P.stats()
    out(dev, "==== Rewind Together diagnostics ====")
    out(dev, "  Mod version:    " .. Net.VERSION .. "  (both PCs must match)")
    out(dev, "  NetMode:        " .. UE.NetModeName())
    out(dev, "  NetDriver:      " .. UE.DescribeNetDriver())
    out(dev, "  Map:            " .. Net.getCurrentMapName())
    out(dev, "  SteamID:        " .. tostring(Net.getLocalSteamId()))
    out(dev, "  Host SteamID:   " .. tostring(Net.hostId()))
    out(dev, "  P2P ready:      " .. tostring(P2P.isReady()))
    out(dev, ("  P2P traffic:    sent %d, failed %d, received %d")
        :format(p.sent, p.failed, p.received))
    out(dev, "  PlayerControllers: " .. tostring(#UE.GetAllPlayerControllers()))
    out(dev, "  GameMode:       " .. UE.ClassNameOf(UE.GetGameMode()))
    out(dev, "  GameInstance:   " .. UE.ClassNameOf(UE.GetGameInstance()))
    out(dev, "  Local pawn:     " .. UE.ClassNameOf(UE.GetPawn()))
    local st = Replication.stats()
    out(dev, ("  Replication:    %d classes / %d instances"):format(st.classes, st.instances))
    for _, line in ipairs(require("pausemenu").report()) do out(dev, "  " .. line) end
    out(dev, "  Set LogLevel = \"debug\" in config.lua for full detail.")
    return true
end

--------------------------------------------------------------------------

handlers["rt.native"] = function(params, dev)
    Native.load()
    out(dev, "==== native helper ====")
    for _, l in ipairs(Native.status()) do out(dev, "  " .. l) end
    if params[1] ~= "test" then return true end

    -- HOST: ask the engine for player 0 inside a guest window and outside it.
    if not UE.IsServer() then out(dev, "  test: host only") return true end
    local guest = nil
    for _, pc in ipairs(UE.GetAllPlayerControllers()) do
        if UE.alive(pc) and not UE.IsLocalController(pc) then guest = pc break end
    end
    if not guest then out(dev, "  test: needs a guest connected") return true end
    local gs, w = UE.GetGameplayStatics(), UE.GetWorld()
    local function who()
        local pc = gs:GetPlayerController(w, 0)
        return UE.valid(pc) and pc:GetFullName() or "nil"
    end
    local before = who()
    local inside = nil
    local ok, swaps, err = Native.asPlayer(guest, function() inside = who() end)
    local after = who()
    out(dev, ("  outside: %s"):format(before))
    out(dev, ("  inside:  %s  (redirected %d, ok=%s %s)"):format(tostring(inside), swaps or 0,
        tostring(ok), err and tostring(err) or ""))
    out(dev, ("  after:   %s"):format(after))
    local pass = inside == guest:GetFullName() and before == after and before ~= inside
    out(dev, pass and "  PASS - the guest is player 0 inside the window only"
                  or "  FAIL - see above")
    return true
end

--- Run one console line as if it had been typed. Used by the dev bridge.
function Commands.run(line, dev)
    local name, rest = tostring(line):match("^(%S+)%s*(.*)$")
    local fn = name and handlers[name]
    if not fn then return false end
    local params = {}
    for w in rest:gmatch("%S+") do params[#params + 1] = w end
    Log.guard("command " .. name, fn, params, dev)
    return true
end

--- F6. The full report goes to the log as before. On screen: the overlay when
--- it is on; SafeMode (the default) keeps it off, and a fresh UE4SS has no
--- console window, so then a short version goes where the game shows its own
--- messages (Hud.notice). Returns what was shown on screen, if anything.
function Commands.showStatus()
    handlers["rt.status"](nil, nil)
    Overlay.set({
        "Rewind Together",
        Net.statusLine(),
        "Steam ID: " .. tostring(Net.getLocalSteamId()),
        "Console: rt.help",
    })
    if Overlay.isEnabled() then return "overlay" end
    local c = Chan.stats()
    local text = ("Rewind Together %s{br}%s{br}Sync channel: sent %d, received %d")
        :format(Net.VERSION, Net.statusLine(), c.sent, c.received)
    -- No HUD at the main menu: rt.status in the game's console (~ twice) works there.
    -- 8 s: the game's own timing (0.04 s a character) is about 3 s for this.
    if Hud.notice(text, false, 8) then return text end
    return nil
end

function Commands.init(config)
    cfg = config

    local registered = 0
    for name, fn in pairs(handlers) do
        RegisterConsoleCommandHandler(name, function(fullCommand, parameters, outputDevice)
            return Log.guard("command " .. name, fn, parameters, outputDevice) or true
        end)
        registered = registered + 1
    end
    -- Counted, not assumed: this used to print #HELP, so a command added to
    -- the table without a help line - or the reverse - was invisible.
    Log.info("registered %d console commands, %d listed in rt.help", registered, #HELP)

    -- Keybinds. UE4SS key names are documented at docs.ue4ss.com.
    --
    -- UE4SS runs a keybind callback on its OWN thread, not the game's. Every
    -- callback here used to do its work right there - travel, spawning,
    -- tracing - while the game thread was in the middle of a frame and this
    -- mod's tick might be running Lua at the same moment. So the callback now
    -- only hands the work to the game thread, which is where the 10 Hz tick
    -- and every hook already run.
    local function bind(keyName, label, fn)
        if not keyName or keyName == "" then return end
        if Input.bind(keyName, label, fn) then return end
        local ok = pcall(function()
            RegisterKeyBind(Key[keyName], function()
                ExecuteInGameThread(function()
                    Log.guard("keybind " .. label, fn)
                end)
            end)
        end)
        if not ok then
            Log.warn("could not bind key %s for %s", tostring(keyName), label)
        end
    end

    bind(cfg.Keys.HostGame, "host", function()
        if UE.IsStandalone() then
            Net.host()
        else
            Log.info("already in a session (%s)", UE.NetModeName())
        end
    end)

    bind(cfg.Keys.QuickJoin, "quickjoin", function()
        if not UE.IsStandalone() then
            Log.info("already in a session (%s) - press F6 for status", UE.NetModeName())
            return
        end
        Net.quickJoin(SteamJoin)
    end)

    bind(cfg.Keys.InviteFriends, "invite", function()
        handlers["rt.invite"](nil, nil)
    end)

    bind(cfg.Keys.ToggleMenu, "menu", Commands.showStatus)

    -- Guest presses are forwarded by guestinput.lua now - every one of the
    -- game's own action keys, aimed from the guest's camera, replayed on the
    -- guest's own pawn. The old single "interact" key (Config.GuestInteractKey)
    -- would send E twice, so it is no longer bound.

    -- TAB in an older config.lua is skipped: it is the game's rotate key.
    local listKey = cfg.Keys.TogglePlayerList
    if listKey == "TAB" then listKey = "" end
    bind(listKey, "playerlist", function()
        Players.refreshRoster()
        local lines = { "Players:" }
        for _, n in ipairs(Players.list()) do lines[#lines + 1] = "  " .. n end
        Overlay.set(lines)
    end)
end

return Commands
