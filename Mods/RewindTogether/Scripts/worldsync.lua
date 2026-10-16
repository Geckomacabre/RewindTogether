--[[
    Rewind Together - the store's look, host to guest

    sync.lua mirrors numbers (money, the clock). This mirrors the handful of
    LEVEL-PLACED actors whose appearance comes from the host's save rather
    than from replication:

      StoreName_C        the sign over the door: text, colour, size
      StoreExpansion_C   which expansions are bought - a locked one draws its
                         walls in yellow-and-black hazard stripes

    MEASURED in 1.7.0 on two instances: a guest sees the host's shelves and
    stock (those replicate), but the sign reads "RETRO REWIND" and every
    expansion the host has bought still stands there striped. Both actors are
    part of the level, so they exist on the guest from the moment it loads -
    with the guest's defaults, because the save that configures them is the
    host's. They are matched across machines by actor name, which is the same
    on both because it comes from the same level asset.

    The hazard stripes PROJECT.md 10 spent three versions on are these walls.
    Not an OverlayMaterial (1.7.0's guest log: "no overlay materials on this
    machine"), not a build mode: unbought store expansions.
]]

local Log    = require("log")
local UE     = require("ue")
local Chan   = require("rpcchan")
local Safety = require("safety")

local World = {}

local PUSH_EVERY = 2.0
local lastPush = 0
local lastSent = nil
local applied = { name = nil, unlocked = {}, made = {} }
local announced = false

--[[
    MEASURED (live, 16 Oct 2026): a guest clicking the host's popcorn machine
    got nothing. Its own copy had Unlocked and Bought false (the host's: both
    true), and Interaction stops there (bp/PopcornMachine.txt @49). Those
    flags come from the save, which only the host's GameMode loads ("Unlock
    Machine" from the save event, @3262). The slushie machine and the
    sidewalk sign differed the same way.

    Each of these has "Make Machine Usable For Player"(Instant), the game's
    own "now it's bought": the flags, the power, the "out of order" or
    covered look. The host sends which of them are bought, by level name
    (placed in the level, so both copies have the same names), and a guest
    runs that on its copy.
]]
local BUYABLE = {
    "PopcornMachine_C", "SlushMachine_C", "CottonCandyMachine_C",
    "ConsoleRental_Mat_C", "ConsoleRental_Station_C", "CustomMovieStation_C",
    "RepairStation_C", "SidewalkSign_C",
}

local function nameOf(actor)
    local ok, n = pcall(function() return actor:GetFName():ToString() end)
    return ok and n or nil
end

local function textOf(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return UE.ToStr(v)
end

local function colorString(c)
    if not c then return nil end
    local ok, s = pcall(function()
        -- Case-insensitive: struct fields come back in the FName table's casing.
        return ("%.4f,%.4f,%.4f,%.4f"):format(UE.field(c, "R"), UE.field(c, "G"),
                                              UE.field(c, "B"), UE.field(c, "A") or 1.0)
    end)
    return ok and s or nil
end

--------------------------------------------------------------------------
-- Host
--------------------------------------------------------------------------

--- The store's name sign as it stands: its name, colour, size, the two neon
--- colours and the font (one of four, named: StoreName.txt @4835-@5108).
function World.signFields(sign, out)
    out = out or {}
    out.n = textOf(UE.TryGet(sign, "Name"))
    out.c = colorString(UE.TryGet(sign, "Color"))
    local size = UE.TryGet(sign, "Size")
    if type(size) == "number" then out.s = ("%.3f"):format(size) end
    -- The neon is not the text colour: measured blue on the host and the
    -- guest's default orange/pink with Name and Color already mirrored.
    out.fc = colorString(UE.TryGet(sign, "Front Store Light Color"))
    out.sc = colorString(UE.TryGet(sign, "Sign Store Light Color"))
    local font = UE.TryGet(sign, "Font")
    if UE.valid(font) then out.ft = nameOf(font) end
    return out
end

-- The four fonts the sign's editor offers (UI_StoreName "Set Font of Store Name").
World.FONTS = { roboto = "/Engine/EngineFonts/Roboto.Roboto",
                ["inter-v"] = "/Game/VideoStore/core/widget/font/Inter-V.Inter-V",
                reglo = "/Game/VideoStore/core/widget/font/Reglo.Reglo",
                notosanssc = "/Game/VideoStore/core/widget/font/NotoSansSC.NotoSansSC" }

--- A font by its name, any casing (an FName's casing is whoever named it first).
function World.font(name)
    local path = type(name) == "string" and World.FONTS[name:lower()] or nil
    if not path then return nil end
    local f = StaticFindObject(path)
    if not UE.valid(f) and LoadAsset then pcall(function() f = LoadAsset(path) end) end
    return UE.valid(f) and f or nil
end

local function collect()
    local out = {}

    local sign = UE.findFirst("StoreName_C")
    if UE.alive(sign) then World.signFields(sign, out) end

    local unlocked = {}
    for _, e in ipairs(UE.findAll("StoreExpansion_C") or {}) do
        if UE.alive(e) and UE.TryGet(e, "Unlocked") == true then
            local n = nameOf(e)
            if n then unlocked[#unlocked + 1] = n end
        end
    end
    table.sort(unlocked)
    out.x = table.concat(unlocked, ";")

    -- Machines the host has bought: see applyMachines.
    local bought = {}
    for _, cls in ipairs(BUYABLE) do
        for _, m in ipairs(UE.findAll(cls) or {}) do
            if UE.alive(m) and UE.TryGet(m, "Bought") == true then
                local n = nameOf(m)
                if n then bought[#bought + 1] = n end
            end
        end
    end
    table.sort(bought)
    out.mb = table.concat(bought, ";")

    -- The season sub-level (snow, bare trees, decorations) - see applySeason.
    local weather = UE.findFirst("WeatherSystem_C")
    if UE.alive(weather) then
        pcall(function()
            local lv = weather["Current level Season Loaded"]
            if lv and lv:IsValid() then out.l = lv.PackageNameToLoad:ToString() end
        end)
    end
    return out
end

--------------------------------------------------------------------------
-- The sky, the sun and the snow: copied as RESULTS, not recomputed
--------------------------------------------------------------------------
--[[
    REPORTED in 1.7.0: on the guest the store is "colored differently and
    seems to be a different time of day". With the clock, season level and
    weather numbers already mirrored, what was still different:

      * Global_Weather, the material parameter collection every outdoor
        material reads (Snow, Wet, Season Foliage Color, Sky - Cloud Density,
        Sky - Night, Sky - Sunset, Sky Intensity, Sky Tint), is written by
        WeatherSystem functions a guest never runs;
      * the fill lights and the fake skylight register themselves with the
        WeatherSystem through the GameMode, so on a guest its "Fake Skylight"
        and "Directional Fills" lists are empty (host 1 and 6, guest 0 and 0,
        measured) and nothing ever dims them.

    Rather than reproduce the Blueprint's curves and lists, the host sends
    what they PRODUCED - every light's intensity and colour, the sun's angle,
    the fog, and the collection's values - and the guest applies those to the
    same level actors, found by full path (actor names repeat across
    sub-levels: there is a DirectionalFill_C_1 in two of them).
]]

local MPC_PATH   = "/Game/VideoStore/asset/outside/Global_Weather.Global_Weather"
local MPC_SCALARS = { "Snow", "Wet", "Sky - Cloud Density", "Sky - Night", "Sky - Sunset", "Sky Intensity" }
local MPC_VECTORS = { "Season Foliage Color", "Sky Tint" }
local SKY_EVERY  = 2.0
local lastSky    = 0

local function kml() return StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end
local function lightBaseClass() return StaticFindObject("/Script/Engine.LightComponentBase") end

local function objectPath(o)
    local ok, full = pcall(function() return o:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$")
end

local function componentsOf(actor, cls)
    local out = {}
    if not (UE.valid(actor) and UE.valid(cls)) then return out end
    pcall(function()
        local arr = actor:K2_GetComponentsByClass(cls)
        for i = 1, #arr do
            local c = arr[i]
            if type(c) == "userdata" and c.get then
                local ok, v = pcall(function() return c:get() end)
                if ok then c = v end
            end
            if UE.valid(c) then out[#out + 1] = c end
        end
    end)
    return out
end

local function colorBytes(c)
    local r, g, b = UE.field(c, "R"), UE.field(c, "G"), UE.field(c, "B")
    if type(r) ~= "number" then return nil end
    return ("%d,%d,%d"):format(r, g or 0, b or 0)
end

local function srgbToLinear(byte)
    local c = byte / 255
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

--- Host: read everything the weather produced.
local function collectSky()
    local out = {}
    local world, lib = UE.GetWorld(), kml()
    local mpc = StaticFindObject(MPC_PATH)
    if UE.valid(world) and UE.valid(lib) and UE.valid(mpc) then
        local parts = {}
        for _, n in ipairs(MPC_SCALARS) do
            local ok, v = pcall(function() return lib:GetScalarParameterValue(world, mpc, FName(n)) end)
            if ok and type(v) == "number" then parts[#parts + 1] = ("%s=%.4f"):format(n, v) end
        end
        for _, n in ipairs(MPC_VECTORS) do
            local ok, v = pcall(function() return lib:GetVectorParameterValue(world, mpc, FName(n)) end)
            if ok and v then
                parts[#parts + 1] = ("%s=%.4f,%.4f,%.4f,%.4f"):format(n, UE.field(v, "R") or 0,
                    UE.field(v, "G") or 0, UE.field(v, "B") or 0, UE.field(v, "A") or 1)
            end
        end
        out.p = table.concat(parts, ";")
    end

    local weather = UE.findFirst("WeatherSystem_C")
    if not UE.alive(weather) then return out end

    -- The time of day, as the weather names it (morning, day, evening, night).
    local dt = tonumber(UE.TryGet(weather, "DayTime"))
    if dt then out.dt = tostring(math.floor(dt)) end

    -- Every light the weather adjusts, by full path + component name.
    local actors = {}
    for _, k in ipairs({ "ref Directional", "ref Sky Light" }) do
        local a = UE.TryGet(weather, k)
        if UE.valid(a) then actors[#actors + 1] = a end
    end
    for _, k in ipairs({ "Fake Skylight", "Directional Fills" }) do
        pcall(function()
            local arr = weather[k]
            for i = 1, #arr do
                local a = arr[i]
                if type(a) == "userdata" and a.get then
                    local ok, v = pcall(function() return a:get() end)
                    if ok then a = v end
                end
                if UE.valid(a) then actors[#actors + 1] = a end
            end
        end)
    end
    local lights, cls = {}, lightBaseClass()
    for _, a in ipairs(actors) do
        local path = objectPath(a)
        if path then
            for _, c in ipairs(componentsOf(a, cls)) do
                local name = c:GetFName():ToString()
                local i = UE.TryGet(c, "Intensity")
                local col = colorBytes(UE.TryGet(c, "LightColor"))
                if type(i) == "number" and col then
                    lights[#lights + 1] = ("%s#%s=%.4f,%s"):format(path, name, i, col)
                end
            end
        end
    end
    out.g = table.concat(lights, ";")

    local sun = UE.TryGet(weather, "ref Directional")
    if UE.valid(sun) then
        pcall(function()
            local r = UE.rot(sun:K2_GetActorRotation())
            if r then out.r = ("%.3f,%.3f,%.3f"):format(r.Pitch, r.Yaw, r.Roll) end
        end)
    end
    local fog = UE.TryGet(weather, "ref Height Fog")
    if UE.valid(fog) then
        pcall(function()
            local c = fog.Component
            local lum = c.FogInscatteringLuminance
            out.f = ("%.6f,%.4f,%.4f,%.4f"):format(c.FogDensity, UE.field(lum, "R") or 0,
                UE.field(lum, "G") or 0, UE.field(lum, "B") or 0)
        end)
    end
    return out
end

local skyApplied = {}

--[[
    THE TIME OF DAY'S LISTENERS. The lamps' lights (Light_DayTimeToggle_C),
    the street lights (Outside_Light_Base_C), the light effects
    (VFX_DayTimeToggle_C) and the ambience (Audio_TimeOfDay_C,
    Audio_AmbienceSystem_C) find the weather through the GameMode ("Timer Get
    Gatherer Event", bp/Light_DayTimeToggle.txt @852) and bind to its "Day
    Time is Update" - which on a guest never happens, so they stay as the
    level was saved whatever the time. Each one's own handler decides from
    its own list (@62: on for the times in "Enable on Day Time"), so the
    guest calls them with the host's time of day when it changes.
]]
local DAYTIME_LISTENERS = {
    { "Light_DayTimeToggle_C",  "New Day Time Event" },
    { "VFX_DayTimeToggle_C",    "New Day Time Event" },
    { "Outside_Light_Base_C",   "New Day Time Event" },
    { "Audio_TimeOfDay_C",      "Weather Day Time is Update Event" },
    { "Audio_AmbienceSystem_C", "Day Time is Update_Event" },
}

local function applyDayTime(dt)
    local told = 0
    for _, l in ipairs(DAYTIME_LISTENERS) do
        for _, o in ipairs(UE.findAll(l[1]) or {}) do
            if UE.valid(o) and pcall(function() o[l[2]](o, dt) end) then told = told + 1 end
        end
    end
    Log.info("world: time of day %d - %d light(s), effect(s) and sound(s) told", dt, told)
    return told
end

local function setOnce(key, value, fn)
    if skyApplied[key] == value then return end
    if pcall(fn) then skyApplied[key] = value end
end

local function applySky(fields)
    local world, lib = UE.GetWorld(), kml()
    local mpc = StaticFindObject(MPC_PATH)
    if type(fields.p) == "string" and UE.valid(world) and UE.valid(lib) and UE.valid(mpc) then
        for name, v in fields.p:gmatch("([^=;]+)=([^;]+)") do
            local r, g, b, a = v:match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
            if r then
                setOnce("p:" .. name, v, function()
                    lib:SetVectorParameterValue(world, mpc, FName(name),
                        { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) })
                end)
            elseif tonumber(v) then
                setOnce("p:" .. name, v, function()
                    lib:SetScalarParameterValue(world, mpc, FName(name), tonumber(v))
                end)
            end
        end
    end

    if type(fields.g) == "string" then
        local cls = lightBaseClass()
        for path, comp, i, r, g, b in fields.g:gmatch("([^#;]+)#([^=;]+)=([%d%.%-]+),(%d+),(%d+),(%d+)") do
            if path:match("^/Game/[%w_/%.:%-]+$") then
                local key = "g:" .. path .. "#" .. comp
                local value = i .. "," .. r .. "," .. g .. "," .. b
                if skyApplied[key] ~= value then
                    local actor = StaticFindObject(path)
                    for _, c in ipairs(componentsOf(actor, cls)) do
                        if c:GetFName():ToString() == comp then
                            setOnce(key, value, function()
                                c:SetIntensity(tonumber(i))
                                c:SetLightColor({ R = srgbToLinear(tonumber(r)), G = srgbToLinear(tonumber(g)),
                                                  B = srgbToLinear(tonumber(b)), A = 1.0 }, true)
                            end)
                        end
                    end
                end
            end
        end
    end

    local weather = UE.findFirst("WeatherSystem_C")
    if UE.alive(weather) and type(fields.r) == "string" then
        local p, y, rr = fields.r:match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
        local sun = UE.TryGet(weather, "ref Directional")
        if p and UE.valid(sun) then
            setOnce("sun", fields.r, function()
                -- UE.rotArg: as { Pitch = .. } the engine read pitch 0 and the
                -- guest's sun sat on the horizon (ue.lua).
                sun:K2_SetActorRotation(UE.rotArg({ Pitch = tonumber(p), Yaw = tonumber(y),
                                                    Roll = tonumber(rr) }), false)
            end)
        end
    end
    -- Once per change: a component list is an object walk (ue.lua).
    local dt = tonumber(fields.dt)
    if dt and skyApplied.dayTime ~= dt then
        skyApplied.dayTime = dt
        applyDayTime(math.floor(dt))
    end
    if UE.alive(weather) and type(fields.f) == "string" then
        local d, r, g, b = fields.f:match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
        local fog = UE.TryGet(weather, "ref Height Fog")
        if d and UE.valid(fog) then
            setOnce("fog", fields.f, function()
                local c = fog.Component
                c:SetFogDensity(tonumber(d))
                c:SetFogInscatteringColor({ R = tonumber(r), G = tonumber(g), B = tonumber(b), A = 1.0 })
            end)
        end
    end
end

function World.tickHost(now)
    if not UE.IsServer() or not Chan.isReady() then return end
    if now - lastSky >= SKY_EVERY then
        lastSky = now
        local sky = collectSky()
        if next(sky) then Chan.broadcast("sky", sky) end
    end
    if now - lastPush < PUSH_EVERY then return end
    lastPush = now

    local state = collect()
    -- Re-sent every few seconds even when unchanged: a guest who joined a
    -- second ago, or whose own GameMode has just reset the store, needs it.
    Chan.broadcast("world", state)

    local key = (state.n or "") .. "|" .. state.x .. "|" .. state.mb
    if key ~= lastSent then
        lastSent = key
        local count = select(2, state.x:gsub("[^;]+", ""))
        local machines = select(2, state.mb:gsub("[^;]+", ""))
        Log.info("store look: sign \"%s\", %d expansion(s) and %d machine(s) bought - mirrored to guests",
                 tostring(state.n), count, machines)
    end
end

--------------------------------------------------------------------------
-- Guest
--------------------------------------------------------------------------

local signLights = nil
local signMaterialsMade = false
local signLightsAt = nil
local SIGN_SETTLE = 30.0

local function applySignLights(sign, fields)
    local key = tostring(fields.fc) .. "|" .. tostring(fields.sc)
    if key == signLights then
        -- MEASURED in 1.7.0: applied in the second the guest joined, the neon
        -- stayed red with the right colours set; the same two calls a minute
        -- later turned it blue. So for a while after, every "world" message
        -- (one per 2 s) runs them again.
        if signLightsAt and (os.clock() - signLightsAt) < SIGN_SETTLE then
            UE.TryCall(sign, "Update Materials for Lights")
            UE.TryCall(sign, "Update for Lights")
        end
        return
    end
    local function color(s)
        local r, g, b, a = (s or ""):match("([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)")
        if r then return { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) } end
    end
    local front, signC = color(fields.fc), color(fields.sc)
    if front then UE.TrySet(sign, "Front Store Light Color", front) end
    if signC then UE.TrySet(sign, "Sign Store Light Color", signC) end
    if front or signC then
        -- The neon's dynamic materials are made by the sign's load path, which
        -- a guest never runs: with the colours already mirrored the guest's
        -- neon stayed red until these ran (measured; blue right after). Once a
        -- session - each call makes new material instances.
        if not signMaterialsMade then
            signMaterialsMade = true
            UE.TryCall(sign, "Create Material Instance for Meshes")
            UE.TryCall(sign, "Create Material Instance for Title sign")
        end
        UE.TryCall(sign, "Update Materials for Lights")
        UE.TryCall(sign, "Update for Lights")
        signLights = key
        signLightsAt = os.clock()
    end
end

local function applySign(fields)
    if not fields.n then return end
    local sign = UE.findFirst("StoreName_C")
    if not UE.alive(sign) then return end
    -- A guest renaming the store (uimachines.lua): its own editor's sign
    -- stands until the host's agrees.
    local UIM = require("uimachines")
    UIM.noteHostSign(fields)
    if UIM.holdSign() then return end
    applySignLights(sign, fields)
    if fields.ft and nameOf(UE.TryGet(sign, "Font") or {}) ~= fields.ft then
        local f = World.font(fields.ft)
        if f and UE.TrySet(sign, "Font", f) then UE.TryCall(sign, "Set StoreName Visual") end
    end
    -- Compared with what the sign SAYS, not with what was last written: a
    -- local GameMode loading its own save puts its own name back.
    if textOf(UE.TryGet(sign, "Name")) == fields.n then return end

    -- UE.setText: a plain FText write runs 8 bytes past Name into Color (ue.lua);
    -- Color was rewritten right after, which hid it.
    local ok = UE.setText(sign, "Name", fields.n)
    if fields.c then
        local r, g, b, a = fields.c:match("([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)")
        if r then
            UE.TrySet(sign, "Color", { R = tonumber(r), G = tonumber(g),
                                       B = tonumber(b), A = tonumber(a) })
        end
    end
    if tonumber(fields.s) then UE.TrySet(sign, "Size", tonumber(fields.s)) end
    UE.TryCall(sign, "Set StoreName Visual")
    UE.TryCall(sign, "Update Materials for Lights")
    UE.TryCall(sign, "Update for Lights")

    if applied.name ~= fields.n then
        applied.name = fields.n
        Log.info("store sign: %s \"%s\"", ok and "now reads" or "could not be set to", fields.n)
    end
end

local function applyExpansions(fields)
    if not fields.x then return end
    local want = {}
    for n in fields.x:gmatch("[^;]+") do want[n] = true end

    local opened = 0
    for _, e in ipairs(UE.findAll("StoreExpansion_C") or {}) do
        if UE.alive(e) then
            local n = nameOf(e)
            if n and want[n] and UE.TryGet(e, "Unlocked") ~= true then
                -- Instant: no wall-removal animation for something the host
                -- did days ago.
                if UE.TryCall(e, "Unlock Expansion", true) then opened = opened + 1 end
                applied.unlocked[n] = true
            end
        end
    end
    if opened > 0 then
        Log.info("store expansions: opened %d the host has bought - the hazard " ..
                 "stripes there should be gone", opened)
    end
end

local function applyMachines(fields)
    if not fields.mb then return end
    local want = {}
    for n in fields.mb:gmatch("[^;]+") do want[n] = true end

    local made = {}
    for _, cls in ipairs(BUYABLE) do
        for _, m in ipairs(UE.findAll(cls) or {}) do
            local n = UE.alive(m) and nameOf(m) or nil
            -- Three tries each: a machine that will not take it is not
            -- called every two seconds for the rest of the session.
            if n and want[n] and UE.TryGet(m, "Bought") ~= true and (applied.made[n] or 0) < 3 then
                applied.made[n] = (applied.made[n] or 0) + 1
                if UE.TryCall(m, "Make Machine Usable For Player", true) then made[#made + 1] = n end
            end
        end
    end
    if #made > 0 then
        Log.info("machines: %s bought, as on the host", table.concat(made, ", "))
    end
end

--[[
    The season sub-level. The host's GameMode streams in
    /Game/VideoStore/asset/level/Season/L_Store01_Season-<Season> as a level
    instance at load; a guest has no GameMode, so it never does - which is the
    "different colours, different time of day" the user saw in 1.7.0: no snow
    on the ground, no bare trees, a different fog and sky.

    The guest's own WeatherSystem has "Load Level for Season"(TSoftObjectPtr
    <UWorld>), which is the game's own code for exactly this. Getting a soft
    pointer into it took three measured tries:
      * a Lua string for the TSoftObjectPtr parameter is a NATIVE CRASH;
      * LevelStreamingDynamic::LoadLevelInstance cannot be called at all -
        UE4SS 3.0.1 never advances past its bool& out-parameter;
      * KismetSystemLibrary MakeSoftObjectPath -> Conv_SoftObjPathToSoftObjRef
        yields a real TSoftObjectPtr userdata, and that one works (season
        level loaded on the guest, measured).
]]
local seasonTried = {}
local SEASON_OP = "loading the host's season scenery on a guest"

local function applySeason(fields)
    local pkg = fields.l
    if type(pkg) ~= "string" or pkg == "" or seasonTried[pkg] then return end
    -- The host's string ends up as an asset path: only this game's own season
    -- levels, only path characters.
    if not pkg:match("^/Game/VideoStore/asset/level/[%w_/%-]+$") then return end

    local weather = UE.findFirst("WeatherSystem_C")
    if not UE.alive(weather) then return end
    local current = nil
    pcall(function()
        local lv = weather["Current level Season Loaded"]
        if lv and lv:IsValid() then current = lv.PackageNameToLoad:ToString() end
    end)
    if current == pkg then seasonTried[pkg] = true return end

    seasonTried[pkg] = true
    local ksl = UE.GetKismetSystemLibrary()
    if not UE.valid(ksl) then return end
    local asset = pkg:match("([^/]+)$")
    local ran, ok = Safety.guard(SEASON_OP, function()
        local ref = ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(pkg .. "." .. asset))
        return (pcall(function() weather["Load Level for Season"](weather, ref) end))
    end)
    if ran and ok then
        Log.info("season scenery: loading %s like the host has", asset)
    else
        Log.warn("season scenery: could not load %s - snow and trees may differ " ..
                 "from the host's", asset)
    end
end

local function onWorld(fields)
    if UE.IsServer() then return end
    applySign(fields)
    applyExpansions(fields)
    applyMachines(fields)
    applySeason(fields)
    if not announced then
        announced = true
        Log.info("store look: receiving the host's sign and expansions")
    end
end

--------------------------------------------------------------------------
-- Guest: the yellow-and-black hazard stripes, finally
--------------------------------------------------------------------------
--[[
    FOUND in 1.7.0, after five versions of theories (replicated CDOs, an
    OverlayMaterial, unbought expansions): the stripes are NavCollisionZone_C
    volumes drawn with M_GhostMode_NavBlocker - the "you cannot place things
    here" overlay of build mode. 138 of them in the store and street.

    The game hides them when Core_Gamemode_C broadcasts "Toggle Ghost Mode
    Dispatcher"(false) at load. A guest has no GameMode, so nothing ever tells
    them build mode is off and they stay drawn. Each zone has its own
    "Toggle Ghost Mode Blockers"(bool); calling it with false on the guest
    clears every stripe (measured: 138 zones, 138 toggled, screenshot clean).

    Zones arrive over replication as well as with the level, so this repeats
    when the count changes and every so often regardless.
]]
local lastBlockers, lastBlockerCount, lastBlockerCheck = 0, -1, -math.huge
local BLOCKER_EVERY = 15.0
local BLOCKER_CHECK_EVERY = 2.0   -- counting them means listing them (ue.lua)
local blockersReported = false

--[[
    THE TELEVISIONS. A TV shows the movie of the MoviePlayer_C on its channel:
    "Try to Get Movie Player on the Correct Channel" finds it in the GameMode's
    Actor Gatherer (bp/BP_Television_BASE.txt @5) and tries again every second
    when it cannot - on a guest, forever. The movie players themselves never
    start there either: their BeginPlay registers with the gatherer first and
    only then makes the screen's material and loads a clip (MoviePlayer @1296).
    So on a guest every TV stayed dark. The guest starts its own movie players
    the way their BeginPlay would, and gives each TV its channel's player the
    way the TV's own function does (@683-@1016: its screen material, the
    volume, the sound). The clip is the guest's own pick of the channel.
]]
local TV_EVERY = 5.0
local tvNext = 0
local playersStarted = {}   -- movie player full name -> true

local function televisions(now)
    if now < tvNext then return end
    tvNext = now + TV_EVERY
    local players = UE.findAll("MoviePlayer_C") or {}
    if #players == 0 then return end
    for _, mp in ipairs(players) do
        local name = UE.alive(mp) and mp:GetFullName() or nil
        if name and not playersStarted[name] and not UE.valid(UE.TryGet(mp, "Dynamic Mat Instance for TV Screen")) then
            playersStarted[name] = true
            UE.TryCall(mp, "Create Material for TV")
            UE.TryCall(mp, "Load a new clip")
            Log.info("televisions: started the movie player for channel %s", tostring(UE.TryGet(mp, "TV Channel")))
        end
    end
    for _, tv in ipairs(UE.findAll("BP_Television_BASE_C") or {}) do
        if UE.alive(tv) and not UE.valid(UE.TryGet(tv, "Movie Player ref")) then
            local channel = UE.TryGet(tv, "TV Channel")
            for _, mp in ipairs(players) do
                if UE.alive(mp) and UE.TryGet(mp, "TV Channel") == channel and UE.TryGet(mp, "Movie is Ready") == true then
                    local mat, mesh = UE.TryGet(mp, "Dynamic Mat Instance for TV Screen"), UE.TryGet(tv, "Mesh")
                    if UE.valid(mat) and UE.valid(mesh) and pcall(function() mesh:SetMaterial(1, mat) end) then
                        UE.TrySet(tv, "Movie Player ref", mp)
                        UE.TryCall(tv, "Set Audio Volume", tonumber(UE.TryGet(tv, "TV Audio Volume")) or 1.0)
                        UE.TryCall(tv, "Volume Visiblity", false)
                        UE.TryCall(tv, "Set Audio Of Movie")
                    end
                    break
                end
            end
        end
    end
end

function World.guestTick(now, cfg)
    if not UE.IsClient() then return end
    Log.guard("televisions", televisions, now)
    if cfg and cfg.ClearBuildModeOverlay == false then return end
    if (now - lastBlockerCheck) < BLOCKER_CHECK_EVERY then return end
    lastBlockerCheck = now
    local zones = UE.findAll("NavCollisionZone_C") or {}
    if #zones == lastBlockerCount and (now - lastBlockers) < BLOCKER_EVERY then return end
    lastBlockers, lastBlockerCount = now, #zones

    local done = 0
    for _, z in ipairs(zones) do
        if UE.alive(z) and UE.TryCall(z, "Toggle Ghost Mode Blockers", false) then
            done = done + 1
        end
    end
    if not blockersReported and done > 0 then
        blockersReported = true
        Log.info("build-mode stripes: hid %d placement blocker(s) the host's GameMode " ..
                 "would have hidden", done)
    end
end

function World.reset()
    applied = { name = nil, unlocked = {}, made = {} }
    lastSent, announced = nil, false
    signLights, signLightsAt = nil, nil
    signMaterialsMade = false
    lastBlockers, lastBlockerCount, blockersReported = 0, -1, false
    lastBlockerCheck = -math.huge
    seasonTried = {}
    skyApplied, lastSky = {}, 0
    tvNext, playersStarted = 0, {}
end

function World.init()
    Chan.on("world", function(fields) Log.guard("world sync", onWorld, fields) end)
    Chan.on("sky", function(fields)
        if UE.IsServer() then return end
        Log.guard("sky sync", applySky, fields)
    end)
end

return World
