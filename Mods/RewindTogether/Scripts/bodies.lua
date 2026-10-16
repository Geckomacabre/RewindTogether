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
local Chan   = require("rpcchan")
local NpcLook = require("npcsync").look

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
-- Pawn address -> which way its body faces (see "Which way the body faces").
-- Up here because holdPlacement, above that section, has to reach it.
local facing = {}
-- Full names of figures dressed for the character screen (charscreen.lua):
-- not pawns, so the poll's clean-up would forget their hair otherwise.
local figures = {}
local lastPoll = 0
local reported = false
local noneSince = nil         -- when the last other player's pawn went (or none had come yet)
local NOBODY_GRACE = 20.0     -- seconds without one before that is worth a warning
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
    -- SetSkinnedAssetAndUpdate(asset, bReinitPose = true) above all. The
    -- Blueprint-facing SetSkeletalMeshAsset keeps the pose buffers sized for
    -- the OLD mesh, which the parallel animation task then walks: npcsync.lua
    -- measured three guest crashes on it in 1.7.0. Swapping one borrowed body
    -- for a better one is exactly that case.
    if pcall(function() comp:SetSkinnedAssetAndUpdate(asset, true) end)
       and UE.valid((readMeshAsset(comp))) then
        return "SetSkinnedAssetAndUpdate"
    end
    -- The setters next: they do the work SetSkeletalMesh exists to do -
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
                if donor then donor.npc = npc return donor end
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
                if donor then donor.npc = npc end
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
        -- That put the body's yaw back to dress()'s: the turning writes its own again.
        for _, st in pairs(facing) do if st.key == key then st.rel = nil end end
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
-- What they wear: one look per player, the same on every screen
--------------------------------------------------------------------------
--[[
    REPORTED (15 Oct 2026): "a lot we could be doing better, especially with
    player pawn animations and their look; some have broken textured shirts".
    Measured on the host, a guest's body next to a passer-by:
      the body   SK_CHA_M_01 in the mesh's own default materials
                 (MI_CHA_Cloth_Tshirt_01 ...), bald, the staring default face
      the NPC    dynamic materials of those same parents, each with its own
                 base-colour texture and tint; hair, beard and glasses as
                 static meshes on HeadTop_EndSocket; a set mouth
    The body was only ever an NPC's MESH, never its look. And each machine
    borrowed from whichever NPC it found first, so the host, a guest and a
    second guest each saw a player as somebody different.

    So the HOST picks a look for every player - each off a different town NPC,
    read with npcsync.lua's own readLook - keeps it for the session, and sends
    it to everyone ("plook": PlayerId + the look; a PlayerId is the same on
    every machine). Every machine dresses each other player's body in it with
    npcsync's own calls (the body mesh by SetSkinnedAssetAndUpdate, the eight
    slots, the eyes, a neutral face) and gives it hair, beard and glasses as
    components of its own - a Player_Character_C has none - with
    AddComponentByClass (measured working) and the NPC's own attachment:
    HeadTop_EndSocket, snap location, keep relative rotation and scale
    (AI_Base_Character "Attach Child to Skeletal" @33527). Until the host's
    look arrives - or with a host on an older version - a body wears the look
    of the local NPC its mesh came from.
]]
local LOOK_SEND_EVERY = 10.0
local HEAD_SOCKET = "HeadTop_EndSocket"
local IDENTITY = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                   Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
                   Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
-- Whose look a player gets, best first: passers-by and customers wear the
-- town's variety; the staff wear the store's uniform.
local LOOK_PREFER = { AI_WalkBy_Character_C = 1, AI_Client_Character_C = 1,
                      AI_BackAlleyVendor_Character_C = 2, AI_Employee_Character_C = 3 }

