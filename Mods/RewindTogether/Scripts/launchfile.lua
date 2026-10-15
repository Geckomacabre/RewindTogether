--[[
    Rewind Together - talking to the launcher

    The launcher (launcher\, C#) never talks to the game directly. It drops a
    one-shot request file before it starts the game, and reads a heartbeat
    file the mod rewrites every two seconds. docs\LAUNCHER_CONTRACT.md is the
    specification; this is the mod's half of it.

      RewindTogether.launch.json   launcher -> mod   { action = join|host, ... }
      RewindTogether.status.json   mod -> launcher   version, mode, players

    Both live in the game's working directory (Binaries\Win64), beside
    RewindTogether.log, so plain relative paths reach them.

    WHY A JOIN NEEDS NO SAVE

    Measured in 1.7.0: OpenLevel to the host's address from the MAIN MENU
    joins in about two seconds - the menu already has a PlayerController, and
    that is all travel needs. The old advice ("load your own save first, then
    press F5") came from a readiness check that demanded a pawn, not from the
    engine. So a launcher join acts as soon as there is a controller.
]]

local Log = require("log")
local UE  = require("ue")
local Net = require("net")

local Launch = {}

local REQUEST = "RewindTogether.launch.json"
local STATUS  = "RewindTogether.status.json"
local MAX_AGE = 600          -- seconds; an older request is a leftover, not an intent
local POLL    = 1.0
local BEAT    = 2.0

local lastPoll, lastBeat = 0, 0
local pending = nil          -- { action = "join"|"host", address = ... }
local lastError = ""

--------------------------------------------------------------------------
-- A very small JSON reader: one flat object of strings, numbers and bools,
-- which is all the contract allows. Anything else is refused, not guessed at.
--------------------------------------------------------------------------

local function parseFlat(text)
    if type(text) ~= "string" then return nil end
    local body = text:match("^%s*{(.*)}%s*$")
    if not body then return nil end
    local out = {}
    local pos = 1
    while true do
        local s, e, key = body:find('^%s*"([^"]*)"%s*:%s*', pos)
        if not s then break end
        pos = e + 1
        local v
        if body:sub(pos, pos) == '"' then
            -- Walk to the closing quote; Lua patterns cannot express "an
            -- escaped character or anything but a quote".
            local i, buf = pos + 1, {}
            while true do
                local c = body:sub(i, i)
                if c == "" then return nil end
                if c == '"' then break end
                if c == "\\" then
                    local n = body:sub(i + 1, i + 1)
                    local map = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                    buf[#buf + 1] = map[n] or n
                    i = i + 2
                else
                    buf[#buf + 1] = c
                    i = i + 1
                end
            end
            v = table.concat(buf)
            pos = i + 1
        else
            local ns, ne, num = body:find("^(-?%d+%.?%d*[eE]?[-+]?%d*)", pos)
            if ns then
                v = tonumber(num)
                pos = ne + 1
            elseif body:find("^true", pos) then
                v = true
                pos = pos + 4
            elseif body:find("^false", pos) then
                v = false
                pos = pos + 5
            elseif body:find("^null", pos) then
                v = nil
                pos = pos + 4
            else
                return nil
            end
        end
        out[key] = v
        local cs, ce = body:find("^%s*,", pos)
        if cs then pos = ce + 1 else break end
    end
    return out
end
Launch._parseFlat = parseFlat   -- for the smoke test

local function esc(s)
    return (tostring(s):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end))
end

local function readAll(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("a")
    fh:close()
    return s
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------

local function takeRequest()
    local text = readAll(REQUEST)
    if not text then return end
    os.remove(REQUEST)

    local req = parseFlat(text)
    if not req or (req.action ~= "join" and req.action ~= "host") then
        lastError = "The launcher's request could not be read."
        Log.warn("launcher request ignored - not understood: %s", text:sub(1, 120))
        return
    end
    local written = tonumber(req.written)
    if written and (os.time() - written) > MAX_AGE then
        Log.info("launcher request ignored - it is %d minutes old",
                 math.floor((os.time() - written) / 60))
        return
    end
    if req.slot ~= nil and not (type(req.slot) == "string" and req.slot:match("^Player_Save[1-5]$")) then
        lastError = "The launcher asked for a save slot the game does not have."
        Log.warn("launcher request ignored - bad save slot %s", tostring(req.slot))
        return
    end
    if req.action == "join" and (type(req.address) ~= "string" or req.address == "") then
        lastError = "The launcher asked to join but gave no address."
        Log.warn("%s", lastError)
        return
    end

    pending = req
    if req.action == "join" then
        Log.info("launcher: joining %s%s", req.address,
                 req.host_name and (" (" .. tostring(req.host_name) .. ")") or "")
    else
        Log.info("launcher: will open your store to friends as soon as you are in it")
    end
end

--- Is the player standing in their own store (not the main menu)?
---
--- The main menu runs in the same level as the store (L_Player_Store_01 with
--- MainMenu_GameMode_C - measured), so the map name cannot tell them apart.
--- The GameMode class can.
local function inOwnStore()
    local gm = UE.GetGameMode()
    return UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C"
           and UE.valid(UE.GetPawn())
end

local function actOnPending(now)
    if not pending then return end
    if not UE.IsStandalone() then pending = nil return end

    if pending.action == "join" then
        if not UE.alive(UE.GetPlayerController()) then return end
        local addr = pending.address
        pending = nil
        if not Net.join(addr) then
            lastError = Net.state.lastError or "Joining did not start - see RewindTogether.log."
        end
    elseif pending.action == "host" then
        -- With a slot, load it the way the game's own menu does (decompiled
        -- UX_Boot_StartOption: GameInstance."Save Slot" = "Player_Save<N>",
        -- then OpenLevel L_Player_Store_01 - which also creates the save if
        -- the slot is empty). Without one, the player picks their save.
        if pending.slot and not pending.slotLoaded then
            local gm = UE.GetGameMode()
            local atMenu = UE.valid(gm) and UE.ClassNameOf(gm) == "MainMenu_GameMode_C"
            if not atMenu then return end
            local gi, gs, w = UE.GetGameInstance(), UE.GetGameplayStatics(), UE.GetWorld()
            if not (UE.valid(gi) and UE.valid(gs) and UE.valid(w)) then return end
            pending.slotLoaded = true
            Log.info("launcher: loading %s and opening it to friends", pending.slot)
            UE.TrySet(gi, "Save Slot", pending.slot)
            pcall(function() gs:OpenLevel(w, FName("L_Player_Store_01"), true, "") end)
            return
        end
        if not inOwnStore() then return end
        -- A moment for the save to finish spawning the store's contents.
        pending.readyAt = pending.readyAt or now
        if (now - pending.readyAt) < 3.0 then return end
        pending = nil
        if not Net.host() then
            lastError = Net.state.lastError or "Hosting did not start - see RewindTogether.log."
        end
    end
end

--------------------------------------------------------------------------
-- Heartbeat
--------------------------------------------------------------------------

local function writeStatus(port)
    local mode = UE.NetModeName()
    local fields = {
        ('"version": "%s"'):format(esc(Net.VERSION)),
        ('"mode": "%s"'):format(esc(mode)),
        ('"in_store": %s'):format(UE.valid(UE.GetPawn()) and "true" or "false"),
        ('"players": %d'):format(UE.IsStandalone() and 1 or (Net.connectedPlayers() or 1)),
        ('"port": %d'):format(tonumber(port) or 27015),
        ('"last_error": "%s"'):format(esc(lastError)),
        ('"updated": %d'):format(os.time()),
    }
    local tmp = STATUS .. ".tmp"
    local fh = io.open(tmp, "w")
    if not fh then return end
    fh:write("{ " .. table.concat(fields, ", ") .. " }\n")
    fh:close()
    -- rename() will not replace an existing file on Windows. The launcher
    -- treats a missing or unreadable file as "try again in a moment".
    os.remove(STATUS)
    os.rename(tmp, STATUS)
end

--------------------------------------------------------------------------

--- Every tick, on the game thread.
function Launch.tick(now, port)
    if now - lastBeat > BEAT then
        lastBeat = now
        pcall(writeStatus, port)
    end

    if not UE.IsStandalone() then return end
    if now - lastPoll > POLL then
        lastPoll = now
        takeRequest()
    end
    actOnPending(now)
end

function Launch.setError(msg) lastError = msg or "" end

--- Steam's own "Join Game" landed on the game, but a Steam-relay join needs
--- the launcher's tunnel. Start the launcher with --join <id>; it starts the
--- tunnel and answers with a launch.json, which takeRequest() acts on.
---
--- The launcher writes its own path to RewindTogether.launcher.txt on every
--- start. Both values are validated before they reach a command line: the
--- ID is exactly 17 digits, the path is an existing .exe with no quotes.
function Launch.askLauncherToJoin(steamId)
    if type(steamId) ~= "string" or not steamId:match("^%d+$") or #steamId ~= 17 then
        Log.warn("ignored a join request with a malformed Steam ID")
        return false
    end
    local path = readAll("RewindTogether.launcher.txt")
    path = path and path:match("^%s*(.-)%s*$")
    local fh = path and path ~= "" and io.open(path, "rb")
    if fh then fh:close() end
    if not fh or not path:lower():match("%.exe$") or path:find('"', 1, true) then
        lastError = "A friend's Join Game needs the Rewind Together launcher - start it once, then try again."
        Log.error("=====================================================")
        Log.error(" Steam asked to join a friend, but the Rewind Together")
        Log.error(" launcher is not installed here (or has moved).")
        Log.error(" Start RewindTogetherLauncher.exe once, then use Join")
        Log.error(" in it - or ask your friend for their address.")
        Log.error("=====================================================")
        return false
    end
    Log.info("starting the launcher to carry the connection to %s", steamId)
    -- "start" detaches it; the empty "" is start's window-title argument.
    os.execute(('start "" "%s" --join %s'):format(path, steamId))
    return true
end

return Launch
