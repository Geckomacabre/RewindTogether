--[[
    Rewind Together - visible bodies for other players

    THE PROBLEM

    Retro Rewind is first person. Player_Character_C derives from ACharacter,
    so it already HAS a Mesh component - every ACharacter does, inherited from
    the C++ base - but a game nobody ever sees themselves in has no reason to
    have put a body in it. So two players can stand next to each other, both
    replicating perfectly, and see nothing at all. Whatever they are carrying
    floats in mid-air, because a pickup is an ordinary actor with an ordinary
    mesh and replicates like one.

    THE FIX

    Borrow a body from the store's own NPCs. The staff and customers walking
    around are skeletal meshes with animation blueprints that are already
    loaded, already cooked, and already the right scale for this world - so
    there is nothing to import and no asset to ship.

    THIS IS PURELY LOCAL, and that is the important part. Nothing here
    replicates and nothing here needs to: each machine decorates the pawns it
    can see and skips its own. A guest can fix their own view of the host
    without the host doing anything, and vice versa. The authority problem that
    makes guest interactions hard (see sync.lua) does not apply at all.

    WHAT IT CANNOT DO

    If the other player's pawn is not replicating, there is no actor on this
    machine to put a mesh on, and no amount of this helps. That is a different
    bug with the same symptom, so the report below counts what it can actually
    see and says which of the two it is looking at rather than failing quietly.

    RISK

    This touches render components on live pawns, which is the exact class of
    operation that has taken this game down before (see safety.lua). It runs
    behind a breadcrumb: if it crashes, the next launch switches it off and
    says so, and co-op carries on without it.

    PAWNS COME AND GO, AND NOT ONLY WHEN SOMEBODY LEAVES

    On a guest, everything the host replicates - the host's pawn, the NPCs
    this borrows from - is destroyed when the guest goes out of network range
    and created again, under a new name, when they come back (measured in
    1.7.0: a guest fell out of the store and back). So nothing found here is
    kept past the tick it was found in: pawns, meshes and donors are looked up
    afresh on every poll, the animation sequences are remembered by path, and
    the bookkeeping, which is keyed by name, forgets every name that is gone.

    A guest crashed in this module's tick in 1.7.0, right after coming back
    into range. It was not this module: UE4SS's member-name cache was holding
    pointers into the strings of a Lua state two hot reloads had closed, and
    the first new name it learned made it re-hash them (RewindNative.cpp, "THE
    UE4SS NAME CACHE"). Dressing a pawn is simply where the most names are
    used for the first time.
]]

local Log    = require("log")
local UE     = require("ue")
local Safety = require("safety")

local Bodies = {}

local cfg = nil

-- pawn full name -> true, once it has been given a body. Keyed on the NAME,
-- never the actor: this game destroys pawns whenever somebody leaves, and the
-- rule about not holding actor pointers across frames applies here as much as
-- anywhere.
local dressed  = {}
-- pawn full name -> the mesh offset and yaw dress() applied, so a later poll
-- can tell whether they are still there. See holdPlacement.
local placed    = {}
local placedRot = {}

-- pawn full name -> { seqs = { idle = path, ... }, playing = "idle"|"walk"|"run" }.
-- The sequences by PATH: an asset kept in Lua is freed by garbage collection
-- once nothing in the engine uses it (PROJECT.md 0 - NPC looks crashed on
-- exactly that).
-- Declared up here, with the rest of the per-pawn bookkeeping, because dress()
-- writes it and dress() is defined above the animation section below. A Lua
-- local is only visible to code written after it; declaring this later made it
-- a nil global inside dress(), which threw, which took the whole of dressing
-- down inside its own pcall and reported as "no body was applied".
local anim = {}
local findSequencesFor
local lastPoll = 0
local reported = false
local noDonorWarned = false
local offWarned = false
local nextAssetWalk = 0

local POLL_INTERVAL = 2.0
-- The last-resort donor search walks every object in the engine (15 ms, and
-- it hands back objects that are being torn down): at most this often.
local ASSET_WALK_EVERY = 30.0

local RISKY_OP = "giving other players a visible body (Config.BorrowNpcBodies)"
-- Named separately so a crash retires the animation search WITHOUT taking
-- bodies with it. Seeing your friend matters more than what pose they are in.
local ANIM_OP  = "searching for animations to drive a borrowed body " ..
                 "(Config.DriveBodyAnimation)"

-- Where to borrow from, best first: the store's own NPC classes (ue.lua knows
-- their paths, so each is a GetActorOfClass, never a walk). Staff persist in
-- the store; customers only exist while the shop is open; passers-by walk the
-- street whether it is or not. Earlier builds listed guesses here ("Staff_C",
-- "Customer_C") that never matched anything, and each miss cost a walk.
local DONOR_CLASSES = {
    "AI_Employee_Character_C",
    "AI_Client_Character_C",
    "AI_WalkBy_Character_C",
    "AI_BackAlleyVendor_Character_C",
}
-- Every NPC, for the ranked search when none of those answers first.
local ANY_NPC = "AI_Base_Character_C"

--------------------------------------------------------------------------
-- Reading a skeletal mesh component
--------------------------------------------------------------------------

--- The asset a skeletal mesh component is displaying.
---
--- UE5.1 renamed USkeletalMeshComponent::SkeletalMesh to SkeletalMeshAsset and
--- left the old name as a deprecated alias, and which one a given build
--- answers to is a property of the build. Ask for both rather than picking one
--- and being silently wrong on the other.
local function readMeshAsset(comp)
    for _, prop in ipairs({ "SkeletalMeshAsset", "SkeletalMesh" }) do
        local asset = UE.TryGet(comp, prop)
        if UE.valid(asset) then return asset, prop end
    end
    return nil, nil
end

