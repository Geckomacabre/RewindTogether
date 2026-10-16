--[[
    Rewind Together - the office computer, for guests

    REPORTED (15 Oct 2026): on a guest the office computer's pages showed the
    designer's placeholders - "name of the shop store", "01.20.1990",
    "999,999,999$", an empty market and one dummy new-release card - and
    nothing could be ordered.

    WHY (bp/UI_ScreenComputer_Widget.txt). The screen's Construct casts
    GetGameMode to Core_Gamemode_C (@20848) and stops when that fails - always,
    on a guest - so "As Core Gamemode" is never set, and every page reads
    through it: the desktop (@6498), the second-hand market (guarded @17548),
    the new releases (@10721), the search and the catalogue. Ordering is the
    host's market logic too: money, spawning the tape, quests.

    WHAT THIS DOES
      * The guest asks for the pages when it sits down (guest action 13), and
        the host answers with what its computer would show: the date, the net
        worth, each market movie and bundle, each new release.
      * The guest fills its OWN screen with cards it makes itself and fills
        field by field, in place - a Product_Structure holds two TSets, and a
        whole one built in Lua hangs the game (guestinput.lua). The card's own
        Construct then draws it - box art, name, genre, rating - from those
        fields, exactly as on the host. Only what depends on the release date
        (FDateTime, which UE4SS cannot write) is taken from the host instead:
        the price and the "Old" tag. A new-release card's Construct stops at
        the same GameMode gate, so its drawing code is run from just past it
        (@2022, both kinds).
      * A Buy click on a guest's card becomes an order (guest action 13 with a
        sequence number - that RPC is unreliable and sent twice, and an order
        must never be charged twice). The host runs ITS screen's own handler -
        the money check, the tape at the delivery spot, the charge, the quests,
        the market losing that movie - with a throwaway card carrying the
        price, and answers the guest. Then every guest at a computer gets the
        new pages.

      * The Search page ("Black Market": type a SKU, buy that movie at a
        mark-up). The guest's own search stops at the same gate ("Return
        Research" reads the GameMode) and always says "not found". The guest
        sends the SKU; the host runs the game's own search on a screen of its
        own that is never shown - so the host's Search page keeps what the
        host typed - and answers with the card it made. A Buy runs the host
        screen's own search handler with that card. It is the real search
        card, so a guest's buy can unlock Steam achievement 17 on the host's
        account, as the host's own would (the user's call, 15 Oct 2026).
      * The Data page (every movie of a genre, the ones the store owns first).
        The rows are the game's own: "Generate A Data" reads only the data
        tables and works on a guest. What the GameMode knows comes from the
        host: the genres researched, the copies owned and the times rented.
      * The new releases' standee picture. The card loads the standee class
        its release names by a soft reference (@3763), spawns one and reads
        its thumbnail. That reference does not cross: read through UE4SS it
        names ".../Standees_Collection.Standees_Collection_19759_C" - the
        package's FName lost its number (Standees_Collection_19759), which
        is why no picture would load from it on either machine. Every
        movie standee's thumbnail is T_Standees_Collection_<SKU> (27 of 27
        in the pak), so the guest loads that by name, a plain string the
        engine parses. Video-game banners are not named that way; theirs
        stays hidden rather than a white panel.

    The video-game new releases use the same path as the movies but have not
    been seen live.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local Computer = {}

local ACTION = 13
local KIND = { PAGES = 0, MOVIE = 1, BUNDLE = 2, NEW_MOVIE = 3, NEW_GAME = 4, SEARCH = 5, SEARCH_BUY = 6 }
local OP_HOST  = "the office computer's pages and orders for guests (host)"
local OP_GUEST = "filling the office computer's pages on a guest"

local UI = "/Game/VideoStore/asset/prop/Computer/UI/"
local CLASS = {
    small  = UI .. "UI_Computer_Product-Small.UI_Computer_Product-Small_C",
    bundle = UI .. "UI_Computer_Product-Bundle.UI_Computer_Product-Bundle_C",
    newM   = UI .. "UI_Computer_Product-NewRelease.UI_Computer_Product-NewRelease_C",
    newG   = UI .. "UI_Computer_Product-VideoGame-NewRelease.UI_Computer_Product-VideoGame-NewRelease_C",
    pad    = UI .. "UI_Computer_WrapBoxBottomPadding.UI_Computer_WrapBoxBottomPadding_C",
    sku    = UI .. "UI_Computer_Product-SKU.UI_Computer_Product-SKU_C",
    none   = UI .. "UI_Computer_NoFoundProduct.UI_Computer_NoFoundProduct_C",
    genre  = UI .. "UI_Computer_Data-ButtonSwitcher.UI_Computer_Data-ButtonSwitcher_C",
}
local BUY_EVENT = ":BndEvt__UI_Computer_Product-Small_UI_Computer_ButtonBuy_K2Node_ComponentBoundEvent_0_On Clicked__DelegateSignature"
local GENRE_EVENT = ":BndEvt__UI_Computer_ButtonSwitcher_btn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local SCREEN = "/Game/VideoStore/asset/prop/Computer/UI_ScreenComputer_Widget.UI_ScreenComputer_Widget_C"
-- The search box's Committed (@10716). Computer_Command_SKU_UI's is a
-- developer's free spawner, not this.
local SEARCH_EVENT = "BndEvt__UI_ScreenComputer_Widget_UI_Computer_Command_SKU_K2Node_ComponentBoundEvent_1_Committed__DelegateSignature"
local WIDGETS = "/Script/UMG.Default__WidgetBlueprintLibrary"
local TEXTS = "/Script/Engine.Default__KismetTextLibrary"
-- A movie standee's thumbnail (Market_C "Return Standee based on SKU" names
-- the class Standees_Collection_<SKU>).
local STANDEE_DIR = "/Game/VideoStore/asset/prop/Standees/Thumbnail/"
local STANDEE_THUMB = "T_Standees_Collection_"
local LIB = {
    movie = "/Game/VideoStore/core/blueprint/function/Movie.Default__Movie_C",
    film  = "/Game/VideoStore/core/blueprint/data/Film_Data.Default__Film_Data_C",
    date  = "/Game/VideoStore/core/blueprint/function/Date.Default__Date_C",
    money = "/Game/VideoStore/core/blueprint/text/MoneyToText.Default__MoneyToText_C",
}
local STRINGS = "/Game/VideoStore/localization/interface/Interface.Interface"
-- The draw code just past each new-release card's GameMode gate (@4582 /
-- @4655 "goto L2022" in both dumps).
local NEW_BODY = 2022

