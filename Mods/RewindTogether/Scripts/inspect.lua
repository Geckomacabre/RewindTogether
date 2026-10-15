--[[
    Rewind Together - runtime object inspector

    Exists because three separate problems were all being attacked by guessing
    at property names:

      * store state (money, day, season, time) not syncing - Config.SyncedState
        lists names nobody has ever confirmed exist,
      * props rendering as yellow placeholder boxes on the guest - which is
        what an actor looks like when its position replicated but the
        Blueprint variables that choose its mesh and material did not,
      * players not seeing each other - which could be a pawn that never
        replicated, or a pawn that replicated fine and has no third-person
        mesh to show.

    All three are answerable by asking the running game what its objects
    actually contain. A cooked Blueprint class carries its full property table,
    so the game will simply tell us - no decompiling, no assumptions.

    Run the same command on the host and on the guest and compare. A property
    that reads 4200 on one machine and 0 on the other is exactly what needs
    mirroring, and you can see it rather than infer it.
]]

local Log = require("log")
local UE  = require("ue")

local Inspect = {}

local MAX_VALUE_CHARS = 60

--------------------------------------------------------------------------

--- Render a property value as something readable in a console.
local function describeValue(v)
    local t = type(v)

    if v == nil then return "nil" end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "string" then
        if #v > MAX_VALUE_CHARS then return ('"%s..."'):format(v:sub(1, MAX_VALUE_CHARS)) end
        return ('"%s"'):format(v)
    end

    -- UObject: its class is more useful than its address.
    if UE.valid(v) then
        local name = nil
        pcall(function() name = v:GetFullName() end)
        if name then
            return (name:match("([^%.:]+)$") or name)
        end
        return UE.ClassNameOf(v)
    end

    -- Struct/array/anything else: best-effort, truncated.
    local ok, s = pcall(tostring, v)
    if not ok then return "<unreadable>" end
    s = tostring(s)
    if #s > MAX_VALUE_CHARS then s = s:sub(1, MAX_VALUE_CHARS) .. "..." end
    return s
end

--- Every property on an object's class, with its current value.
--- Returns a sorted list of "Name = value  (Type)" strings.
function Inspect.properties(obj, filter)
    if not UE.valid(obj) then return { "<object not available here>" } end

    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    if not UE.valid(cls) then return { "<class not resolvable>" } end

    local rows, seen = {}, {}
    local ok = pcall(function()
        cls:ForEachProperty(function(prop)
            local name, ptype
            pcall(function()
                name  = prop:GetFName():ToString()
                ptype = prop:GetClass():GetFName():ToString()
            end)
            if name and not seen[name] then
                seen[name] = true
                if not filter or name:lower():find(filter, 1, true) then
                    rows[#rows + 1] = {
                        name = name,
                        text = ("%-34s = %-24s (%s)")
                            :format(name, describeValue(UE.TryGet(obj, name)),
                                    tostring(ptype or "?")),
                    }
                end
            end
        end)
    end)

    if not ok then
        return { "<ForEachProperty is not available in this UE4SS build>" }
    end
    if #rows == 0 then
        return { filter and ("no properties matching '" .. filter .. "'")
                        or "no properties (this class exposes none)" }
    end

    table.sort(rows, function(a, b) return a.name < b.name end)

    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.text end
    return out
end

--- Every UFunction an object's class exposes.
---
--- Properties tell you what an object *is*; functions tell you what can be
--- done to it, and that is the missing half. Guest interaction forwarding
--- replays a guest's action by calling the interaction function on whatever
--- the host's trace hit - and the name of that function has only ever been
--- guessed at, from a list of five plausible spellings. If none of them is
--- right the call is skipped and forwarding silently does nothing, which is
--- this project's most familiar failure mode.
---
--- A cooked Blueprint carries its full function table, so stop guessing and
--- read it off the running game.
function Inspect.functions(obj, filter)
    if not UE.valid(obj) then return { "<object not available here>" } end

    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    if not UE.valid(cls) then return { "<class not resolvable>" } end

    local rows, seen = {}, {}
    local ok = pcall(function()
        cls:ForEachFunction(function(fn)
            local name
            pcall(function() name = fn:GetFName():ToString() end)
            if name and not seen[name] then
                seen[name] = true
                if not filter or name:lower():find(filter, 1, true) then
                    rows[#rows + 1] = {
                        name = name,
                        text = ("%-44s %s"):format(name, UE.DescribeFunctionString(fn)),
                    }
                end
            end
        end)
    end)

    if not ok then
        return { "<ForEachFunction is not available in this UE4SS build>" }
    end
    if #rows == 0 then
        return { filter and ("no functions matching '" .. filter .. "'")
                        or "no functions (this class exposes none)" }
    end

    table.sort(rows, function(a, b) return a.name < b.name end)

    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.text end
    return out