--- Point a skeletal mesh component at an asset. Returns how it worked, or nil.
local function writeMeshAsset(comp, asset)
    -- The setters first: they do the work SetSkeletalMesh exists to do -
    -- reinitialising the pose and re-registering - which a bare property write
    -- does not.
    for _, fn in ipairs({ "SetSkeletalMeshAsset", "SetSkeletalMesh" }) do
        local ok = pcall(function() comp[fn](comp, asset, false) end)
        if ok and UE.valid((readMeshAsset(comp))) then return fn end
        -- Some signatures take only the asset.
        ok = pcall(function() comp[fn](comp, asset) end)
        if ok and UE.valid((readMeshAsset(comp))) then return fn end
    end

    for _, prop in ipairs({ "SkeletalMeshAsset", "SkeletalMesh" }) do
        if UE.TrySet(comp, prop, asset) and UE.valid((readMeshAsset(comp))) then
            return prop .. " (property)"
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Finding a donor
--------------------------------------------------------------------------

--- An NPC we can copy a body from. Returns a description table, or nil.
---
--- Re-resolved every time rather than cached. The asset itself is long-lived,
--- but the NPC we read it off is not - this store spawns and despawns
--- customers constantly, and a stale pointer to one is how this mod has
--- crashed before.
-- How good a donor is, so a later poll knows whether swapping is an upgrade.
--   3  a real character, animated       - correct proportions, feet at origin
--   2  a real character, no animation
--   1  some other skeletal mesh, animated
--   0  a bare asset
--
-- The gap between 1 and 3 is not cosmetic. A character mesh has its origin at
-- the feet, which is what makes "drop it to the bottom of the capsule" put it
-- on the floor. An arbitrary level mesh can have its origin anywhere, and one
-- centred on the body is exactly why the borrowed body was still hovering a
-- metre up after the offset was supposedly fixed.
local function rankOf(isCharacter, animClass)
    local base = isCharacter and 2 or 0
    return base + (UE.valid(animClass) and 1 or 0)
end

--- Is this component the Mesh of an ACharacter?
---
--- Asked structurally - the owner has a CapsuleComponent and its Mesh is this
--- component - rather than by class name, because DONOR_CLASSES is a guess
--- about this game's naming and the fallback search finds NPCs it does not
--- cover. Measured consequence of not asking: the store's own staff, found via
--- route 2, were described as "a skeletal mesh in the level" and ranked 1
--- instead of 3. That is not cosmetic. It says the mesh's origin might be
--- anywhere, so the donor's own offset is distrusted; and a donor below rank 3
--- is re-searched on every poll for the rest of the session.
--- The actor a component belongs to.
---
--- Measured on this build, 2026-08-05: UE.TryGet(comp, "Owner") comes back
--- empty. That is why every donor the fallback sweep finds is reported as
--- "a skeletal mesh in the level" and ranked 1 - including SK_CHA_M_01, which
--- is plainly one of the town's characters. The property is not readable here;
--- UActorComponent::GetOwner() is a UFUNCTION and is, and it is not one of the
--- names UE4SS's built-in UObject members shadow (PROJECT.md 5).
local function ownerOf(comp)
    local o = UE.TryGet(comp, "Owner")
    if UE.valid(o) then return o end
    local ok, got = pcall(function() return comp:GetOwner() end)
    if ok and UE.valid(got) then return got end
    return nil
end

local function looksLikeCharacterMesh(comp)
    local owner = ownerOf(comp)
    if not UE.alive(owner) then return false end
    if not UE.alive(UE.TryGet(owner, "CapsuleComponent")) then return false end
    return UE.sameObject(UE.TryGet(owner, "Mesh"), comp)
end

local function describeComponent(comp, className, isCharacter)
    local asset = readMeshAsset(comp)
    if not UE.valid(asset) then return nil end
    local animClass = UE.TryGet(comp, "AnimClass")
    isCharacter = isCharacter or looksLikeCharacterMesh(comp)
    return {
        class     = className,
        asset     = asset,
        animClass = animClass,
        isChar    = isCharacter,
        rank      = rankOf(isCharacter, animClass),
        -- The donor's mesh is already positioned correctly against its own
        -- capsule, so copying its relative transform beats reconstructing the
        -- ACharacter convention (Z = -halfheight, yaw -90) by hand.
        relLoc    = UE.TryGet(comp, "RelativeLocation"),
        relRot    = UE.TryGet(comp, "RelativeRotation"),
        relScale  = UE.TryGet(comp, "RelativeScale3D"),
    }
end

local function findDonor()
    -- 1. A named NPC. Best case by a distance: it comes with an animation
    --    blueprint, so the borrowed body walks instead of standing in its
    --    bind pose.
    for _, className in ipairs(DONOR_CLASSES) do
        local npc = UE.findFirst(className)
        if UE.alive(npc) then
            local comp = UE.TryGet(npc, "Mesh")
            if UE.alive(comp) then
                local donor = describeComponent(comp, className, true)
                if donor then return donor end
            end
        end
    end

    -- 2. Every NPC there is, ranked.
    --
    --    This exists because of a measurement: with the shop closed,
    --    "NPC classes present in this level: none found right now". Customers
    --    and staff are spawned when the shop opens, so on the quiet screen
    --    where somebody is most likely to be testing this, route 1 can find
    --    nothing and the feature looks broken rather than waiting.
    --
    --    Earlier builds walked every SkeletalMeshComponent in the engine here:
    --    15 ms, every two seconds while the donor was not the best one, and a
    --    walk hands back components whose actors are being destroyed - on a
    --    guest, every NPC the host's range has just dropped. The engine's own
    --    actor list leaves those out.
    local fallback = nil
    for _, npc in ipairs(UE.findAll(ANY_NPC) or {}) do
        if UE.alive(npc) then
            local comp = UE.TryGet(npc, "Mesh")
            if UE.alive(comp) then
                local donor = describeComponent(comp, UE.ClassNameOf(npc), true)
                -- A better donor is worth searching the whole list for.
                -- Taking the first match found one with no animation
                -- blueprint and produced a T-posing body sliding around the
                -- store, which is what got reported. Rank 3 - a real
                -- character with an animation blueprint - is as good as it
                -- gets, so stop there; anything less is only kept in case
                -- nothing better turns up.
                if donor and donor.rank >= 3 then return donor end
                if donor and (not fallback or donor.rank > fallback.rank) then
                    fallback = donor
                end
            end
        end
    end
    if fallback then return fallback end

    -- 3. Any loaded skeletal mesh asset at all. No animation blueprint comes
    --    with this, so the body stands in its bind pose - but a T-posing
    --    figure sliding around the store still answers "where is my friend",
    --    which is the whole question. That is a walk of the whole object
    --    array, so it is rare, and the asset is used this tick and not kept.
    local now = os.clock()
    if now >= nextAssetWalk then
        nextAssetWalk = now + ASSET_WALK_EVERY
        local asset = FindFirstOf("SkeletalMesh")
        if UE.alive(asset) then
            return { class = "a loaded skeletal mesh (no animation)", asset = asset, rank = 0 }
        end
    end

    return nil
