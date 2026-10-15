--[[
    Rewind Together - Steam P2P side-channel

    Why this exists
    ---------------
    Unreal's own replication handles the *world*: where people and props are,
    what animation they are playing. It cannot handle this game's store
    simulation, because none of the shop Blueprints were authored with
    replicated properties or RPCs, and we cannot add new ones to a cooked
    build.

    So gameplay state rides a second channel that we own end to end. Retro
    Rewind ships SteamCore Pro, which exposes Steam's P2P packet API to
    Blueprints - and therefore to us. That gives us arbitrary payloads between
    host and guests over Steam's relay network, with no port forwarding and no
    dependency on the game's replication graph.

    A note on discovery
    -------------------
    The exact SteamCore Pro signatures are not published with the shipped game,
    so this module *discovers* them at load and logs what it found. If the
    plugin's API differs from what we expect, you get a clear log line naming
    the function and its real parameters rather than a silent failure. Run with
    LogLevel = "debug" to see them.
]]

local Log = require("log")
local UE  = require("ue")

local P2P = {}

local api = {
    networking = nil,      -- USteamProNetworking instance or CDO
    friends    = nil,      -- USteamProFriends, for names
    user       = nil,      -- USteamProUser, for our own SteamID
    send       = nil,
    read       = nil,
    available  = nil,
    accept     = nil,
    sendIdClass= nil,      -- property class of SendP2PPacket's first parameter
    ready      = false,
}

local channel = 41
local handlers = {}        -- messageType -> function(payload, fromSteamId)

-- Counters, so "is the side-channel actually carrying anything" is a question
-- the log can answer at info level. It could not before, and that is precisely
-- how a channel that had never carried a single byte passed for working.
local stats = { sent = 0, failed = 0, received = 0 }

--------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------

local NETWORKING_CANDIDATES = {
    "SteamProNetworking",
    "SteamCoreNetworking",
    "SteamProNetworkingUtils",
}

local function findObjectOfClass(classNames)
    for _, name in ipairs(classNames) do
        local obj = FindFirstOf(name)
        if UE.valid(obj) then return obj, name end
        -- Fall back to the class default object: these SteamCore wrappers are
        -- stateless shims over the Steam API, so the CDO works as a receiver.
        local cdo = StaticFindObject("/Script/SteamCorePro.Default__" .. name)
        if UE.valid(cdo) then return cdo, name .. " (CDO)" end
        cdo = StaticFindObject("/Script/SteamCoreShared.Default__" .. name)
        if UE.valid(cdo) then return cdo, name .. " (CDO)" end
    end
    return nil, nil
end

-- Field names a SteamCore struct might carry its ID in. Declared HERE, above
-- its first use, and not down beside ID_SHAPES where it reads more naturally.
-- A `local` is only in scope after its declaration, so a reference from above
-- silently resolves to a nil global - which is exactly what happened: this
-- list lived 250 lines further down, probeIdStruct threw "attempt to index a
-- nil value" on every discovery attempt, and because that ran before
-- api.ready was set, the Steam channel could never come up at all.
local ID_FIELDS = {
    "SteamID", "SteamId", "Value", "ID", "Id",
    "UniqueNetId", "Identifier", "SteamID64", "AccountId", "Data",
}

