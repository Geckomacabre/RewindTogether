--[[
    Rewind Together - the store's screen machines, for guests

    REQUESTED (16 Oct 2026): "comb thru every part of the game ... when i
    wake up i want this to be perfect". After the office computer
    (computer.lua) these are the machines a player works with the mouse on a
    screen of their own (docs/MULTIPLAYER-AUDIT.md). A guest's game runs each
    one itself, as in single player - machines.lua leaves screen machines to
    it - but its copy has no GameMode to read from, which only the host has.
    Read off the dumps for every one of them, and measured on the two-copy rig:

      * THE CATALOGUE (shelves, equipment, decorations, counter stations).
        On a guest every product card stayed under its "Unlock at level 99"
        cover (its Construct casts GetGameMode for the level, @406), the
        station cards kept the designer's "$999" and "Call Bob's Repair
        Services...", and a Buy did nothing - the widget's own handlers charge
        through the GameMode it never got (@3618, @8421). Here the guest's
        cards are uncovered as far as the store's level goes and the station
        cards are filled from the guest's own copies of the machines; a Buy
        is an order (guest action 21) that the HOST's catalogue places with
        its own handler - the money, the box at the delivery spot, the
        "buy shelves" tutorial step - exactly as a click on the host's.
      * THE STORE EXPANSION MAP. Its rooms are linked to the store's
        expansions through the GameMode (Binds And Link to Map @1273), so on
        a guest every room read "Text Block", "9999$" and did nothing. The
        host says which expansion each room is; the guest links its own map
        to its own copies (the game's own Set Reference And Construct draws
        name, price and colour), and a click buys that room on the host
        (action 20) - walls, dust and all.
      * THE SIDEWALK SIGN. Which ad it shows is saved and loaded by the host's
        GameMode only, so a guest's sign showed the wrong one and a guest's
        pick changed nothing. The host's pick is shown on every sign; a
        guest's pick is the host's (action 19).
      * THE STORE LEVEL BOARD. Its cross-mark and the movie-genre post-its
        are placed from the GameMode's level (Switch Page @570, @727), so on
        a guest they stayed where the designer left them. They are drawn from
        the host's level here, on every page turn.
      * THE STORE'S NAME SIGN. A guest's game opens its own sign's editor (its
        Interaction asks the GameMode only for the tool) and every edit goes
        straight into the guest's own copy (Send info to StoreName @6179) -
        which worldsync.lua then put back to the host's within two seconds,
        while the guest was still typing. Now, while the guest's editor is up,
        the host's sign waits; when it closes the guest's sign goes to the
        host if it differs - name, colours and font in one name on
        character.lua's route ("RTSN:", the name in hex: an FName keeps
        whichever casing it first met) - and the host's sign takes it as its
        own editor would, and worldsync gives it to everybody.

    Orders and rooms cost money, and the guest-to-host channel is unreliable
    and sent twice (rpcchan.lua): each carries a number, the host does each
    number once and answers, and the guest asks again once if no answer
    comes - computer.lua's way.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local UIM = {}

local ACTION_SIGN, ACTION_ROOM, ACTION_ORDER = 19, 20, 21
local KIND_PRODUCT, KIND_STATION = 1, 2
local OP_HOST  = "a guest's catalogue, expansion or sidewalk-sign choice on the host"
local OP_GUEST = "the store's screen machines on a guest"

local CATALOGUE_W = "/Game/VideoStore/asset/prop/catalogue/UI_Catalogue_Widget.UI_Catalogue_Widget_C"
local SECTOR_W    = "/Game/VideoStore/asset/prop/StoreExpansion_Map/UI_StoreExpansion_Sector.UI_StoreExpansion_Sector_C"
local LEVEL_BOARD = "/Game/VideoStore/asset/prop/StoreLevel/StoreLevel_Machine.StoreLevel_Machine_C"
local HOOKS = {
    product = CATALOGUE_W .. ":Market - Click on Button Product Event",
    station = CATALOGUE_W .. ":Countertop - Click on Button Countertop",
    room    = SECTOR_W .. ":BndEvt__UI_StoreExpansion_Sector_btn_map_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
    page    = LEVEL_BOARD .. ":Switch Page",
}
-- The catalogue's three product pages: the widget's own lists, the same on
-- every machine (hard-coded class arrays), and the box each page's cards go in.
local PAGES = {
    { list = "Return Catalogue Container product class",  box = "Container_WrapBox" },
    { list = "Return Catalogue Equipmement product class", box = "Equipment_WrapBox" },
    { list = "Return Catalogue Decoration product class",  box = "Decoration_WrapBox" },
}
-- The station cards' machines, by Unlock_GameplaySystem (the widget's
-- Countertop handler, UI_Catalogue_Widget @8658-@11224).
local STATIONS = { [2] = "SlushMachine_C", [3] = "PopcornMachine_C", [4] = "CottonCandyMachine_C",
                   [15] = "RepairStation_C", [16] = "SidewalkSign_C", [17] = "CustomMovieStation_C",
                   [20] = "ConsoleRental_Station_C" }