end

--------------------------------------------------------------------------
-- Dressing a pawn
--------------------------------------------------------------------------

local function step(name, fn)
    if not pcall(fn) then Log.debug("body: %s is not callable here", name) end
end

--- Where an ACharacter's mesh belongs relative to its capsule.
---
--- The engine's own convention, and it has to be reconstructed because a mesh
--- component that has never had a mesh in it has never had its transform set
--- either. Measured symptom of not doing this: the borrowed body stands with
--- its feet at the capsule's CENTRE, which is roughly 88 units up, so it
--- floats at head height and faces ninety degrees off from the direction the
--- player is actually looking.
local function characterMeshOffset(pawn)
    local half = 88.0
    local capsule = UE.TryGet(pawn, "CapsuleComponent")
    if UE.alive(capsule) then
        local ok, h = pcall(function() return capsule:GetScaledCapsuleHalfHeight() end)
        if ok and type(h) == "number" and h > 0 then half = h end
    end
    return { X = 0.0, Y = 0.0, Z = -half },
           { Pitch = 0.0, Yaw = -90.0, Roll = 0.0 }
end

--- Is this a transform worth copying, or an unset one?
local function isSetTransform(v)
    if v == nil then return false end
    local ok, zero = pcall(function()
        return (v.X or 0) == 0 and (v.Y or 0) == 0 and (v.Z or 0) == 0
    end)
    if ok and zero then return false end
    return true
end

--------------------------------------------------------------------------
-- Placing the mesh, and proving it moved
--------------------------------------------------------------------------

--- Read a vector property back as plain Lua numbers.
---
--- Engine vectors are userdata here, the same way strings are (PROJECT.md 5).
--- Keeping one as userdata makes it useless for the comparison below, and
--- holding it risks reading a value that has since moved on.
local function readVec(obj, prop)
    local v = UE.TryGet(obj, prop)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if not ok or type(x) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end

local function readRot(obj, prop)
    local v = UE.TryGet(obj, prop)
    if v == nil then return nil end
    -- Case-insensitive: FRotator's "Pitch" can come back as "pitch" (ue.lua).
    return UE.rot(v)
end

local function near(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.5
end

--- Re-apply the scale a component already has.
---
--- SetRelativeScale3D is the only transform setter on USceneComponent whose
--- signature contains no out-parameter, so it is the one call here that cannot
--- be refused for marshalling reasons. Re-applying the current scale changes
--- nothing except that it runs UpdateComponentToWorld, which is exactly what a
--- bare property write leaves undone.
local function flushTransform(comp)
    local s = readVec(comp, "RelativeScale3D") or { X = 1.0, Y = 1.0, Z = 1.0 }
    comp:SetRelativeScale3D(s)
end

--- Move the mesh component, then READ IT BACK.
---
--- The previous version dispatched K2_SetRelativeLocation with an empty table
--- where the FHitResult out-parameter goes, swallowed any error at debug
--- level, and then logged the offset it had *intended* to apply. That is this
--- project's oldest failure mode (PROJECT.md 5, and the rule in 8: never
--- report success for something that was merely dispatched) - a call that
--- quietly does nothing reads identically to one that worked.
---
--- Whether UE4SS wants an out-parameter passed, passed as nil, or omitted is a
--- property of the UE4SS build rather than of this game, which is not
--- something to have an opinion about. Try the shapes, verify each against the
--- value that comes back, and return which one took - or nil, honestly, along
--- with where the mesh actually is.
local function setRelLocation(comp, loc)
    local attempts = {
        { "K2_SetRelativeLocation(v,false,{},false)",
          function() UE.withHit(function(hit) comp:K2_SetRelativeLocation(loc, false, hit, false) end) end },
        { "K2_SetRelativeLocation(v,false,nil,false)",
          function() comp:K2_SetRelativeLocation(loc, false, nil, false) end },
        { "K2_SetRelativeLocation(v,false)",
          function() comp:K2_SetRelativeLocation(loc, false) end },
        { "K2_SetRelativeLocation(v)",
          function() comp:K2_SetRelativeLocation(loc) end },
        { "RelativeLocation property + scale flush",
          function() comp.RelativeLocation = loc; flushTransform(comp) end },
    }
    for _, a in ipairs(attempts) do
        pcall(a[2])
        local got = readVec(comp, "RelativeLocation")
        if got and near(got.X, loc.X) and near(got.Y, loc.Y) and near(got.Z, loc.Z) then
            return a[1], got
        end
    end
    return nil, readVec(comp, "RelativeLocation")
end

local function setRelRotation(comp, rot)
    local attempts = {
        { "K2_SetRelativeRotation(r,false,{},false)",
          function() UE.withHit(function(hit) comp:K2_SetRelativeRotation(rot, false, hit, false) end) end },
        { "K2_SetRelativeRotation(r,false,nil,false)",
          function() comp:K2_SetRelativeRotation(rot, false, nil, false) end },
        { "K2_SetRelativeRotation(r,false)",
          function() comp:K2_SetRelativeRotation(rot, false) end },
        { "K2_SetRelativeRotation(r)",
          function() comp:K2_SetRelativeRotation(rot) end },
        { "RelativeRotation property + scale flush",
          function() comp.RelativeRotation = rot; flushTransform(comp) end },
    }
    for _, a in ipairs(attempts) do
        pcall(a[2])
        local got = readRot(comp, "RelativeRotation")
        if got and near(got.Pitch, rot.Pitch) and near(got.Yaw, rot.Yaw)
                and near(got.Roll, rot.Roll) then
            return a[1], got
        end
    end
    return nil, readRot(comp, "RelativeRotation")
