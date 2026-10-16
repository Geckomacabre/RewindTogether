"""
Build Mods/RewindTogether/Scripts/wardrobe.lua - every way the game dresses a
character - from a bpdump of the game (~/RetroRewind-decomp by default). Only
asset PATHS go into the output, never the game's files.

    py dev/make_wardrobe.py [decomp folder]

Read from:
  bp/AI_Base_Character.txt   the clothes the game picks from, per body and
                             season (Return Top/Bottom Cloth BC, Return Shoes
                             BC), hair, hats, beards and glasses (Set Hair
                             Mesh Style)
  json/AI_Data_Membership-Unique.json   the 21 named regulars, each fully set
  CXXHeaderDump/*_enums.hpp  the enum values the data table names
  pak_uassets.txt            to turn a short asset name into its full path
"""
import json
import os
import re
import sys

DECOMP = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/RetroRewind-decomp")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Mods", "RewindTogether", "Scripts",
                   "wardrobe.lua")

# name -> /Game paths, for every asset in the pak
paths = {}
for line in open(os.path.join(DECOMP, "pak_uassets.txt"), encoding="utf-8"):
    line = line.strip()
    if not line.endswith(".uasset") or "/L10N/" in line or not line.startswith("RetroRewind/Content/"):
        continue
    p = "/Game/" + line[len("RetroRewind/Content/"):-len(".uasset")]
    name = p.rsplit("/", 1)[1]
    paths.setdefault(name, []).append(p + "." + name)


def full(name):
    got = [p for p in paths.get(name, []) if "/Developers/" not in p]
    return got[0] if got else None


bp = open(os.path.join(DECOMP, "bp", "AI_Base_Character.txt"), encoding="utf-8").read()


def function_body(name):
    m = re.search(r"^function AI_Base_Character_C::" + re.escape(name) + r"\(.*?end_of_script", bp, re.S | re.M)
    return m.group(0) if m else ""


BODY_OF_FOLDER = {"NPC_F_01": "F_01", "NPC_F_02": "F_02", "NPC_M_01": "M_01", "NPC_M_02": "M_02"}


def body_of(path):
    for folder, body in BODY_OF_FOLDER.items():
        if "/" + folder + "/" in path:
            return body
    return None


clothes = {b: {"top": [], "bottom": [], "shoes": []} for b in BODY_OF_FOLDER.values()}
for kind, fn in (("top", "Return Top Cloth BC for "), ("bottom", "Return Bottom Cloth BC for "),
                 ("shoes", "Return Shoes BC for ")):
    for season in ("Spring", "Summer", "Fall", "Winter"):
        for name in re.findall(r"Texture2D'([^']+)'", function_body(fn + season)):
            p = full(name)
            b = p and body_of(p)
            if b and p not in clothes[b][kind]:
                clothes[b][kind].append(p)

# Hair, hats, glasses, masks: every Hat struct the game builds in Set Hair Mesh Style.
start = bp.find("//================ EVENT Set Hair Mesh Style")
section = bp[start:]
nxt = section.find("//================ EVENT", 60)
section = section[:nxt] if nxt > 0 else section
arrays = {}
for var, body in re.findall(r"(K2Node_MakeArray_Array(?:_\d+)?) = \[([^\]]*)\]", section):
    arrays[var] = re.findall(r'Soft\("([^"]+)"\)', body)
hats = {}
order = []
for var, path in re.findall(r'(K2Node_MakeStruct_Hat(?:_\d+)?)\.Mesh_2_[0-9A-F]+ = Soft\("([^"]+)"\)', section):
    if var not in hats:
        order.append(var)
    hats[var] = {"mesh": path, "bc": [], "tint": False}
for var, arr in re.findall(r"(K2Node_MakeStruct_Hat(?:_\d+)?)\.BC_6_[0-9A-F]+ = (K2Node_MakeArray_Array(?:_\d+)?)", section):
    if var in hats:
        hats[var]["bc"] = arrays.get(arr, [])
for var, allow in re.findall(r"(K2Node_MakeStruct_Hat(?:_\d+)?)\.AllowChangeHatColor_10_[0-9A-F]+ = (true|false)", section):
    if var in hats:
        hats[var]["tint"] = allow == "true"
facial = []
for name in re.findall(r"StaticMesh'([^']+)'", section):
    p = full(name)
    if p and p not in facial and ("Mustache" in name or "Beard" in name):
        facial.append(p)


def enum_values(header):
    text = open(os.path.join(DECOMP, "CXXHeaderDump", header), encoding="utf-8").read()
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"(\w+) = (\d+)", text)}


SKIN = enum_values("SkinTone_enums.hpp")
HAIR = enum_values("HairColor_enums.hpp")


def enum_value(v, table):
    if not isinstance(v, str) or "::" not in v:
        return 0
    return table.get(v.split("::")[1], 0)


def field(row, prefix):
    if not isinstance(row, dict):
        return None
    for k, v in row.items():
        if k.startswith(prefix):
            return v
    return None


def soft(v):
    return (v.get("AssetPathName") or "") if isinstance(v, dict) else ""


