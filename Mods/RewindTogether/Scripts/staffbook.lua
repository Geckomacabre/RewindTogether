--[[
    Rewind Together - the staff book, for guests

    REQUESTED (16 Oct 2026): the follow-up to the store's screen machines
    (uimachines.lua): "make the staff book work for guests - hire, fire, job
    changes". Read off the dumps (UI_StaffBook_Widget, _HireStaff,
    _CounterTop, _Txt_GameplayTraits; docs/MULTIPLAYER-AUDIT.md):

      * A guest's game opens its own copy of the book, but both its pages
        come up empty. Each one is filled from the GameMode, which only the
        host has: the applicants are the host Market's "Potential Staff of
        the Day" (made each morning with an unseeded random, so a guest could
        never make the same people), the employees the host AI Director's
        "Staff Hired" (Generate Container Page @145, @826 - both stop there on
        a guest). Here the host says who is in each list - name, pay, the two
        skills, photo, traits, and for an employee the job, "about me" and
        favourite movie - and the guest's game draws its own cards from it,
        each with the game's own card: the plain numbers go into the card's
        Staff before it is shown, so its Construct writes "$120 / Day", the
        skill words and their colours itself (HireStaff @20-@938, CounterTop
        @1581-@4292); the texts, the photo and the traits are put on after.
      * Hire, fire and a job change are the host's. A guest's click is an
        action (22) with the card's place in its list and its pay to check
        it by, and the host does exactly what a click on its own book would:
        it keeps a copy of the book's screen that is never shown, has it
        draw the page from its GameMode (Generate Container Page), and clicks
        that card's own button - so the hire runs the game's own Hire Staff
        handler (@0-@3329: the staff limit from the research done, the new
        employee walking in, the applicant gone from the list, the sound, the
        host's Steam stat and achievements), the fire its Event Fired Staff
        (@1507, AI Director "Remove Staff"), the job the card's own Set Staff
        Job (@5715, the employee's task too). Nothing is built from Lua: the
        FStaff struct has seven sets, a date and two texts the engine copies
        itself, card to handler.
      * A hire the game refuses says why on the screen of whoever clicked
        (Show Error To Player, the GameMode's HUD): run as the guest, the
        host's HUD is out of reach (guestinput.lua asGuest), and the guest
        gets the game's own words for it from its own string table.

    The guest-to-host channel is unreliable and sent twice: each action has a
    number, the host does each number once and answers, and the guest asks
    again once if no answer comes (uimachines.lua's way).
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local Staff = {}

local ACTION_STAFF = 22
local DO_HIRE, DO_FIRE, DO_RETURNS, DO_CHECKOUT = 1, 2, 3, 4
local JOB_RETURNS, JOB_CHECKOUT = 1, 2       -- Staff-Job: the radios (CounterTop @5698, @5681)
local PAGE_HIRE, PAGE_STAFF = 2, 5           -- Catalogue_WidgetSwitcher: the book's two pages
local FIRST_LEVEL = 6                        -- the applicants' cover (HireStaff @1035)
local OP_HOST  = "a guest's hire, fire or job change on the host"
local OP_GUEST = "the staff book on a guest"

local DIR      = "/Game/VideoStore/asset/prop/StaffBook/"
local BOOK_W   = DIR .. "UI_StaffBook_Widget.UI_StaffBook_Widget_C"
local CV_W     = DIR .. "UI_StaffBook_HireStaff.UI_StaffBook_HireStaff_C"
local FOLDER_W = DIR .. "UI_StaffBook_CounterTop.UI_StaffBook_CounterTop_C"
local TRAIT_W  = DIR .. "UI_StaffBook_Txt_GameplayTraits.UI_StaffBook_Txt_GameplayTraits_C"
local HIRE_SOUND = DIR .. "sfx/sfx_staffbook_hire_Cue.sfx_staffbook_hire_Cue"
local WIDGETS  = "/Script/UMG.Default__WidgetBlueprintLibrary"
local HIRE_EVT = "BndEvt__UI_StaffBook_Product_UI_Catalogue_ButtonHireStaff_K2Node_ComponentBoundEvent_0_On Clicked__DelegateSignature"
local FIRE_EVT = "BndEvt__UI_Catalogue_CounterTop_UI_Catalogue_ButtonBuy_K2Node_ComponentBoundEvent_1_On Clicked__DelegateSignature"
local HOOKS = {
    hire = CV_W .. ":" .. HIRE_EVT,
    fire = FOLDER_W .. ":" .. FIRE_EVT,
    job  = FOLDER_W .. ":Set Staff Job",
}
-- FStaff (CXXHeaderDump Staff.hpp).
local F = {
    name   = "Name_3_8A98C9844ED44E799022148DD2FEB3FE",
    about  = "Aboutme_6_8C6F9DA549C7DC2216B17A809D3B7EB4",
    movie  = "FavoriteMovie_15_7F62F1854D389FC3C3C9D58BA2710F8A",
    sr     = "SkillReturn_13_7FEF813241BE4F085D076EB3B3004D62",
    sc     = "SkillCheckout_14_42B673714489E8C35671BCA911793494",
    pay    = "Salaryperday_24_3EA43710410217A934721D8A9C95FC39",
    traits = "Gameplaytraits_29_044F073B4CAE1F7A9D4C7B9498790768",
    job    = "Job_49_3F2CB4954D93012507593486BA6D956D",
    photo  = "Photo_55_324EFCB84AA7B6008C5B5AB2AB9323FD",
}
-- The favourite movie's title, inside its Product_Structure (CounterTop @1705).
local MOVIE_NAME = { "BaseStructure_2_FBB12C464AE570CAFD12ED8506160683", "BoxData_25_B5A798DA4F509BDCCF4B189171C1DA10",
                     "ProductName_14_055828B1436E5AD27BFA95AF181099DE" }
-- Why a hire was refused: the game's own words (Hire Staff @1951, @2562, @3126).
local ERRORS = "/Game/VideoStore/localization/interface/ErrorPlayer.ErrorPlayer"
local REFUSALS = {
    first  = { key = "ErrorPlayer_StaffBook_FirstStaffNotUnlock",  level = 6,
               text = "Your first employee can be hired from store level 6." },
    second = { key = "ErrorPlayer_StaffBook_SecondStaffNotUnlock", level = 20,
               text = "A second employee can be hired from store level 20." },
    max    = { key = "ErrorPlayer_StaffBook_MaximumStaffReach",
               text = "The store has all the staff it can take." },
}

local SEP         = "\31"    -- between a person's fields (the channel escapes only % | = and newlines)
local SEND_EVERY  = 2.0
local RESEND      = 10.0
local RETRY_AFTER = 4.0
local SEEN_FOR    = 15.0
local MAX_PEOPLE  = 6

local stats = { sent = 0, hired = 0, fired = 0, jobs = 0, refused = 0, cardsDrawn = 0, traitsRead = 0 }

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

local function get(s, k)
    local v = nil
    if s ~= nil then pcall(function() v = s[k] end) end
    return v
end

local function textOf(v)
    local s = nil
    if v ~= nil then pcall(function() s = v:ToString() end) end
    return type(s) == "string" and s or ""
end

--- A machine's screen: the user widget on its "Widget" component.
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

--- A set of trait bytes, sorted.
local function traitsOf(set)
    local t = {}
    if set == nil then return t end
    pcall(function()
        set:ForEach(function(a, b)
            local e = b ~= nil and b or a
            pcall(function() e = e:get() end)
            e = tonumber(e)
            if e and #t < 8 then t[#t + 1] = math.floor(e) end
        end)
    end)
    table.sort(t)
    if #t > 0 then stats.traitsRead = stats.traitsRead + 1 end
    return t
end

--- One person in the book, as the cards show them.
local function person(s, employee)
    local r = { name = textOf(get(s, F.name)), pay = round(get(s, F.pay)), sr = round(get(s, F.sr)),
                sc = round(get(s, F.sc)), photo = nameOf(get(s, F.photo)) or "", traits = traitsOf(get(s, F.traits)) }
    if employee then
        r.job = round(get(s, F.job))
        r.about = textOf(get(s, F.about))
        local m = get(s, F.movie)
        for _, k in ipairs(MOVIE_NAME) do m = get(m, k) end
        r.movie = textOf(m)
    end
    return r
end

local function clean(s) return (tostring(s or ""):gsub(SEP, " ")) end

local function encode(r, employee)
    local parts = { clean(r.name), tostring(r.pay), tostring(r.sr), tostring(r.sc), clean(r.photo),
                    table.concat(r.traits, ",") }
    if employee then
        parts[#parts + 1] = tostring(r.job)
        parts[#parts + 1] = clean(r.about)
        parts[#parts + 1] = clean(r.movie)
    end
    return table.concat(parts, SEP)
end

local function decode(s, employee)
    if type(s) ~= "string" then return nil end
    local v = {}
    for part in (s .. SEP):gmatch("(.-)" .. SEP) do v[#v + 1] = part end
    local r = { name = v[1] or "", pay = tonumber(v[2]) or 0, sr = tonumber(v[3]) or 0, sc = tonumber(v[4]) or 0,
                photo = v[5] or "", traits = {} }
    for t in (v[6] or ""):gmatch("%d+") do r.traits[#r.traits + 1] = tonumber(t) end
    if employee then
        r.job, r.about, r.movie = tonumber(v[7]) or 0, v[8] or "", v[9] or ""
    end
    return r
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

local seen = {}            -- pc full name .. "#" .. number -> when
local lastSig, lastAt = nil, -1e9
local probePath = nil

local function gatherer()
    local gm = UE.GetGameMode()
    if not (UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C") then return nil, nil end
    local g = UE.TryGet(gm, "Actor Gatherer")
    return gm, UE.valid(g) and g or nil
end

local function lists(g)
    local market, director = UE.TryGet(g, "Market"), UE.TryGet(g, "AI Director")
    return UE.valid(market) and UE.TryGet(market, "Potential Staff of the Day") or nil,
           UE.valid(director) and UE.TryGet(director, "Staff Hired") or nil
end

local function hiredCount(g)
    local _, hired = lists(g)
    local n = 0
    if hired ~= nil then pcall(function() n = hired:GetArrayNum() end) end
    return tonumber(n) or 0
end

local function tell(pc, ok, text, extra)
    local f = { ok = ok and "1" or "0", t = text or "" }
    for k, v in pairs(extra or {}) do f[k] = v end
    Chan.sendTo(pc, "stfres", f)
    if not ok then stats.refused = stats.refused + 1 end
end

local function sendState(now)
    if (now - lastAt) < SEND_EVERY then return end
    local gm, g = gatherer()
    if not g then return end
    local applicants, hired = lists(g)
    local fields = { lv = (tonumber(UE.TryGet(gm, "Level")) or 0) >= FIRST_LEVEL and "1" or "0" }
    local na, ne = 0, 0
    eachOf(applicants, function(_, s)
        if na >= MAX_PEOPLE then return false end
        na = na + 1
        fields["a" .. na] = encode(person(s, false), false)
    end)
    eachOf(hired, function(_, s)
        if ne >= MAX_PEOPLE then return false end
        ne = ne + 1
        fields["e" .. ne] = encode(person(s, true), true)
    end)
    fields.na, fields.ne = tostring(na), tostring(ne)
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. fields[k] end
    local sig = table.concat(parts, "|")
    if sig == lastSig and (now - lastAt) < RESEND then return end
    if Chan.broadcast("stf", fields) > 0 then
        lastSig, lastAt = sig, now
        stats.sent = stats.sent + 1
    end
end

--- The host's copy of the book's screen that nobody sees. Made the way the
--- book makes its own, never put on screen: so it never constructs, and is
--- given the two things its Construct and the book's BeginPlay would.
local function probe(gm)
    local w = probePath and UE.findObject(probePath) or nil
    if not UE.valid(w) then
        w = nil
        local lib, cls = StaticFindObject(WIDGETS), StaticFindObject(BOOK_W)
        if not UE.valid(cls) then cls = UE.load(BOOK_W) end
        if not (UE.valid(lib) and UE.valid(cls)) then return nil end
        pcall(function() w = lib:Create(UE.GetWorld(), cls, UE.GetPlayerController()) end)
        if not UE.valid(w) then return nil end
        probePath = UE.pathOf(w)
    end
    UE.TrySet(w, "As Core Gamemode", gm)
    local book = UE.findFirst("StaffBook_C")
    if UE.alive(book) then UE.TrySet(w, "Staff Book Ref", book) end
    return w
end

local function payOf(card) return round(get(UE.TryGet(card, "Staff"), F.pay)) end

--- A card on the host's (unseen) page: the one at that place, if its pay is
--- the guest's - or else the only one on the page with that pay (the list
--- moved under the guest's click).
local function cardOn(w, page, boxName, index, pay)
    UE.TryCall(w, "Generate Container Page", page)
    local box = UE.TryGet(w, boxName)
    local n = childCount(box)
    local c = (index >= 1 and index <= n) and childAt(box, index - 1) or nil
    if c and payOf(c) == pay then return c end
    local found, count = nil, 0
    for i = 0, n - 1 do
        local x = childAt(box, i)
        if x and payOf(x) == pay then found, count = x, count + 1 end
    end
    return count == 1 and found or nil
end

local function asGuest(pc, fn) return require("guestinput").asGuest(pc, fn) end

local function hire(pc, index, pay)
    local gm, g = gatherer()
    local w = g and probe(gm) or nil
    if not w then return tell(pc, false, "The host's staff book is not ready.") end
    local card = cardOn(w, PAGE_HIRE, "Staff_WrapBox", index, pay)
    if not card then return tell(pc, false, "That applicant is not in the book any more.") end
    local who = textOf(get(UE.TryGet(card, "Staff"), F.name))
    local before = hiredCount(g)
    asGuest(pc, function() card[HIRE_EVT](card, UE.TryGet(card, "UI_Catalogue_ButtonHireStaff")) end)
    if hiredCount(g) > before then
        stats.hired = stats.hired + 1
        lastAt = -1e9
        Log.info("staff book: %s hired %s", UE.PlayerNameOf(pc) or "a guest", who ~= "" and who or "someone")
        return tell(pc, true, ("%s is hired."):format(who ~= "" and who or "They"), { k = "hire" })
    end
    -- The handler counted the store's staff places into the screen (@5-@818).
    local places = tonumber(UE.TryGet(w, "Maximum Staff Hired")) or 0
    local why = places == 0 and "first" or (places == 1 and "second" or "max")
    tell(pc, false, REFUSALS[why].text, { e = why })
end

local function fire(pc, index, pay)
    local gm, g = gatherer()
    local w = g and probe(gm) or nil
    if not w then return tell(pc, false, "The host's staff book is not ready.") end
    local card = cardOn(w, PAGE_STAFF, "Staff-Folder_WrapBox", index, pay)
    if not card then return tell(pc, false, "That employee is not in the book any more.") end
    local who = textOf(get(UE.TryGet(card, "Staff"), F.name))
    local before = hiredCount(g)
    asGuest(pc, function() card[FIRE_EVT](card, UE.TryGet(card, "UI_Catalogue_Fired")) end)
    if hiredCount(g) < before then
        stats.fired = stats.fired + 1
        lastAt = -1e9
        Log.info("staff book: %s let %s go", UE.PlayerNameOf(pc) or "a guest", who ~= "" and who or "someone")
        return tell(pc, true, ("%s has been let go."):format(who ~= "" and who or "They"))
    end
    -- AI Director "Remove Staff" needs the employee in the store (@0-@1314).
    tell(pc, false, "They can only be let go while they are in the store.")
end

local function setJob(pc, index, pay, job)
    local gm, g = gatherer()
    local w = g and probe(gm) or nil
    if not w then return tell(pc, false, "The host's staff book is not ready.") end
    local card = cardOn(w, PAGE_STAFF, "Staff-Folder_WrapBox", index, pay)
    if not card then return tell(pc, false, "That employee is not in the book any more.") end
    UE.TryCall(card, "Set Staff Job", job)
    local _, hired = lists(g)
    local now = nil
    eachOf(hired, function(i, s) if i == index then now = round(get(s, F.job)) return false end end)
    lastAt = -1e9
    if now == job then
        stats.jobs = stats.jobs + 1
        Log.info("staff book: %s gave an employee job %d", UE.PlayerNameOf(pc) or "a guest", job)
        return tell(pc, true, job == JOB_CHECKOUT and "They will work the register." or "They will work the returns.")
    end
    tell(pc, false, "The job did not change.")
end

--- Host: guest action 22 (guestinput.lua routes it here). X what, Y the
--- card's place in its list, Z its pay; numbered in Pitch.
function Staff.onGuest(pc, pawn, loc, rot)
    if not UE.IsServer() or not (UE.valid(pc) and loc) then return end
    local what, index, pay = round(loc.X), round(loc.Y), round(loc.Z)
    local now = os.clock()
    local key = pc:GetFullName() .. "#" .. round(rot and rot.Pitch)
    for k, t in pairs(seen) do if now - t > SEEN_FOR then seen[k] = nil end end
    if seen[key] then return end
    seen[key] = now
    if index < 1 or index > MAX_PEOPLE then return end
    if what == DO_HIRE then
        Safety.guard(OP_HOST, hire, pc, index, pay)
    elseif what == DO_FIRE then
        Safety.guard(OP_HOST, fire, pc, index, pay)
    elseif what == DO_RETURNS or what == DO_CHECKOUT then
        Safety.guard(OP_HOST, setJob, pc, index, pay, what == DO_CHECKOUT and JOB_CHECKOUT or JOB_RETURNS)
    end
end

function Staff.tickHost(now)
    if not UE.IsServer() or UE.IsStandalone() then return end
    if Chan.isReady() then sendState(now) end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local host = nil           -- guest: { lv, a = {...}, e = {...}, sig }
local hooked = {}
local nextHook, nextDraw = 0, 0
local clicks = {}
local pending = nil
local seq = 0
local drawn = {}           -- box name -> { sig, first, n }

local function hook(path, fn)
    local f = StaticFindObject(path)
    local addr = UE.valid(f) and addressOf(f) or nil
    if not addr or hooked[path] == addr then return end
    if pcall(function() RegisterHook(path, fn) end) then hooked[path] = addr end
end

local function hookAll(now)
    if now < nextHook then return end
    nextHook = now + 5
    local function take(what)
        return function(ctx, job)
            if not UE.IsClient() or #clicks >= 8 then return end
            local path, j = nil, nil
            pcall(function() path = UE.pathOf(ctx:get()) end)
            if job ~= nil then pcall(function() j = job:get() end) end
            local w = what
            if what == "job" then w = round(j) == JOB_CHECKOUT and DO_CHECKOUT or DO_RETURNS end
            if path then clicks[#clicks + 1] = { what = w, card = path } end
        end
    end
    hook(HOOKS.hire, take(DO_HIRE))
    hook(HOOKS.fire, take(DO_FIRE))
    hook(HOOKS.job, take("job"))
end

local function send(o)
    return Chan.sendAction(ACTION_STAFF, { X = o.x, Y = o.y, Z = o.z }, { Pitch = o.seq, Yaw = 0, Roll = 0 }) > 0
end

local function ask(x, y, z, note)
    if pending then
        require("hud").notice("One moment - the last one is still going through.", false, 2)
        return
    end
    seq = (seq % 80) + 1
    pending = { x = x, y = y, z = z, seq = seq, at = os.clock() }
    send(pending)
    if note then require("hud").notice(note, false, 1.5) end
end

local NOTES = { [DO_HIRE] = "Hiring...", [DO_FIRE] = "Letting them go...", [DO_RETURNS] = "Changing their job...",
                [DO_CHECKOUT] = "Changing their job..." }

local function takeClicks()
    while #clicks > 0 do
        local c = table.remove(clicks, 1)
        local card = UE.findObject(c.card)
        local parent, index = nil, nil
        if UE.valid(card) then pcall(function() parent = card:GetParent() end) end
        if UE.valid(parent) then pcall(function() index = parent:GetChildIndex(card) end) end
        index = tonumber(index)
        if index and index >= 0 then
            ask(c.what, index + 1, payOf(card), NOTES[c.what])
        else
            -- The page was drawn again under the click (the host's list changed).
            require("hud").notice("The book just changed - try again.", false, 2)
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

local function setText(block, s)
    if UE.valid(block) and type(s) == "string" then pcall(function() block:SetText(FText(s)) end) end
end

local function photo(name)
    if type(name) ~= "string" or not name:match("^T_UI_StaffBook_Staff%-%a+_%d+$") then return nil end
    return UE.load(DIR .. name .. "." .. name)
end

local function create(w, path)
    local lib, cls = StaticFindObject(WIDGETS), StaticFindObject(path)
    if not UE.valid(cls) then cls = UE.load(path) end
    if not (UE.valid(lib) and UE.valid(cls)) then return nil end
    local card = nil
    pcall(function() card = lib:Create(w, cls, UE.GetPlayerController()) end)
    return UE.valid(card) and card or nil
end

--- One card, the game's own: its numbers in its Staff before it is shown
--- (its Construct writes pay and skills from them), the rest after.
local function card(w, r, employee)
    local c = create(w, employee and FOLDER_W or CV_W)
    if not c then return nil end
    local s = UE.TryGet(c, "Staff")
    if s == nil then return nil end
    pcall(function() s[F.pay] = r.pay end)
    pcall(function() s[F.sr] = r.sr end)
    pcall(function() s[F.sc] = r.sc end)
    if employee then pcall(function() s[F.job] = r.job end) end
    local tex = photo(r.photo)
    if tex then pcall(function() s[F.photo] = tex end) end
    return c
end

local function dress(w, c, r, employee)
    setText(UE.TryGet(c, "Text_Name"), r.name)
    local box = UE.TryGet(c, "VerticalBox_GameplayTraits")
    if UE.valid(box) and childCount(box) == 0 then
        for _, t in ipairs(r.traits) do
            local tw = create(w, TRAIT_W)
            if tw then
                UE.TrySet(tw, "Gameplay traits", t)
                pcall(function() box:AddChild(tw) end)
            end
        end
    end
    if employee then
        setText(UE.TryGet(c, "Text_AboutMe"), r.about)
        setText(UE.TryGet(c, "Text_FavoriteMovie"), r.movie)
    else
        UE.TryCall(c, "Unlock Toggle", host.lv, FIRST_LEVEL)
    end
end

--- A page's box, drawn from the host's list - again when the host's list
--- changed or the guest's game emptied the box (every tab switch does, @40).
local function fill(w, boxName, list, employee)
    local box = UE.TryGet(w, boxName)
    if not UE.valid(box) then return end
    local n = childCount(box)
    local first = n > 0 and addressOf(childAt(box, 0)) or nil
    local d = drawn[boxName]
    if d and d.sig == host.sig and d.first == first and d.n == n then return end
    pcall(function() box:ClearChildren() end)
    for _, r in ipairs(list) do
        local c = card(w, r, employee)
        if c then
            pcall(function() box:AddChild(c) end)
            dress(w, c, r, employee)
            stats.cardsDrawn = stats.cardsDrawn + 1
        end
    end
    n = childCount(box)
    drawn[boxName] = { sig = host.sig, first = n > 0 and addressOf(childAt(box, 0)) or nil, n = n }
end

local function draw()
    local w = widgetOf(UE.findFirst("StaffBook_C"))
    if not w then return end
    local page = round(UE.TryGet(w, "Current Widget Switcher"))
    if page == PAGE_HIRE then
        fill(w, "Staff_WrapBox", host.a, false)
    elseif page == PAGE_STAFF then
        fill(w, "Staff-Folder_WrapBox", host.e, true)
    end
end

function Staff.tickGuest(now)
    if not UE.IsClient() then return end
    hookAll(now)
    takeClicks()
    if host and now >= nextDraw and require("guestinput").machineClass() == "StaffBook_C" then
        nextDraw = now + 0.25
        Safety.guard(OP_GUEST, draw)
    end
end

local function onState(f)
    if not UE.IsClient() then return end
    local h = { lv = f.lv == "1", a = {}, e = {} }
    for i = 1, math.min(tonumber(f.na) or 0, MAX_PEOPLE) do h.a[#h.a + 1] = decode(f["a" .. i], false) end
    for i = 1, math.min(tonumber(f.ne) or 0, MAX_PEOPLE) do h.e[#h.e + 1] = decode(f["e" .. i], true) end
    local parts = { f.lv or "" }
    for i = 1, MAX_PEOPLE do parts[#parts + 1] = (f["a" .. i] or "") .. "/" .. (f["e" .. i] or "") end
    h.sig = table.concat(parts, "|")
    host = h
end

--- The game's own words for a refused hire, from the guest's string table.
local function refusal(why)
    local r = REFUSALS[why]
    if not r then return nil end
    local s = nil
    pcall(function()
        local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        s = ktl:TextFromStringTable(FName(ERRORS), r.key):ToString()
    end)
    if type(s) ~= "string" or s == "" or s:find(r.key, 1, true) then return r.text end
    return (s:gsub("{level}", tostring(r.level or "")))
end

local function playHire()
    local cue = UE.load(HIRE_SOUND)
    local gs = UE.GetGameplayStatics()
    if UE.valid(cue) and UE.valid(gs) then
        pcall(function() gs:PlaySound2D(UE.GetWorld(), cue, 1.0, 1.0, 0.0, nil, nil, true) end)
    end
end

local function onResult(f)
    if not UE.IsClient() then return end
    local ok = f.ok == "1"
    pending = nil
    if ok and f.k == "hire" then playHire() end
    local text = (f.e and refusal(f.e)) or (f.t ~= "" and f.t) or (ok and "Done." or "That did not go through.")
    require("hud").notice(text, not ok, 3)
end

function Staff.report()
    local h = host and ("; the host's book: %d applicant(s), %d employee(s)"):format(#host.a, #host.e) or ""
    return { ("Staff book: host sent %d, %d hired, %d let go, %d job change(s), %d refused, traits read %d " ..
              "time(s); guest drew %d card(s)%s%s"):format(stats.sent, stats.hired, stats.fired, stats.jobs,
              stats.refused, stats.traitsRead, stats.cardsDrawn, h, pending and ", one waiting" or "") }
end

function Staff.reset()
    seen, host, clicks, pending, drawn = {}, nil, {}, nil, {}
    lastSig, lastAt = nil, -1e9
    hooked = {}
end

function Staff.init()
    Chan.on("stf", function(f) Log.guard("the host's staff book", onState, f) end)
    Chan.on("stfres", function(f) Log.guard("a staff book answer", onResult, f) end)
end

-- For the tests.
Staff._stats = function() return stats end
Staff._decode, Staff._encode = decode, encode
Staff._F, Staff._MOVIE, Staff._HOOKS = F, MOVIE_NAME, HOOKS
Staff._paths = { book = BOOK_W, cv = CV_W, folder = FOLDER_W, trait = TRAIT_W, dir = DIR, hire = HIRE_EVT, fire = FIRE_EVT }

return Staff