end

--- FRotator -> FQuat, UE's own conversion.
---
--- BaseRotationOffset is a quaternion, and there is no reflected helper to
--- build one from a rotator - FRotator::Quaternion() is plain C++. This is
--- that function, transcribed, half-angles and all.
local function rotatorToQuat(rot)
    local h = math.pi / 360.0        -- degrees -> radians, halved
    local sp, cp = math.sin((rot.Pitch or 0) * h), math.cos((rot.Pitch or 0) * h)
    local sy, cy = math.sin((rot.Yaw   or 0) * h), math.cos((rot.Yaw   or 0) * h)
    local sr, cr = math.sin((rot.Roll  or 0) * h), math.cos((rot.Roll  or 0) * h)
    return {
        X =  cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z =  cr * cp * sy - sr * sp * cy,
        W =  cr * cp * cy + sr * sp * sy,
    }
end

--- Teach the character where its own mesh belongs.
---
--- THIS IS THE BUG. Everything before 1.5.9 treated the floating body as a
--- placement that failed to apply. It applies fine and is then overwritten,
--- every frame, by the engine.
---
--- A remote player is a SIMULATED PROXY, and ACharacter network-smooths those.
--- UCharacterMovementComponent::SmoothClientPosition_UpdateVisuals() does,
--- literally:
---
---   NewRelTranslation = ...(MeshTranslationOffset + GetBaseTranslationOffset())
---   NewRelRotation    = MeshRotationOffset * GetBaseRotationOffset()
---   Mesh->SetRelativeLocationAndRotation(NewRelTranslation, NewRelRotation)
---
--- BaseTranslationOffset is cached by ACharacter from wherever the mesh sat at
--- construction. Player_Character_C has never had a body in it, so its mesh
--- sits at the origin, so that cache is (0,0,0) - which is precisely the value
--- the offset kept reverting to, on remote pawns only, nine seconds after
--- being set. It was never a marshalling problem and never a call-shape
--- problem. The engine was correcting us.
---
--- So write the cache instead of fighting what it produces. Then smoothing
--- computes the offset we want every frame on its own, and the body
--- interpolates like a real character rather than being yanked back into place
--- twice a second.
---
--- ACharacter::CacheInitialMeshOffset is the engine's own front door for this
--- and is plain C++ with no UFUNCTION, so it cannot be called from here. Both
--- fields behind it are UPROPERTY() and can be written directly.
---
--- Returns whether the cache now holds what we asked for.
local function setBaseMeshOffset(pawn, loc, rot)
    local before = readVec(pawn, "BaseTranslationOffset")

    UE.TrySet(pawn, "BaseTranslationOffset", loc)
    UE.TrySet(pawn, "BaseRotationOffset", rotatorToQuat(rot))

    local after = readVec(pawn, "BaseTranslationOffset")
    local ok = after ~= nil and near(after.Z, loc.Z)
    return ok, before, after
end

--- Stop the engine writing the mesh transform at all.
---
--- The fallback for when BaseTranslationOffset will not take. Costs the
--- interpolation - a remote player moves in 10 Hz steps instead of smoothly -
--- which is a real downgrade and much better than a body at head height.
--- ENetworkSmoothingMode::Disabled == 0.
local function disableNetworkSmoothing(pawn)
    local move = UE.TryGet(pawn, "CharacterMovement")
    if not UE.alive(move) then return false end
    if not UE.TrySet(move, "NetworkSmoothingMode", 0) then return false end
    local got = UE.TryGet(move, "NetworkSmoothingMode")
    return got == nil or got == 0
end

--- Put the mesh back where dress() already put it.
---
--- MEASURED, nine seconds apart on one machine, 2026-08-05:
---
---   18:56:51  mesh offset Z-90 applied via K2_SetRelativeLocation(...)
---   18:56:51  measured: the mesh origin sits -90 from the pawn's origin
---   18:57:00  rt.bodies -> feet offset: Z+0   world rise +0
---
--- The cause is network smoothing overwriting the component every frame -
--- see setBaseMeshOffset, which is the actual fix. This is the net underneath
--- it, and the only thing it is really for is the case that fix does not
--- cover: a pawn whose BaseTranslationOffset took, but which then got its
--- component transform reset by something else entirely.
---
--- Re-asserting the cache as well as the component, because if the cache has
--- gone back to zero then the component will follow it again in a frame and
--- putting the component back alone would be pure theatre - a body that snaps
--- into place twice a second and floats the rest of the time.
local function holdPlacement(pawn, key)
    local want = placed[key]
    if not want then return end
    local comp = UE.TryGet(pawn, "Mesh")
    if not UE.alive(comp) then return end

    local base = readVec(pawn, "BaseTranslationOffset")
    if not (base and near(base.Z, want.Z)) then
        setBaseMeshOffset(pawn, want, placedRot[key] or { Pitch = 0, Yaw = -90, Roll = 0 })
    end

    local got = readVec(comp, "RelativeLocation")
    if got and near(got.Z, want.Z) then return end

    local how = setRelLocation(comp, want)
    Log.info("the body's mesh had been moved to %s - put back to Z%+.0f%s",
             got and string.format("Z%+.0f", got.Z) or "<unreadable>",
             want.Z, how and "" or " (AND IT WOULD NOT GO)")
end