rows = []
dt = json.load(open(os.path.join(DECOMP, "json", "AI_Data_Membership-Unique.json"), encoding="utf-8"))
table = [x for x in dt if x.get("Type") == "DataTable"][0]["Rows"]
for key, row in table.items():
    bt = field(row, "BodyType")
    mesh = ""
    if isinstance(bt, dict) and bt.get("ObjectPath"):
        o = bt["ObjectPath"]
        mesh = "/Game/" + o[len("RetroRewind/Content/"):].rsplit(".", 1)[0]
        mesh = mesh + "." + mesh.rsplit("/", 1)[1]
    hair, acc, fh = field(row, "HeadHair") or {}, field(row, "HeadAccessory") or {}, field(row, "FacialHair") or {}
    name = field(row, "Name_") or {}
    rows.append({
        "id": key,
        "name": name.get("SourceString", key) if isinstance(name, dict) else key,
        "mesh": mesh,
        "skin": enum_value(field(row, "SkinTone"), SKIN),
        "bodyTex": soft(field(row, "BodyBCTexture")),
        "hair": soft(field(hair, "Mesh_2")),
        "hairBc": [soft(x) for x in (field(hair, "BC_6") or [])],
        "acc": soft(field(acc, "Mesh_2")),
        "accBc": [soft(x) for x in (field(acc, "BC_6") or [])],
        "hairColor": enum_value(field(row, "HeadHairColor"), HAIR),
        "facial": soft(field(fh, "Mesh_2")),
        "top": soft(field(row, "TopCloth")),
        "bottom": soft(field(row, "BottomCloth")),
        "shoes": soft(field(row, "ShoesCloth")),
        "height": float(field(row, "SizeHeight") or 1.0),
    })

# Hair colours (AI_Base_Character @27958): value -> material.
HAIR_COLOURS = [(1, "Brown"), (2, "Black"), (3, "Gray"), (4, "White"), (5, "Blond"), (6, "Red"),
                (7, "Red-Intense"), (8, "Blue"), (9, "Purple")]


def s(x):
    return '"' + str(x).replace("\\", "\\\\").replace('"', '\\"') + '"'


def lst(xs):
    return "{ " + ", ".join(s(x) for x in xs) + " }"


# The bodies (Return SK Mesh for <season>, plus the dealer's, which two regulars wear), and the
# skin each skin tone gives them (AI_Base_Character @23193..23808: tone 1 -> *_02, tone 2 -> *_01).
BODIES = [
    ("F_01", "SK_CHA_F_01", "F", "NPC_Body_F_01_bc", ("MI_CHA_Skin_F_02", "MI_CHA_Skin_F_01")),
    ("F_02", "SK_CHA_F_02", "F", "NPC_Body_F_01_bc", ("MI_CHA_Skin_F_02", "MI_CHA_Skin_F_01")),
    ("M_01", "SK_CHA_M_01", "M", "NPC_Body_M_01_bc", ("MI_CHA_M-02_Skin_02", "MI_CHA_M-01_Skin_01")),
    ("M_02", "SK_CHA_M_02", "M", "NPC_04_Body_M_01_bc", ("MI_CHA_M-02_Skin_02", "MI_CHA_M-01_Skin_01")),
    ("Dealer", "SK_CHA_Dealer_01", "M", "NPC_Body_M_01_bc", ("MI_CHA_M-02_Skin_02", "MI_CHA_M-01_Skin_01")),
]

out = ["-- GENERATED by dev/make_wardrobe.py from a bpdump of the game - do not edit by hand.",
       "-- Asset paths only: every way the game dresses a character (character.lua).",
       "return {", "  bodies = {"]
for key, mesh, gender, skinTex, skins in BODIES:
    out.append("    { key = %s, mesh = %s, gender = %s, skinTex = %s, skins = %s }," % (
        s(key), s(full(mesh) or ""), s(gender), s(full(skinTex) or ""), lst([full(x) or "" for x in skins])))
out.append("  },")
out.append("  clothes = {")
for b, kinds in clothes.items():
    out.append("    %s = { top = %s, bottom = %s, shoes = %s }," % (b, lst(kinds["top"]), lst(kinds["bottom"]),
                                                                 lst(kinds["shoes"])))
out.append("  },")
out.append("  hats = {")
for var in order:
    h = hats[var]
    out.append("    { mesh = %s, bc = %s, tint = %s }," % (s(h["mesh"]), lst(h["bc"]), "true" if h["tint"] else "false"))
out.append("  },")
out.append("  facial = %s," % lst(facial))
out.append("  hairColours = {")
for v, label in HAIR_COLOURS:
    out.append("    { value = %d, label = %s, mi = %s }," % (v, s(label.replace("-", " ")), s(full("MI_CHA_Hair_" + label) or "")))
out.append("  },")
out.append("  regulars = {")
for r in rows:
    out.append(("    { id = %s, name = %s, mesh = %s, skin = %d, bodyTex = %s, hair = %s, hairBc = %s, acc = %s, "
                "accBc = %s, hairColor = %d, facial = %s, top = %s, bottom = %s, shoes = %s, height = %r },") % (
        s(r["id"]), s(r["name"]), s(r["mesh"]), r["skin"], s(r["bodyTex"]), s(r["hair"]), lst(r["hairBc"]),
        s(r["acc"]), lst(r["accBc"]), r["hairColor"], s(r["facial"]), s(r["top"]), s(r["bottom"]), s(r["shoes"]),
        r["height"]))
out.append("  },")
out.append("}")
open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print("wrote", OUT)
print("clothes:", {b: {k: len(v) for k, v in kinds.items()} for b, kinds in clothes.items()})
print("hats:", len(hats), "facial:", len(facial), "regulars:", len(rows))