--- Log the real field names of the SteamID struct, so nobody has to guess.
---
--- Two routes, because which one a UE4SS build supports is not something to
--- assume: the plugin's own struct type looked up by path, and - failing that
--- - an actual FSteamID handed back by GetSteamID, whose fields can be probed
--- by name. Whatever this prints is the answer to "what shape does
--- SendP2PPacket want", which four versions of guessing have not produced.
--- Read the SteamID struct's fields off SendP2PPacket's own parameter.
---
--- The most direct route there is, and the one to try first: the function
--- carries the parameter, the parameter carries the struct, and the struct
--- carries its field names. Everything else is a search.
---
--- Measured on this build: probing a live FSteamID by field name answers to
--- NONE of the ten names this mod knows, and the struct type is not findable
--- by any of the obvious paths - so the guessing approach is exhausted and
--- this is what is left.
local function probeSendParam(fn)
    if not UE.valid(fn) then return false end

    local first = nil
    pcall(function()
        fn:ForEachProperty(function(prop)
            if first == nil then first = prop end
        end)
    end)
    if first == nil then return false end

    -- Whichever accessor this UE4SS build publishes for a StructProperty's
    -- underlying type.
    local struct = nil
    for _, get in ipairs({
        function() return first:GetStruct() end,
        function() return first.Struct end,
        function() return first:GetPropertyClass() end,
    }) do
        local ok, s = pcall(get)
        if ok and UE.valid(s) then struct = s break end
    end
    if not UE.valid(struct) then return false end

    local name = "?"
    pcall(function() name = struct:GetFName():ToString() end)

    local fields = {}
    pcall(function()
        struct:ForEachProperty(function(prop)
            local n, c
            pcall(function()
                n = prop:GetFName():ToString()
                c = prop:GetClass():GetFName():ToString()
            end)
            if n then fields[#fields + 1] = ("%s %s"):format(tostring(c), n) end
        end)
    end)

    if #fields == 0 then
        Log.info("  SteamID struct is '%s' but exposes no readable fields", name)
        return false
    end

    Log.info("  SteamID struct '%s' fields: %s", name, table.concat(fields, ", "))

    -- Put the real names at the front of the shape list, so the very next send
    -- tries the answer instead of the guesses.
    for i = #fields, 1, -1 do
        local fieldName = fields[i]:match("%s(%S+)$")
        if fieldName then P2P.preferIdField(fieldName) end
    end
    return true
end

local function probeIdStruct()
    for _, path in ipairs({
        "/Script/SteamCorePro.SteamID",
        "/Script/SteamCoreShared.SteamID",
        "/Script/SteamCorePro.SteamCoreID",
        "/Script/CoreUObject.SteamID",
    }) do
        local s = StaticFindObject(path)
        if UE.valid(s) then
            local fields = {}
            pcall(function()
                s:ForEachProperty(function(prop)
                    local n, c
                    pcall(function()
                        n = prop:GetFName():ToString()
                        c = prop:GetClass():GetFName():ToString()
                    end)
                    if n then fields[#fields + 1] = ("%s %s"):format(tostring(c), n) end
                end)
            end)
            if #fields > 0 then
                Log.info("  SteamID struct (%s) fields: %s", path, table.concat(fields, ", "))
                return
            end
        end
    end

    -- Fall back to probing a live one by name.
    local user = StaticFindObject("/Script/SteamCorePro.Default__SteamProUser")
             or FindFirstOf("SteamProUser")
    if UE.valid(user) then
        for _, fn in ipairs({ "GetSteamID", "GetSteamId" }) do
            local ok, raw = UE.TryCall(user, fn)
            if ok and raw ~= nil and type(raw) ~= "number" and type(raw) ~= "string" then
                local hits = {}
                for _, field in ipairs(ID_FIELDS) do
                    local ok2, v = pcall(function() return raw[field] end)
                    if ok2 and v ~= nil then
                        hits[#hits + 1] = ("%s=%s"):format(field, tostring(v))
                    end
                end
                if #hits > 0 then
                    Log.info("  a live SteamID answers to: %s", table.concat(hits, ", "))
                else
                    Log.warn("  a live SteamID answers to NONE of the field names " ..
                             "this mod knows - that is why sending fails")
                end
                return
            end
        end
    end
    Log.debug("  could not probe the SteamID struct")
end

local function bindFunction(obj, names)
    for _, n in ipairs(names) do
        local fn = UE.valid(obj) and obj[n]
        if fn ~= nil then
            return n
        end
    end
    return nil
end

--- Locate the SteamCore Pro networking API. Safe to call repeatedly; it will
--- retry until Steam has initialised.
function P2P.discover()
    if api.ready then return true end

    local obj, how = findObjectOfClass(NETWORKING_CANDIDATES)
    if not UE.valid(obj) then
        Log.debug("SteamCore networking object not found yet")
        return false
    end
    api.networking = obj

    api.send      = bindFunction(obj, { "SendP2PPacket" })
    api.read      = bindFunction(obj, { "ReadP2PPacket" })
    api.available = bindFunction(obj, { "IsP2PPacketAvailable" })
    api.accept    = bindFunction(obj, { "AcceptP2PSessionWithUser" })

    if not (api.send and api.read and api.available) then
        Log.warn("SteamCore networking found via %s but the packet API is incomplete " ..
                 "(send=%s read=%s available=%s). Store state sync will be disabled; " ..
                 "movement and world replication still work.",
                 tostring(how), tostring(api.send), tostring(api.read), tostring(api.available))
        return false
    end

    Log.info("Steam P2P side-channel bound via %s", tostring(how))

    -- READY FIRST, DIAGNOSTICS AFTER, and the diagnostics behind a pcall.
    --
    -- The order is the point. Everything below this line only describes what
    -- was just bound; none of it decides whether the binding worked. When it
    -- ran BEFORE this assignment, one bad line in the reporting code
    -- (a forward-referenced local, throwing "attempt to index a nil value")
    -- took the whole tick down before api.ready was set - so discovery
    -- retried every three seconds forever and the Steam channel never came up
    -- at all. A diagnostic that can break the thing it is diagnosing is worse
    -- than no diagnostic.
    api.ready = true

    Log.guard("P2P discovery report", function()
        -- These were debug-level, which meant that with the default LogLevel
        -- nobody ever saw the one piece of information that decides whether
        -- this channel can work: what the plugin actually wants passed to it.
        if api.send then
            Log.info("  SendP2PPacket %s", UE.DescribeFunctionString(obj[api.send]))
            -- The first parameter is the peer's SteamID, and its property
            -- class is what decides how one has to be handed over.
            local params = UE.DescribeFunction(obj[api.send])
            if params and params[1] then
                api.sendIdClass = params[1].class
                Log.info("  SteamIDs are declared as %s", tostring(api.sendIdClass))
                if tostring(api.sendIdClass):find("Struct") then
                    -- Straight at the parameter first; the searches only run
                    -- if that comes up empty.
                    if not probeSendParam(obj[api.send]) then probeIdStruct() end
                end
            end
        end
        if api.read then
            Log.info("  ReadP2PPacket %s", UE.DescribeFunctionString(obj[api.read]))
        end
        if api.available then
            Log.info("  IsP2PPacketAvailable %s", UE.DescribeFunctionString(obj[api.available]))
        end
        if not api.accept then
            Log.warn("  no AcceptP2PSessionWithUser on this plugin - if packets never " ..
                     "arrive, Steam is refusing the session rather than dropping them")
        end
    end)
    return true
end

function P2P.isReady()
    return api.ready
end

--------------------------------------------------------------------------
-- Wire format
--------------------------------------------------------------------------
-- A message is a single line:
--     RT1|<type>|<k>=<v>|<k>=<v>...
-- Values are percent-escaped so they never contain | or =.
-- Small, human-readable in a packet capture, and cheap to parse. The store
-- sim sends a few hundred bytes a second at most, so a binary format would be
-- optimising the wrong thing.

local function esc(s)
    return (tostring(s):gsub("[%%|=\n\r]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

function P2P.encode(msgType, payload)
    local parts = { "RT1", esc(msgType) }
    for k, v in pairs(payload or {}) do
        parts[#parts + 1] = esc(k) .. "=" .. esc(v)
    end
    return table.concat(parts, "|")
end

function P2P.decode(str)
    if type(str) ~= "string" or str:sub(1, 4) ~= "RT1|" then return nil, nil end
    local fields, msgType = {}, nil
    local i = 0
    for chunk in str:gmatch("[^|]+") do
        i = i + 1
        if i == 1 then
            -- version tag, already checked
        elseif i == 2 then
            msgType = unesc(chunk)
        else
            local k, v = chunk:match("^(.-)=(.*)$")
            if k then fields[unesc(k)] = unesc(v) end
        end
    end
    return msgType, fields
end

--------------------------------------------------------------------------
-- Byte array conversion
--------------------------------------------------------------------------
-- SendP2PPacket takes a TArray<uint8>. UE4SS accepts a Lua array of numbers
-- for byte arrays; we build one from the string.

local function stringToBytes(s)
    local t = {}
    for i = 1, #s do t[i] = s:byte(i) end
    return t
end

local function bytesToString(arr)
    if type(arr) == "string" then return arr end
    local out = {}
    local ok = pcall(function()
        local n = arr:GetArrayNum()
        for i = 1, n do out[i] = string.char(arr[i] % 256) end
    end)
    if not ok then
        -- Plain Lua table fallback
        ok = pcall(function()
            for i = 1, #arr do out[i] = string.char(arr[i] % 256) end
        end)
        if not ok then return nil end
    end
    return table.concat(out)
end

--------------------------------------------------------------------------
-- Send / receive
--------------------------------------------------------------------------

P2P.SEND_UNRELIABLE = 0
P2P.SEND_RELIABLE   = 2   -- ESteamP2PSend: 0 Unreliable, 1 NoDelay, 2 Reliable, 3 ReliableWithBuffering

--[[
    How to hand this plugin a SteamID64.

    THIS IS WHY THE SIDE-CHANNEL HAS NEVER CARRIED A PACKET, and it is the
    second bug hiding behind the one 1.5.0 fixed. 1.5.0 correctly found that
    Net.addPeer had no callers, so the peer list was always empty and every
    broadcast went nowhere. With that fixed the list finally had entries - and
    still nothing moved, because every send aimed at those entries was thrown
    away one layer further down.

    The rest of this mod carries SteamIDs as strings, and it must: a SteamID64
    is around 7.6e16, past the 2^53 a double holds exactly, so putting one
    through a float loses digits and produces an ID that looks right and is
    not. But SteamCore Pro takes an FSteamID struct, not a string, and the
    struct's field name is not published with the shipped game. Passing the
    string threw, inside a pcall whose only report was a DEBUG line - so at the
    default log level every packet failed in complete silence.

    Rather than guess the shape, try them in order of likelihood and remember
    the first that works. Lua 5.4 has real 64-bit integers, so the conversion
    to a number is exact and is checked for having stayed exact.
]]

-- Measured on both machines: SendP2PPacket's first parameter is a
-- StructProperty, and all four of the shapes 1.5.1 tried were refused -
-- int64, {Value=int}, {SteamID=int} and a plain string. So the struct exists,
-- and neither of the two field names guessed at is right.
--
-- Two changes rather than more guessing. First, the field list is now the same
-- one UE.ExtractSteamId uses to READ an ID out of a SteamCore struct, crossed
-- with both int64 and string - because a plugin that stores a SteamID64 as
-- text (a reasonable thing to do; it does not fit in a double) would have been
-- missed entirely by only ever trying numbers. Second, and better, the struct's
-- real field names get logged at startup - see probeIdStruct below. Guessing
-- is what this file keeps getting wrong.
local ID_SHAPES = {}
do
    ID_SHAPES[#ID_SHAPES + 1] =
        { name = "int64", make = function(n) return n end }
    for _, field in ipairs(ID_FIELDS) do
        ID_SHAPES[#ID_SHAPES + 1] = {
            name = ("{%s=int}"):format(field),
            make = function(n) return n and { [field] = n } or nil end,
        }
        ID_SHAPES[#ID_SHAPES + 1] = {
            name = ("{%s=string}"):format(field),
            make = function(_, s) return { [field] = s } end,
        }
    end
    ID_SHAPES[#ID_SHAPES + 1] =
        { name = "string", make = function(_, s) return s end }
end

local idShape      = nil     -- index of the shape that worked, once one has
local shapeWarned  = false

--- Put a field name discovered from reflection at the front of the queue.
--- Called by the startup probe, so the first real send tries the build's own
--- answer before any of the guesses below it.
function P2P.preferIdField(field)
    if type(field) ~= "string" or field == "" then return end
    table.insert(ID_SHAPES, 1, {
        name = ("{%s=string}"):format(field),
        make = function(_, s) return { [field] = s } end,
    })
    table.insert(ID_SHAPES, 1, {
        name = ("{%s=int}"):format(field),
        make = function(n) return n and { [field] = n } or nil end,
    })
end

--- Which shapes to try, best first, according to what reflection says the
--- plugin actually declared.
---
--- Ask the build, do not assume: DescribeFunction gives the first parameter's
--- property class, and that alone usually settles it. Starting from the right
--- answer matters more here than it does elsewhere in this mod, because the
--- alternative is calling into native code with an argument of the wrong kind
--- several times over and hoping UE4SS turns each mismatch into a Lua error
--- rather than a fault.
---
--- Order matters below: "StructProperty" also contains "Str".
local function shapeOrder()
    local hint = api.sendIdClass
    local preferred = {}

    if type(hint) == "string" then
        if hint:find("Struct") then
            preferred = { 2, 3 }        -- FSteamID{Value}, FSteamID{SteamID}
        elseif hint:find("Str") then
            preferred = { 4 }           -- a plain string after all
        elseif hint:find("Int") then
            preferred = { 1 }           -- Int64Property / UInt64Property
        end
    end

    local order, seen = {}, {}
    for _, i in ipairs(preferred) do
        order[#order + 1] = i
        seen[i] = true
    end
    for i = 1, #ID_SHAPES do
        if not seen[i] then order[#order + 1] = i end
    end
    return order
end

--- Exact int64 for a SteamID64, or nil if it would have to go through a float.
local function toExactInt(id)
    local n = tonumber(id)
    if n == nil then return nil end
    if math.type(n) ~= "integer" then return nil end
    return n
end

--- One attempt with one shape.
--- Returns "yes" when the plugin said it sent, "maybe" when the call went
--- through without saying anything, and false when it threw or refused.
---
--- The distinction is the house rule: never report success for something that
--- was merely dispatched. SendP2PPacket returns a bool, so a shape that comes
--- back true really did go out; a shape that comes back nil may just mean the
--- argument list did not match and UE4SS filled the gap with nothing. During
--- probing we take "yes" over "maybe" so a wrong shape cannot win the race
--- against a right one.
local function trySend(arg, bytes, sendType)
    if arg == nil then return false end
    local ok, result = pcall(function()
        return api.networking[api.send](api.networking, arg, bytes, sendType, channel)
    end)
    if not ok then
        Log.debug("  send shape threw: %s", tostring(result))
        return false
    end
    if result == true  then return "yes" end
    if result == false then return false end
    return "maybe"
end

--- Send a message to one peer.
--- @param steamId  string|number  the peer's SteamID64
--- @param msgType  string
--- @param payload  table          string/number values only
--- @param reliable boolean
function P2P.send(steamId, msgType, payload, reliable)
    if not api.ready then return false end

    local wire     = P2P.encode(msgType, payload)
    local bytes    = stringToBytes(wire)
    local sendType = reliable and P2P.SEND_RELIABLE or P2P.SEND_UNRELIABLE
    local idStr    = tostring(steamId)
    local idInt    = toExactInt(idStr)

    -- Known shape: the fast path, which is every send after the first.
    if idShape then
        if trySend(ID_SHAPES[idShape].make(idInt, idStr), bytes, sendType) ~= false then
            stats.sent = stats.sent + 1
            Log.debug("-> %s %s (%d bytes)", idStr, msgType, #wire)
            return true
        end
        stats.failed = stats.failed + 1
        Log.debug("send failed to %s (%s) using the %s shape",
                  idStr, msgType, ID_SHAPES[idShape].name)
        return false
    end

    -- Probing, in the order reflection suggests. Two passes, so a shape the
    -- plugin actually confirmed always beats one that merely failed to
    -- complain.
    local fallback = nil
    for _, i in ipairs(shapeOrder()) do
        local shape = ID_SHAPES[i]
        local r = trySend(shape.make(idInt, idStr), bytes, sendType)
        if r == "yes" then
            idShape    = i
            stats.sent = stats.sent + 1
            Log.info("Steam P2P: SteamIDs go over as %s - side-channel is live", shape.name)
            return true
        elseif r == "maybe" and not fallback then
            fallback = i
        end
    end

    if fallback then
        idShape    = fallback
        stats.sent = stats.sent + 1
        Log.warn("Steam P2P: sending SteamIDs as %s - the call is accepted but " ..
                 "SendP2PPacket did not confirm delivery, so treat state sync " ..
                 "and chat as unproven until you see traffic on both machines.",
                 ID_SHAPES[fallback].name)
        return true
    end

    stats.failed = stats.failed + 1
    if not shapeWarned then
        shapeWarned = true
        Log.error("=====================================================")
        Log.error(" The Steam P2P side-channel cannot send.")
        Log.error("")
        local tried = {}
        for _, s in ipairs(ID_SHAPES) do tried[#tried + 1] = s.name end
        Log.error(" SendP2PPacket refused every way of passing a SteamID:")
        Log.error("   %s", table.concat(tried, ", "))
        Log.error(" It declares its first parameter as %s.", tostring(api.sendIdClass))
        Log.error(" The full signature was logged at startup - look for the")
        Log.error(" 'SendP2PPacket (...)' line.")
        Log.error("")
        Log.error(" Money, day and chat will not sync until this works.")
        Log.error(" Walking around and seeing each other are unaffected -")
        Log.error(" those ride the game's own replication, not this channel.")
        Log.error("=====================================================")
    end
    return false
end

--- Sent / failed / received totals, for rt.status.
function P2P.stats()
    return { sent = stats.sent, failed = stats.failed, received = stats.received,
             idShape = idShape and ID_SHAPES[idShape].name or nil }
end

--- Send to every known peer.
function P2P.broadcast(peers, msgType, payload, reliable)
    local sent = 0
    for _, id in ipairs(peers) do
        if P2P.send(id, msgType, payload, reliable) then sent = sent + 1 end
    end
    return sent
end

--- Register a handler for a message type.
function P2P.on(msgType, fn)
    handlers[msgType] = fn
end

--- Drain the receive queue. Call every tick; it is cheap when idle.
function P2P.poll()
    if not api.ready then return 0 end
    local processed = 0

    for _ = 1, 64 do   -- bound the work per frame
        local hasPacket, size = false, 0
        local ok = pcall(function()
            hasPacket, size = api.networking[api.available](api.networking, channel)
        end)
        if not ok or not hasPacket then break end

        local data, fromId
        ok = pcall(function()
            data, fromId = api.networking[api.read](api.networking, channel)
        end)
        if not ok then
            Log.debug("ReadP2PPacket threw; stopping this drain")
            break
        end

        local str = bytesToString(data)
        if str then
            local msgType, fields = P2P.decode(str)
            if msgType then
                Log.debug("<- %s %s", tostring(fromId), msgType)
                -- Anyone who sends us a well-formed packet IS a peer. Peer
                -- registration used to depend on a handshake nothing ever
                -- performed, so the peer list stayed empty forever and every
                -- broadcast - state sync, chat - silently sent to nobody.
                if P2P.onPeerSeen and fromId ~= nil then
                    Log.guard("onPeerSeen", P2P.onPeerSeen, fromId)
                end
                local h = handlers[msgType]
                if h then
                    Log.guard("p2p handler " .. msgType, h, fields, fromId)
                else
                    Log.debug("no handler for message type %s", msgType)
                end
                processed      = processed + 1
                stats.received = stats.received + 1
            end
        end
    end

    return processed
end

--- Accept an incoming P2P session (Steam requires this before packets flow).
---
--- Takes a SteamID the same way SendP2PPacket does, so it has the same problem
--- and needs the same treatment - passing a string here failed silently too,
--- which is why "accepted P2P session with ..." never once appeared in a log.
function P2P.acceptSession(steamId)
    if not api.ready or not api.accept then return false end

    local idStr = tostring(steamId)
    local idInt = toExactInt(idStr)

    -- Whatever sending settled on, if anything, then the reflection-guided
    -- order for the rest.
    local order = {}
    if idShape then order[1] = idShape end
    for _, i in ipairs(shapeOrder()) do
        if i ~= idShape then order[#order + 1] = i end
    end

    for _, i in ipairs(order) do
        local shape = ID_SHAPES[i]
        local arg = shape.make(idInt, idStr)
        if arg ~= nil then
            local ok = pcall(function()
                api.networking[api.accept](api.networking, arg)
            end)
            if ok then
                Log.info("accepted P2P session with %s", idStr)
                return true
            end
        end
    end

    Log.debug("could not accept a P2P session with %s", idStr)
    return false
end

function P2P.setChannel(c)
    channel = c or 41
end

return P2P