--- How far the mesh's origin ended up above the pawn's own origin.
---
--- The number that actually answers "is it still floating", in world space,
--- after everything above has had its say. Both getters are BlueprintPure and
--- take no out-parameters, so neither can fail for the reason the setters can.
local function measureRise(pawn, comp)
    local rise = nil
    pcall(function()
        rise = comp:K2_GetComponentLocation().Z - pawn:K2_GetActorLocation().Z
    end)
    return rise
end

--- Start the animation blueprint actually running.
---
--- SetAnimInstanceClass on its own is not always enough: a component whose
--- AnimationMode is not AnimationBlueprint keeps rendering its bind pose, and
--- a bind pose is exactly what a T-posing body is. Set the mode first, then
--- the class, then read the class back - because "the call did not throw" has
--- never been the same thing as "it worked" in this project.
---
--- Two further things have to be true before a pose updates, and neither is
--- implied by the class being set. This mesh component has never held a mesh
--- in its life, so nothing has ever needed it to tick: an untraversed
--- component can carry the right animation blueprint and still render the
--- frame it was initialised with, forever. And UE5's default
--- VisibilityBasedAnimTickOption only refreshes bones for components the
--- renderer considers visible, which is a judgement made about a component
--- that was empty until a moment ago.
---
--- Returns whether an AnimInstance actually exists afterwards. That is a
--- stronger claim than AnimClass being set - the class is what was asked for,
--- the instance is what the engine built.
local function startAnimation(comp, animClass)
    if not UE.valid(animClass) then return false, "no animation blueprint on the donor" end

    -- EAnimationMode::AnimationBlueprint == 1
    step("SetAnimationMode", function() comp:SetAnimationMode(1) end)
    step("SetAnimInstanceClass", function() comp:SetAnimInstanceClass(animClass) end)
    if not UE.valid(UE.TryGet(comp, "AnimClass")) then
        -- Older name for the same thing.
        step("SetAnimClass", function() comp:SetAnimClass(animClass) end)
    end

    step("SetComponentTickEnabled", function() comp:SetComponentTickEnabled(true) end)
    -- EVisibilityBasedAnimTickOption::AlwaysTickPoseAndRefreshBones == 0
    UE.TrySet(comp, "VisibilityBasedAnimTickOption", 0)

    if not UE.valid(UE.TryGet(comp, "AnimClass")) then
        return false, "the animation class would not stick"
    end

    local inst = nil
    pcall(function() inst = comp:GetAnimInstance() end)
    if UE.valid(inst) then return true, UE.ClassNameOf(inst) end

    -- The class is set and the engine built nothing from it. Worth saying
    -- plainly rather than reporting the class and calling it animated: a
    -- borrowed animation blueprint that casts its owner to the NPC class it
    -- was written for gets a Player_Character_C, fails the cast, and drives
    -- nothing - which renders as the reference pose, which is a T-pose.
    return false, "class set but the engine built no AnimInstance from it"
end