end

--------------------------------------------------------------------------
-- Resolving what to look at
--------------------------------------------------------------------------

--- Turn a console argument into an object.
---
--- Accepts the shorthands used by Config.SyncedState so that what you inspect
--- and what you configure are named the same way, plus any class name for
--- FindFirstOf, plus "look" for whatever the host is aiming at - which is how
--- you identify a yellow box without knowing its class.
function Inspect.resolve(what)
    what = tostring(what or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local key = what:lower()

    if key == "" or key == "gameinstance" then return UE.GetGameInstance(), "GameInstance" end
    if key == "gamemode"    then return UE.GetGameMode(), "GameMode" end
    if key == "gamestate"   then return UE.GetGameState(), "GameState" end
    if key == "pawn"        then return UE.GetPawn(), "your pawn" end
    if key == "controller"  then return UE.GetPlayerController(), "your controller" end
    if key == "playerstate" then
        local pc = UE.GetPlayerController()
        return UE.TryGet(pc, "PlayerState"), "your PlayerState"
    end

    -- Anything else: a class name. Try it verbatim and with the cooked suffix.
    for _, name in ipairs({ what, what .. "_C" }) do
        local o = FindFirstOf(name)
        if UE.valid(o) then return o, name end
    end

    return nil, what
end

--------------------------------------------------------------------------
-- Comparing the two machines
--------------------------------------------------------------------------

--- A compact snapshot of the values most likely to matter, for eyeballing
--- host against guest. Deliberately unfiltered by Config.SyncedState: the
--- whole point is to find names that config does not yet know about.
function Inspect.stateSnapshot()
    local lines = {}
    -- Two groups. The numbers were always the point; the second group was
    -- added after a guest's screenshot showed the whole store rendered in
    -- yellow-and-black hazard stripes - correct meshes, correct textures, with
    -- a build-mode overlay on top of all of them and a placement footprint on
    -- the floor. That is not per-prop appearance data, which is what the
    -- "yellow boxes" problem was assumed to be. It is a MODE the guest's
    -- client is in and the host's is not, and none of the terms below the
    -- first line would have found it.
    local WANTED = { "money", "cash", "day", "week", "season", "time", "hour",
                     "clock", "date", "level", "experience", "xp", "rank",
                     "progress", "unlock", "reputation",
                     -- mode / phase / editing state
                     "mode", "build", "edit", "place", "preview", "construct",
                     "phase", "state", "open", "close", "shop", "store",
                     "active", "paused", "tutorial", "highlight", "overlay" }

    for _, kind in ipairs({ "gameinstance", "gamemode", "gamestate", "controller", "pawn" }) do
        local obj, label = Inspect.resolve(kind)
        if UE.valid(obj) then
            lines[#lines + 1] = ("-- %s (%s) --"):format(label, UE.ClassNameOf(obj))
            local hits = 0
            for _, term in ipairs(WANTED) do
                for _, row in ipairs(Inspect.properties(obj, term)) do
                    if not row:find("^no properties") and not row:find("^<") then
                        lines[#lines + 1] = "   " .. row
                        hits = hits + 1
                    end
                end
            end
            if hits == 0 then
                lines[#lines + 1] = "   (nothing matching money/day/season/time/progress)"
            end
        else
            lines[#lines + 1] = ("-- %s: not available here --"):format(label)
        end
    end

    return lines
end

--------------------------------------------------------------------------
-- The hazard stripes
--------------------------------------------------------------------------

--- What is being drawn ON TOP of the store on the guest.
---
--- The guest's screenshot settles something three versions of this mod got
--- wrong. The counter's price signs are readable, the door mullions and window
--- frames are intact, the blue counter is the right blue - and yellow-and-black
--- hazard stripes are drawn OVER all of it. An actor arriving as an
--- unconfigured network proxy would draw a wrong appearance; it would not draw
--- a correct one with stripes on top. So the CDO theory 1.5.7 shipped is not
--- what this is.
---
--- UE5 renders exactly this with UPrimitiveComponent::OverlayMaterial - an
--- extra material pass over the mesh, which is what a build or placement mode
--- uses to tint everything placeable at once. It is a plain UPROPERTY and it
--- reads back, so one run on each machine turns this from an argument into a
--- number: the guest should report a non-zero count and the host zero.
---
--- Sweeps the component types that can carry one. FindAllOf by component
--- class, never a full ForEachUObject (PROJECT.md 5).
local OVERLAY_SWEEP = { "StaticMeshComponent", "SkeletalMeshComponent",
                        "InstancedStaticMeshComponent" }

-- Per class. A store interior is a few hundred meshes; a number far above that
-- means we are walking into parts of the object array that have nothing to do
-- with this level.
--
-- The cap exists because the unbounded version of this pattern - enumerate
-- every object of a class, touch each one - is what PROJECT.md 5 forbids and
-- what took the host down in 1.6.0 when it was written into bodies.lua. This
-- function has the same shape and runs automatically on a guest, so it gets
-- the same treatment before it gets the chance.
local MAX_PER_CLASS = 1500

local function eachOverlayComponent(fn)
    local seen, withOverlay = 0, 0
    for _, className in ipairs(OVERLAY_SWEEP) do
        local comps = FindAllOf(className) or {}
        local inClass = 0
        for _, c in ipairs(comps) do
            inClass = inClass + 1
            if inClass > MAX_PER_CLASS then break end
            if UE.alive(c) then
                seen = seen + 1
                local mat = UE.TryGet(c, "OverlayMaterial")
                if UE.valid(mat) then
                    withOverlay = withOverlay + 1
                    fn(c, mat, className)
                end
            end
        end
    end
    return seen, withOverlay
end

function Inspect.overlayReport()
    local lines = {}
    local function add(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and s or tostring(fmt)
    end

    add("mode: %s", UE.NetModeName())

    local byMaterial, examples = {}, {}
    local seen, withOverlay = eachOverlayComponent(function(c, mat)
        local name = UE.ClassNameOf(mat)
        pcall(function()
            local full = mat:GetFullName()
            name = full:match("([^%.:/]+)$") or name
        end)
        byMaterial[name] = (byMaterial[name] or 0) + 1
        if #examples < 6 then
            local owner = UE.TryGet(c, "Owner")
            if not UE.valid(owner) then
                local ok, o = pcall(function() return c:GetOwner() end)
                if ok then owner = o end
            end
            examples[#examples + 1] = ("%s on %s"):format(
                name, UE.valid(owner) and UE.ClassNameOf(owner) or "<no owner>")
        end
    end)

    add("mesh components examined: %d", seen)
    add("carrying an OverlayMaterial: %d", withOverlay)

    if withOverlay == 0 then
        add("")
        add("Nothing is being overlaid on this machine.")
        add("  If the OTHER machine reports a non-zero count here, that is the")
        add("  hazard stripes, and rt.stripes clear will prove it in one press.")
        add("  If BOTH machines report zero, the stripes are not an overlay")
        add("  material and this whole line of enquiry is dead - say so.")
        return lines
    end

    add("")
    for name, count in pairs(byMaterial) do add("  %-40s x%d", name, count) end
    add("")
    for _, e in ipairs(examples) do add("  e.g. %s", e) end
    add("")
    add("rt.stripes clear removes these locally. Purely cosmetic and purely")
    add("local - nothing is sent anywhere and the host is unaffected.")
    return lines
end

--- Clear every OverlayMaterial. The A/B test for the report above.
---
--- Local and cosmetic: an overlay pass is decoration, and removing it cannot
--- desynchronise anything because nothing about it was ever synchronised.
function Inspect.clearOverlays()
    local cleared, failed = 0, 0
    local _, withOverlay = eachOverlayComponent(function(c)
        local ok = pcall(function() c:SetOverlayMaterial(nil) end)
        if not ok then ok = UE.TrySet(c, "OverlayMaterial", nil) end
        -- Read back, because "the call did not throw" is not "it worked".
        if not UE.valid(UE.TryGet(c, "OverlayMaterial")) then
            cleared = cleared + 1
        else
            failed = failed + 1
        end
    end)
    return cleared, failed, withOverlay
end

--- Why can we not see each other? Answers the two candidate causes at once:
--- whether the other player's pawn exists on this machine at all, and whether
--- it has anything visible on it.
function Inspect.visibility()
    local lines = {}
    local mine = UE.GetPawn()

    local pawns = FindAllOf("Player_Character_C") or {}
    local n = 0
    for _, p in ipairs(pawns) do if UE.valid(p) then n = n + 1 end end

    lines[#lines + 1] = ("Player_Character_C actors visible to THIS machine: %d"):format(n)
    if n < 2 then
        lines[#lines + 1] = "   <- fewer than 2 means the other player's pawn is not"
        lines[#lines + 1] = "      replicating here at all. That is a replication"
        lines[#lines + 1] = "      problem, not a model problem."
    end

    for _, p in ipairs(pawns) do
        if UE.valid(p) then
            -- sameObject, not ==: UE4SS returns a fresh wrapper per lookup, so
            -- this reported the local player's own pawn as "OTHER PLAYER"
            -- alongside the real one and made the whole report unreadable.
            local tag = UE.sameObject(p, mine) and "yours" or "OTHER PLAYER"
            lines[#lines + 1] = ("-- %s: %s --"):format(tag, UE.ClassNameOf(p))
            lines[#lines + 1] = ("   role=%s remoteRole=%s hidden=%s"):format(
                tostring(UE.TryGet(p, "Role")),
                tostring(UE.TryGet(p, "RemoteRole")),
                tostring(UE.TryGet(p, "bHidden")))

            -- Every mesh hung off this pawn, and whether it would draw.
            local comps = UE.TryGet(p, "BlueprintCreatedComponents")
            local mesh = UE.TryGet(p, "Mesh")
            for label, c in pairs({ Mesh = mesh }) do
                if UE.valid(c) then
                    lines[#lines + 1] = ("   %s: %s visible=%s ownerNoSee=%s onlyOwnerSee=%s"):format(
                        label, UE.ClassNameOf(c),
                        tostring(UE.TryGet(c, "bVisible")),
                        tostring(UE.TryGet(c, "bOwnerNoSee")),
                        tostring(UE.TryGet(c, "bOnlyOwnerSee")))
                    -- SkeletalMeshAsset first. UE5.1 renamed the property and
                    -- left the old name as a deprecated alias that reads back
                    -- as an unusable object - which is why this used to print
                    -- "UObject: 0000027E42A25628" and looked like a mesh was
                    -- present when the question being asked was exactly
                    -- whether one was.
                    local sk, prop = nil, nil
                    for _, name in ipairs({ "SkeletalMeshAsset", "SkeletalMesh" }) do
                        local v = UE.TryGet(c, name)
                        if UE.valid(v) then sk, prop = v, name break end
                    end
                    lines[#lines + 1] = ("   %s asset: %s%s"):format(
                        label,
                        sk and describeValue(sk) or "<none>  <- nothing to draw",
                        prop and ("  (" .. prop .. ")") or "")
                else
                    lines[#lines + 1] = ("   %s: <none>  <- a pawn with no mesh cannot be seen"):format(label)
                end
            end
            if comps ~= nil then
                lines[#lines + 1] = "   (BlueprintCreatedComponents present - run rt.props pawn for the full list)"
            end
        end
    end

    -- What we could borrow a body from, if the player pawn has nothing to show.
    lines[#lines + 1] = "-- NPC classes present in this level --"
    local found = false
    for _, name in ipairs({ "AI_Character_C", "Customer_C", "Staff_C",
                            "AI_Character", "Customer", "Staff" }) do
        local o = FindFirstOf(name)
        if UE.valid(o) then
            found = true
            local m = UE.TryGet(o, "Mesh")
            lines[#lines + 1] = ("   %-18s present   mesh: %s"):format(
                name, UE.valid(m) and describeValue(UE.TryGet(m, "SkeletalMesh")) or "<none>")
        end
    end
    if not found then
        lines[#lines + 1] = "   none found right now (customers may only spawn when the shop is open)"
    end

    return lines
end

function Inspect.log(lines)
    for _, l in ipairs(lines) do Log.info("  %s", l) end
end

return Inspect