-- The console rental has no price, level, name or picture of its own to
-- read: its Gather Product Info says them (ConsoleRental_Station @0-@264).
local CONSOLE_PRICE, CONSOLE_LEVEL = 150.0, 21
local CONSOLE_NAME  = { "/Game/VideoStore/localization/interface/Interface.Interface", "Interface_ConsoleRental_Title" }
local CONSOLE_THUMB = "/Game/VideoStore/asset/prop/ConsoleRental/T_ConsoleRental-T.T_ConsoleRental-T"
local SECTORS = { "UI_StoreExpansion_Sector", "UI_StoreExpansion_Sector_1", "UI_StoreExpansion_Sector_3",
                  "UI_StoreExpansion_Sector_Adult", "UI_StoreExpansion_Sector_Northest_L",
                  "UI_StoreExpansion_Sector_Northest_R" }

local SEND_EVERY  = 13.0     -- host: what the guests' copies need, when it changed;
                             -- MEASURED 23 ms on the host's frame a send, so not every 2 s
local RESEND      = 10.0     -- host: and again regardless (a guest who just joined)
local RETRY_AFTER = 4.0      -- guest: an order not answered by then goes again, once
local SEEN_FOR    = 15.0     -- host: an order number from a guest, remembered
local SIGN_WAIT   = 6.0      -- guest: its own ad pick waits this long for the host to agree
local MAX_PENNIES = 100000000

local NAME_PREFIX = "RTSN:"
local NAME_HOLD   = 6.0      -- guest: its own sign stands this long after it sent it

local stats = { sent = 0, orders = 0, rooms = 0, ads = 0, refused = 0, cardsShown = 0, roomsLinked = 0,
                boards = 0, renamed = 0 }

--------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end

local function nameOf(o)
    local n = nil
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

--- A machine's screen: the user widget on its "Widget" component.
local function widgetOf(machine)
    local wc = UE.alive(machine) and UE.TryGet(machine, "Widget") or nil
    if not UE.valid(wc) then return nil end
    local ok, w = UE.TryCall(wc, "GetUserWidgetObject")
    return (ok and UE.valid(w)) and w or nil
end

--- One of the catalogue's own class lists (an array out-parameter: it comes
--- back as a Lua list of parameters, measured).
local function listOf(w, fn)
    local t, out = {}, {}
    if UE.TryCall(w, fn, t) then
        for i, p in ipairs(t) do
            local v = nil
            pcall(function() v = p:get() end)
            out[i] = v
        end
    end
    UE.releaseOut(t)
    return out
end

--- The level a product unlocks at: its class default's (Shelve, Arcade,
--- PosterFrame, Decoration: "Unlock Level"; a machine: "Product Unlock
--- Level") - what its Gather Product Info answers.
local function unlockLevelOf(cls)
    local cdo = nil
    pcall(function() cdo = cls:GetCDO() end)
    if not UE.valid(cdo) then return 0 end
    return tonumber(UE.TryGet(cdo, "Unlock Level")) or tonumber(UE.TryGet(cdo, "Product Unlock Level")) or 0
end

local function firstOf(short)
    local m = UE.findFirst(short)
    return UE.alive(m) and m or nil
end

--- A station's machine: unlocked by research or level ("Unlocked" on the
--- concession machines, "Unlock" on the rest), bought, its price and level.
local function stationState(id, m)
    local unlocked = UE.TryGet(m, "Unlocked") == true or UE.TryGet(m, "Unlock") == true
    local bought = UE.TryGet(m, "Bought") == true
    local price = tonumber(UE.TryGet(m, "Product Price")) or tonumber(UE.TryGet(m, "Price"))
    local level = tonumber(UE.TryGet(m, "Product Unlock Level")) or tonumber(UE.TryGet(m, "Unlock Level"))
    if id == 20 then price, level = CONSOLE_PRICE, CONSOLE_LEVEL end
    return unlocked, bought, price or 0.0, level or 0
end