--- Give one remote pawn a visible body.
--- Returns true when the result is animated, false when it is a bind pose.
--- `upgrade` means we are replacing a body this module put on earlier, having
--- since found a donor that comes with an animation blueprint.
local function dress(pawn, donor, upgrade)
    local comp = UE.TryGet(pawn, "Mesh")
    if not UE.alive(comp) then
        Log.warn("%s has no Mesh component at all - cannot give it a body",
                 UE.ClassNameOf(pawn))
        return false
    end

    -- Already showing something: leave it alone. The game may well put a real
    -- body on other players in some situations, and overwriting it with a
    -- shop assistant would be a downgrade.
    --
    -- Except on an upgrade pass, where the mesh it is "already showing" is the
    -- one this module put there itself and the whole point is to replace it
    -- with an animated one.
    local existing = not upgrade and readMeshAsset(comp) or nil
    if UE.valid(existing) then
        Log.info("%s already has a mesh - leaving it alone", UE.ClassNameOf(pawn))
        step("SetVisibility",  function() comp:SetVisibility(true, true) end)
        step("SetHiddenInGame", function() comp:SetHiddenInGame(false, true) end)
        return true
    end

    local how = writeMeshAsset(comp, donor.asset)
    if not how then
        Log.warn("could not put a mesh on %s - neither the setters nor the " ..
                 "property took", UE.ClassNameOf(pawn))
        return false
    end

    -- Without a running animation blueprint the body renders in its bind pose
    -- - which is precisely the T-pose that was reported. Reported back so a
    -- posed body and a frozen one are distinguishable in the log.
    local animated, animNote = startAnimation(comp, donor.animClass)

    -- Placement. Prefer the donor's own numbers - but ONLY when the donor is a
    -- character, because that is the case where they mean anything. A
    -- character's mesh is dropped to the bottom of its capsule and its origin
    -- is at the feet; an arbitrary level mesh can have its origin anywhere,
    -- and copying its offset onto a capsule it knows nothing about is how the
    -- body was still hovering a metre up after 1.5.6 "fixed" the hovering.
    -- 1.5.7 ranked donors to spot that case and then went on copying the
    -- transform anyway. Otherwise reconstruct the engine's own convention from
    -- this pawn's real capsule, which is right by construction.
    local loc, rot = characterMeshOffset(pawn)
    if donor.isChar and isSetTransform(donor.relLoc) then
        loc = { X = donor.relLoc.X, Y = donor.relLoc.Y, Z = donor.relLoc.Z }
    end
    if donor.isChar and isSetTransform(donor.relRot) then
        rot = { Pitch = donor.relRot.Pitch, Yaw = donor.relRot.Yaw, Roll = donor.relRot.Roll }
    end

    -- FIRST: teach the character's smoothing cache the offset, because that is
    -- what will be writing this component's transform from now on. Setting the
    -- component without this lasts until the next smoothing update.
    local baseOk, baseWas = setBaseMeshOffset(pawn, loc, rot)
    local smoothingOff = false
    if not baseOk then smoothingOff = disableNetworkSmoothing(pawn) end

    local locHow, gotLoc = setRelLocation(comp, loc)
    local rotHow, gotRot = setRelRotation(comp, rot)

    -- Remembered so holdPlacement can tell later whether it is still there.
    -- It will not be.
    local key = nil
    pcall(function() key = pawn:GetFullName() end)
    if key then
        placed[key], placedRot[key] = loc, rot

        -- Take the pose off the borrowed blueprint if we can find sequences
        -- that fit this skeleton. See driveAnimation for why.
        --
        -- Opt-IN, checked with == true, unlike every other flag in this file.
        -- The rest default on because their absence is harmless; this one
        -- crashed the host on join in 1.6.0 and a missing value must not turn
        -- it back on. It is also behind a breadcrumb, so if it crashes again
        -- the next launch retires it and says so.
        if cfg and cfg.DriveBodyAnimation == true then
            local ran, seqs = Safety.guard(ANIM_OP, findSequencesFor, donor.asset)
            if not ran then
                seqs = nil
                Log.warn("  animation sequence search is off after an earlier " ..
                         "crash (rt.safety)")
            end
            anim[key] = { seqs = seqs, playing = nil }
            if seqs then
                Log.info("  driving the animation directly: idle/walk/run found " ..
                         "on this skeleton, so the donor's wander blueprint is " ..
                         "no longer in charge of the pose")
            else
                Log.info("  no animation sequences match this skeleton - the " ..
                         "donor's own blueprint stays in charge, which is why " ..
                         "the body may idle oddly")
            end
        end
    end

    -- The owning client must never see this from inside its own head. It is
    -- only ever applied to pawns that are remote HERE, so this should never
    -- matter - but "should never" is how the last few bugs started.
    step("SetOwnerNoSee",   function() comp:SetOwnerNoSee(true) end)
    step("SetVisibility",   function() comp:SetVisibility(true, true) end)
    step("SetHiddenInGame", function() comp:SetHiddenInGame(false, true) end)

    Log.info("gave %s a body borrowed from %s (via %s)",
             UE.ClassNameOf(pawn), donor.class, how)
    Log.info("  animation: %s (%s)", animated and "running" or "NONE - bind pose",
             animNote or "?")

    -- The line that says whether the real cause was addressed. A `was Z+0`
    -- here is the confirmation that network smoothing is what has been
    -- flattening the offset all along.
    if baseOk then
        Log.info("  BaseTranslationOffset set to Z%+.0f (was %s) - smoothing will " ..
                 "now keep the mesh there itself", loc.Z,
                 baseWas and string.format("Z%+.0f", baseWas.Z) or "unreadable")
    elseif smoothingOff then
        Log.warn("  BaseTranslationOffset would not take, so network smoothing is " ..
                 "OFF for this pawn - the body will step rather than glide")
    else
        Log.warn("  BaseTranslationOffset would not take AND smoothing could not be " ..
                 "disabled - the engine will keep flattening the offset and the " ..
                 "body will float. This is the real fault; nothing downstream helps.")
    end

    -- Measured, not intended. If the setter was refused the body is floating
    -- at the capsule's centre and the player can see that perfectly well, so
    -- the log had better agree with their eyes.
    if locHow then
        Log.info("  mesh offset Z%+.0f applied via %s", gotLoc.Z, locHow)
    else
        Log.warn("  COULD NOT MOVE THE MESH. Wanted Z%+.0f, it is at %s - the body " ..
                 "will float. No call shape for K2_SetRelativeLocation was accepted " ..
                 "by this UE4SS build.", loc.Z,
                 gotLoc and string.format("Z%+.0f", gotLoc.Z) or "<unreadable>")
    end
    if not rotHow then
        Log.warn("  could not rotate the mesh - the body will face %s off",
                 gotRot and "the wrong way" or "ninety degrees")
    end

    local rise = measureRise(pawn, comp)
    if rise then
        Log.info("  measured: the mesh origin sits %+.0f from the pawn's origin " ..
                 "(wanted %+.0f)", rise, loc.Z)
    end

    -- An un-animated body is a T-pose. That is a big enough downgrade to be
    -- worth another go later: staff and customers only exist once the shop is
    -- open, so the donor that was available at join time is often the worst
    -- one available all session.
    return animated
end

--------------------------------------------------------------------------
-- Driving the animation ourselves
--------------------------------------------------------------------------
--[[
    Reported from a live session: the borrowed body "appears to move in a
    circle", with the idle playing far more than the walk.

    That is what borrowing somebody else's animation blueprint buys you. The
    donor in the log is AI_WalkBy_Character_C and its AnimBP is written to
    drive a wandering pedestrian - it reads that NPC's own state, decides for
    itself what the character is doing, and on a Player_Character_C it is
    reading nothing and guessing. There is no variable we can set to correct
    it, because it is somebody else's graph.

    So stop asking it. A skeletal mesh component can play a single animation
    directly - SetAnimationMode(AnimationSingleNode) + PlayAnimation - and we
    know something the borrowed AnimBP does not: how fast this pawn is actually
    moving, because AActor::GetVelocity is reflected and replicated movement
    keeps it current on a simulated proxy.

    Pick sequences off the donor's own skeleton so they are guaranteed to fit,
    choose between them on measured speed, and the body walks when the player
    walks. If no compatible sequences turn up, fall through to the AnimBP - a
    circling body still answers "where is my friend", which was the original
    point.
]]

-- Speeds in cm/s. Retro Rewind's walk is in the low hundreds and sprint
-- roughly double; the boundaries only have to separate three cases.
local WALK_ABOVE = 10.0
local RUN_ABOVE  = 320.0

local function skeletonOf(obj)
    return UE.TryGet(obj, "Skeleton")
end

--- Animation sequences that fit this mesh's skeleton, sorted into roles.
---
--- Matched on name, because a name is the only thing an AnimSequence tells us
--- about its content. Anything unmatched is kept as a last-resort idle: a
--- wrong-but-still pose beats a T-pose.
-- How many AnimSequences to look at before giving up.
--
-- THIS CAP IS NOT A PERFORMANCE TUNING. The first version of this function had
-- no cap and it took the host's process down the instant a guest joined, in
-- the exact way PROJECT.md 5 says a sweep will: enumerating every loaded
-- object of a class and calling GetFullName() on each touches objects that are
-- mid-construction or already freed, and pcall does not catch an access
-- violation in native code. A game with a full character animation set has
-- thousands of these.
--
-- Capped, liveness-checked, and behind an opt-in flag. It is still a sweep and
-- it is still the riskiest thing in this file.
local MAX_SEQUENCES = 400

