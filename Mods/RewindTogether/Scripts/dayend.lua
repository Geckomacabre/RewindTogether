--[[
    Rewind Together - the end of the day on a guest's screen

    WHAT THE HOST SEES (bp/Core_Gamemode.txt "End of the day" @29157, @8475;
    bp/UI_EndOfTheDay.txt; bp/UI_NewDay.txt)

    At closing time the host clicks the front door and the GameMode ends the
    day: the customers go, the clock stops, +100 XP, and a full-screen summary
    goes up - UI_EndOfTheDay_C, kept in the GameMode's "End of Day Interface":
    the day's rentals, sales and earnings, then the XP bar. Its "new day"
    button starts the next morning (Go to Next day event: the weather adds a
    day, the GameMode's Create a new day closes the summary), and after a fade
    a banner announces the day and the season (UI_NewDay_C).

    WHAT A GUEST SAW

    Nothing. The summary is made by the GameMode, which a guest does not have,
    and its contents come from the GameMode's Statistic object. The guest's
    clock jumped to the next morning and the customers vanished, unexplained.
    (Its presses are ignored while the host's summary is up: guestinput.lua.)

    WHAT THIS DOES

    The host sends what its summary shows - the date, each statistic's text,
    the level and XP texts, the bar, the page it is on - every couple of
    seconds while it is up. The guest builds the same widget (its Construct
    finds no GameMode and leaves every text alone), writes those texts into
    it through the statistic panels' own Set Text, greys out the two buttons
    (the next day is the host's to start), and closes it when the host's
    closes - the widget's own closing animation - then shows the game's
    new-day banner with the host's day and season.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local DayEnd = {}

local SUMMARY = "/Game/VideoStore/core/widget/dayUI/UI_EndOfTheDay.UI_EndOfTheDay_C"
local BANNER  = "/Game/VideoStore/core/widget/dayUI/UI_NewDay.UI_NewDay_C"
local RISKY_OP = "showing the end-of-day summary on a guest's screen"

-- The summary's statistic panels (UI_Statistic_MovieRent_C): each shows its
-- "Text of Result" once its own Set Text runs (UI_EndOfTheDay "Set Text from
-- Statistic", @8448). Sent by position in this list.
local STATS = {
    "UI_Statistic_MovieRent", "UI_Statistic_MovieRent_Income", "UI_Statistic_MovieSold_Income",
    "UI_Statistic_Snack_Income", "UI_Statistic_Concession", "UI_Statistic_Spending_Staff",
    "UI_Statistic_Toys_Income", "UI_Statistic_EarningTotal", "UI_Statistic_ClientServeCheckOut",
    "UI_Statistic_MovieReturn", "UI_Statistic_ClientReserved", "UI_Statistic_ClientRequestMovie",
    "UI_Statistic_ClientConcession", "UI_Statistic_ClientRequest-Acoomplished",
    "UI_Statistic_MovieRent_PopularGenre",
}
-- Plain text blocks, by the field that carries them.
local TEXTS = { d = "txt_Date", ln = "txt_LevelName", lx = "txt_Level_Player-XP", lq = "txt_Level_XpNeed" }
local BUTTONS = { "UX_Button_NewDay", "UX_Button_Base", "Button_115" }
-- Shown or hidden by the summary's Construct and its XP animation - which a
-- guest's copy never gets as far as (it finds no GameMode). MEASURED: a
-- guest's XP page said "LEVEL UP!" over an empty unlock box the host's had
-- collapsed. Sent as one digit each (ESlateVisibility).
local VISIBILITY = { "txt_LevelUp", "SizeBox_ScrollLEvelUp", "SizeBox_ScrollBox_PopularGenre" }
-- What a level brings (UI_EndOfTheDay "Add Widgets For Level Unlock and
-- Unlock it", @0): one UI_Statistic_Levelup_Unlock_C per unlock in the
-- level's row of gamesettings_XP-Per-Level, added to this box. It runs from
-- the XP animation, which a guest's copy never starts (no GameMode), so a
-- guest's box stays empty. Each is described by three bytes, set before it
-- is added (its Construct reads them): sent as "system.movie.game",
-- comma-separated.
local UNLOCK_BOX = "HorizontalBox_LevelUpUnlock"
local UNLOCK_BYTES = { "Gameplay System", "Movie Genre", "Game Genre" }
local UNLOCK = "/Game/VideoStore/core/widget/dayUI/UI_Statistic_Levelup_Unlock.UI_Statistic_Levelup_Unlock_C"
-- A movie genre that unlocks also gets the game's full-screen popup (same
-- function, @2087), which removes itself when its animation ends.
local GENRE_POPUP = "/Game/VideoStore/core/widget/dayUI/UI_GenreUnlock.UI_GenreUnlock_C"

local HOST_EVERY  = 1.0     -- host: look at the summary
local RESEND      = 3.0     -- host: say it again even when nothing changed
local BANNER_WAIT = 10.0    -- host: how long to look for the new-day banner

local stats = { sent = 0, shown = 0, banners = 0, unlocks = 0 }

local function textOf(widget)
    if not UE.valid(widget) then return "" end
    local v = UE.TryGet(widget, "Text")
    if v == nil then return "" end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or ""
end

local function ftextString(v)
    if v == nil then return "" end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or ""
end

local function inViewport(w)
    local ok, on = pcall(function() return w:IsInViewport() end)
    return ok and on == true
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local nextHost, lastSig, lastAt = 0, nil, 0
local wasUp, bannerUntil = false, nil

--- The unlocks the summary lists, as sent ("" while there are none).
local function unlocksOf(w)
    local box = UE.TryGet(w, UNLOCK_BOX)
    if not UE.valid(box) then return "" end
    local n = 0
    pcall(function() n = box:GetChildrenCount() end)
    local out = {}
    for i = 0, (tonumber(n) or 0) - 1 do
        local child = nil
        pcall(function() child = box:GetChildAt(i) end)
        if UE.valid(child) then
            local b = {}
            for j, prop in ipairs(UNLOCK_BYTES) do
                b[j] = tostring(math.floor(tonumber(UE.TryGet(child, prop)) or 0))
            end
            out[#out + 1] = table.concat(b, ".")
        end
    end
    return table.concat(out, ",")
end

local function collect(w)
    local fields = { s = "1" }
    for i, name in ipairs(STATS) do
        local panel = UE.TryGet(w, name)
        if UE.valid(panel) then fields["t" .. i] = ftextString(UE.TryGet(panel, "Text of Result")) end
    end
    for key, name in pairs(TEXTS) do fields[key] = textOf(UE.TryGet(w, name)) end
    local bar = UE.TryGet(w, "ProgressBar_Level")
    local pct = tonumber(UE.TryGet(bar, "Percent"))
    if pct then fields.b = ("%.4f"):format(pct) end
    local page = tonumber(UE.TryGet(UE.TryGet(w, "WidgetSwitcher"), "ActiveWidgetIndex"))
    if page then fields.p = tostring(page) end
    local shown = {}
    for i, name in ipairs(VISIBILITY) do
        shown[i] = tostring(math.floor(tonumber(UE.TryGet(UE.TryGet(w, name), "Visibility")) or 0))
    end
    fields.v = table.concat(shown)
    fields.u = unlocksOf(w)
    return fields
end

local function signature(fields)
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. fields[k] end
    return table.concat(parts, "\n")
end

--- The banner the host's GameMode puts up after the fade into the new day.
--- Nothing keeps it (a local in the GameMode's graph), so it is looked for
--- by class - a walk, about once a second for a few seconds once a day.
local function hostBanner()
    local b = FindFirstOf and FindFirstOf("UI_NewDay_C") or nil
    if not UE.valid(b) then return nil end
    local day, season = textOf(UE.TryGet(b, "txt_day")), textOf(UE.TryGet(b, "txt_season"))
    if day == "" then return nil end
    return day, season
end

--[[
    REPORTED (16 Oct 2026): from day 2 on, the guest woke up in the store
    instead of outside with the host. The GameMode's new morning ("Create a
    new day" @29557, after the summary's closing animation and a fade) puts
    player 0 - the host - at the Actor Gatherer's "PlayerStart Game Zone"
    and turns their view; nobody else. So once the host is standing there,
    every guest is put beside them, facing the same way (guestinput.lua
    everyoneToHost, the move "Back to the store" makes).
]]
local MORNING_WAIT = 20.0      -- seconds after the summary closes to see the host arrive
local MORNING_NEAR = 300.0     -- cm from the start zone: the host is there
local morningUntil = nil

local function startZone()
    local gm = UE.GetGameMode()
    local gather = UE.valid(gm) and UE.TryGet(gm, "Actor Gatherer") or nil
    local zone = UE.valid(gather) and UE.TryGet(gather, "PlayerStart Game Zone") or nil
    if not UE.valid(zone) then return nil end
    local at = nil
    pcall(function() at = UE.vec(zone:K2_GetActorLocation()) end)
    return at
end

local function morningTick(now)
    if not morningUntil then return end
    if now > morningUntil then
        morningUntil = nil
        Log.info("end of day: the host never reached the morning start spot - guests left where they are")
        return
    end
    local zone, host = startZone(), nil
    pcall(function() host = UE.vec(UE.GetPawn():K2_GetActorLocation()) end)
    if not (zone and host) then return end
    local dx, dy = zone.X - host.X, zone.Y - host.Y
    if math.sqrt(dx * dx + dy * dy) > MORNING_NEAR then return end
    morningUntil = nil
    local n = require("guestinput").everyoneToHost("the new morning: beside the host outside")
    stats.mornings = (stats.mornings or 0) + 1
    if n > 0 then Log.info("end of day: %d guest(s) start the new day outside with the host", n) end
end

function DayEnd.tickHost(now)
    if not UE.IsServer() or now < nextHost then return end
    nextHost = now + HOST_EVERY
    morningTick(now)
    local gm = UE.GetGameMode()
    local w = UE.valid(gm) and UE.TryGet(gm, "End of Day Interface") or nil
    if UE.valid(w) and inViewport(w) then
        wasUp, bannerUntil = true, nil
        local fields = collect(w)
        local sig = signature(fields)
        if sig ~= lastSig or (now - lastAt) > RESEND then
            if Chan.broadcast("day", fields) > 0 then
                lastSig, lastAt = sig, now
                stats.sent = stats.sent + 1
            end
        end
        return
    end
    if wasUp then
        -- The summary has just closed: the next day has begun. Say so at once,
        -- then once more with the banner's words when the host's appears.
        wasUp, lastSig = false, nil
        Chan.broadcast("day", { s = "0" })
        bannerUntil = now + BANNER_WAIT
        morningUntil = now + MORNING_WAIT
        return
    end
    if bannerUntil then
        local day, season = hostBanner()
        if day then
            Chan.broadcast("day", { s = "0", nd = day, ns = season or "" })
            bannerUntil = nil
        elseif now > bannerUntil then
            bannerUntil = nil
        end
    end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local summaryPath = nil      -- the guest's copy of the summary, by path (ue.lua: never held)
local sawSummary = false
local warned = false
local unlocksShown = ""      -- the unlock list the guest's summary holds, as sent
local popupsShown = {}       -- movie genre -> true: its popup went up this summary

local function create(classPath, zOrder)
    local cls = UE.load(classPath)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local world, pc = UE.GetWorld(), UE.GetPlayerController()
    if not (UE.valid(cls) and UE.valid(wbl) and UE.valid(world) and UE.alive(pc)) then return nil end
    local ran, widget = Safety.guard(RISKY_OP, function()
        local w = nil
        pcall(function() w = wbl:Create(world, cls, pc) end)
        if not UE.valid(w) then return nil end
        pcall(function() w:AddToViewport(zOrder) end)
        return w
    end)
    if not ran then
        if not warned then
            warned = true
            Log.warn("end of day: not shown on this screen after an earlier crash (rt.safety)")
        end
        return nil
    end
    return widget
end

local function summary()
    if not summaryPath then return nil end
    local w = UE.findObject(summaryPath)
    if UE.valid(w) and inViewport(w) then return w end
    summaryPath = nil
    return nil
end

local function setText(widget, s)
    if type(s) ~= "string" or not UE.valid(widget) or textOf(widget) == s then return end
    pcall(function() widget:SetText(FText(s)) end)
end

--- The host's unlocks, made the way the summary makes them: Create, the
--- three bytes, AddChildToHorizontalBox (the "Return Level Unlock Widget"
--- functions, @404-@426). A movie genre gets the game's popup too, once.
local function fillUnlocks(w, list)
    if type(list) ~= "string" or list == unlocksShown then return end
    local box = UE.TryGet(w, UNLOCK_BOX)
    local cls = UE.load(UNLOCK)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local world, pc = UE.GetWorld(), UE.GetPlayerController()
    if not (UE.valid(box) and UE.valid(cls) and UE.valid(wbl) and UE.valid(ksl)
            and UE.valid(world) and UE.alive(pc)) then return end
    -- Safety.guard reports a function that raised as run, with no result:
    -- only a fill that got to the end counts, so a failed one is tried again.
    local ran, filled = Safety.guard(RISKY_OP, function()
        pcall(function() box:ClearChildren() end)
        for entry in list:gmatch("[^,]+") do
            local bytes = { entry:match("^(%d+)%.(%d+)%.(%d+)$") }
            if #bytes == 3 then
                local item = nil
                pcall(function() item = wbl:Create(world, cls, pc) end)
                if UE.valid(item) then
                    for j, prop in ipairs(UNLOCK_BYTES) do
                        pcall(function() ksl:SetBytePropertyByName(item, FName(prop), tonumber(bytes[j])) end)
                    end
                    pcall(function() box:AddChildToHorizontalBox(item) end)
                end
                local movie = tonumber(bytes[2])
                if tonumber(bytes[1]) == 0 and movie ~= 0 and not popupsShown[movie] then
                    popupsShown[movie] = true
                    local popupCls = UE.load(GENRE_POPUP)
                    local popup = nil
                    if UE.valid(popupCls) then pcall(function() popup = wbl:Create(world, popupCls, pc) end) end
                    if UE.valid(popup) then
                        pcall(function() ksl:SetBytePropertyByName(popup, FName("Genre Unlock"), movie) end)
                        -- Above this screen's summary, as the host's lands
                        -- above its own (both at 0 there, the popup added later).
                        pcall(function() popup:AddToViewport(12) end)
                    end
                end
            end
        end
        return true
    end)
    if ran and filled == true then
        unlocksShown = list
        stats.unlocks = stats.unlocks + 1
    end
end

local function fill(w, fields)
    for i, name in ipairs(STATS) do
        local s = fields["t" .. i]
        local panel = UE.TryGet(w, name)
        if type(s) == "string" and UE.valid(panel)
           and ftextString(UE.TryGet(panel, "Text of Result")) ~= s then
            -- UE.setText, never a plain FText write: that one overran into
            -- the row's Font Size and the rows vanished (ue.lua).
            UE.setText(panel, "Text of Result", s)
            UE.TryCall(panel, "Set Text")
        end
    end
    for key, name in pairs(TEXTS) do setText(UE.TryGet(w, name), fields[key]) end
    local pct = tonumber(fields.b)
    local bar = UE.TryGet(w, "ProgressBar_Level")
    if pct and UE.valid(bar) then pcall(function() bar:SetPercent(pct) end) end
    for i, name in ipairs(VISIBILITY) do
        local want, part = tonumber((fields.v or ""):sub(i, i)), UE.TryGet(w, name)
        if want and UE.valid(part) and tonumber(UE.TryGet(part, "Visibility")) ~= want then
            pcall(function() part:SetVisibility(want) end)
        end
    end
    local page = tonumber(fields.p)
    local switcher = UE.TryGet(w, "WidgetSwitcher")
    if page and UE.valid(switcher) and tonumber(UE.TryGet(switcher, "ActiveWidgetIndex")) ~= page then
        pcall(function() switcher:SetActiveWidgetIndex(page) end)
    end
    fillUnlocks(w, fields.u)
end

local function showSummary(fields)
    local w = summary()
    if not w then
        w = create(SUMMARY, 10)
        if not w then return end
        summaryPath = UE.pathOf(w)
        unlocksShown, popupsShown = "", {}
        -- The next day is the host's to start; on this screen the buttons
        -- would do nothing (they ask for a GameMode) - say so by greying them.
        for _, name in ipairs(BUTTONS) do
            local b = UE.TryGet(w, name)
            if UE.valid(b) then pcall(function() b:SetIsEnabled(false) end) end
        end
        stats.shown = stats.shown + 1
        Log.info("end of day: the host closed the store - their summary is on your screen " ..
                 "until they start the next day")
    end
    sawSummary = true
    fill(w, fields)
end

local function closeSummary()
    local w = summary()
    summaryPath = nil
    if not w then return end
    if not UE.TryCall(w, "Close Animation and auto-destroy") then
        pcall(function() w:RemoveFromParent() end)
    end
end

local function showBanner(day, season)
    local b = create(BANNER, 11)
    if not b then return end
    setText(UE.TryGet(b, "txt_day"), day)
    setText(UE.TryGet(b, "txt_season"), season)
    -- Its own entry animation; it removes itself after the exit one. (Its
    -- Construct waits for a GameMode that never comes and does nothing else.)
    UE.TryCall(b, "Animation")
    stats.banners = stats.banners + 1
    Log.info("end of day: a new day - %s %s", day, season or "")
end

local function onDay(fields)
    if UE.IsServer() then return end
    if fields.s == "1" then
        showSummary(fields)
    elseif fields.s == "0" then
        closeSummary()
        if fields.nd and sawSummary then
            sawSummary = false
            showBanner(fields.nd, fields.ns)
        end
    end
end

--------------------------------------------------------------------------

function DayEnd.stats() return stats end

function DayEnd.reset()
    nextHost, lastSig, lastAt = 0, nil, 0
    wasUp, bannerUntil, morningUntil = false, nil, nil
    -- A world that is going away takes the widget with it.
    summaryPath, sawSummary = nil, false
    unlocksShown, popupsShown = "", {}
end

function DayEnd.init()
    Chan.on("day", function(fields) Log.guard("end of day", onDay, fields) end)
end

return DayEnd