--- A price as the game writes it (MoneyToText "Format Pennies to Text",
--- which the station cards use themselves, @8170).
local MONEY_TEXT = "/Game/VideoStore/core/blueprint/text/MoneyToText.Default__MoneyToText_C"
local function priceText(pennies)
    local lib = StaticFindObject(MONEY_TEXT)
    local out, s = {}, nil
    if UE.valid(lib) then
        pcall(function()
            lib["Format Pennies to Text"](lib, pennies, UE.GetWorld(), out, {})
            s = out["Format Text"]:ToString()
        end)
    end
    UE.releaseOut(out)
    return type(s) == "string" and s ~= "" and s or ("$%.2f"):format(pennies / 100)
end

local function isSoft(v) return type(v) == "userdata" and tostring(v):find("TSoftObjectPtr", 1, true) ~= nil end

--- A station's name and picture, as its own Gather Product Info has them:
--- the machine's "Product Name" / "Product Image Thumbnail", or "Station
--- Name" / "Image Thumbnail" on the stations that are not MachineActors' own.
local function stationLook(id, m)
    local name, thumb = nil, nil
    pcall(function() name = UE.TryGet(m, "Product Name"):ToString() end)
    if type(name) ~= "string" or name == "" then pcall(function() name = UE.TryGet(m, "Station Name"):ToString() end) end
    thumb = UE.TryGet(m, "Product Image Thumbnail")
    if not isSoft(thumb) then thumb = UE.TryGet(m, "Image Thumbnail") end
    if id == 20 then
        pcall(function()
            local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
            name = ktl:TextFromStringTable(FName(CONSOLE_NAME[1]), CONSOLE_NAME[2]):ToString()
        end)
        local ksl = UE.GetKismetSystemLibrary()
        thumb = nil
        pcall(function() thumb = ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(CONSOLE_THUMB)) end)
    end
    if type(name) ~= "string" or name == "" then name = nil end
    return name, isSoft(thumb) and thumb or nil
end

local function storeLevel()
    if UE.IsServer() then
        local gm = UE.GetGameMode()
        return UE.valid(gm) and tonumber(UE.TryGet(gm, "Level")) or nil
    end
    local ok, m = pcall(function() return require("sync").mirroredState() end)
    return ok and type(m) == "table" and tonumber(m.Level) or nil
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local seen = {}            -- host: pc full name .. "#" .. number -> when
local queue = {}           -- host: orders, one placed per tick (the widget keeps one in its frame)
local lastSig, lastAt, lastBuild = nil, -1e9, -1e9

local function tell(pc, ok, text)
    Chan.sendTo(pc, "uimres", { ok = ok and "1" or "0", t = text or "" })
end

--- The host's map: each room's expansion, by the room's ID, as the game
--- linked them (Binds And Link to Map).
local function roomsOnHost()
    local w = widgetOf(firstOf("StoreExpansion_Machine_C"))
    if not w then return nil end
    local rooms = {}
    for _, field in ipairs(SECTORS) do
        local s = UE.TryGet(w, field)
        if UE.valid(s) then
            local id = tonumber(UE.TryGet(s, "Store Expansion ID"))
            local ref = UE.TryGet(s, "Store Expansion Ref")
            if id and UE.alive(ref) then rooms[id] = { sector = s, ref = ref } end
        end
    end
    return w, rooms
end

local function sendState(now)
    if (now - lastAt) < SEND_EVERY or (now - lastBuild) < SEND_EVERY then return end
    -- At most once per SEND_EVERY, sent or not. MEASURED (16 Oct 2026): with the
    -- state unchanged, or no guest to send it to, this rebuilt it on every
    -- tick - the calendar's month read is 28 ms of the host's frame.
    lastBuild = now
    local fields = {}
    local sign = firstOf("SidewalkSign_C")
    if sign then fields.ss = tostring(round(UE.TryGet(sign, "Sale Type"))) end
    local _, rooms = roomsOnHost()
    for id, r in pairs(rooms or {}) do
        local n = nameOf(r.ref)
        if n and id >= 0 and id <= 9 then fields["x" .. id] = n end
    end
    if not next(fields) then return end
    local parts = {}
    for k, v in pairs(fields) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    local sig = table.concat(parts, ";")
    if sig == lastSig and (now - lastAt) < RESEND then return end
    if Chan.broadcast("uim", fields) > 0 then
        lastSig, lastAt = sig, now
        stats.sent = stats.sent + 1
    end
end

local function asGuest(pc, fn) return require("guestinput").asGuest(pc, fn) end