findSequencesFor = function(asset)
    local want = skeletonOf(asset)
    if not UE.valid(want) then return nil end

    local all = FindAllOf("AnimSequence")
    if not all then return nil end

    -- Paths, not the sequences: these are kept for as long as the body is.
    local out, any, seen = {}, nil, 0
    for _, seq in ipairs(all) do
        seen = seen + 1
        if seen > MAX_SEQUENCES then break end
        -- alive(), not valid(): an asset can be part-way through being torn
        -- down and still answer as a UObject.
        if UE.alive(seq) and UE.sameObject(skeletonOf(seq), want) then
            local path = UE.pathOf(seq)
            local name = path and (path:match("([^%.:/]+)$") or ""):lower() or ""
            if path then
                any = any or path
                if     name:find("idle")  then out.idle = out.idle or path
                elseif name:find("walk")  then out.walk = out.walk or path
                elseif name:find("jog")
                    or name:find("run")   then out.run  = out.run  or path
                end
            end
        end
    end

    if not (out.idle or out.walk or out.run) then
        if not any then return nil end
        out.idle = any
    end
    -- Collapse the gaps so a missing run falls back to walk, and so on.
    out.walk = out.walk or out.run or out.idle
    out.run  = out.run  or out.walk
    out.idle = out.idle or out.walk
    return out
end

local function speedOf(pawn)
    local s = nil
    pcall(function()
        local v = pawn:GetVelocity()
        s = math.sqrt((v.X * v.X) + (v.Y * v.Y))
    end)
    return s
end

--- Keep one body's animation matching what its player is doing.
--- Runs at tick rate, not on the two-second poll: a walk cycle that starts two
--- seconds after the player does is worse than none.
local function driveAnimation(pawn, key)
    local state = anim[key]
    if not state or not state.seqs then return end

    local comp = UE.TryGet(pawn, "Mesh")
    if not UE.alive(comp) then return end

    local speed = speedOf(pawn)
    if speed == nil then return end

    local wanted = "idle"
    if speed > RUN_ABOVE then wanted = "run"
    elseif speed > WALK_ABOVE then wanted = "walk" end

    if wanted == state.playing then return end

    -- Found again by path, only when it changes (UE.findObject costs a little
    -- memory per call, and this runs every tick).
    local seq = UE.findObject(state.seqs[wanted])
    if not UE.alive(seq) then return end

    -- PlayAnimation switches the component to single-node mode itself, which
    -- is what takes the borrowed blueprint out of the picture.
    local ok = pcall(function() comp:PlayAnimation(seq, true) end)
    if ok then
        state.playing = wanted
    else
        -- One failure means this route is not available on this build. Stop
        -- retrying it every tick forever and leave the AnimBP running.
        state.seqs = nil
        Log.debug("PlayAnimation is not callable here - leaving the borrowed " ..
                  "animation blueprint in charge")
    end
end

--------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------

