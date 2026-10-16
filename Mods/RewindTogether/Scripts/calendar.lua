--[[
    Rewind Together - the office calendar, for guests

    REQUESTED (16 Oct 2026), with the staff book (staffbook.lua): "the
    calendar's rewards for guests, its page as a nice-to-have". Read off the
    dumps (Calendar_Machine, UI_Calendar_Widget, UI_Calendar-Achievement and
    its _Slot, UI_Calendar_Sector; docs/MULTIPLAYER-AUDIT.md):

      * THE TASK LIST. Each of its 18 rows pays the store once, $100 and
        50 XP, for a Steam achievement the player has. A row's Claim is
        enabled from the machine's "Achievement Sucessful" (filled from the
        player's own Steam, Calendar_Machine @1459-@2018) and greyed once the
        store's save has it in "Achievement Reclame" (the slot's Set Claim
        Button State @9655). A guest's machine never gets that far - it
        waits for a GameMode forever (Set init Calendar @30, the widget's Get
        Gatherer @3642) - so every Claim stayed grey, and a click on one did
        nothing (it charges through the GameMode, @9181). Here the guest's
        machine is given its own weather actor and its "loaded" flag, so its
        own list is drawn as in single player, from the guest's own Steam;
        each row's claimed mark is the host's; and a Claim is the host's
        (action 23): the host's own row for that achievement is clicked on
        the host's calendar, which writes the store's save and pays the store
        (@9288-@9640) - once per store, whoever claims it.
      * THE MONTH PAGE. On a guest it kept the designer's "25th Spring 1990",
        blank day cells, one stray check mark and "NOT SET" for the weather.
        The host's page is read off its own widget - the year and each day
        cell's events - and drawn on the guest's with the game's own cells,
        whose PreConstruct and Construct put the event's icon and bonus on
        them (UI_Calendar_Sector @24423, @27077). The check marks, today's
        mark and the forecast come from the guest's own weather actor, which
        sync.lua keeps at the host's day and weather.

    The guest-to-host channel is unreliable and sent twice: each claim has a
    number, the host does each number once and answers, and the guest asks
    again once if no answer comes (uimachines.lua's way).
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local Cal = {}

local ACTION_CLAIM = 23
local OP_HOST  = "a guest's calendar reward on the host"
local OP_GUEST = "the calendar on a guest"

local DIR      = "/Game/VideoStore/asset/prop/Calendar/"
local SLOT_W   = DIR .. "Achievement/UI_Calendar-Achievement_Slot.UI_Calendar-Achievement_Slot_C"
local SECTOR_W = DIR .. "UI_Calendar_Sector.UI_Calendar_Sector_C"
local EMPTY_W  = DIR .. "UI_Calendar_EmptySlot.UI_Calendar_EmptySlot_C"
local PAY_SOUND = "/Game/VideoStore/asset/sfx/machine/global/sfx_Pay_Cue.sfx_Pay_Cue"
local WIDGETS  = "/Script/UMG.Default__WidgetBlueprintLibrary"
local CLAIM_EVT = "BndEvt__UI_Calendar-Achievement_Slot_Button_Claim_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature"
local CLAIM_HOOK = SLOT_W .. ":" .. CLAIM_EVT
-- The rows the task list shows (Generate Achievement List @85, @176).
local ROWS = {}
for _, a in ipairs({ 15, 1, 3, 4, 5, 6, 7, 8, 9, 11, 16, 10, 14, 17, 18, 2, 12, 13 }) do ROWS[a] = true end

local SEND_EVERY  = 10.0     -- MEASURED: a send reads the month widget, 28 ms on the host's frame
local RESEND      = 10.0
local RETRY_AFTER = 4.0
local SEEN_FOR    = 15.0
local MAX_CELLS   = 40

local stats = { sent = 0, claims = 0, refused = 0, setups = 0, rowsMarked = 0, months = 0 }

--------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

local function widgetOf(machine)
    local wc = UE.alive(machine) and UE.TryGet(machine, "Widget") or nil
    if not UE.valid(wc) then return nil end
    local ok, w = UE.TryCall(wc, "GetUserWidgetObject")
    return (ok and UE.valid(w)) and w or nil
end

local function childCount(box)
    local n = 0
    if UE.valid(box) then pcall(function() n = box:GetChildrenCount() end) end
    return tonumber(n) or 0
end

local function childAt(box, i)
    local c = nil
    pcall(function() c = box:GetChildAt(i) end)
    return UE.valid(c) and c or nil
end

local function eachOf(arr, fn)
    local n = 0
    if arr == nil then return end
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

local function textOf(block)
    local s = nil
    pcall(function() s = block:GetText():ToString() end)
    return type(s) == "string" and s or nil
end

local function machine()
    local m = UE.findFirst("Calendar_Machine_C")
    return UE.alive(m) and m or nil
end

--- The task list's rows: achievement -> row.
local function rowsOf(list)
    local box = UE.TryGet(list, "ScrollBox_Achievement")
    local out, n = {}, childCount(box)
    for i = 0, n - 1 do
        local s = childAt(box, i)
        local a = s and tonumber(UE.TryGet(s, "Achievement")) or nil
        if a and ROWS[a] then out[a] = s end
    end
    return out, box, n
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local seen = {}
local lastSig, lastAt, lastBuild = nil, -1e9, -1e9

--- The store's claimed rewards, from its calendar's "Achievement Reclame".
local function claimedOnHost(m)
    local out = {}
    local map = UE.TryGet(m, "Achievement Reclame")
    if map == nil then return out end
    pcall(function()
        map:ForEach(function(k, v)
            local key, val = k, v
            pcall(function() key = k:get() end)
            pcall(function() val = v:get() end)
            key = tonumber(key)
            if key and val == true then out[key] = true end
        end)
    end)
    return out
end

local function listOf(set)
    local t = {}
    for a in pairs(set) do t[#t + 1] = a end
    table.sort(t)
    return table.concat(t, ",")
end

--- The host's month page as its widget drew it: each cell's place and its
--- events (none for an empty day).
local function monthOnHost(w)
    local grid = UE.TryGet(w, "Calendar_Grid")
    local cells = {}
    for i = 0, math.min(childCount(grid), MAX_CELLS) - 1 do
        local c = childAt(grid, i)
        local slot = c and UE.TryGet(c, "Slot") or nil
        local row, col = round(UE.TryGet(slot, "Row")), round(UE.TryGet(slot, "Column"))
        local ev = {}
        if c and UE.ClassNameOf(c) == "UI_Calendar_Sector_C" then
            eachOf(UE.TryGet(c, "Calender Event"), function(_, e)
                e = tonumber(e)
                if e and #ev < 8 then ev[#ev + 1] = tostring(math.floor(e)) end
            end)
            if #ev == 0 then ev[1] = "0" end
        end
        cells[#cells + 1] = ("%d,%d,%s"):format(row, col, table.concat(ev, "."))
    end
    return table.concat(cells, ";")
end

local function sendState(now)
    if (now - lastAt) < SEND_EVERY or (now - lastBuild) < SEND_EVERY then return end
    -- At most once per SEND_EVERY, sent or not. MEASURED (16 Oct 2026): with the
    -- state unchanged, or no guest to send it to, this rebuilt it on every
    -- tick - the calendar's month read is 28 ms of the host's frame.
    lastBuild = now
    local m = machine()
    if not m then return end
    local fields = { c = listOf(claimedOnHost(m)) }
    local w = widgetOf(m)
    if w then
        fields.y = textOf(UE.TryGet(w, "Txt_date")) or ""
        fields.ev = monthOnHost(w)
    end
    local sig = (fields.c or "") .. "|" .. (fields.y or "") .. "|" .. (fields.ev or "")
    if sig == lastSig and (now - lastAt) < RESEND then return end
    if Chan.broadcast("cal", fields) > 0 then
        lastSig, lastAt = sig, now
        stats.sent = stats.sent + 1
    end
end

local function tell(pc, ok, text)
    Chan.sendTo(pc, "calres", { ok = ok and "1" or "0", t = text or "" })
    if not ok then stats.refused = stats.refused + 1 end
end

--- A reward, claimed the way a click on the host's own row claims it.
local function claim(pc, a)
    local m = machine()
    local w = widgetOf(m)
    local list = w and UE.TryGet(w, "UI_Calendar-Achievement") or nil
    if not UE.valid(list) then return tell(pc, false, "The host's calendar is not ready.") end
    if claimedOnHost(m)[a] then return tell(pc, false, "That reward was already claimed for the store.") end
    local rows = rowsOf(list)
    if not rows[a] and UE.valid(UE.TryGet(list, "ref Calendar Machine")) then
        -- Not drawn yet on the host (it is drawn when someone walks by).
        UE.TryCall(list, "Generate Achievement List")
        rows = rowsOf(list)
    end
    local row = rows[a]
    if not row then return tell(pc, false, "The host's calendar is not ready.") end
    if UE.TryGet(row, "Reclame") == true then return tell(pc, false, "That reward was already claimed for the store.") end
    UE.TryCall(row, CLAIM_EVT)
    if UE.TryGet(row, "Reclame") ~= true then return tell(pc, false, "The reward did not go through.") end
    stats.claims = stats.claims + 1
    lastAt, lastBuild = -1e9, -1e9
    local money, xp = tonumber(UE.TryGet(row, "Money")) or 0, tonumber(UE.TryGet(row, "XP")) or 0
    Log.info("calendar: %s claimed reward %d ($%.2f, %d XP)", UE.PlayerNameOf(pc) or "a guest", a, money / 100, xp)
    tell(pc, true, ("Claimed: $%d and %d XP for the store."):format(math.floor(money / 100), xp))
end

--- Host: guest action 23 (guestinput.lua routes it here). X the achievement,
--- numbered in Pitch.
function Cal.onGuest(pc, pawn, loc, rot)
    if not UE.IsServer() or not (UE.valid(pc) and loc) then return end
    local a = round(loc.X)
    local now = os.clock()
    local key = pc:GetFullName() .. "#" .. round(rot and rot.Pitch)
    for k, t in pairs(seen) do if now - t > SEEN_FOR then seen[k] = nil end end
    if seen[key] then return end
    seen[key] = now
    if ROWS[a] then Safety.guard(OP_HOST, claim, pc, a) end
end

function Cal.tickHost(now)
    if not UE.IsServer() or UE.IsStandalone() then return end
    if Chan.isReady() then sendState(now) end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local host = nil           -- guest: { claimed = {a = true}, year, ev, sig }
local hookedAt = nil
local nextHook, nextLook = 0, 0
local clicks = {}
local pending = nil
local seq = 0
local setUp = nil          -- the guest's machine we set up (its address)
local marked = nil         -- { claimedSig, first, n } of the task list as last marked
local monthDone = nil      -- { ev, first, n } of the month grid as last drawn
local lastDay = nil

local function hookClaim(now)
    if now < nextHook then return end
    nextHook = now + 5
    local f = StaticFindObject(CLAIM_HOOK)
    local addr = UE.valid(f) and addressOf(f) or nil
    if not addr or hookedAt == addr then return end
    local ok = pcall(function()
        RegisterHook(CLAIM_HOOK, function(ctx)
            if not UE.IsClient() or #clicks >= 4 then return end
            local row = nil
            pcall(function() row = ctx:get() end)
            if not UE.valid(row) or UE.TryGet(row, "Reclame") == true then return end
            local a = tonumber(UE.TryGet(row, "Achievement"))
            if a and ROWS[a] then clicks[#clicks + 1] = a end
        end)
    end)
    if ok then hookedAt = addr end
end

local function send(o)
    return Chan.sendAction(ACTION_CLAIM, { X = o.a, Y = 0, Z = 0 }, { Pitch = o.seq, Yaw = 0, Roll = 0 }) > 0
end

local function takeClicks()
    while #clicks > 0 do
        local a = table.remove(clicks, 1)
        if pending then
            require("hud").notice("One moment - the last one is still going through.", false, 2)
        else
            seq = (seq % 80) + 1
            pending = { a = a, seq = seq, at = os.clock() }
            send(pending)
            require("hud").notice("Claiming...", false, 1.5)
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

local function create(w, path)
    local lib, cls = StaticFindObject(WIDGETS), StaticFindObject(path)
    if not UE.valid(cls) then cls = UE.load(path) end
    if not (UE.valid(lib) and UE.valid(cls)) then return nil end
    local c = nil
    pcall(function() c = lib:Create(w, cls, UE.GetPlayerController()) end)
    return UE.valid(c) and c or nil
end

--- The guest's own calendar, started as the host's starts its own (Set init
--- Calendar @30-@503, the widget's Init Calendar @4831), with the guest's own
--- weather actor where those look for the GameMode's.
local function setup(m, w, weather)
    UE.TrySet(m, "Save Load", true)
    UE.TrySet(m, "Weather Actor ref", weather)
    UE.TrySet(w, "Calendar Ref", m)
    UE.TrySet(w, "ref Weather Actor", weather)
    UE.TryCall(m, "Achievement - Check which is unlock")
    UE.TryCall(w, "Init Calendar")
    UE.TryCall(m, "Set Season Calendar Material", round(UE.TryGet(weather, "Season")))
    stats.setups = stats.setups + 1
end

--- Each row's claimed mark, the store's (host's): again whenever the guest's
--- game draws the list again (it does when the player walks by, @7718).
local function markRows(w)
    local list = UE.TryGet(w, "UI_Calendar-Achievement")
    if not UE.valid(list) then return end
    local rows, box, n = rowsOf(list)
    local first = n > 0 and addressOf(childAt(box, 0)) or nil
    local claimedSig = listOf(host.claimed)
    if marked and marked.sig == claimedSig and marked.first == first and marked.n == n then return end
    for a, row in pairs(rows) do
        local want = host.claimed[a] == true
        if (UE.TryGet(row, "Reclame") == true) ~= want then
            UE.TrySet(row, "Reclame", want)
            stats.rowsMarked = stats.rowsMarked + 1
        end
        UE.TryCall(row, "Set Claim Button State")
    end
    marked = { sig = claimedSig, first = first, n = n }
end

--- The host's month, with the game's own day cells.
local function drawMonth(w)
    local grid = UE.TryGet(w, "Calendar_Grid")
    if not (UE.valid(grid) and host.ev and host.ev ~= "") then return end
    local n = childCount(grid)
    local first = n > 0 and addressOf(childAt(grid, 0)) or nil
    if monthDone and monthDone.ev == host.ev and monthDone.first == first and monthDone.n == n then return end
    pcall(function() grid:ClearChildren() end)
    local count = 0
    for cell in host.ev:gmatch("[^;]+") do
        local row, col, ev = cell:match("^(%d+),(%d+),([%d%.]*)$")
        if row and count < MAX_CELLS then
            count = count + 1
            local events = {}
            for e in ev:gmatch("%d+") do events[#events + 1] = tonumber(e) end
            local c = create(w, #events > 0 and SECTOR_W or EMPTY_W)
            if c then
                if #events > 0 then UE.TrySet(c, "Calender Event", events) end
                pcall(function() grid:AddChildToUniformGrid(c, tonumber(row), tonumber(col)) end)
            end
        end
    end
    n = childCount(grid)
    monthDone = { ev = host.ev, first = n > 0 and addressOf(childAt(grid, 0)) or nil, n = n }
    stats.months = stats.months + 1
end

local function look()
    local m = machine()
    local w = widgetOf(m)
    local weather = UE.findFirst("WeatherSystem_C")
    if not (w and UE.alive(weather)) then return end
    local a = addressOf(m) or UE.pathOf(m)
    if setUp ~= a then
        setup(m, w, weather)
        setUp, marked, monthDone, lastDay = a, nil, nil, nil
    end
    -- A new day: the check marks, the forecast and the season's page, from
    -- the guest's weather actor (the widget's New Day Event never comes, @4905).
    local day = round(UE.TryGet(weather, "Day"))
    if lastDay ~= nil and day ~= lastDay then
        UE.TryCall(w, "Clear and Add Checkmark On Passed Days")
        UE.TryCall(UE.TryGet(w, "UI_Calendar-Weather"), "Generate Weather")
        UE.TryCall(m, "Set Season Calendar Material", round(UE.TryGet(weather, "Season")))
        UE.TryCall(m, "Achievement - Check which is unlock")
    end
    lastDay = day
    if host.year and host.year ~= "" then
        local txt = UE.TryGet(w, "Txt_date")
        if UE.valid(txt) and textOf(txt) ~= host.year then pcall(function() txt:SetText(FText(host.year)) end) end
    end
    drawMonth(w)
    markRows(w)
end

function Cal.tickGuest(now)
    if not UE.IsClient() then return end
    hookClaim(now)
    takeClicks()
    if host and now >= nextLook then
        nextLook = now + 1.0
        Safety.guard(OP_GUEST, look)
    end
end

local function onState(f)
    if not UE.IsClient() then return end
    local claimed = {}
    for s in (f.c or ""):gmatch("%d+") do
        local a = tonumber(s)
        if ROWS[a] then claimed[a] = true end
    end
    host = { claimed = claimed, year = f.y, ev = f.ev }
end

local function onResult(f)
    if not UE.IsClient() then return end
    local ok = f.ok == "1"
    if ok and pending and host then
        host.claimed[pending.a] = true
        marked = nil
        local cue, gs = UE.load(PAY_SOUND), UE.GetGameplayStatics()
        if UE.valid(cue) and UE.valid(gs) then
            pcall(function() gs:PlaySound2D(UE.GetWorld(), cue, 1.0, 1.0, 0.0, nil, nil, true) end)
        end
    end
    pending = nil
    require("hud").notice(f.t ~= "" and f.t or (ok and "Claimed." or "That did not go through."), not ok, 3)
end

function Cal.report()
    local n = 0
    for _ in pairs(host and host.claimed or {}) do n = n + 1 end
    return { ("Calendar: host sent %d, %d reward(s) claimed for guests, %d refused; guest set up %d time(s), " ..
              "marked %d row(s), drew the month %d time(s)%s%s"):format(stats.sent, stats.claims, stats.refused,
              stats.setups, stats.rowsMarked, stats.months,
              host and (", the store has claimed %d"):format(n) or "", pending and ", one waiting" or "") }
end

function Cal.reset()
    seen, host, clicks, pending = {}, nil, {}, nil
    setUp, marked, monthDone, lastDay = nil, nil, nil, nil
    lastSig, lastAt, lastBuild = nil, -1e9, -1e9
    hookedAt = nil
end

function Cal.init()
    Chan.on("cal", function(f) Log.guard("the host's calendar", onState, f) end)
    Chan.on("calres", function(f) Log.guard("a calendar answer", onResult, f) end)
end

-- For the tests.
Cal._stats = function() return stats end
Cal._paths = { sector = SECTOR_W, empty = EMPTY_W, claim = CLAIM_EVT, hook = CLAIM_HOOK }

return Cal