--- A room on the map: what a click on it does on the host's own map.
local function buyRoom(pc, id)
    local w, rooms = roomsOnHost()
    local r = rooms and rooms[id]
    if not r then return tell(pc, false, "That room is not on the host's map.") end
    if UE.TryGet(r.ref, "Unlocked") == true then return tell(pc, false, "That room is already open.") end
    local gm = UE.GetGameMode()
    local money, price = tonumber(UE.TryGet(gm, "Money")), tonumber(UE.TryGet(r.ref, "Price"))
    asGuest(pc, function() w["Click Map Button Event"](w, r.sector, r.ref) end)
    if UE.TryGet(r.ref, "Unlocked") == true then
        stats.rooms = stats.rooms + 1
        Log.info("store expansion: %s bought a room (%s)", UE.PlayerNameOf(pc) or "a guest", nameOf(r.ref) or "?")
        return tell(pc, true, "The new room is yours - the builders are on it.")
    end
    stats.refused = stats.refused + 1
    if money and price and money < price then return tell(pc, false, "Not enough money for that room.") end
    tell(pc, false, "That room needs the one beside it first.")
end

local function product(pc, page, index, pennies)
    local def = PAGES[page]
    local cat = firstOf("Catalogue_C")
    local w = widgetOf(cat)
    if not (def and w) then return tell(pc, false, "The host's catalogue is not ready.") end
    local cls = listOf(w, def.list)[index]
    if not UE.valid(cls) then return tell(pc, false, "That is not in the host's catalogue.") end
    local level, need = storeLevel() or 0, unlockLevelOf(cls)
    if level < need then
        stats.refused = stats.refused + 1
        return tell(pc, false, ("That unlocks at store level %d."):format(need))
    end
    local gm = UE.GetGameMode()
    local money = tonumber(UE.TryGet(gm, "Money"))
    if money and money < pennies then
        stats.refused = stats.refused + 1
        return tell(pc, false, "Not enough money.")
    end
    local spawner = UE.TryGet(w, "Spawner Ref")
    if not UE.valid(spawner) then return tell(pc, false, "The host's catalogue is not ready.") end
    local spawnId = tonumber(UE.TryGet(spawner, "Spawn ID Location"))
    -- The card is never read by the handler (@3539): none is made.
    local ok, _, err = asGuest(pc, function() w["Market - Click on Button Product Event"](w, nil, cls, pennies) end)
    if not ok then
        Log.warn("catalogue: a guest's order failed on the host: %s", tostring(err))
        return tell(pc, false, "The order did not go through.")
    end
    -- Boxed, it goes to the next delivery place (@6213), and the charge
    -- follows a tick later, as on the host's own clicks. A VHS player is not
    -- boxed (@7100).
    if spawnId and nameOf(cls) ~= "VHSPlayer_C" and tonumber(UE.TryGet(spawner, "Spawn ID Location")) == spawnId then
        stats.refused = stats.refused + 1
        return tell(pc, false, "There is no room at the delivery spot - clear it and order again.")
    end
    stats.orders = stats.orders + 1
    Log.info("catalogue: %s ordered a %s ($%.2f)", UE.PlayerNameOf(pc) or "a guest",
             nameOf(cls) or "product", pennies / 100)
    tell(pc, true, "Ordered - it is at the delivery spot.")
end

local function station(pc, id, pennies)
    local short = STATIONS[id]
    local m = short and firstOf(short) or nil
    local w = widgetOf(firstOf("Catalogue_C"))
    if not (m and w) then return tell(pc, false, "The host's catalogue is not ready.") end
    local unlocked, bought, price, need = stationState(id, m)
    if bought then return tell(pc, false, "The store already has that.") end
    if not unlocked and (storeLevel() or 0) < need then
        stats.refused = stats.refused + 1
        return tell(pc, false, ("That unlocks at store level %d."):format(need))
    end
    -- The host's own price, whatever the guest's card said.
    pennies = math.floor(price * 100 + 0.5)
    local gm = UE.GetGameMode()
    local money = tonumber(UE.TryGet(gm, "Money"))
    if money and money < pennies then
        stats.refused = stats.refused + 1
        return tell(pc, false, "Not enough money.")
    end
    asGuest(pc, function() w["Countertop - Click on Button Countertop"](w, nil, id, pennies) end)
    if UE.TryGet(m, "Bought") == true then
        stats.orders = stats.orders + 1
        Log.info("catalogue: %s bought the %s", UE.PlayerNameOf(pc) or "a guest", short)
        return tell(pc, true, "Bought - it is ready to use.")
    end
    tell(pc, false, "The purchase did not go through.")