function Bodies.tick(now)
    -- Compared against false so a config.lua predating this option still gets
    -- the feature, the same way AutoSpawnGuestPawns does.
    if not cfg or cfg.BorrowNpcBodies == false then return end
    if UE.IsStandalone() then return end

    local mine  = UE.GetPawn()
    -- No pawn of our own for the moment (a guest's being replaced, say):
    -- nothing tells "ours" from "theirs" then, and a body put on our own
    -- would be inside our camera. Next tick.
    if not UE.alive(mine) then return end

    -- Animation runs every tick. Dressing is the expensive part and stays on
    -- the poll below; matching a walk cycle to a moving player cannot be.
    if cfg.DriveBodyAnimation == true then
        for _, p in ipairs(UE.findAll("Player_Character_C") or {}) do
            if UE.alive(p) and not UE.sameObject(p, mine) then
                local k = nil
                pcall(function() k = p:GetFullName() end)
                if k and anim[k] then
                    Safety.guard(RISKY_OP, driveAnimation, p, k)
                end
            end
        end
    end

    if (now - lastPoll) < POLL_INTERVAL then return end
    lastPoll = now

    local pawns = UE.findAll("Player_Character_C")
    if not pawns then return end

    -- Collect the remote ones first, by name, so nothing is held across the
    -- work below.
    -- `dressed[key]` holds the RANK of the donor used, so a later poll can tell
    -- an upgrade from pointless churn. Anything below the best rank stays a
    -- candidate: staff and customers only exist once the shop is open, so the
    -- donor available at join time is very often the worst one all session.
    local todo, others, present = {}, 0, {}
    for _, p in ipairs(pawns) do
        -- sameObject, not ==: UE4SS returns a new wrapper per lookup, so the
        -- local pawn does not necessarily compare equal to itself. Getting
        -- this wrong puts a borrowed body inside your own head.
        if UE.alive(p) and not UE.sameObject(p, mine) then
            others = others + 1
            local key = nil
            pcall(function() key = p:GetFullName() end)
            if key then
                present[key] = true
                -- Before anything else: whatever reverts the offset does so
                -- after dress() has returned and verified it, so this has to
                -- be a standing check rather than part of dressing.
                Safety.guard(RISKY_OP, holdPlacement, p, key)

                if (dressed[key] or -1) < 3 then
                    todo[#todo + 1] = { key = key, pawn = p, have = dressed[key] }
                end
            end
        end
    end

    -- Forget every pawn that is not here any more. On a guest that is the
    -- host's pawn each time the guest leaves network range: it comes back as
    -- a new actor under a new name, and is dressed again as one.
    for _, book in ipairs({ dressed, placed, placedRot, anim }) do
        for key in pairs(book) do
            if not present[key] then book[key] = nil end
        end
    end

    -- Nothing of anyone else's is here. That is the OTHER bug with this
    -- symptom, and it is worth saying so exactly once rather than sitting
    -- silently doing nothing that could ever help.
    if others == 0 then
        if not reported then
            reported = true
            Log.warn("no other player's pawn exists on this machine, so there is " ..
                     "nothing to give a body to - that is a replication problem, " ..
                     "not a model one. Run rt.why on both machines.")
        end
        return
    end
    reported = false

    if #todo == 0 then return end

    -- Behind the same breadcrumb as dressing: it reads the NPCs' components.
    local searched, donor = Safety.guard(RISKY_OP, findDonor)
    if not searched then
        if not offWarned then
            offWarned = true
            Log.warn("bodies for other players are off after an earlier crash (rt.safety)")
        end
        return
    end
    if not donor then
        if not noDonorWarned then
            noDonorWarned = true
            Log.warn("no NPC to borrow a body from yet - staff and customers " ..
                     "have to exist first. Open the shop and this will retry.")
        end
        return
    end
    noDonorWarned = false

    local rank = donor.rank or 0
    for _, entry in ipairs(todo) do
        -- Only swap for something strictly better. Re-dressing a body with an
        -- equally bad donor every two seconds would be pure churn.
        if entry.have == nil or rank > entry.have then
            local ran = Safety.guard(RISKY_OP, dress, entry.pawn, donor, entry.have ~= nil)
            if not ran then
                if not offWarned then
                    offWarned = true
                    Log.warn("bodies for other players are off after an earlier crash " ..
                             "(rt.safety)")
                end
                return
            end
            dressed[entry.key] = rank
        end
    end
end

--------------------------------------------------------------------------
-- Diagnosis
--------------------------------------------------------------------------

--- Lines for rt.bodies. Answers, in order: is there anyone else here, does
--- their pawn have a mesh, and is there anything to borrow.
function Bodies.reportLines()
    local lines = {}
    local function add(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and s or tostring(fmt)
    end

    local mine  = UE.GetPawn()
    local pawns = UE.findAll("Player_Character_C") or {}
    local others = 0

    for _, p in ipairs(pawns) do
        if UE.alive(p) then
            local isMine = UE.sameObject(p, mine)
            if not isMine then others = others + 1 end

            local comp  = UE.TryGet(p, "Mesh")
            local asset, prop = nil, nil
            if UE.alive(comp) then asset, prop = readMeshAsset(comp) end

            local name = "<none>"
            if UE.valid(asset) then
                local ok, full = pcall(function() return asset:GetFullName() end)
                name = ok and (full:match("([^%.:]+)$") or full) or "<unreadable>"
            end

            add("%-6s %-22s mesh component: %s   asset: %s%s",
                isMine and "yours" or "OTHER",
                UE.ClassNameOf(p),
                UE.alive(comp) and "yes" or "NO",
                name,
                prop and ("  (" .. prop .. ")") or "")

            -- The two numbers that answer "why does it look wrong", measured
            -- off the live component rather than off what dress() meant to do.
            -- A body that floats and a body in a T-pose are separate faults
            -- with separate causes, and this is where they are told apart.
            if not isMine and UE.alive(comp) and UE.valid(asset) then
                local rise = measureRise(p, comp)
                local rel  = readVec(comp, "RelativeLocation")
                local want = (characterMeshOffset(p))
                add("       feet offset: %s   (should be about Z%+.0f)%s",
                    rel and string.format("Z%+.0f", rel.Z) or "<unreadable>",
                    want.Z,
                    rise and string.format("   world rise %+.0f", rise) or "")

                -- The number that decides the one above. Network smoothing
                -- rewrites the component's transform every frame from this
                -- cache, so a Z+0 here means the feet offset is going back to
                -- zero no matter what anything else does.
                local base = readVec(p, "BaseTranslationOffset")
                add("       smoothing:   BaseTranslationOffset %s%s",
                    base and string.format("Z%+.0f", base.Z) or "<unreadable>",
                    (base and near(base.Z, want.Z)) and ""
                    or "   <-- THIS is what flattens the offset every frame")

                local inst = nil
                pcall(function() inst = comp:GetAnimInstance() end)
                add("       animation:   %s",
                    UE.valid(inst) and ("running " .. UE.ClassNameOf(inst))
                    or "NONE - this body is standing in its bind pose (a T-pose)")
            end
        end
    end

    if others == 0 then
        add("")
        add("No other player's pawn exists here.")
        add("  Nothing can be given a body that is not present, so this is a")
        add("  REPLICATION problem, not a model one. rt.why has the detail.")
    end

    add("")
    local donor = findDonor()
    if donor then
        local ok, full = pcall(function() return donor.asset:GetFullName() end)
        add("donor available: %s -> %s", donor.class,
            ok and (full:match("([^%.:]+)$") or full) or "?")
        add("  anim blueprint: %s",
            UE.valid(donor.animClass) and UE.ClassNameOf(donor.animClass)
            or "<none - the body will stand in its bind pose>")
        -- Rank 3 is a real character with animation, and only a real character
        -- has its mesh origin at the feet - which is what decides whether the
        -- donor's own offset is trusted or the engine convention rebuilt.
        add("  rank: %d/3  (%s)", donor.rank or 0,
            donor.isChar and "a character - its own offset is trusted"
            or "not a character - the offset is rebuilt from this pawn's capsule")
    else
        add("no donor NPC in the store right now.")
        add("  Staff and customers are what this borrows from; open the shop.")
    end

    return lines
end

--- Forget what has been done and dress everyone again. Wired to rt.bodies retry.
function Bodies.retry()
    dressed, placed, placedRot, anim = {}, {}, {}, {}
    reported, noDonorWarned = false, false
    lastPoll = 0
end

function Bodies.init(config)
    cfg = config
end

--- Tests only: the per-pawn bookkeeping, keyed by pawn name.
function Bodies._books()
    return { dressed = dressed, placed = placed, anim = anim }
end

return Bodies