-- Field names as the cooked structs carry them (CXXHeaderDump).
local BASE  = "BaseStructure_2_FBB12C464AE570CAFD12ED8506160683"
local BOX   = "BoxData_25_B5A798DA4F509BDCCF4B189171C1DA10"
local GAME  = "GameData_34_BCBD34374FEBA7FBF4BCDAA8AD713241"
local INNER = "Product_20_70BD1F524D92D6CBA577C4A0DBD84A5B"        -- Film/VideoGame_NewRelease
local SKU   = "SKU_26_C5F25F4E49D05A4DEC2DEEAE5AEE5876"
local RARITY = "Rarityoftheprint_21_2CE41A2E4CFBE62E26CA5AA1867213B8"
local NEW = {
    released = "Released_11_B4D9EA814C0A621F73C68C8C69EE27CB",
    second   = "SecondHand-Available_10_F20D589C4B387B17350DDB9BBA3BC9DC",
    base     = "BasePrice_27_EE08E27845CFEDDA1B8663A1450D0FA5",
    midnight = "MidnightRelease_29_635B25514C18E97CC9CF8FAA45C3CEB5",
}
local BUNDLE = {
    price  = "Price_3_9D992E0B47068A11C8DF34B668581079",
    movies = "MovieinBundle_9_B5E078094EB4A75EE8D0D09697FD193C",
    genre  = "SpecificGenre_7_03E982C04EAA94284E0281ABD4C4F0E3",
    rarity = "Rarity_12_496795EE477A1C0ADA9BEFAC5E7A8749",
}
-- One product, in this order: n = number, b = bool, name = FName, str = FString.
local FIELDS = {
    { nil, "CriticReview_11_C12BFEEC478099F229DEE9B4472EF801", "n" },
    { nil, "CustomerReview_12_DC5049F743A3E62D2135E99E35EB1DD6", "n" },
    { nil, RARITY, "n" },
    { nil, "TypeofProduct_28_4CF994D64BC7B26013B4E983386ABC2C", "n" },
    { nil, "AvailableingameDay_31_9E1A4B4040F7BA6592E2478027A378D7", "n" },
}
local DATA_FIELDS = {
    { "ProductName_14_055828B1436E5AD27BFA95AF181099DE", "name" },
    { "SubjectImage_8_2143A5174CF48C9FA1162C88264DCCE8", "str" },
    { "BackgroundImage_10_0F3F7E5F40CFC420FDEBA5BC7C0C3B54", "str" },
    { "SubjectName_15_349EDA35415477D434C88AAB4B5DD9D8", "name" },
    { "SubjectPlacement_28_6052A49B4B97EAAD54799EBB4CCEE0F8", "n" },
    { "LayoutStyle_24_CC983F9348517FFCA950D69DCB2466FE", "n" },
    { "LayoutStyleColor_31_C0B0026748206466AEE27892EF5CFC5F", "n" },
    { "ColorPalette_34_17384983427AD81F2FFF43B4DD141E18", "n" },
    { SKU, "n" },
    { "NewToUnlock_38_BA70B2EB4DC856BEBF7A62867B16B108", "b" },
}
for _, f in ipairs(DATA_FIELDS) do
    FIELDS[#FIELDS + 1] = { BOX, f[1], f[2] }
    FIELDS[#FIELDS + 1] = { GAME, f[1], f[2] }
end
FIELDS[#FIELDS + 1] = { BOX,  "Genre_27_8F38DC364314469FC08A2AB858AC3CF8", "n" }
FIELDS[#FIELDS + 1] = { GAME, "Genre_39_8F38DC364314469FC08A2AB858AC3CF8", "n" }
FIELDS[#FIELDS + 1] = { GAME, "ForceMidnightRelease_42_43B715494C1EAC50636C6AB6C0A6CB44", "b" }
FIELDS[#FIELDS + 1] = { GAME, "ColorCartridgeHolo_46_BFAE8900401A1796312A22A78236D572", "n" }
local AT = {}              -- where a field sits in a line
for i, f in ipairs(FIELDS) do AT[(f[1] or "") .. "." .. f[2]] = i end
local AT_SKU, AT_RARITY = AT[BOX .. "." .. SKU], AT["." .. RARITY]

local SEP = "\t"
local MAX_ITEMS = 40          -- per page, per message
local MAX_COUNTS = 1500       -- owned / rented SKUs, per message
local ROWS_PER_TICK = 10      -- guest: Data rows made in one tick (the game's own pace is similar)
local MAX_ROWS = 3000         -- guest: a genre's rows, at most
local REQUEST_EVERY = 30.0    -- guest: ask again this often while seated
local RETRY_AFTER = 4.0       -- guest: an order not answered by then goes again, once
local SEEN_FOR = 10.0         -- host: an order number from a guest, remembered

local cfg = nil
local stats = { sent = 0, orders = 0, bought = 0, refused = 0, filled = 0, clicks = 0,
                searches = 0, found = 0, rows = 0, standees = 0 }

--------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------

local function static(path)
    local o = StaticFindObject(path)
    if UE.valid(o) then return o end
    return nil
end

--- The office computer's screen widget on this machine, or nil.
local function screen()
    local cs = UE.findFirst("ComputerScreen_C")
    if not UE.alive(cs) then return nil end
    local wc = UE.TryGet(cs, "Widget")
    if not UE.valid(wc) then return nil end
    local w = nil
    pcall(function() w = wc:GetUserWidgetObject() end)
    if UE.valid(w) then return w end
    return nil
end

local function field(s, name)
    if s == nil then return nil end
    local v = nil
    pcall(function() v = s[name] end)
    return v
end

local function split(s)
    local out = {}
    for part in (s .. SEP):gmatch("(.-)" .. SEP) do out[#out + 1] = part end
    return out
end

--- Call a static Blueprint library function whose results are out-parameters.
--- Returns them by name. MEASURED: UE4SS wants an argument for every
--- out-parameter, and puts ALL of them into the first table it is given, by
--- name (Format Date in RR: Season, Year, Day, Date Format Text, Day and
--- Season - all in the first; Movie_C: { ["Value in Pennies"] = 1800 }).
local function call(libPath, fn, nOut, ...)
    local lib = static(libPath)
    if not lib then return nil end
    local outs = {}
    for i = 1, nOut do outs[i] = {} end
    local args = { ... }
    args[#args + 1] = UE.GetWorld()
    for i = 1, nOut do args[#args + 1] = outs[i] end
    local ok = pcall(function() lib[fn](lib, table.unpack(args)) end)
    local values = {}
    for i = 1, nOut do
        for k, v in pairs(outs[i]) do values[k] = v end
        UE.releaseOut(outs[i])
    end
    if not ok then return nil end
    return values
end

local function textOf(v)
    if type(v) == "string" then return v end
    local s = nil
    pcall(function() s = v:ToString() end)
    return type(s) == "string" and s or nil
end

--------------------------------------------------------------------------
-- Host: what its computer shows
--------------------------------------------------------------------------

local function market()
    local m = UE.findFirst("Market_C")
    if UE.alive(m) then return m end
    return nil
end

--- One Product_Structure as a line: FIELDS, in order.
local function readProduct(p)
    local base = field(p, BASE)
    if base == nil then return nil end
    local parts = {}
    for _, f in ipairs(FIELDS) do
        local holder = f[1] and field(base, f[1]) or base
        local v = field(holder, f[2])
        local s
        if f[3] == "name" or f[3] == "str" then s = textOf(v) or ""
        elseif f[3] == "b" then s = (v == true) and "1" or "0"
        else s = tostring(tonumber(v) or 0) end
        parts[#parts + 1] = (s:gsub(SEP, " "))
    end
    return table.concat(parts, SEP)
end

local function skuOf(p)
    local base = field(p, BASE)
    local sku = field(field(base, BOX), SKU)
    if tonumber(sku) and sku ~= 0 then return sku end
    return tonumber(field(field(base, GAME), SKU)) or 0
end

local function moviePrice(p)
    local v = call(LIB.movie, "Generate Value in Pennies of Movie", 1, p)
    return v and tonumber(v["Value in Pennies"]) or nil
end

local function isOld(p)
    local v = call(LIB.film, "Return if Film if Old", 1, p)
    return v and v["is Old"] == true
end

local function perUnit(units, basePrice)
    local v = call(LIB.movie, "Generate Value in Pennies of Movies per unit", 1, units, basePrice)
    return v and tonumber(v["Value in Pennies"]) or nil
end

--- Each entry of a TArray property, as the engine's own wrapper.
local function eachOf(arr, fn)
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    for i = 1, n do
        local e = nil
        pcall(function() e = arr[i] end)
        if e ~= nil then
            pcall(function() if e.type and e:type() == "RemoteUnrealParam" then e = e:get() end end)
            if fn(i, e) == false then break end
        end
    end
end

--- Each released, not yet second-hand new release (the screen's own filter, @3333).
local function eachNew(m, mapName, fn)
    local map = field(m, mapName)
    if map == nil then return end
    pcall(function()
        map:ForEach(function(k, v)
            local key, val = k, v
            pcall(function() key = k:get() end)
            pcall(function() val = v:get() end)
            if field(val, NEW.released) == true and field(val, NEW.second) ~= true then
                fn(tonumber(key) or 0, val)
            end
        end)
    end)
end

local function deskPayload(w)
    local out = {}
    local weather = UE.findFirst("WeatherSystem_C")
    if UE.alive(weather) then
        local v = call(LIB.date, "Format Date in RR", 5, field(weather, "Current Date"))
        -- The one the screen shows (@6655).
        if v and v["Day and Season"] then out.d = textOf(v["Day and Season"]) end
    end
    if w then
        local nw = {}
        local ok = pcall(function() w["Return Net Worth of Store"](w, nw) end)
        if ok and tonumber(nw["Net Worth"]) then out.w = tostring(tonumber(nw["Net Worth"])) end
        UE.releaseOut(nw)
    end
    local m = market()
    if m then
        local a, b, c = {}, {}, {}
        pcall(function() m["Return if a new Movie release today"](m, a) end)
        pcall(function() m["Return if a new Video Game release today"](m, b, c) end)
        local fresh = a["New Release is releasing today"] == true
                   or b["New Video Game Release is releasing today"] == true
        UE.releaseOut(a) UE.releaseOut(b) UE.releaseOut(c)
        out.r = fresh and "1" or "0"
    end
    return out
end

local function marketPayload()
    local m = market()
    if not m then return nil end
    local out = { n = "0", b = "0" }
    local n = 0
    eachOf(field(m, "Marketplace Movie of the Day"), function(_, e)
        if n >= MAX_ITEMS then return false end
        local line = readProduct(e)
        local price = moviePrice(e)
        if line and price then
            n = n + 1
            out["m" .. n] = table.concat({ tostring(price), isOld(e) and "1" or "0", line }, SEP)
        end
    end)
    out.n = tostring(n)
    local nb = 0
    eachOf(field(m, "Marketplace Movie Bundles of the Day"), function(i, b)
        if nb >= MAX_ITEMS then return false end
        local count = 0
        pcall(function() count = field(b, BUNDLE.movies):GetArrayNum() end)
        nb = nb + 1
        out["b" .. nb] = table.concat({ tostring(i), tostring(tonumber(field(b, BUNDLE.price)) or 0),
            tostring(tonumber(field(b, BUNDLE.genre)) or 0), tostring(tonumber(field(b, BUNDLE.rarity)) or 0),
            tostring(count) }, SEP)
    end)
    out.b = tostring(nb)
    return out
end

local function newPayload()
    local m = market()
    if not m then return nil end
    local out = {}
    local n = 0
    for kind, mapName in pairs({ m = "NewRelease Movies SKU", g = "NewRelease Video Game SKU" }) do
        eachNew(m, mapName, function(key, val)
            if n >= MAX_ITEMS then return end
            local p = field(val, INNER)
            local line = readProduct(p)
            if not line then return end
            -- (Product by reference, context, is New, Day Left)
            local days = call(LIB.film, "Return if Film is New", 2, p)
            local left = days and tonumber(days["is New Day Left"]) or 0
            n = n + 1
            out["e" .. n] = table.concat({ kind, tostring(key), tostring(tonumber(field(val, NEW.base)) or 0),
                tostring(left), field(val, NEW.midnight) == true and "1" or "0", line }, SEP)
        end)
    end
    out.n = tostring(n)
    return out
end

local function gatherer()
    local gm = UE.GetGameMode()
    if not (UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C") then return nil end
    local g = UE.TryGet(gm, "Actor Gatherer")
    if UE.valid(g) then return g end
    return nil
end

--- A TMap<int, int> as "key:value,key:value".
local function countsOf(map)
    local parts = {}
    if map == nil then return "" end
    pcall(function()
        map:ForEach(function(k, v)
            if #parts >= MAX_COUNTS then return end
            local key, val = k, v
            pcall(function() key = k:get() end)
            pcall(function() val = v:get() end)
            key, val = tonumber(key), tonumber(val)
            if key and val then parts[#parts + 1] = ("%d:%d"):format(key, val) end
        end)
    end)
    return table.concat(parts, ",")
end

--- What the Data page reads through the GameMode: the genres researched, in
--- the order the screen lists them (+ Adult, @398), the copies the store owns
--- (which rows come first) and how often each was rented.
local function dataPayload()
    local g = gatherer()
    if not g then return nil end
    local genres, have = {}, {}
    local research = UE.TryGet(g, "Research System")
    if UE.valid(research) then
        eachOf(UE.TryGet(research, "Movie Genres Unlock"), function(_, e)
            local n = tonumber(e)
            if n and not have[n] then have[n] = true genres[#genres + 1] = tostring(n) end
        end)
        if UE.TryGet(research, "Adult Genre Request Enable") == true and not have[16] then genres[#genres + 1] = "16" end
    end
    local rent = UE.TryGet(g, "RentSystem")
    return { g = table.concat(genres, ","), o = countsOf(UE.TryGet(g, "Cartridge SKU Count Map")),
             r = UE.valid(rent) and countsOf(UE.TryGet(rent, "Cartridge SKU Times Rented")) or "" }
end

local function sendPages(pc)
    local w = screen()
    local ok = 0
    for msgType, payload in pairs({ cdesk = deskPayload(w), cmkt = marketPayload(), cnew = newPayload(),
                                    cdata = dataPayload() }) do
        if payload and Chan.sendTo(pc, msgType, payload) then ok = ok + 1 end
    end
    if ok > 0 then stats.sent = stats.sent + 1 end
end

--------------------------------------------------------------------------
-- Host: a guest's order
--------------------------------------------------------------------------

local seen = {}             -- pc full name .. "#" .. order number -> when
local asked = {}            -- pc full name -> when it last asked for the pages

local function money()
    local gm = UE.GetGameMode()
    if not (UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C") then return nil end
    return tonumber(UE.TryGet(gm, "Money"))
end

local function reply(pc, ok, text)
    Chan.sendTo(pc, "cres", { ok = ok and "1" or "0", t = text or "" })
    if ok then stats.bought = stats.bought + 1 else stats.refused = stats.refused + 1 end
end

--- A card for the host's handler to read the price from. Never shown; the
--- handler removes it from a parent it never had.
local function throwaway(w, cls, price, units)
    local lib, c = static(WIDGETS), static(cls)
    if not (lib and c) then return nil end
    local card = nil
    pcall(function() card = lib:Create(w, c, UE.GetPlayerController()) end)
    if not UE.valid(card) then return nil end
    UE.TrySet(card, "Value in pennies", price)
    if units then
        UE.TrySet(card, "Number Of Unit", units)
        UE.TrySet(card, "Total in pennies", price * units)
    end
    return card
end

--- The game's own search for one SKU, run on a screen of our own that is never
--- shown: the host's Search page keeps what the host typed there. Returns the
--- UI_Computer_Product-SKU card the search made, false for "no such movie",
--- nil when it could not run.
local function searchCard(w, sku)
    local lib, cls = static(WIDGETS), static(SCREEN)
    if not (lib and cls and sku > 0) then return nil end
    local probe = nil
    pcall(function() probe = lib:Create(w, cls, UE.GetPlayerController()) end)
    if not UE.valid(probe) then return nil end
    if not pcall(function() probe[SEARCH_EVENT](probe, sku) end) then return nil end
    local box = UE.TryGet(probe, "Search_WrapBox")
    local card = nil
    pcall(function() card = box:GetChildAt(0) end)
    if UE.valid(card) and UE.ClassNameOf(card) == "UI_Computer_Product-SKU_C" then return card end
    return false
end

--- What the card would show: its own price (the movie's, x1.2 for a genre
--- researched, x3.5 for one not, + $5 - UI_Computer_Product-SKU). Its
--- Construct never ran, never having been shown.
local function skuPrice(card)
    local out = {}
    local ok = pcall(function() card["Generate Value in Pennies"](card, UE.TryGet(card, "Product"), out) end)
    local v = tonumber(out.Value)
    UE.releaseOut(out)
    if ok and v and v > 0 then return v end
    return nil
end

--- Host: a guest searched for a SKU.
local function answerSearch(pc, sku, q)
    local w = screen()
    local card = w and searchCard(w, sku)
    local answer = { s = tostring(sku), q = tostring(q), f = "x" }
    if card == false then
        answer.f = "0"
    elseif card then
        local p = UE.TryGet(card, "Product")
        local line, price = readProduct(p), skuPrice(card)
        if line and price then
            answer.f, answer.l, answer.p = "1", line, tostring(price)
            answer.u = UE.TryGet(card, "Do the Player has Unlock the Genre?") == true and "1" or "0"
            answer.o = isOld(p) and "1" or "0"
            stats.found = stats.found + 1
        end
    end
    Chan.sendTo(pc, "csku", answer)
end

local function order(pc, kind, a, b)
    local w, m = screen(), market()
    if not (w and m) then return reply(pc, false, "The office computer is not ready on the host.") end
    local before = money()
    if not before then return reply(pc, false, "The host's store is not ready.") end

    local price, ran = nil, false
    if kind == KIND.MOVIE then
        local want, rarity = math.floor(a + 0.5), math.floor(b + 0.5)
        local found = nil
        eachOf(field(m, "Marketplace Movie of the Day"), function(_, e)
            if skuOf(e) == want and tonumber(field(field(e, BASE), RARITY)) == rarity then found = e return false end
        end)
        if not found then return reply(pc, false, "Somebody already bought that one.") end
        price = moviePrice(found)
        if not price then return reply(pc, false, "The host could not price that movie.") end
        if before < price then return reply(pc, false, "Not enough money in the store.") end
        local card = throwaway(w, CLASS.small, price)
        if card then ran = pcall(function() w["Market - Click on Button Product Event"](w, card, found) end) end
    elseif kind == KIND.BUNDLE then
        local index, want = math.floor(a + 0.5), math.floor(b + 0.5)
        local found = nil
        eachOf(field(m, "Marketplace Movie Bundles of the Day"), function(i, e)
            if i == index and tonumber(field(e, BUNDLE.price)) == want then found = e return false end
        end)
        if not found then return reply(pc, false, "Somebody already bought that bundle.") end
        price = want
        if before < price then return reply(pc, false, "Not enough money in the store.") end
        local card = throwaway(w, CLASS.bundle, price)
        if card then ran = pcall(function() w["Market - Click on Button Bundle Movie Event"](w, card, found) end) end
    elseif kind == KIND.NEW_MOVIE or kind == KIND.NEW_GAME then
        local key, units = math.floor(a + 0.5), math.max(1, math.floor(b + 0.5))
        local mapName = kind == KIND.NEW_MOVIE and "NewRelease Movies SKU" or "NewRelease Video Game SKU"
        local found = nil
        eachNew(m, mapName, function(k, val) if k == key then found = val end end)
        if not found then return reply(pc, false, "That release is not on sale any more.") end
        local unit = perUnit(units, tonumber(field(found, NEW.base)) or 0)
        if not unit then return reply(pc, false, "The host could not price that order.") end
        price = unit * units
        if before < price then return reply(pc, false, "Not enough money in the store.") end
        local cls = kind == KIND.NEW_MOVIE and CLASS.newM or CLASS.newG
        local fn = kind == KIND.NEW_MOVIE and "New Release Movie - Product Click on Button Buy Even"
                                           or "New Release Video Game - Product Click on Button Buy Event"
        local card = throwaway(w, cls, unit, units)
        if card then ran = pcall(function() w[fn](w, card, found) end) end
    elseif kind == KIND.SEARCH_BUY then
        -- The search's own card: its Product is the whole movie (tags too),
        -- and its class is what the achievement checks (@10306).
        local card = searchCard(w, math.floor(a + 0.5))
        if not card then return reply(pc, false, "The host's computer cannot find that movie.") end
        price = skuPrice(card)
        if not price then return reply(pc, false, "The host could not price that movie.") end
        if before < price then return reply(pc, false, "Not enough money in the store.") end
        UE.TrySet(card, "Value in pennies", price)
        ran = pcall(function() w["Search - Clicked on a Product Event"](w, card, UE.TryGet(card, "Product")) end)
    else
        return
    end

    local after = money()
    -- The host's own screen, if it is on that page, would still offer it.
    local page = tonumber(UE.TryGet(w, "Current Widget Switcher"))
    if page == 2 then pcall(function() w["Generate Market Page"](w) end)
    elseif page == 3 then pcall(function() w["Generate New Released Page"](w) end) end
    if ran and after and after < before then
        Log.info("office computer: a guest ordered for %d (store money %d -> %d)", price, before, after)
        reply(pc, true, "Ordered. It is on its way to the store.")
    else
        -- The handler's own reasons go to the host's screen (no room at the
        -- delivery spot, mostly). Say what can be said here.
        reply(pc, false, "The order did not go through - is the delivery spot blocked?")
    end
end

--- Host: guest action 13. loc.X = what (KIND), loc.Y / loc.Z = which; rot.Pitch
--- = the order's number (ServerSetSpectatorLocation is unreliable and the
--- guest may send an order twice).
function Computer.onGuest(pc, loc, rot)
    if not UE.IsServer() or (cfg and cfg.GuestOfficeComputer == false) then return end
    if not (UE.valid(pc) and loc) then return end
    local kind = math.floor((loc.X or 0) + 0.5)
    if kind == KIND.PAGES then
        asked[pc:GetFullName()] = os.clock()
        Safety.guard(OP_HOST, sendPages, pc)
        return
    end
    local now = os.clock()
    local q = math.floor(((rot and rot.Pitch) or 0) + 0.5)
    local key = pc:GetFullName() .. "#" .. q
    for k, t in pairs(seen) do if now - t > SEEN_FOR then seen[k] = nil end end
    if seen[key] then return end
    seen[key] = now
    asked[pc:GetFullName()] = now      -- whoever orders is at a computer
    if kind == KIND.SEARCH then
        stats.searches = stats.searches + 1
        Safety.guard(OP_HOST, answerSearch, pc, math.floor((loc.Y or 0) + 0.5), q)
        return
    end
    stats.orders = stats.orders + 1
    Safety.guard(OP_HOST, order, pc, kind, loc.Y or 0, loc.Z or 0)
    -- Everyone at a computer now sees the market without it (a seated guest
    -- asks every REQUEST_EVERY seconds).
    for _, other in ipairs(UE.GetAllPlayerControllers() or {}) do
        if UE.alive(other) and not UE.IsLocalController(other)
                and now - (asked[other:GetFullName()] or -1e9) < REQUEST_EVERY * 2 then
            Safety.guard(OP_HOST, sendPages, other)
        end
    end
end

--------------------------------------------------------------------------
-- Guest: the pages
--------------------------------------------------------------------------

local pages = { desk = nil, mkt = nil, new = nil, data = nil, sku = nil }  -- the host's last answer, by page
local dirty = { desk = false, mkt = false, new = false, sku = false }
-- Card address -> { kind, a, b }, one table per page: the pages arrive as
-- separate messages, often in different ticks, and MEASURED - one shared
-- table, emptied for every rebuild, lost the market's cards whenever the new
-- releases came in after them, and their Buy did nothing.
local ours = { mkt = {}, new = {}, sku = {} }
local function ourCard(a) return a and (ours.mkt[a] or ours.new[a] or ours.sku[a]) or nil end
local genreButtons = {}    -- address of a genre button we made -> its genre
local genresAgain = false  -- the guest's own Generate Data Movie Genre Button ran (and found none)
local genreClicked = nil   -- address of the genre button pressed
local rowsJob = nil        -- { genre, id, owned, rented }: the Data rows still to make
local searchWant = nil     -- the SKU the guest just searched for
local searchAsk = nil      -- { sku, q, at, retried }: waiting for the host's answer
local shownSig = {}         -- page -> the payload it was last drawn from
local seatedAt = nil       -- os.clock() of the last request while seated
local wasSeated = false
local deskAgain = false    -- the guest's own Generate Desktop ran (and blanked it)
local clicked = {}         -- { a = card address, units = n } whose Buy was pressed
local pending = nil        -- { kind, a, b, seq, at, retried }
local seq = 0
local hooks = {}
local nextHook = 0

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

--- Write one line from readProduct into a Product_Structure, in place.
local function writeProduct(p, line)
    local base = field(p, BASE)
    if base == nil then return false end
    local vals = split(line)
    for i, f in ipairs(FIELDS) do
        local s = vals[i]
        if s ~= nil then
            local holder = f[1] and field(base, f[1]) or base
            if holder ~= nil then
                pcall(function()
                    if f[3] == "name" then holder[f[2]] = FName(s)
                    elseif f[3] == "str" then holder[f[2]] = s
                    elseif f[3] == "b" then holder[f[2]] = (s == "1")
                    else holder[f[2]] = tonumber(s) or 0 end
                end)
            end
        end
    end
    return true
end

local function makeCard(w, clsPath)
    local lib, cls = static(WIDGETS), static(clsPath)
    if not (lib and cls) then return nil end
    local card = nil
    pcall(function() card = lib:Create(w, cls, UE.GetPlayerController()) end)
    if UE.valid(card) then return card end
    return nil
end

local function setText(block, s)
    if not (UE.valid(block) and s) then return end
    pcall(function() block:SetText(FText(s)) end)
end

--- A line from the game's own string table, in the guest's language.
local function stringTable(key)
    local lib = static(TEXTS)
    if not lib then return nil end
    local t = nil
    pcall(function() t = lib:TextFromStringTable(FName(STRINGS), key) end)
    return textOf(t)
end

local function pennies(v, rounded)
    local r = call(LIB.money, "Format Pennies to Text", 2, tonumber(v) or 0)
    if not r then return nil end
    return textOf(r[rounded and "Format Text Round to Dollar" or "Format Text"])
end

local function fillDesk(w)
    local d = pages.desk
    if not d then return end
    setText(UE.TryGet(w, "txt_desktop_date"), d.d)
    if d.w then setText(UE.TryGet(w, "txt_NetWorth"), pennies(d.w, true)) end
    local sign = UE.findFirst("StoreName_C")
    if UE.alive(sign) then setText(UE.TryGet(w, "TextBlock_StoreName"), textOf(UE.TryGet(sign, "Name"))) end
    local tab = UE.TryGet(w, "UI_Computer_ButtonSwitcher_New")
    if UE.valid(tab) then pcall(function() tab["Toggle Notification"](tab, d.r == "1") end) end
end

local function fillMarket(w)
    local d = pages.mkt
    local box = UE.TryGet(w, "Market_WrapBox")
    if not (d and UE.valid(box)) then return end
    pcall(function() box:ClearChildren() end)
    for i = 1, tonumber(d.b) or 0 do
        local v = split(d["b" .. i] or "")
        local card = makeCard(w, CLASS.bundle)
        if card and #v >= 5 then
            local bp = UE.TryGet(card, "Bundle Product")
            pcall(function()
                bp[BUNDLE.price] = tonumber(v[2]) or 0
                bp[BUNDLE.genre] = tonumber(v[3]) or 0
                bp[BUNDLE.rarity] = tonumber(v[4]) or 0
            end)
            pcall(function() box:AddChild(card) end)
            -- Its title counts the movies in it (@10), an array not copied here.
            local desc = stringTable("Interface_Computer_Product_Bundle_Desc")
            if desc then setText(UE.TryGet(card, "Text_Name"), (desc:gsub("{int}", v[5]))) end
            ours.mkt[addressOf(card) or 0] = { kind = KIND.BUNDLE, a = tonumber(v[1]), b = tonumber(v[2]) }
        end
    end
    for i = 1, tonumber(d.n) or 0 do
        local line = d["m" .. i]
        local card = line and makeCard(w, CLASS.small)
        if card then
            local price, old = line:match("^([^\t]*)\t([^\t]*)\t")
            local rest = line:gsub("^[^\t]*\t[^\t]*\t", "")
            writeProduct(UE.TryGet(card, "Product"), rest)
            pcall(function() box:AddChild(card) end)
            -- What the release date decides, from the host (see the top).
            UE.TrySet(card, "Value in pennies", tonumber(price) or 0)
            setText(UE.TryGet(card, "Text_Price"), pennies(price, false))
            local tag = UE.TryGet(card, "UI_Computer_ProductTag_Old")
            if UE.valid(tag) then pcall(function() tag:SetVisibility(old == "1" and 0 or 1) end) end
            local vals = split(rest)
            ours.mkt[addressOf(card) or 0] = { kind = KIND.MOVIE, a = tonumber(vals[AT_SKU]) or 0,
                                           b = tonumber(vals[AT_RARITY]) or 0 }
        end
    end
    local pad = makeCard(w, CLASS.pad)
    if pad then pcall(function() box:AddChild(pad) end) end
end

--- The path of a movie standee's thumbnail (see the top), or nil.
local function standeePath(isMovie, sku)
    sku = tonumber(sku)
    if not (isMovie and sku and sku > 0) then return nil end
    local name = STANDEE_THUMB .. math.floor(sku)
    return STANDEE_DIR .. name .. "." .. name
end

--- The free standee's picture on a guest's new-release card; hidden when
--- there is none to load, rather than the white panel the image otherwise is.
local function showStandee(card, isMovie, sku)
    local img = UE.TryGet(card, "Image_Standee")
    if not UE.valid(img) then return end
    local path = standeePath(isMovie, sku)
    local tex = nil
    if path then
        -- UE4SS's own loader takes the path as a string; ue.lua's goes
        -- through a soft reference.
        if type(LoadAsset) == "function" then pcall(function() tex = LoadAsset(path) end) end
        if not UE.valid(tex) then tex = UE.load(path) end
    end
    if UE.valid(tex) then
        pcall(function() img:SetBrushFromTexture(tex, false) end)
        stats.standees = stats.standees + 1
    else
        pcall(function() img:SetVisibility(2) end)
    end
end

local function fillNew(w)
    local d = pages.new
    local box = UE.TryGet(w, "New_WrapBox")
    if not (d and UE.valid(box)) then return end
    -- Also takes away the designer's dummy card (UI_Computer_Product-NewRelease_112).
    pcall(function() box:ClearChildren() end)
    local template = stringTable("Interface_Computer_NewRelease_DayLeft")
    local lastDay = stringTable("Interface_Computer_NewRelease_LastDay")
    for i = 1, tonumber(d.n) or 0 do
        local v = split(d["e" .. i] or "")
        local isMovie = v[1] == "m"
        local card = #v > 5 and makeCard(w, isMovie and CLASS.newM or CLASS.newG)
        if card then
            local prod = UE.TryGet(card, "Product")
            writeProduct(field(prod, INNER), table.concat(v, SEP, 6))
            pcall(function()
                prod[NEW.base] = tonumber(v[3]) or 0
                prod[NEW.released] = true
                if not isMovie then prod[NEW.midnight] = (v[5] == "1") end
            end)
            pcall(function() box:AddChild(card) end)
            -- Its Construct stopped at the GameMode gate; the rest draws it.
            local fn = isMovie and "ExecuteUbergraph_UI_Computer_Product-NewRelease"
                                or "ExecuteUbergraph_UI_Computer_Product-VideoGame-NewRelease"
            pcall(function() card[fn](card, NEW_BODY) end)
            showStandee(card, isMovie, v[5 + AT_SKU])
            local left = tonumber(v[4]) or 0
            local text = (left <= 0) and lastDay or (template and template:gsub("{int}", "<number>" .. left .. "</>"))
            setText(UE.TryGet(card, "Text_DayLeft"), text)
            ours.new[addressOf(card) or 0] = { kind = isMovie and KIND.NEW_MOVIE or KIND.NEW_GAME, a = tonumber(v[2]) or 0 }
        end
    end
end

--- The Search page: the host's answer for the SKU the guest typed.
local function fillSearch(w)
    local d = pages.sku
    local box = UE.TryGet(w, "Search_WrapBox")
    if not (d and UE.valid(box)) then return end
    pcall(function() box:ClearChildren() end)
    if d.f == "1" and d.l then
        local card = makeCard(w, CLASS.sku)
        if card then
            UE.TrySet(card, "Do the Player has Unlock the Genre?", d.u == "1")
            writeProduct(UE.TryGet(card, "Product"), d.l)
            pcall(function() box:AddChild(card) end)
            UE.TrySet(card, "Value in pennies", tonumber(d.p) or 0)
            setText(UE.TryGet(card, "Text_Price"), pennies(d.p, false))
            local tag = UE.TryGet(card, "UI_Computer_ProductTag_Old")
            if UE.valid(tag) then pcall(function() tag:SetVisibility(d.o == "1" and 0 or 1) end) end
            ours.sku[addressOf(card) or 0] = { kind = KIND.SEARCH_BUY, a = tonumber(d.s) or 0, b = tonumber(d.p) or 0 }
            return
        end
    end
    local none = makeCard(w, CLASS.none)
    if none then pcall(function() box:AddChild(none) end) end
end

--- "k:v,k:v" -> { [k] = v }
local function countsFrom(s)
    local t = {}
    for k, v in (s or ""):gmatch("(%d+):(%d+)") do t[tonumber(k)] = tonumber(v) end
    return t
end

--- The Data page's genre buttons, as the host's screen lists them (its own
--- Generate Data Movie Genre Button stops at the GameMode).
local function fillGenres(w)
    local box = UE.TryGet(w, "WrapBox_Data-Genre")
    if not (pages.data and UE.valid(box)) then return end
    pcall(function() box:ClearChildren() end)
    genreButtons = {}
    for g in (pages.data.g or ""):gmatch("%d+") do
        local b = makeCard(w, CLASS.genre)
        if b then
            UE.TrySet(b, "Genre", tonumber(g))
            pcall(function() box:AddChild(b) end)
            genreButtons[addressOf(b) or 0] = tonumber(g)
        end
    end
end

--- A genre button was pressed: the screen's own click handler lights it and
--- empties the lists (Generate Data Page of Genre, up to its GameMode gate);
--- the rows follow, a few per tick.
local function openGenre(w, addr)
    local box = UE.TryGet(w, "WrapBox_Data-Genre")
    local n = 0
    pcall(function() n = box:GetChildrenCount() end)
    for i = 0, n - 1 do
        local b = nil
        pcall(function() b = box:GetChildAt(i) end)
        if UE.valid(b) and addressOf(b) == addr then
            pcall(function() w["Button Movie Genre Data - Click Event"](w, b) end)
            rowsJob = { genre = genreButtons[addr], id = 0,
                        owned = countsFrom(pages.data and pages.data.o), rented = countsFrom(pages.data and pages.data.r) }
            return
        end
    end
end

--- The next few rows of the open genre: the game's own "Generate A Data"
--- (data tables only, so it works here), owned ones first, as on the host
--- (@308: the "Cartridge SKU Count Map").
local function moreRows(w)
    local j = rowsJob
    local owned, other = UE.TryGet(w, "VerticalBox_Data-Owned"), UE.TryGet(w, "VerticalBox_Data-Non-Owned")
    if not (UE.valid(owned) and UE.valid(other)) then rowsJob = nil return end
    for _ = 1, ROWS_PER_TICK do
        local row = nil
        pcall(function() row = w["Generate A Data"](w, j.id, j.genre) end)
        if not UE.valid(row) or j.id >= MAX_ROWS then rowsJob = nil return end
        j.id = j.id + 1
        local sku = tonumber(field(field(field(UE.TryGet(row, "Product Struct"), BASE), BOX), SKU)) or 0
        local copies = j.owned[sku]
        pcall(function() (copies and owned or other):AddChild(row) end)
        -- Its own Set copies / Set Times Rented stop at the GameMode and
        -- leave these alone.
        UE.TrySet(row, "Number of copies", copies or 0)
        setText(UE.TryGet(row, "txt_copies"), tostring(copies or 0))
        setText(UE.TryGet(row, "txt_Rented"), tostring(j.rented[sku] or 0))
        if not copies then pcall(function() row["Set Disable"](row) end) end
        stats.rows = stats.rows + 1
    end
end

local function fillAll()
    local w = screen()
    if not w then return end
    if dirty.mkt then ours.mkt = {} end
    if dirty.new then ours.new = {} end
    if dirty.sku then ours.sku = {} end
    if dirty.desk or deskAgain then fillDesk(w) end
    if dirty.mkt then fillMarket(w) end
    if dirty.new then fillNew(w) end
    if dirty.sku then fillSearch(w) end
    dirty.desk, dirty.mkt, dirty.new, dirty.sku, deskAgain = false, false, false, false, false
    stats.filled = stats.filled + 1
end

local function dataPage()
    local w = screen()
    if not w then rowsJob = nil return end
    if genresAgain and pages.data then
        genresAgain = false
        fillGenres(w)
    end
    if genreClicked then
        local addr = genreClicked
        genreClicked = nil
        openGenre(w, addr)
    end
    if rowsJob then moreRows(w) end
end

local function hookAll(now)
    if now < nextHook then return end
    nextHook = now + 5
    local function hook(path, fn)
        local f = StaticFindObject(path)
        if not UE.valid(f) then return end
        local addr = addressOf(f)
        if addr and hooks[path] ~= addr then
            if pcall(function() RegisterHook(path, fn) end) then hooks[path] = addr end
        end
    end
    -- The guest's own buttons. Only noted here; acted on in the tick.
    for _, cls in ipairs({ CLASS.small, CLASS.bundle, CLASS.newM, CLASS.newG }) do
        hook(cls .. BUY_EVENT, function(ctx)
            local card = ctx
            pcall(function() card = ctx:get() end)
            local a = addressOf(card)
            if ourCard(a) and #clicked < 4 then
                -- The unit counter on a new-release card works on a guest.
                clicked[#clicked + 1] = { a = a, units = tonumber(UE.TryGet(card, "Number Of Unit")) }
            end
        end)
    end
    -- Clicking Desktop runs the screen's own Generate Desktop, which blanks it.
    hook(SCREEN .. ":Generate Desktop", function() deskAgain = true end)
    -- Clicking Data runs its own Generate Data Movie Genre Button: none, here.
    hook(SCREEN .. ":Generate Data Movie Genre Button", function() genresAgain = true end)
    hook(CLASS.genre .. GENRE_EVENT, function(ctx)
        local b = ctx
        pcall(function() b = ctx:get() end)
        local a = addressOf(b)
        if a and genreButtons[a] then genreClicked = a end
    end)
    -- A SKU typed into the search box (its own search said "not found").
    hook(SCREEN .. ":" .. SEARCH_EVENT, function(_, skuParam)
        local v = nil
        pcall(function() v = skuParam:get() end)
        v = tonumber(v)
        if v and v > 0 then searchWant = math.floor(v) end
    end)
end

local function sendOrder(o)
    return Chan.sendAction(ACTION, { X = o.kind, Y = o.a or 0, Z = o.b or 0 },
                           { Pitch = o.seq, Yaw = 0, Roll = 0 }) > 0
end

local function sendSearch(s)
    return Chan.sendAction(ACTION, { X = KIND.SEARCH, Y = s.sku, Z = 0 }, { Pitch = s.q, Yaw = 0, Roll = 0 }) > 0
end

--- A page is drawn again only when what the host sent for it changed: every
--- rebuild empties the list, which on the market also throws away how far it
--- was scrolled - and a seated guest asks again every REQUEST_EVERY seconds.
local function signature(fields)
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(fields[k]) end
    return table.concat(parts, "|")
end

local function onPage(name)
    return function(fields)
        if not UE.IsClient() then return end
        local sig = signature(fields)
        pages[name] = fields
        if sig ~= shownSig[name] then
            shownSig[name] = sig
            dirty[name] = true
        end
    end
end

local function onData(fields)
    if not UE.IsClient() then return end
    local before = pages.data and pages.data.g
    pages.data = fields
    -- Genres researched since the buttons were made: make them again.
    if next(genreButtons) and fields.g ~= before then genresAgain = true end
end

local function onSearch(fields)
    if not UE.IsClient() then return end
    if not (searchAsk and tonumber(fields.s) == searchAsk.sku) then return end   -- an older search's
    searchAsk = nil
    if fields.f == "x" then
        require("hud").notice("The host's computer could not search for that.", true, 3)
        fields = { s = fields.s, f = "0" }
    end
    pages.sku = fields
    dirty.sku = true
end

local function onResult(fields)
    if not UE.IsClient() then return end
    pending = nil
    local Hud = require("hud")
    Hud.notice(fields.t ~= "" and fields.t or (fields.ok == "1" and "Ordered." or "The order did not go through."),
               fields.ok ~= "1", 3)
end

--- Guest, every tick.
function Computer.tickGuest(now)
    if not UE.IsClient() or (cfg and cfg.GuestOfficeComputer == false) then return end
    hookAll(now)
    local seated = require("guestinput").machineClass() == "ComputerScreen_C"
    if seated and (not wasSeated or (now - (seatedAt or -1e9)) > REQUEST_EVERY) then
        seatedAt = now
        Chan.sendAction(ACTION, { X = KIND.PAGES, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end
    -- Sitting down runs the screen's Init Set to Main Page: the desktop again.
    if seated and not wasSeated then deskAgain = true end
    wasSeated = seated

    if searchWant then
        local w = screen()
        local box = w and UE.TryGet(w, "Search_WrapBox")
        -- Its own "not found", until the host answers.
        if UE.valid(box) then pcall(function() box:ClearChildren() end) end
        seq = (seq % 80) + 1
        searchAsk = { sku = searchWant, q = seq, at = now }
        searchWant = nil
        sendSearch(searchAsk)
    end
    if searchAsk and (now - searchAsk.at) > RETRY_AFTER then
        if searchAsk.retried then
            pages.sku, dirty.sku = { s = tostring(searchAsk.sku), f = "0" }, true
            searchAsk = nil
            require("hud").notice("The host did not answer - try again.", true, 3)
        else
            searchAsk.retried, searchAsk.at = true, now
            sendSearch(searchAsk)
        end
    end

    if dirty.desk or dirty.mkt or dirty.new or dirty.sku or deskAgain then Safety.guard(OP_GUEST, fillAll) end
    if (genresAgain and pages.data) or genreClicked or rowsJob then Safety.guard(OP_GUEST, dataPage) end

    if #clicked > 0 then
        local c = table.remove(clicked, 1)
        local o = ourCard(c.a)
        if o and not pending then
            seq = (seq % 80) + 1
            local b = o.b
            if o.kind == KIND.NEW_MOVIE or o.kind == KIND.NEW_GAME then b = math.max(1, c.units or 1) end
            pending = { kind = o.kind, a = o.a, b = b, seq = seq, at = now }
            stats.clicks = stats.clicks + 1
            sendOrder(pending)
            require("hud").notice("Ordering...", false, 1)
        end
    end
    if pending and (now - pending.at) > RETRY_AFTER then
        if pending.retried then
            pending = nil
            require("hud").notice("The host did not answer - try again.", true, 3)
        else
            pending.retried, pending.at = true, now
            sendOrder(pending)
        end
    end
end

function Computer.report()
    return { ("Office computer: pages sent %d, orders %d (%d bought, %d refused), searches %d (%d found);"
              .. " guest: filled %d, buy clicks %d, data rows %d, standees %d")
        :format(stats.sent, stats.orders, stats.bought, stats.refused, stats.searches, stats.found,
                stats.filled, stats.clicks, stats.rows, stats.standees) }
end

function Computer.reset()
    pages = { desk = nil, mkt = nil, new = nil, data = nil, sku = nil }
    dirty = { desk = false, mkt = false, new = false, sku = false }
    ours, clicked, pending, seen, asked, shownSig = { mkt = {}, new = {}, sku = {} }, {}, nil, {}, {}, {}
    wasSeated, seatedAt, deskAgain = false, nil, false
    genreButtons, genresAgain, genreClicked, rowsJob = {}, false, nil, nil
    searchWant, searchAsk = nil, nil
end

function Computer.init(config)
    cfg = config
    Chan.on("cdesk", function(f) Log.guard("computer desktop", onPage("desk"), f) end)
    Chan.on("cmkt", function(f) Log.guard("computer market", onPage("mkt"), f) end)
    Chan.on("cnew", function(f) Log.guard("computer new releases", onPage("new"), f) end)
    Chan.on("cres", function(f) Log.guard("computer order", onResult, f) end)
    Chan.on("cdata", function(f) Log.guard("computer data page", onData, f) end)
    Chan.on("csku", function(f) Log.guard("computer search", onSearch, f) end)
end

-- For the tests.
Computer._writeProduct, Computer._readProduct, Computer._FIELDS = writeProduct, readProduct, FIELDS
Computer._standeePath = standeePath

return Computer
