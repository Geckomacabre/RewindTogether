--[[
    Rewind Together - chat

    Chat rides the same Steam P2P side-channel as state sync, so it works even
    before the UE connection has finished handshaking and keeps working if the
    game's replication hiccups.

    The host relays: guests send to the host, the host echoes to everyone. That
    keeps a single ordering of messages and means guests only ever need to know
    the host's Steam ID.
]]

local Log     = require("log")
local UE      = require("ue")
local P2P     = require("steamp2p")
local Net     = require("net")
local Overlay = require("overlay")

local Chat = {}

local history = {}
local MAX_HISTORY = 8
local FADE_SECONDS = 12
local composing = false
local buffer = ""

local function localName()
    return UE.PlayerNameOf(UE.GetPlayerController()) or "Me"
end

local function record(who, text)
    history[#history + 1] = { who = who, text = text, at = os.clock() }
    while #history > MAX_HISTORY do table.remove(history, 1) end
    Log.info("[chat] %s: %s", who, text)
    Chat.render()
end

--- Lines that have not aged out yet, for the overlay.
function Chat.recentLines()
    local now = os.clock()
    local out = {}
    for _, m in ipairs(history) do
        if composing or (now - m.at) < FADE_SECONDS then
            out[#out + 1] = ("%s: %s"):format(m.who, m.text)
        end
    end
    if composing then
        out[#out + 1] = "> " .. buffer .. "_"
    end
    return out
end

function Chat.render()
    Overlay.set(Chat.recentLines())
end

--------------------------------------------------------------------------

--- Send a chat message.
function Chat.say(text)
    if not text or text == "" then return false end
    text = text:sub(1, 200)

    local me = localName()

    if UE.IsServer() then
        -- Host: show locally and fan out.
        record(me, text)
        P2P.broadcast(Net.peerIds(), "chat", { who = me, msg = text }, true)
    else
        -- Guest: show locally for responsiveness, host will echo to others.
        record(me, text)
        local host = Net.hostId()
        if host then
            P2P.send(host, "chat", { who = me, msg = text }, true)
        else
            Log.warn("your message was not delivered - the host's Steam ID is not " ..
                     "known yet. Put their ID in Config.PeerSteamIds (they run rt.id).")
        end
    end
    return true
end

local function onChat(fields, fromId)
    local who  = fields.who or "Player"
    local text = fields.msg or ""
    if text == "" then return end

    record(who, text)

    -- Host relays to the other guests so everyone sees the same conversation.
    if UE.IsServer() then
        for _, id in ipairs(Net.peerIds()) do
            if tostring(id) ~= tostring(fromId) then
                P2P.send(id, "chat", { who = who, msg = text }, true)
            end
        end
    end
end

--------------------------------------------------------------------------
-- Composing
--------------------------------------------------------------------------

function Chat.isComposing() return composing end

function Chat.beginCompose()
    composing = true
    buffer = ""
    Chat.render()
end

function Chat.appendChar(c)
    if not composing then return end
    buffer = buffer .. c
    Chat.render()
end

function Chat.backspace()
    if not composing then return end
    buffer = buffer:sub(1, -2)
    Chat.render()
end

function Chat.commit()
    if not composing then return end
    local text = buffer
    composing, buffer = false, ""
    if text ~= "" then Chat.say(text) end
    Chat.render()
end

function Chat.cancelCompose()
    composing, buffer = false, ""
    Chat.render()
end

function Chat.init()
    P2P.on("chat", onChat)
end

return Chat