end

local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

local function color(s)
    local r, g, b, a = (s or ""):match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
    if r then return { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) } end
end

--- Host: a guest's new store sign, done the way the sign's own editor does
--- it (Send info to StoreName: Name @217, Set StoreName Visual @267, Color
--- @961, Font @1011, Front Store Light Color @1710).
local function onStoreName(pcName, payload)
    if not UE.IsServer() then return end
    local h, c, fc, sc, ft = payload:match("^(%x*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    local sign = firstOf("StoreName_C")
    if not (h and sign) or #h > 160 then return end
    local name = unhex(h)
    UE.setText(sign, "Name", name)
    if color(c) then UE.TrySet(sign, "Color", color(c)) end
    if color(fc) then UE.TrySet(sign, "Front Store Light Color", color(fc)) end
    if color(sc) then UE.TrySet(sign, "Sign Store Light Color", color(sc)) end
    local font = ft ~= "" and require("worldsync").font(ft) or nil
    if font then UE.TrySet(sign, "Font", font) end
    UE.TryCall(sign, "Set StoreName Visual")
    UE.TryCall(sign, "Update Materials for Lights")
    UE.TryCall(sign, "Update for Lights")
    stats.renamed = stats.renamed + 1
    Log.info("store sign: a guest renamed the store \"%s\"", name)
    for _, pc in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(pc) and pc:GetFullName() == pcName then tell(pc, true, "The store's new sign is up.") end
    end
end

local function placeOrder(o)
    local pc = nil
    for _, c in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(c) and c:GetFullName() == o.pc then pc = c end
    end
    if not pc then return end
    if o.kind == KIND_PRODUCT then
        product(pc, math.floor(o.a / 1000), o.a % 1000, o.pennies)
    elseif o.kind == KIND_STATION then
        station(pc, o.a, o.pennies)
    end
end

--- Host: guest actions 19-21 (guestinput.lua routes them here).
function UIM.onGuest(pc, pawn, what, loc, rot)
    if not UE.IsServer() or not (UE.valid(pc) and loc) then return end
    local x, y, z = round(loc.X), round(loc.Y), round(loc.Z)
    if what == "sidewalkAd" then
        local sign = firstOf("SidewalkSign_C")
        if sign and x >= 1 and x <= 6 and round(UE.TryGet(sign, "Sale Type")) ~= x then
            UE.TryCall(sign, "Set Sale Type", x)
            stats.ads = stats.ads + 1
            lastAt, lastBuild = -1e9, -1e9                -- everyone's sign, now
            Log.info("sidewalk sign: %s put up ad %d", UE.PlayerNameOf(pc) or "a guest", x)
        end
        return
    end
    -- Rooms and orders cost money: each number once.
    local now = os.clock()
    local key = pc:GetFullName() .. "#" .. what .. round(rot and rot.Pitch)
    for k, t in pairs(seen) do if now - t > SEEN_FOR then seen[k] = nil end end
    if seen[key] then return end
    seen[key] = now
    if what == "expansionRoom" then
        Safety.guard(OP_HOST, buyRoom, pc, x)
    elseif what == "catalogueOrder" and #queue < 8 and y > 0 and z >= 0 and z <= MAX_PENNIES then
        queue[#queue + 1] = { pc = pc:GetFullName(), kind = x, a = y, pennies = z }
    end
end

function UIM.tickHost(now)
    if not UE.IsServer() or UE.IsStandalone() then return end
    if Chan.isReady() then sendState(now) end
    -- One order a tick: the widget keeps an order's box, product and price
    -- in its frame until a tick later (DelayUntilNextTick @6316).
    local o = table.remove(queue, 1)
    if o then Safety.guard(OP_HOST, placeOrder, o) end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local host = {}            -- guest: the host's last "uim"
local hooked = {}          -- hook path -> function address
local nextHook = 0
local clicks = {}          -- guest: from the hooks, used from the tick
local pending = nil        -- guest: { what, x, y, z, seq, at, retried }
local seq = 0
local signWant = nil       -- guest: { type, untilT } - our own pick, waiting for the host
local boardPage, boardDirty, boardLevel = 0, true, nil
local cardsDone = {}       -- guest: card address -> what it was drawn from
local roomsSig = nil
local nextCards, nextRooms, nextBoard = 0, 0, 0

local function hook(path, fn)
    local f = StaticFindObject(path)
    local addr = UE.valid(f) and addressOf(f) or nil
    if not addr or hooked[path] == addr then return end
    if pcall(function() RegisterHook(path, fn) end) then hooked[path] = addr end
end

local function hookAll(now)
    if now < nextHook then return end
    nextHook = now + 5
    hook(HOOKS.product, function(_, card, _, pennies)
        if not UE.IsClient() or #clicks >= 8 then return end
        local path, p = nil, nil
        pcall(function() path = UE.pathOf(card:get()) end)
        pcall(function() p = pennies:get() end)
        clicks[#clicks + 1] = { what = "product", card = path, pennies = tonumber(p) or 0 }
    end)
    hook(HOOKS.station, function(_, _, id, pennies)
        if not UE.IsClient() or #clicks >= 8 then return end
        local i, p = nil, nil
        pcall(function() i = id:get() end)
        pcall(function() p = pennies:get() end)
        clicks[#clicks + 1] = { what = "station", id = tonumber(i), pennies = tonumber(p) or 0 }
    end)
    hook(HOOKS.room, function(ctx)
        if not UE.IsClient() or #clicks >= 8 then return end
        local id = nil
        pcall(function() id = tonumber(UE.TryGet(ctx:get(), "Store Expansion ID")) end)
        if id then clicks[#clicks + 1] = { what = "room", id = id } end
    end)
    hook(HOOKS.page, function(_, page)
        if not UE.IsClient() then return end
        local p = nil
        pcall(function() p = page:get() end)
        boardPage, boardDirty = tonumber(p) or 0, true
    end)
end

local function send(o)
    return Chan.sendAction(o.code, { X = o.x, Y = o.y or 0, Z = o.z or 0 }, { Pitch = o.seq or 0, Yaw = 0, Roll = 0 }) > 0
end

local function ask(code, x, y, z, note)
    if pending then
        require("hud").notice("One moment - the last one is still going through.", false, 2)
        return
    end
    seq = (seq % 80) + 1
    pending = { code = code, x = x, y = y, z = z, seq = seq, at = os.clock() }
    send(pending)
    if note then require("hud").notice(note, false, 1.5) end
end

--- Which page and place a catalogue card is on: the card's own box and its
--- index there (the boxes are filled in the lists' order, W@1822).
local function cardPlace(path)
    local card = path and UE.findObject(path) or nil
    if not UE.valid(card) then return nil end
    local parent = nil
    pcall(function() parent = card:GetParent() end)
    local w = widgetOf(firstOf("Catalogue_C"))
    if not (UE.valid(parent) and w) then return nil end
    for page, def in ipairs(PAGES) do
        if UE.sameObject(UE.TryGet(w, def.box), parent) then
            local i = nil
            pcall(function() i = parent:GetChildIndex(card) end)
            if tonumber(i) and i >= 0 then return page, i + 1 end
        end
    end
    return nil
end

local function takeClicks()
    while #clicks > 0 do
        local c = table.remove(clicks, 1)
        if c.what == "product" then
            local page, index = cardPlace(c.card)
            if page and c.pennies > 0 then
                ask(ACTION_ORDER, KIND_PRODUCT, page * 1000 + index, c.pennies, "Ordering...")
            end
        elseif c.what == "station" and c.id and STATIONS[c.id] then
            ask(ACTION_ORDER, KIND_STATION, c.id, c.pennies, "Buying...")
        elseif c.what == "room" then
            ask(ACTION_ROOM, c.id, 0, 0, "Asking the builders...")
        end
    end
    if pending and (os.clock() - pending.at) > RETRY_AFTER then
        if pending.retried then
            pending = nil
            require("hud").notice("The host did not answer - try again.", true, 3)
        else
            pending.retried, pending.at = true, os.clock()
            send(pending)
        end
    end
end

--- The catalogue's cards, drawn from what the guest has: the store's level
--- (the host's, mirrored) for the covers, the guest's own copies of the
--- machines for the stations (bought is the host's, worldsync.lua).
local function drawCards(level)
    local w = widgetOf(firstOf("Catalogue_C"))
    if not w then return end
    for _, def in ipairs(PAGES) do
        local box = UE.TryGet(w, def.box)
        local n = 0
        if UE.valid(box) then pcall(function() n = box:GetChildrenCount() end) end
        for i = 0, (tonumber(n) or 0) - 1 do
            local card = nil
            pcall(function() card = box:GetChildAt(i) end)
            local a = UE.valid(card) and addressOf(card) or nil
            local cls = a and UE.TryGet(card, "Product Class") or nil
            if a and UE.valid(cls) then
                local need = unlockLevelOf(cls)
                local sig = "p" .. need .. "@" .. level
                if cardsDone[a] ~= sig then
                    cardsDone[a] = sig
                    UE.TryCall(card, "Unlock Toggle", level >= need, need)
                    stats.cardsShown = stats.cardsShown + 1
                end
            end
        end
    end
    local list = UE.TryGet(w, "Promotional_WrapBox")
    local n = 0
    if UE.valid(list) then pcall(function() n = list:GetChildrenCount() end) end
    for i = 0, (tonumber(n) or 0) - 1 do
        local card = nil
        pcall(function() card = list:GetChildAt(i) end)
        local a = UE.valid(card) and addressOf(card) or nil
        local id = a and tonumber(UE.TryGet(card, "CounterTop")) or nil
        local m = id and STATIONS[id] and firstOf(STATIONS[id]) or nil
        if m then
            local unlocked, bought, price, need = stationState(id, m)
            local sig = ("s%s%s%d@%d"):format(tostring(unlocked), tostring(bought), need, level)
            if cardsDone[a] ~= sig then
                cardsDone[a] = sig
                UE.TrySet(card, "Value in pennies", math.floor(price * 100 + 0.5))
                -- The card's own Generate Text, as its Construct would call it
                -- (@7914): name, price, level and picture. The picture is the
                -- machine's own soft pointer, handed straight back (measured:
                -- the slushie's picture loads).
                local name, thumb = stationLook(id, m)
                if not (name and thumb and UE.TryCall(card, "Generate Text", name, price, need, thumb)) then
                    local txt = UE.TryGet(card, "Text_Name")
                    if name and UE.valid(txt) then pcall(function() txt:SetText(FText(name)) end) end
                    local priceBox = UE.TryGet(card, "Text_PriceTotal")
                    if UE.valid(priceBox) then
                        local t = priceText(math.floor(price * 100 + 0.5))
                        pcall(function() priceBox:SetText(FText(t)) end)
                    end
                end
                local open = unlocked or level >= need
                UE.TryCall(card, "Unlock Toggle", open, need)
                UE.TryCall(card, "Generate Button", open, bought)
                stats.cardsShown = stats.cardsShown + 1
            end
        end
    end
end

--- The expansion map: the guest's own rooms linked to the guest's own copies
--- of the expansions the host named, then drawn again when one opens.
local function drawRooms()
    local w = widgetOf(firstOf("StoreExpansion_Machine_C"))
    if not w then return end
    local byName = nil
    local unlockedSig = {}
    for _, e in ipairs(UE.findAll("StoreExpansion_C") or {}) do
        if UE.alive(e) then
            unlockedSig[#unlockedSig + 1] = (nameOf(e) or "?") .. (UE.TryGet(e, "Unlocked") == true and "1" or "0")
        end
    end
    table.sort(unlockedSig)
    local sig = table.concat(unlockedSig, ",")
    local again = sig ~= roomsSig
    roomsSig = sig
    for _, field in ipairs(SECTORS) do
        local s = UE.TryGet(w, field)
        local id = UE.valid(s) and tonumber(UE.TryGet(s, "Store Expansion ID")) or nil
        local want = id and host["x" .. id] or nil
        if want then
            local ref = UE.TryGet(s, "Store Expansion Ref")
            if not UE.alive(ref) or nameOf(ref) ~= want then
                if not byName then
                    byName = {}
                    for _, e in ipairs(UE.findAll("StoreExpansion_C") or {}) do
                        local n = UE.alive(e) and nameOf(e) or nil
                        if n then byName[n] = e end
                    end
                end
                local e = byName[want]
                if e and UE.TryCall(s, "Set Reference And Construct", e) then
                    stats.roomsLinked = stats.roomsLinked + 1
                end
            elseif again then
                UE.TryCall(s, "Construct Widget")
            end
        end
    end
end

--- The level board: the cross-mark at the store's level, and the genre
--- post-its still to come, on the page it shows.
local function drawBoard(level)
    if level == boardLevel and not boardDirty then return end
    for _, b in ipairs(UE.findAll("StoreLevel_Machine_C") or {}) do
        if UE.alive(b) then
            UE.TryCall(b, "Set the crossmark location", level, boardPage)
            if boardPage == 0 then UE.TryCall(b, "Update New Movie Genre Postit", level) end
            stats.boards = stats.boards + 1
        end
    end
    boardLevel, boardDirty = level, false
end

--- The sidewalk sign: the host's ad on the guest's sign - and the guest's
--- own pick, made at its own sign, to the host.
local function sign(now)
    local s = firstOf("SidewalkSign_C")
    local want = tonumber(host.ss)
    if not (s and want) then return end
    local mine = round(UE.TryGet(s, "Sale Type"))
    if signWant and (signWant.type == want or now > signWant.untilT) then signWant = nil end
    if mine == want then return end
    if UE.TryGet(s, "In Machine") == true and mine >= 1 and mine <= 6 then
        if not signWant or signWant.type ~= mine then
            signWant = { type = mine, untilT = now + SIGN_WAIT }
            Chan.sendAction(ACTION_SIGN, { X = mine, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        end
        return
    end
    if not signWant then UE.TryCall(s, "Set Sale Type", want) end
end

local editingName, holdUntil, lastHostSign = false, 0, nil

--- The guest's own sign editor: up, the host's sign waits; closed, what it
--- left on the guest's sign goes to the host if it is not the host's.
local function nameSign(now)
    local sign = firstOf("StoreName_C")
    if not sign then return end
    local ui = UE.TryGet(sign, "UI Store")
    local open = false
    if UE.valid(ui) then pcall(function() open = ui:IsInViewport() end) end
    if open then editingName = true return end
    if not editingName then return end
    editingName = false
    local W = require("worldsync")
    local mine, h = W.signFields(sign), lastHostSign or {}
    if mine.n == h.n and mine.c == h.c and mine.fc == h.fc and (mine.ft or ""):lower() == (h.ft or ""):lower() then
        return
    end
    local payload = table.concat({ hex(mine.n or ""), mine.c or "", mine.fc or "", mine.sc or "", mine.ft or "" }, "|")
    if require("character").sendName(NAME_PREFIX, payload) then
        holdUntil = now + NAME_HOLD
        stats.renamed = stats.renamed + 1
        require("hud").notice("Putting up the new sign...", false, 2)
    end
end

--- worldsync.lua: the host's sign, as it last said it.
function UIM.noteHostSign(fields)
    lastHostSign = fields
end

--- worldsync.lua: leave the guest's own sign alone for now?
function UIM.holdSign() return editingName or os.clock() < holdUntil end

function UIM.tickGuest(now)
    if not UE.IsClient() then return end
    hookAll(now)
    takeClicks()
    sign(now)
    nameSign(now)
    local level = storeLevel()
    if level and now >= nextBoard then
        nextBoard = now + 1.0
        drawBoard(level)
    end
    local at = require("guestinput").machineClass()
    if level and now >= nextCards and at == "Catalogue_C" then
        nextCards = now + 0.5
        drawCards(level)
    end
    if next(host) and now >= nextRooms then
        nextRooms = now + 2.0
        drawRooms()
    end
end

local function onState(fields)
    if not UE.IsClient() then return end
    host = fields
end

local function onResult(fields)
    if not UE.IsClient() then return end
    local ok = fields.ok == "1"
    if ok and pending and pending.code == ACTION_ORDER then
        -- The till sound of the guest's own catalogue (the host's played there).
        UE.TryCall(widgetOf(firstOf("Catalogue_C")), "Play Payment Sound")
    end
    pending = nil
    require("hud").notice(fields.t ~= "" and fields.t or (ok and "Done." or "That did not go through."), not ok, 3)
end

function UIM.report()
    return { ("Screen machines: host sent %d, %d order(s), %d room(s), %d ad(s), %d refused, %d store sign(s); " ..
              "guest drew %d card(s), linked %d room(s), set the level board %d time(s)%s"):format(stats.sent,
              stats.orders, stats.rooms, stats.ads, stats.refused, stats.renamed, stats.cardsShown, stats.roomsLinked,
              stats.boards, pending and ", an order waiting" or "") }
end

function UIM.reset()
    queue, seen, host, clicks, pending, signWant = {}, {}, {}, {}, nil, nil
    editingName, holdUntil, lastHostSign = false, 0, nil
    boardDirty, boardLevel, boardPage = true, nil, 0
    cardsDone, roomsSig, lastSig, lastAt, lastBuild = {}, nil, nil, -1e9, -1e9
    hooked = {}
end

function UIM.init()
    require("character").onName(NAME_PREFIX, onStoreName)
    Chan.on("uim", function(f) Log.guard("the host's screen machines", onState, f) end)
    Chan.on("uimres", function(f) Log.guard("a screen machine's answer", onResult, f) end)
end

-- For the tests.
UIM._stats = function() return stats end

return UIM