local looks = {}        -- PlayerId -> the look the host gave that player
local localLook = {}    -- pawn full name -> the look of the local NPC its body came from
local wearing = {}      -- pawn full name -> the look it has on (a signature)
local heights = {}      -- pawn full name -> its Character Scale (the walk's play rate needs it)
local headComps = {}    -- pawn full name -> { h = path, f = path, a = path }: its hair etc.
local usedDonor = {}    -- host: NPC name -> the PlayerId wearing its look
local nextLookSend = 0
local lookStats = { assigned = 0, sent = 0, received = 0, worn = 0 }

local function stateId(ps)
    if not UE.valid(ps) then return nil end
    local id = tonumber(UE.TryGet(ps, "PlayerId"))
    if id == nil then pcall(function() id = tonumber(ps:GetPlayerId()) end) end
    return id
end

local function pawnId(pawn) return stateId(UE.TryGet(pawn, "PlayerState")) end

--- A look worth wearing: its top is a dressed dynamic material ("parent|
--- texture|tint" with a texture). An NPC a moment old is still in the mesh's
--- defaults, which is the very look being replaced.
local function dressedLook(look)
    return type(look) == "table" and type(look.m) == "string" and look.m ~= ""
       and ((look.s1 or ""):match("^[^|]*|[^|]+|") ~= nil)
end

--- Host: a town NPC's look nobody wears yet, for this player.
local function pickLook(pid)
    local best, bestName, bestRank = nil, nil, 99
    for _, npc in ipairs(UE.findAll(ANY_NPC) or {}) do
        if UE.alive(npc) and UE.TryGet(npc, "bHidden") ~= true then
            local name = nil
            pcall(function() name = npc:GetFName():ToString() end)
            local rank = LOOK_PREFER[UE.ClassNameOf(npc)] or 2
            if name and usedDonor[name] == nil and rank < bestRank then
                local look = NpcLook.read(npc)
                if dressedLook(look) then best, bestName, bestRank = look, name, rank end
            end
        end
    end
    if not best then return nil end
    usedDonor[bestName] = pid
    return best
end

--- Host: this player has chosen how they look (character.lua) - theirs for
--- the session, sent to everyone at once.
function Bodies.chooseLook(pid, look, why)
    if not (pid and type(look) == "table" and dressedLook(look)) then return false end
    looks[pid] = look
    for name, who in pairs(usedDonor) do if who == pid then usedDonor[name] = nil end end
    nextLookSend = 0
    Log.info("bodies: player %d looks like a %s to everyone (%s)", pid,
             (look.m or ""):match("([^/%.]+)$") or "town character", why or "chosen")
    return true
end

--- The look this machine has for a player, or nil.
function Bodies.lookOf(pid) return looks[pid] end

local function assignLooks()
    for _, ps in ipairs(UE.findAll("PlayerState") or {}) do
        local pid = stateId(ps)
        if pid and not looks[pid] then
            local look = pickLook(pid)
            if look then
                looks[pid] = look
                lookStats.assigned = lookStats.assigned + 1
                Log.info("bodies: player %d will look like a %s to everyone", pid,
                         (look.m or ""):match("([^/%.]+)$") or "town NPC")
            end
        end
    end
end

local function sendLooks(now)
    if now < nextLookSend or not Chan.isReady() then return end
    nextLookSend = now + LOOK_SEND_EVERY
    local here = {}
    for _, ps in ipairs(UE.findAll("PlayerState") or {}) do
        local pid = stateId(ps)
        if pid then here[pid] = true end
    end
    for pid, look in pairs(looks) do
        if here[pid] then
            local payload = { p = tostring(pid) }
            for k, v in pairs(look) do payload[k] = v end
            if Chan.broadcast("plook", payload) > 0 then lookStats.sent = lookStats.sent + 1 end
        end
    end
end

local function onLook(fields)
    if not UE.IsClient() then return end
    local pid = tonumber(fields.p)
    if not pid then return end
    local look = {}
    for k, v in pairs(fields) do if k ~= "p" then look[k] = v end end
    if dressedLook(look) then
        looks[pid] = look
        lookStats.received = lookStats.received + 1
    end
end

local function signature(look)
    local parts = { look.m or "" }
    for i = 0, 7 do parts[#parts + 1] = look["s" .. i] or "" end
    for _, k in ipairs({ "h", "hm", "f", "fm", "a", "am", "e", "eb", "cs" }) do parts[#parts + 1] = look[k] or "" end
    return table.concat(parts, "\n")
end

--- Their height: the look's Character Scale, on the body mesh the way the
--- game sizes a town character (npcsync.lua's applySize). The mesh's origin
--- is at its feet, so they stay on the floor.
local function wearHeight(mesh, key, look)
    local cs = tonumber(look.cs)
    if not (cs and cs > 0.5 and cs < 1.5) then cs = 1.0 end
    pcall(function() mesh:SetRelativeScale3D({ X = cs, Y = cs, Z = cs }) end)
    heights[key] = cs
end

--- This pawn's own hair / beard / glasses component, found again by path
--- (never kept as a pointer), made when `create` and it has none.
local function headPiece(pawn, key, mesh, slot, create)
    local book = headComps[key]
    if not book then book = {} headComps[key] = book end
    local c = book[slot] and UE.findObject(book[slot]) or nil
    if UE.valid(c) then return c end
    if not create then return nil end
    local cls = StaticFindObject("/Script/Engine.StaticMeshComponent")
    if not UE.valid(cls) then return nil end
    pcall(function() c = pawn:AddComponentByClass(cls, true, IDENTITY, false) end)
    if not UE.valid(c) then return nil end
    pcall(function() c:K2_AttachToComponent(mesh, FName(HEAD_SOCKET), 2, 0, 0, true) end)
    -- Hair that blocks: the host's traces for a guest's pickups would hit it.
    pcall(function() c:SetCollisionEnabled(0) end)
    book[slot] = UE.pathOf(c)
    return c
end

local function wearHead(pawn, key, mesh, look)
    for slot in pairs(NpcLook.HEAD) do
        local path = look[slot]
        local m = (type(path) == "string" and path ~= "") and NpcLook.asset(path) or nil
        if m then
            local c = headPiece(pawn, key, mesh, slot, true)
            if c then
                pcall(function() c:SetStaticMesh(m) end)
                pcall(function() c:SetVisibility(true, false) end)
                local i = 0
                for spec in (look[slot .. "m"] or ""):gmatch("[^%^]+") do
                    NpcLook.dressSlot(c, i, spec)
                    i = i + 1
                end
            end
        else
            local c = headPiece(pawn, key, mesh, slot, false)
            if c then pcall(function() c:SetVisibility(false, false) end) end
        end
    end
end

--- Put this pawn's look on it, once per look.
local function wearLook(pawn, key)
    local pid = pawnId(pawn)
    local look = (pid and looks[pid]) or localLook[key]
    if not look then return end
    local sig = signature(look)
    if wearing[key] == sig then return end
    local mesh = UE.TryGet(pawn, "Mesh")
    if not UE.alive(mesh) then return end
    local body = NpcLook.asset(look.m)
    if body and not UE.sameObject(readMeshAsset(mesh), body) then
        if not pcall(function() mesh:SetSkinnedAssetAndUpdate(body, true) end) then return end
    end
    NpcLook.dressBody(mesh, look)
    NpcLook.face(mesh, 0)
    wearHead(pawn, key, mesh, look)
    wearHeight(mesh, key, look)
    wearing[key] = sig
    lookStats.worn = lookStats.worn + 1
    Log.info("bodies: %s dressed in %s", UE.ClassNameOf(pawn),
             (pid and looks[pid]) and ("the look the host gave player " .. pid)
             or "the look of the NPC its body came from")
end

--- Dress any actor's skeletal mesh in a look the way a body is dressed: the
--- body mesh, its materials, a neutral face, hair, beard and glasses
--- (character.lua's figure in the character select). Returns whether the
--- body mesh is on.
function Bodies.dressFigure(actor, mesh, look)
    if not (UE.alive(actor) and UE.alive(mesh) and type(look) == "table") then return false end
    local body = NpcLook.asset(look.m)
    if not body or not pcall(function() mesh:SetSkinnedAssetAndUpdate(body, true) end) then return false end
    NpcLook.dressBody(mesh, look)
    NpcLook.face(mesh, 0)
    local key = nil
    pcall(function() key = actor:GetFullName() end)
    if key then
        figures[key] = true
        wearHead(actor, key, mesh, look)
    end
    return true
end

--- The character screen's figure is gone: forget its hair and the rest.
function Bodies.dropFigure(actor)
    local key = nil
    pcall(function() key = actor:GetFullName() end)
    if not key then return end
    figures[key] = nil
    headComps[key] = nil
end

--- Whether a look is one worth wearing (a dressed top: see dressedLook).
function Bodies.isLook(look) return dressedLook(look) end

--- Two looks the same? (the parts that show)
function Bodies.sameLook(a, b) return type(a) == "table" and type(b) == "table" and signature(a) == signature(b) end

--------------------------------------------------------------------------
-- What their body does
--------------------------------------------------------------------------
--[[
    MEASURED on the host (15 Oct 2026): a guest's body running the town's
    animation blueprint showed Speed 0 and Scale Character Play Rate 0 while
    the guest walked - a passer-by beside it, 165 and 1.14. AnimBP_Base_C's
    update (@4578) casts its pawn to AI_Base_Character_C and stops when that
    fails, which on a player it always does: nothing past the cast ever sets
    Speed (its idle/walk transitions are Speed > 2 / Speed < 1) or the walk's
    play rate (an NPC's Max Speed Walk Scale / Character Scale). So the body
    stood idle while its player walked, or walked frozen at rate 0.

    The blueprint's own variables, then, written here every tick: the pawn's
    speed, a play rate that matches its legs to it, and whether it is carrying
    something (its hand socket has a child), which the blueprint blends into
    the carrying pose (@2365). Fed this way by hand, the body walked.
]]
-- The town's walk cycle plays at rate 1.0 for about this ground speed, cm/s:
-- a passer-by measured 165 cm/s at Scale Character Play Rate 1.143.
local WALK_CYCLE_SPEED = 144.0

local function carrying(pawn)
    local socket = UE.TryGet(pawn, "AttachObject Socket")
    local n = 0
    if UE.valid(socket) then pcall(function() n = socket:GetNumChildrenComponents() end) end
    return (tonumber(n) or 0) > 0
end

--[[
    What they carry, in their hands. A held item hangs on the pawn's
    "AttachObject Socket", which sits under the first-person camera rig (its
    parent is "Lag offset", -80/0/-20 from it): right for the player holding
    it, and in mid-air beside the head on everybody else's screen (measured:
    a guest's tape at 2413,20,140, the guest at 2444,41). The socket itself does
    not replicate - only the item's attachment to it does - so every machine
    where this player is somebody else puts the socket on the body's own hand
    (the skeleton's hand_rSocket; the stack's socket on hand_lSocket), and the
    item goes with it. On the host a guest's pickup also plays the socket's
    first-person "bring up" timeline (Player_Character @19159), which writes
    its relative location - relative to the hand, now - so that is put back
    every tick.
]]
local HAND_SOCKETS = { { "AttachObject Socket", "hand_rSocket" },
                       { "AttachObject Inventory Socket", "hand_lSocket" } }
local handsOn = {}      -- pawn full name -> true once its sockets are on its hands

local function holdInHands(pawn, key)
    if handsOn[key] then return end
    local mesh = UE.TryGet(pawn, "Mesh")
    if not UE.alive(mesh) then return end
    local moved = 0
    for _, pair in ipairs(HAND_SOCKETS) do
        local socket = UE.TryGet(pawn, pair[1])
        if UE.valid(socket) and pcall(function()
                socket:K2_AttachToComponent(mesh, FName(pair[2]), 2, 2, 1, false)
            end) then
            moved = moved + 1
        end
    end
    handsOn[key] = true
    Log.debug("bodies: %d carrying socket(s) moved onto %s's hands", moved, UE.ClassNameOf(pawn))
end

--[[
    REPORTED (16 Oct 2026, a screenshot from the guest): what the host carried
    floated beside the host - the stack low and in front, the tape in hand off
    the hand. MEASURED on the guest: both sockets were on the hand bones, but
    each item hangs from its socket at the offset the first-person pickup gave
    it (the stack's tape -68,-21,-2, the hand's -68,21,8): 70 cm from the
    hand. That offset is the item's replicated attachment - changed on the
    host it would also move the guest's own first-person view of its own
    things - so the SOCKET goes the other way instead: minus its first item's
    offset, which puts the item on the hand. No item: the hand itself.
]]
local function keepInHands(pawn)
    for _, pair in ipairs(HAND_SOCKETS) do
        local socket = UE.TryGet(pawn, pair[1])
        if UE.valid(socket) then
            local want = { X = 0.0, Y = 0.0, Z = 0.0 }
            local item = nil
            pcall(function() item = socket:GetChildComponent(0) end)
            local off = UE.valid(item) and readVec(item, "RelativeLocation") or nil
            if off then want = { X = -off.X, Y = -off.Y, Z = -off.Z } end
            local rel = readVec(socket, "RelativeLocation")
            if rel and (math.abs(rel.X - want.X) + math.abs(rel.Y - want.Y) + math.abs(rel.Z - want.Z)) > 1.0 then
                setRelLocation(socket, want)
            end
        end
    end
end

local function addressOf(o)
    local a = nil
    pcall(function() a = o:GetAddress() end)
    return a
end

local function feedAnimation(pawn, key)
    local speed = speedOf(pawn) or 0.0
    local mesh = UE.TryGet(pawn, "Mesh")
    if not UE.alive(mesh) then return speed end
    local inst = nil
    pcall(function() inst = mesh:GetAnimInstance() end)
    if not UE.valid(inst) or UE.ClassNameOf(inst) ~= "AnimBP_Base_C" then return speed end
    UE.TrySet(inst, "Speed", speed)
    -- A shorter body's legs take shorter steps: the town's own rate is its
    -- walk speed over its Character Scale.
    local stride = WALK_CYCLE_SPEED * ((key and heights[key]) or 1.0)
    UE.TrySet(inst, "Scale Character Play Rate",
              speed > 2 and math.max(0.5, math.min(2.5, speed / stride)) or 1.0)
    UE.TrySet(inst, "Is Holding Something", carrying(pawn))
    -- Standing still is 0.5, not the 0 nobody writes (see "Which way the
    -- body faces"); a body the turning is turning gets its value per frame.
    local st = facing[addressOf(pawn) or 0]
    if not (st and st.turning) then UE.TrySet(inst, "Rotation Delta Z Normalize", 0.5) end
    return speed
end

--------------------------------------------------------------------------
-- Which way the body faces
--------------------------------------------------------------------------
--[[
    REPORTED (16 Oct 2026, with a friend and in the two-copy tests): "why do
    the player pawns move in circles". MEASURED: a remote player's whole body
    faced exactly where that player looked - the guest's body went to yaw -16
    the moment its camera did. A first-person pawn's rotation IS its view
    (the controller's yaw), and that is what replicates. People look around
    all the time, so on everybody else's screen the bodies spun on the spot -
    and at a machine, where the view swings from part to part, round and
    round.

    The other half of it was in the legs. MEASURED on the guest (a recording
    from the user, then the host's body sampled): standing still, its hips
    went round a loop about 30 cm across every 1.6 s, feet stepping - a
    turning-on-the-spot cycle. AnimBP_Base adds its "Blend1D_Rotate" (the
    town's Anim_CHA_Rotate_Left/Right steps) at full weight whenever the
    character stands (ApplyMeshSpaceAdditive, alpha 1 - Speed/15), picked by
    "Rotation Delta Z Normalize": an NPC's update makes that (still to turn +
    rate/2) / rate, so 0.5 standing still. On a player nothing writes it and
    it sits at 0 - turning round, for ever. Measured: hips moved 21 x 16 cm
    at 0, 17 x 12 at 1, 0 x 1 at 0.5. So it is 0.5, and while the body turns
    on the spot it is the NPC's own formula, which steps the feet round with
    the turn.

    So the body turns like a person's. Standing, the head follows the view -
    the town NPCs' own look-at node on the head bone, clamped at 60 degrees
    (AnimBP_Base: "Look At Pos", world space, and "Look at Player Alpha",
    which its own update never writes on a player: it stops at the AI cast,
    @4694) - and the body stays put until the view is more than TURN_AFTER
    away, then turns on the spot to catch up. Walking, the body turns with
    the view.

    Every frame, not on the mod's 10 Hz tick: a body counter-turned ten
    times a second shakes while its player turns. A hook on the pawn's own
    ReceiveTick does it, and writes only properties - the character's
    BaseRotationOffset, which network smoothing puts the mesh at on every
    update (see setBaseMeshOffset), and the mesh's RelativeRotation, which
    the capsule's next move carries to the screen. An engine call with a
    struct argument costs a little memory in UE4SS 3.0.1 (ue.lua), so the one
    such call here, putting the mesh straight, runs only on frames where
    nothing else would: the body still turning after the view has stopped.
    The engine's own rotation smoothing on these pawns is set to zero: it
    eases the mesh toward each new view yaw, which is the very turn being
    taken out, and would shake the body by it.
]]
local TURN_AFTER   = 60.0     -- degrees from the view before a standing body turns (the head covers 60)
local TURN_DONE    = 3.0      -- degrees: close enough, the turn ends
local TURN_RATE    = 300.0    -- degrees a second, turning on the spot
local WALK_RATE    = 720.0    -- degrees a second, walking
local MOVING_ABOVE = 30.0     -- cm/s
local EYE_HEIGHT   = 64.0     -- cm above the capsule's centre: the first-person camera
local LOOK_AHEAD   = 300.0    -- cm along the view, where the head looks
local STEP_SPAN    = 240.0    -- degrees still to turn for the full stepping turn (an NPC's: its turn rate)

-- facing (declared at the top): pawn address -> { live, speed, base (the
-- mesh yaw dress() put), body (world yaw), turning, at, view, rel, settle,
-- key }. By address because it is read every frame, where a GetFullName would
-- be too dear; the 10 Hz tick drops the ones that are gone.
local myAddress = nil
local turnHooked, turnHookNext = nil, 0     -- the hooked function's address

local function wrap(a) return (a + 180.0) % 360.0 - 180.0 end

--- The head looks where its player looks: a point along the view. And the
--- legs step round while the body turns on the spot (turn: degrees still to
--- go, or nil).
local function aimHead(pawn, at, yaw, turn)
    local mesh = UE.TryGet(pawn, "Mesh")
    local inst = nil
    if UE.valid(mesh) then pcall(function() inst = mesh:GetAnimInstance() end) end
    if not UE.valid(inst) then return end
    UE.TrySet(inst, "Rotation Delta Z Normalize",
              turn and math.max(0.0, math.min(1.0, 0.5 + turn / STEP_SPAN)) or 0.5)
    local b = tonumber(UE.TryGet(pawn, "RemoteViewPitch")) or 0
    local pitch = b * 360.0 / 255.0
    if pitch > 180.0 then pitch = pitch - 360.0 end
    local p, y = math.rad(pitch), math.rad(yaw)
    UE.TrySet(inst, "Look At Pos", {
        X = at.X + math.cos(p) * math.cos(y) * LOOK_AHEAD,
        Y = at.Y + math.cos(p) * math.sin(y) * LOOK_AHEAD,
        Z = at.Z + EYE_HEIGHT + math.sin(p) * LOOK_AHEAD })
end

--- One remote pawn, one frame (the ReceiveTick hook).
local function turnFrame(pawn)
    local st = facing[addressOf(pawn) or 0]
    if not (st and st.live) then return end
    local root = UE.TryGet(pawn, "RootComponent")
    if not UE.valid(root) then return end
    local r = readRot(root, "RelativeRotation")
    local at = readVec(root, "RelativeLocation")
    if not (r and at) then return end
    local view = r.Yaw

    local now = os.clock()
    local dt = math.min(0.1, math.max(0.0, now - (st.at or now)))
    st.at = now
    st.body = st.body or view

    local diff = wrap(view - st.body)
    local moving = (st.speed or 0) > MOVING_ABOVE
    if moving or math.abs(diff) > TURN_AFTER then st.turning = true end
    if st.turning then
        local stepBy = (moving and WALK_RATE or TURN_RATE) * dt
        if math.abs(diff) <= stepBy then
            st.body = view
        else
            st.body = wrap(st.body + (diff > 0 and stepBy or -stepBy))
        end
        if not moving and math.abs(wrap(view - st.body)) < TURN_DONE then st.turning = false end
    end

    local want = wrap(st.base + wrap(st.body - view))
    local viewMoved = st.view == nil or math.abs(wrap(view - st.view)) > 0.01
    st.view = view
    if st.rel == nil or math.abs(wrap(want - st.rel)) > 0.2 then
        st.rel = want
        local rot = { Pitch = 0.0, Yaw = want, Roll = 0.0 }
        UE.TrySet(pawn, "BaseRotationOffset", rotatorToQuat(rot))
        local mesh = UE.TryGet(pawn, "Mesh")
        if UE.valid(mesh) then
            UE.TrySet(mesh, "RelativeRotation", UE.rotArg(rot))
            -- The capsule did not move this frame, so nothing would carry
            -- the new rotation to the screen.
            if not viewMoved then
                pcall(UE.withHit, function(hit) mesh:K2_SetRelativeRotation(UE.rotArg(rot), false, hit, false) end)
            else
                st.settle = true
            end
        end
    elseif st.settle and not viewMoved then
        -- The view has stopped: put the mesh exactly where it belongs once,
        -- in case smoothing placed it before this frame's offset was written.
        st.settle = false
        local mesh = UE.TryGet(pawn, "Mesh")
        if UE.valid(mesh) then
            pcall(UE.withHit, function(hit)
                mesh:K2_SetRelativeRotation(UE.rotArg({ Pitch = 0.0, Yaw = st.rel, Roll = 0.0 }), false, hit, false)
            end)
        end
    end
    aimHead(pawn, at, view, st.turning and wrap(view - st.body) or nil)
end

-- Not Safety.guard per frame: it flushes the crash record to disk twice a
-- call. Only property reads and writes run here, and the bodies' own switch
-- (RISKY_OP) is honoured; repeated Lua errors switch the turning off.
local turnErrors, turnOff, turnLastError = 0, false, nil

-- MEASURED (host): a guest's pawn never runs its ReceiveTick there -
-- guestinput.lua stops it (its look-at trace would act on the host's
-- screen) - while on a guest the host's pawn ticks every frame. So on the
-- host the host's own pawn's tick turns every guest's body, found through
-- the controllers (engine calls that take and return only objects and
-- numbers: nothing to leak).
local othersFromMine = false

local function turnOne(pawn)
    local ok, err = pcall(turnFrame, pawn)
    if not ok then
        turnErrors, turnLastError = turnErrors + 1, tostring(err)
        if turnErrors >= 30 then
            turnOff = true
            Log.warn("bodies: natural turning switched off after repeated errors: %s", tostring(err))
        end
    end
end

local TURN_HOOK = "/Game/VideoStore/core/pawn/Player_Character.Player_Character_C:ReceiveTick"

--- Hooked again whenever the function itself is a new object (a reloaded
--- Blueprint class takes its hooks with it), as mirror.lua does.
local function hookTurning(now)
    if now < turnHookNext then return end
    turnHookNext = now + 5.0
    local f, addr = StaticFindObject(TURN_HOOK), nil
    if UE.valid(f) then addr = addressOf(f) end
    if not addr or addr == turnHooked then return end
    local ok = pcall(function()
        RegisterHook(TURN_HOOK, function(ctx)
            if turnOff or next(facing) == nil then return end
            local pawn = nil
            pcall(function() pawn = ctx:get() end)
            if not pawn then return end
            if addressOf(pawn) ~= myAddress then return turnOne(pawn) end
            if not othersFromMine then return end
            for _, pc in ipairs(UE.GetAllPlayerControllers()) do
                local other = nil
                pcall(function() other = pc.Pawn end)
                local addr = UE.valid(other) and addressOf(other) or nil
                if addr and addr ~= myAddress and facing[addr] then turnOne(other) end
            end
        end)
    end)
    if ok then
        turnHooked = addr
        Log.debug("bodies: turning hooked to the pawns' own tick")
    end
end

--- 10 Hz, per remote pawn: what the frame hook needs, read here where it is
--- cheap enough.
local function turnTick(pawn, key, speed)
    local addr = addressOf(pawn)
    if not addr then return end
    local st = facing[addr]
    if not st then
        st = {}
        facing[addr] = st
        -- No easing toward the view's yaw (see above); location smoothing stays.
        local move = UE.TryGet(pawn, "CharacterMovement")
        if UE.alive(move) then
            UE.TrySet(move, "NetworkSimulatedSmoothRotationTime", 0.0)
            UE.TrySet(move, "ListenServerNetworkSimulatedSmoothRotationTime", 0.0)
        end
    end
    st.live = dressed[key] ~= nil
    st.speed = speed
    st.base = (placedRot[key] and placedRot[key].Yaw) or -90.0
    st.key = key
    local mesh = UE.TryGet(pawn, "Mesh")
    local inst = nil
    if UE.valid(mesh) then pcall(function() inst = mesh:GetAnimInstance() end) end
    if UE.valid(inst) then UE.TrySet(inst, "Look at Player Alpha", st.live and 1.0 or 0.0) end
end

--------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------

function Bodies.tick(now)
    -- Compared against false so a config.lua predating this option still gets
    -- the feature, the same way AutoSpawnGuestPawns does.
    if not cfg or cfg.BorrowNpcBodies == false then return end
    if UE.IsStandalone() then noneSince = nil return end

    local mine  = UE.GetPawn()
    -- No pawn of our own for the moment (a guest's being replaced, say):
    -- nothing tells "ours" from "theirs" then, and a body put on our own
    -- would be inside our camera. Next tick.
    if not UE.alive(mine) then return end

    -- The animation blueprint's own inputs, the carried things in the hands
    -- and which way the body faces, every tick (feedAnimation, keepInHands,
    -- turnTick).
    myAddress = addressOf(mine)
    local turning = cfg.NaturalTurning ~= false and not Safety.isBlocked(RISKY_OP)
    if not turning then facing = {} end
    othersFromMine = UE.IsServer()
    if turning then hookTurning(now) end
    local seen = {}
    for _, p in ipairs(UE.findAll("Player_Character_C") or {}) do
        if UE.alive(p) and not UE.sameObject(p, mine) then
            local k = nil
            pcall(function() k = p:GetFullName() end)
            local _, speed = pcall(feedAnimation, p, k)
            if k and handsOn[k] then pcall(keepInHands, p) end
            if k and turning then
                pcall(turnTick, p, k, tonumber(speed) or 0.0)
                seen[addressOf(p) or 0] = true
            end
        end
    end
    for addr in pairs(facing) do
        if not seen[addr] then facing[addr] = nil end
    end

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

    -- The host decides what everybody looks like, and tells everyone.
    if UE.IsServer() and cfg.PlayerLooks ~= false then
        Safety.guard(RISKY_OP, assignLooks)
        sendLooks(now)
    end

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
                -- Its look goes on a body that has been dressed (a poll after):
                -- a mesh put there first would make dress() leave it alone,
                -- animation and placement included.
                if dressed[key] ~= nil and cfg.PlayerLooks ~= false then
                    Safety.guard(RISKY_OP, wearLook, p, key)
                end
                if dressed[key] ~= nil and cfg.CarryInHands ~= false then
                    Safety.guard(RISKY_OP, holdInHands, p, key)
                end

                if (dressed[key] or -1) < 3 then
                    todo[#todo + 1] = { key = key, pawn = p, have = dressed[key] }
                end
            end
        end
    end

    -- Forget every pawn that is not here any more. On a guest that is the
    -- host's pawn each time the guest leaves network range: it comes back as
    -- a new actor under a new name, and is dressed again as one.
    for _, book in ipairs({ dressed, placed, placedRot, anim, wearing, localLook, headComps, handsOn }) do
        for key in pairs(book) do
            if not present[key] and not figures[key] then book[key] = nil end
        end
    end

    -- Nothing of anyone else's is here. That is the OTHER bug with this
    -- symptom, and it is worth saying so exactly once rather than sitting
    -- silently doing nothing that could ever help.
    -- MEASURED (lag, rejoin and 3-player tests, 15 Oct 2026): it fired on every
    -- join - the others' pawns land a few seconds after the level - and on the
    -- host each time a guest left. Neither is a problem, and the text sent
    -- people looking for one. Now only when someone else is in the session
    -- (their PlayerState is here) and has had no pawn for NOBODY_GRACE seconds.
    if others == 0 then
        if #(UE.findAll("PlayerState") or {}) <= 1 then
            noneSince = nil                -- alone: nobody's pawn to wait for
        else
            noneSince = noneSince or now
        end
        if not reported and noneSince and (now - noneSince) >= NOBODY_GRACE then
            reported = true
            Log.warn("no other player's pawn exists on this machine, so there is " ..
                     "nothing to give a body to - that is a replication problem, " ..
                     "not a model one. Run rt.why on both machines.")
        end
        return
    end
    reported, noneSince = false, nil

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
            -- A new body: its look goes on again, and until the host's
            -- arrives it is the look of the NPC this one came from.
            wearing[entry.key] = nil
            local fallback = UE.alive(donor.npc) and NpcLook.read(donor.npc) or nil
            localLook[entry.key] = dressedLook(fallback) and fallback or nil
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
    add("%s", Bodies.lookReport())
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
    wearing, localLook, handsOn = {}, {}, {}
    reported, noDonorWarned = false, false
    lastPoll = 0
end

--- A session ended: the looks were the host's choice for that session.
function Bodies.reset()
    Bodies.retry()
    looks, usedDonor, headComps, nextLookSend = {}, {}, {}, 0
    facing, myAddress, heights = {}, nil, {}
end

function Bodies.init(config)
    cfg = config
    Chan.on("plook", function(f) Log.guard("a player's look", onLook, f) end)
end

function Bodies.lookReport()
    local n = 0
    for _ in pairs(looks) do n = n + 1 end
    return ("Player looks: %d known, %d assigned here, %d sent, %d received, %d bodies dressed in one")
        :format(n, lookStats.assigned, lookStats.sent, lookStats.received, lookStats.worn)
end

--- Tests only: the per-pawn bookkeeping, keyed by pawn name.
--- Which way the bodies face, for rt.bodies and the tests.
function Bodies._turning()
    return { facing = facing, errors = turnErrors, lastError = turnLastError, off = turnOff, hooked = turnHooked }
end

function Bodies._books()
    return { dressed = dressed, placed = placed, anim = anim }
end

return Bodies
