--[[
    Rewind Together - the character creator's model: what a character is made
    of, every choice the game itself has, and the look that makes

    A CHARACTER (a "spec") is what the game picks when it makes a townsperson
    (bp/AI_Base_Character: Return SK Mesh / Top / Bottom / Shoes for the
    season, Return Skin Color, Set Hair Mesh Style, Return Hair Color Array):

      body        one of the game's bodies (wardrobe.bodies: two women, two
                  men, and the dealer's, which two of the regulars wear)
      skin        1 or 2 - the skin tone, which picks the skin's material
                  (@23193: tone 1 the *_02, tone 2 the *_01)
      skinTex     the body's texture (the regulars have their own: a punk's,
                  an old man's arms)
      hair        a hair (or hat) mesh, "" for none; hairBc a hat's texture
      hairColour  1..9, the game's hair colours (@27958), on the hair, the
                  brows (the body's "Hair" slot) and any beard
      facial      a beard or moustache mesh, ""
      acc         glasses or a mask, ""
      top, bottom, shoes   textures made for that body, each with a tint
                  (the game tints them at random; a regular's are untinted)
      height      the regular's SizeHeight / an NPC's Character Scale

    The options are the game's own lists (wardrobe.lua, made from the
    Blueprints by dev/make_wardrobe.py) and the 14 named regulars of
    AI_Data_Membership-Unique, which are also the presets.

    A spec becomes a LOOK - the same table npcsync.lua reads off an NPC and
    bodies.lua dresses a body in (m, s0..s7 "parent|texture|r,g,b", h/hm,
    f/fm, a/am, cs) - by each mesh's own material slots, read off the asset
    by NAME (Skin, ClothTop, ClothBottom, ClothShoes, Hair...; measured: the
    same eight, in the same order, on every body; a hair mesh has ClothTop -
    its hat part - and Hair).
]]

local UE = require("ue")
local W  = require("wardrobe")

local Creator = {}

local WHITE = "1.000,1.000,1.000"

-- Clothes colours: the game picks a tint at random (0.05..0.95 a channel,
-- @289); a palette is easier to choose from. The first is the texture's own.
Creator.PALETTE = {
    { label = "Original", tint = WHITE },
    { label = "Red",      tint = "0.850,0.150,0.150" },
    { label = "Orange",   tint = "0.920,0.450,0.100" },
    { label = "Yellow",   tint = "0.920,0.800,0.150" },
    { label = "Green",    tint = "0.200,0.700,0.250" },
    { label = "Teal",     tint = "0.150,0.650,0.650" },
    { label = "Blue",     tint = "0.200,0.350,0.880" },
    { label = "Navy",     tint = "0.120,0.150,0.420" },
    { label = "Purple",   tint = "0.520,0.250,0.780" },
    { label = "Pink",     tint = "0.920,0.420,0.650" },
    { label = "Brown",    tint = "0.450,0.300,0.180" },
    { label = "Grey",     tint = "0.500,0.500,0.500" },
    { label = "Black",    tint = "0.120,0.120,0.120" },
}

local BODY_LABEL = { F_01 = "Woman 1", F_02 = "Woman 2", M_01 = "Man 1", M_02 = "Man 2", Dealer = "Man 3" }
local HEIGHTS = { 0.85, 0.9, 0.95, 1.0, 1.05, 1.1 }

local bodies, bodyOrder = {}, {}
for _, b in ipairs(W.bodies) do
    bodies[b.key] = b
    bodyOrder[#bodyOrder + 1] = b.key
end

local function bodyOfMesh(mesh)
    for _, b in ipairs(W.bodies) do
        if b.mesh == mesh then return b.key end
    end
    return nil
end

local function addOnce(list, v)
    if type(v) ~= "string" or v == "" then return end
    for _, x in ipairs(list) do if x == v then return end end
    list[#list + 1] = v
end

-- Everything one body can wear: the game's lists, then what the regulars of
-- that body wear (their textures were made for it).
local wear = {}
for _, key in ipairs(bodyOrder) do
    local c = W.clothes[key] or {}
    wear[key] = { top = {}, bottom = {}, shoes = {}, skinTex = {} }
    for _, k in ipairs({ "top", "bottom", "shoes" }) do
        for _, v in ipairs(c[k] or {}) do addOnce(wear[key][k], v) end
    end
    addOnce(wear[key].skinTex, bodies[key].skinTex)
end
for _, r in ipairs(W.regulars) do
    local key = bodyOfMesh(r.mesh)
    if key then
        addOnce(wear[key].top, r.top)
        addOnce(wear[key].bottom, r.bottom)
        addOnce(wear[key].shoes, r.shoes)
        addOnce(wear[key].skinTex, r.bodyTex)
    end
end
-- The dealer's body has no list of its own: the men's (it is a man's body).
for _, k in ipairs({ "top", "bottom", "shoes" }) do
    if #wear.Dealer[k] == 0 then
        for _, v in ipairs(wear.M_01[k]) do addOnce(wear.Dealer[k], v) end
    end
end

-- Hair by gender, from the game's hair list (NPC_Hair_F_* / _M_*) and the
-- regulars'; glasses and masks for anyone.
local hairs = { F = { "" }, M = { "" } }
local accessories = { "" }
local hatBc = {}            -- mesh -> its textures, for the hats that have some
for _, h in ipairs(W.hats) do
    local name = h.mesh:match("([^/%.]+)$") or ""
    if name:find("Glasses") or name:find("Mask") then
        addOnce(accessories, h.mesh)
    elseif name:find("_F_") then
        addOnce(hairs.F, h.mesh)
    elseif name:find("_M_") then
        addOnce(hairs.M, h.mesh)
    end
    if #h.bc > 0 then hatBc[h.mesh] = h.bc end
end
for _, r in ipairs(W.regulars) do
    local key = bodyOfMesh(r.mesh)
    if key then
        addOnce(hairs[bodies[key].gender], r.hair)
        addOnce(accessories, r.acc)
    end
end
local facials = { "" }
for _, f in ipairs(W.facial) do addOnce(facials, f) end

--------------------------------------------------------------------------
-- Presets: the named regulars
--------------------------------------------------------------------------

local presets = {}
for _, r in ipairs(W.regulars) do
    local key = bodyOfMesh(r.mesh)
    if key and r.top ~= "" then
        presets[#presets + 1] = { name = r.name, spec = {
            body = key, skin = (r.skin == 1) and 1 or 2, skinTex = r.bodyTex ~= "" and r.bodyTex or bodies[key].skinTex,
            hair = r.hair, hairBc = r.hairBc[1] or "", hairColour = (r.hairColor >= 1 and r.hairColor <= 9) and r.hairColor or 1,
            facial = r.facial, acc = r.acc,
            top = r.top, topTint = WHITE, bottom = r.bottom, bottomTint = WHITE, shoes = r.shoes, shoesTint = WHITE,
            height = (r.height > 0.3) and r.height or 1.0,
        } }
    end
end
function Creator.presets() return presets end

--------------------------------------------------------------------------
-- The choices
--------------------------------------------------------------------------

--- What a spec can be set to, per row: a list of values and how each reads.
function Creator.choices(spec, row)
    local b = bodies[spec.body] or bodies.F_01
    if row == "body" then return bodyOrder end
    if row == "skin" then return { 2, 1 } end
    if row == "skinTex" then return wear[b.key].skinTex end
    if row == "hair" then return hairs[b.gender] end
    if row == "hairColour" then
        local out = {}
        for _, c in ipairs(W.hairColours) do out[#out + 1] = c.value end
        return out
    end
    if row == "facial" then return b.gender == "M" and facials or { "" } end
    if row == "acc" then return accessories end
    if row == "top" or row == "bottom" or row == "shoes" then return wear[b.key][row] end
    if row == "topTint" or row == "bottomTint" or row == "shoesTint" then
        local out = {}
        for _, p in ipairs(Creator.PALETTE) do out[#out + 1] = p.tint end
        return out
    end
    if row == "height" then return HEIGHTS end
    return {}
end

local function indexOf(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return nil
end

--- How a row's current value reads on the screen.
function Creator.label(spec, row)
    local list = Creator.choices(spec, row)
    local v = spec[row]
    local i = indexOf(list, v)
    if row == "body" then return BODY_LABEL[v] or tostring(v) end
    if row == "skin" then return v == 1 and "Darker" or "Lighter" end
    if row == "hairColour" then
        for _, c in ipairs(W.hairColours) do if c.value == v then return c.label end end
        return "Brown"
    end
    if row == "topTint" or row == "bottomTint" or row == "shoesTint" then
        for _, p in ipairs(Creator.PALETTE) do if p.tint == v then return p.label end end
        return "Custom"
    end
    if row == "height" then return ("%d%%"):format(math.floor((tonumber(v) or 1) * 100 + 0.5)) end
    if v == "" or v == nil then return "None" end
    return ("%d / %d"):format(i or 1, #list)
end

--- Step a row to the next (+1) or previous (-1) choice. Changing the body
--- keeps what still fits and picks the rest from what that body can wear.
function Creator.step(spec, row, dir)
    local list = Creator.choices(spec, row)
    if #list == 0 then return spec end
    local i = indexOf(list, spec[row]) or (dir > 0 and 0 or 1)
    spec[row] = list[(i - 1 + dir) % #list + 1]
    if row == "body" then Creator.fit(spec) end
    return spec
end

--- Make every part one this body can wear (after a body change).
function Creator.fit(spec)
    local b = bodies[spec.body]
    if not b then spec.body = "F_01" b = bodies.F_01 end
    for _, row in ipairs({ "skinTex", "hair", "facial", "top", "bottom", "shoes" }) do
        local list = Creator.choices(spec, row)
        if not indexOf(list, spec[row]) then
            spec[row] = (row == "hair" and list[2]) or list[1] or ""
        end
    end
    if spec.hair ~= "" and not hatBc[spec.hair] then spec.hairBc = "" end
    spec.skin = spec.skin == 1 and 1 or 2
    spec.hairColour = tonumber(spec.hairColour) or 1
    for _, k in ipairs({ "topTint", "bottomTint", "shoesTint" }) do spec[k] = spec[k] or WHITE end
    spec.height = tonumber(spec.height) or 1.0
    spec.acc = spec.acc or ""
    return spec
end

--- A character the way the game makes a passer-by: a body, a skin tone (the
--- game's [1,2,2,2,2]), hair for that body, a hair colour (mostly natural:
--- [1..6] ten times, then [7,8,9]), a moustache one time in five, clothes
--- for that body each with its own tint.
function Creator.random(rng)
    rng = rng or math.random
    local function pick(list) return list[rng(1, #list)] end
    local spec = { body = pick(bodyOrder) }
    if spec.body == "Dealer" and rng(1, 4) > 1 then spec.body = pick({ "M_01", "M_02" }) end
    local b = bodies[spec.body]
    spec.skin = pick({ 1, 2, 2, 2, 2 })
    spec.skinTex = b.skinTex
    local hl = hairs[b.gender]
    spec.hair = hl[rng(2, math.max(2, #hl))] or ""
    local colours = {}
    for _ = 1, 10 do for c = 1, 6 do colours[#colours + 1] = c end end
    for c = 7, 9 do colours[#colours + 1] = c end
    spec.hairColour = pick(colours)
    spec.facial = (b.gender == "M" and rng(1, 5) == 1) and pick({ facials[2] or "", facials[3] or "" }) or ""
    spec.acc = ""
    spec.hairBc = ""
    for _, k in ipairs({ "top", "bottom", "shoes" }) do
        spec[k] = pick(wear[b.key][k])
        spec[k .. "Tint"] = Creator.PALETTE[rng(1, #Creator.PALETTE)].tint
    end
    spec.height = HEIGHTS[rng(2, 5)]
    return Creator.fit(spec)
end

--------------------------------------------------------------------------
-- The look
--------------------------------------------------------------------------

local slotCache = {}    -- asset path -> { { name, mat } ... } by material index

local function assetOf(path)
    local a = UE.findObject(path)
    if not UE.valid(a) and LoadAsset then pcall(function() a = LoadAsset(path) end) end
    return UE.valid(a) and a or nil
end

--- A mesh's material slots, by index: { name = "ClothTop", mat = its material's path }.
function Creator.slotsOf(path)
    if type(path) ~= "string" or path == "" then return nil end
    if slotCache[path] then return slotCache[path] end
    local a = assetOf(path)
    if not a then return nil end
    local out = {}
    if UE.ClassNameOf(a) == "StaticMesh" then
        -- A head piece: its own calls, not its StaticMaterials array - MEASURED,
        -- read from inside this module right after LoadAsset that array came
        -- back empty every time (typed into the console, the same read worked).
        -- GetMaterial(i) until there are no more; the two slots that matter
        -- found by name.
        local named = {}
        for _, slot in ipairs({ "Hair", "ClothTop" }) do
            local i = -1
            pcall(function() i = a:GetMaterialIndex(FName(slot)) end)
            if type(i) == "number" and i >= 0 then named[i] = slot end
        end
        for i = 0, 7 do
            local m = nil
            pcall(function() m = a:GetMaterial(i) end)
            if not UE.valid(m) then break end
            out[#out + 1] = { name = named[i] or "", mat = UE.pathOf(m) or "" }
        end
    else
        pcall(function()
            a.Materials:ForEach(function(_, e)
                local v = e
                pcall(function() v = e:get() end)
                local name, mat = "", ""
                pcall(function() name = v.MaterialSlotName:ToString() end)
                pcall(function() mat = UE.pathOf(v.MaterialInterface) or "" end)
                out[#out + 1] = { name = name, mat = mat }
            end)
        end)
    end
    if #out == 0 then return nil end
    slotCache[path] = out
    return out
end

local function hairMaterial(value)
    for _, c in ipairs(W.hairColours) do if c.value == value then return c.mi end end
    return W.hairColours[1].mi
end

--- A head piece's materials, slot by slot ("^"-joined, as npcsync reads them):
--- its hair part takes the hair colour, its hat part (ClothTop) its texture.
local function headSpecs(mesh, hairColour, bc)
    local slots = Creator.slotsOf(mesh)
    if not slots then return "" end
    local specs = {}
    for i, s in ipairs(slots) do
        if s.name == "Hair" and hairColour then
            specs[i] = hairMaterial(hairColour) .. "||"
        elseif s.name == "ClothTop" and bc and bc ~= "" then
            specs[i] = s.mat .. "|" .. bc .. "|" .. WHITE
        else
            specs[i] = s.mat .. "||"
        end
    end
    return table.concat(specs, "^")
end

--- The look this character wears, or nil (an asset that would not load).
function Creator.compose(spec)
    Creator.fit(spec)
    local b = bodies[spec.body]
    local slots = Creator.slotsOf(b.mesh)
    if not slots then return nil end
    local look = { m = b.mesh }
    for i, s in ipairs(slots) do
        local spec_ = s.mat .. "||"
        if s.name == "Skin" then
            spec_ = (b.skins[spec.skin == 1 and 1 or 2] or s.mat) .. "|" .. (spec.skinTex or "") .. "|"
        elseif s.name == "ClothTop" then
            spec_ = s.mat .. "|" .. spec.top .. "|" .. spec.topTint
        elseif s.name == "ClothBottom" then
            spec_ = s.mat .. "|" .. spec.bottom .. "|" .. spec.bottomTint
        elseif s.name == "ClothShoes" then
            spec_ = s.mat .. "|" .. spec.shoes .. "|" .. spec.shoesTint
        elseif s.name == "Hair" then
            spec_ = hairMaterial(spec.hairColour) .. "||"
        end
        look["s" .. (i - 1)] = spec_
    end
    look.h, look.f, look.a = spec.hair, spec.facial, spec.acc
    if spec.hair ~= "" then look.hm = headSpecs(spec.hair, spec.hairColour, spec.hairBc) end
    if spec.facial ~= "" then look.fm = headSpecs(spec.facial, spec.hairColour) end
    if spec.acc ~= "" then look.am = headSpecs(spec.acc) end
    look.cs = ("%.3f"):format(spec.height)
    return look
end

--------------------------------------------------------------------------
-- Kept with the look (character.lua's file): "spec_<field>=value"
--------------------------------------------------------------------------

local FIELDS = { "body", "skin", "skinTex", "hair", "hairBc", "hairColour", "facial", "acc",
                 "top", "topTint", "bottom", "bottomTint", "shoes", "shoesTint", "height" }
local NUMBERS = { skin = true, hairColour = true, height = true }

function Creator.toFields(spec, into)
    into = into or {}
    for _, k in ipairs(FIELDS) do into["spec_" .. k] = tostring(spec[k] or "") end
    return into
end

function Creator.fromFields(fields)
    if type(fields) ~= "table" or not fields.spec_body then return nil end
    local spec = {}
    for _, k in ipairs(FIELDS) do
        local v = fields["spec_" .. k]
        spec[k] = NUMBERS[k] and tonumber(v) or v
    end
    if not bodies[spec.body] then return nil end
    return Creator.fit(spec)
end

function Creator.copy(spec)
    local out = {}
    for k, v in pairs(spec or {}) do out[k] = v end
    return out
end

Creator.ROWS = { "body", "skin", "hair", "hairColour", "facial", "acc", "top", "bottom", "shoes", "height" }

return Creator
