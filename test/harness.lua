-- Fake UE4SS environment: enough of it to load and run the mod for real.
-- Mirrors the one behaviour that matters most here - UE4SS's built-in UObject
-- members shadow reflected UFunctions of the same name.

local H = { log = {}, world = { objects = {} }, realprint = print }

local function out(s) H.log[#H.log + 1] = tostring(s) end
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    out(table.concat(parts, " "))
end

-- ---------------------------------------------------------------- objects --

-- Marked, so a stub can tell a real FName from a Lua string. UE4SS does NOT
-- convert a string into an FName parameter - it dereferences it as one and
-- the process dies (measured in 1.7.0). Stubs for functions taking an FName
-- should refuse anything that is not one of these.
local function fname(s)
    return { ToString = function() return s end, __fname = true }
end

local ClassCache = {}
local function classOf(name)
    if not ClassCache[name] then
        ClassCache[name] = {
            IsValid    = function() return true end,
            GetFName   = function() return fname(name) end,
            GetFullName= function() return "Class /Script/Fake." .. name end,
            ForEachProperty = function(_, fn) end,
        }
    end
    return ClassCache[name]
end

local counter = 0
H.byName = {}      -- full name -> object, so a path finds it again like the real thing
function H.obj(className, fields)
    counter = counter + 1
    local o = fields or {}
    local full = className .. "_" .. counter
    H.byName[full] = o
    o.__class  = className
    o.IsValid  = function(self) return self.__dead ~= true end
    o.GetFullName = function() return full end
    o.GetClass = function() return classOf(className) end
    o.GetFName = function() return fname(full) end
    o.GetOuter = function(self) return self.__outer end
    o.HasAnyInternalFlags = function(self, flag)
        return self.__garbage == true and flag ~= nil
    end
    -- Only actors have this; anything else must throw, like the real thing.
    if o.__isActor ~= false then
        o.IsActorBeingDestroyed = function(self) return self.__destroying == true end
    end
    return o
end

function H.spawn(className, fields)
    local o = H.obj(className, fields)
    H.world.objects[className] = H.world.objects[className] or {}
    table.insert(H.world.objects[className], o)
    return o
end

function H.reset()
    H.world.objects = {}
end

-- ------------------------------------------------------------- UE4SS API --

_G.FindAllOf = function(name)
    local list = H.world.objects[name]
    if list and #list > 0 then return list end
    return nil
end

_G.FindFirstOf = function(name)
    local list = H.world.objects[name]
    if list and #list > 0 then return list[1] end
    return nil
end

H.staticObjects = {}
_G.StaticFindObject = function(path) return H.staticObjects[path] or H.byName[path] end

-- SteamCore Pro, modelled on what the real plugin reports on this build.
--
-- The stubs below exist because their ABSENCE hid a real bug: with no Steam
-- objects, P2P.discover() bailed out early and the smoke test never executed
-- the discovery reporting at all - which is where a forward-referenced local
-- was throwing on every attempt, on both players' machines, silently killing
-- the side-channel. A fake engine that is too empty tests nothing.
--
-- SendP2PPacket's first parameter really is a StructProperty here; that is
-- measured, not invented, and it is what drives the interesting code path.
local function fakeFunction(params)
    return {
        IsValid = function() return true end,
        ForEachProperty = function(_, fn)
            for _, p in ipairs(params) do
                fn({
                    GetFName = function() return fname(p[2]) end,
                    GetClass = function() return classOf(p[1]) end,
                })
            end
        end,
    }
end

H.staticObjects["/Script/SteamCorePro.Default__SteamProNetworking"] = H.obj("SteamProNetworking", {
    __isActor = false,
    SendP2PPacket = fakeFunction({
        { "StructProperty", "SteamIDRemote" }, { "ArrayProperty", "Data" },
        { "EnumProperty", "P2PSendType" }, { "IntProperty", "Channel" },
        { "BoolProperty", "ReturnValue" },
    }),
    ReadP2PPacket = fakeFunction({
        { "ArrayProperty", "Data" }, { "StructProperty", "OutSteamIdRemote" },
        { "IntProperty", "MessageSize" }, { "IntProperty", "Channel" },
        { "BoolProperty", "ReturnValue" },
    }),
    IsP2PPacketAvailable = fakeFunction({
        { "IntProperty", "MessageSize" }, { "IntProperty", "Channel" },
        { "BoolProperty", "ReturnValue" },
    }),
    AcceptP2PSessionWithUser = fakeFunction({ { "StructProperty", "SteamID" } }),
})

H.staticObjects["/Script/SteamCorePro.Default__SteamProUser"] = H.obj("SteamProUser", {
    __isActor = false,
    -- Returns a struct, exactly as the real one does - which is why reading a
    -- SteamID out of it needs field-name probing in the first place.
    GetSteamID = function() return { SteamID = "76561198000000101" } end,
})

H.constructCalls = {}
_G.StaticConstructObject = function(cls, outer, name, ...)
    local n = select("#", ...)
    H.constructCalls[#H.constructCalls + 1] = { argc = 3 + n }
    -- The real one is happy with just three.
    return H.obj("TextRenderComponent", {
        __outer               = outer,
        RegisterComponent     = function() end,
        K2_AttachToComponent  = function() end,
        K2_SetRelativeLocation= function() end,
        K2_SetRelativeRotation= function() end,
        K2_SetWorldRotation   = function() end,
        SetWorldSize          = function() end,
        SetHorizontalAlignment= function() end,
        SetVerticalAlignment  = function() end,
        SetTextRenderColor    = function() end,
        SetCastShadow         = function() end,
        SetVisibility         = function() end,
        SetText               = function() end,
        K2_DestroyComponent   = function() end,
    })
end

_G.FName = function(s) return fname(s) end
_G.FText = function(s) return { ToString = function() return s end, __ftext = true } end

H.hooks = {}
_G.RegisterHook = function(path, fn)
    -- Mirror the real build: the plain C++ virtuals carry no reflection data.
    if path:find("K2_OnLogout") or path:find("GameMode:K2_PostLogin") then
        error("no reflection data for " .. path)
    end
    H.hooks[path] = fn
end

H.commands = {}
_G.RegisterConsoleCommandHandler = function(name, fn) H.commands[name] = fn end

H.keybinds = {}
_G.RegisterKeyBind = function(key, fn)
    if key == nil then error("bad key") end
    H.keybinds[#H.keybinds + 1] = fn
end

_G.Key = { F5=1, F6=2, F7=3, F8=4, F9=5, TAB=6 }
_G.ModifierKey = { CONTROL = 1 }
_G.EInternalObjectFlags = { PendingKill = 8, Garbage = 8 }

H.ticks = {}
H.polls = {}
_G.LoopAsync = function(ms, fn) H.ticks[#H.ticks + 1] = fn end
-- The game-thread loop this UE4SS build has (measured: present in 1.7.0's
-- UE4SS.dll). The 100 ms one is the mod's tick, anything faster is the key
-- poll; H.tick and H.poll drive them separately.
_G.LoopInGameThreadWithDelay = function(ms, fn)
    if ms >= 100 then H.ticks[#H.ticks + 1] = fn else H.polls[#H.polls + 1] = fn end
    return #H.ticks + #H.polls
end
_G.ExecuteInGameThread = function(fn) fn() end

function H.tick()
    for _, fn in ipairs(H.ticks) do fn() end
end

function H.poll()
    for _, fn in ipairs(H.polls) do fn() end
end

return H
