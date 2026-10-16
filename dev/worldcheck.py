"""
Does every guest see the host's store? Compares what each running copy reports.

    py dev/worldcheck.py            # host A against every other live bridge slot
    py dev/worldcheck.py A B        # just these
    py dev/worldcheck.py --near 40  # how far apart (cm) still counts as the same thing
    py dev/worldcheck.py --wait 300 # right after a join: check again until it matches, and say how long that took

For each kind of thing the store is made of (tapes, boxes, shelves, decorations)
each copy lists where every one stands; each of the host's is paired with the
nearest of the guest's of that kind. Reported: how many each side has, how many
pair up within --near cm, and the worst gap. Also the NPC count (they walk, so
only counted) and the store's numbers: money, level, XP, day, clock, season, weather.
Hidden things are left out: the host keeps rented-out tapes hidden at the world's
origin, and the engine never sends a hidden actor to a client (measured: 83 of 479).
Exit code 1 when anything differs, so a test script can stop on it.
"""
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bridge  # noqa: E402

KINDS = ["Cartridge_Base_C", "MovingBox_C", "Shelve_C", "Decoration_C", "PosterFrame_C", "Standees_C"]
NAMES = {"Cartridge_Base_C": "tapes", "MovingBox_C": "boxes", "Shelve_C": "shelves",
         "Decoration_C": "decorations", "PosterFrame_C": "posters", "Standees_C": "standees"}

# Store numbers: the host reads its own; a guest reports what it shows - its own
# clock (driven from the host's) and the money/level/XP it last heard (sync.lua).
STATE = [("g", "Money", "Money"), ("g", "Level", "Level"), ("g", "Experience", "XP"),
         ("w", "Day", "Day"), ("w", "Hour", "Hour"), ("w", "Minute", "Minute"),
         ("w", "Day of the week", "Weekday"), ("w", "Season", "Season"), ("w", "Current Weather", "Weather")]

LUA = ('lua local UE=require("ue"); local out={}; for _, cls in ipairs({%s}) do '
       'for _, a in ipairs(UE.findAll(cls) or {}) do local ok, l = pcall(function() return a:K2_GetActorLocation() end); '
       'if ok and l and a.bHidden ~= true then out[#out+1] = ("%%s,%%.0f,%%.0f,%%.0f"):format(cls, l.X, l.Y, l.Z) end end end; '
       'out[#out+1] = "NPC," .. #(UE.findAll("AI_Base_Character_C") or {}); '
       'local gm = UE.GetGameMode(); if UE.IsClient() or not (UE.valid(gm) and UE.ClassNameOf(gm) == "Core_Gamemode_C") then gm = nil end; '
       'local w = UE.findFirst("WeatherSystem_C"); local m = require("sync").mirroredState(); '
       'for _, e in ipairs({%s}) do local o = e[1] == "g" and gm or (e[1] == "w" and w or nil); '
       'local v = o and UE.TryGet(o, e[2]); if v == nil then v = m[e[3]] end; out[#out+1] = "STATE," .. e[3] .. "=" .. tostring(v) end; '
       'return UE.NetModeName() .. ";" .. table.concat(out, ";")') % (
    ", ".join('"%s"' % k for k in KINDS),
    ", ".join('{"%s", "%s", "%s"}' % e for e in STATE))


def snapshot(slot):
    text = bridge.send(slot, [LUA], timeout=60)
    line = next((l for l in text.splitlines() if l.startswith("=> ")), None)
    if line is None:
        raise SystemExit("slot %s gave no answer:\n%s" % (slot, text))
    parts = line[3:].split(";")
    snap = {"mode": parts[0], "pos": {k: [] for k in KINDS}, "npc": 0, "state": []}
    for p in parts[1:]:
        kind, _, rest = p.partition(",")
        if kind in snap["pos"]:
            snap["pos"][kind].append(tuple(float(v) for v in rest.split(",")))
        elif kind == "NPC":
            snap["npc"] = int(rest)
        elif kind == "STATE":
            snap["state"].append(tuple(rest.strip().split("=", 1)))
    return snap


def pair(host, guest, near):
    """Greedy nearest pairing. Returns (paired within near, worst gap of those paired, unpaired host, unpaired guest)."""
    left = list(guest)
    paired, worst = 0, 0.0
    for h in host:
        if not left:
            break
        i, d = min(((i, math.dist(h, g)) for i, g in enumerate(left)), key=lambda t: t[1])
        if d <= near:
            paired += 1
            worst = max(worst, d)
            left.pop(i)
    return paired, worst, len(host) - paired, len(left)


def compare(host_slot, guest_slot, host, guest, near):
    ok = True
    print("\n== %s (%s) vs %s (%s)" % (host_slot, host["mode"], guest_slot, guest["mode"]))
    for k in KINDS:
        h, g = host["pos"][k], guest["pos"][k]
        if not h and not g:
            continue
        paired, worst, only_h, only_g = pair(h, g, near)
        good = only_h == 0 and only_g == 0
        ok = ok and good
        print("  %-12s host %4d  guest %4d  same place %4d (worst %3.0f cm)%s" % (
            NAMES[k], len(h), len(g), paired, worst,
            "" if good else "   <-- %d only on the host, %d only on the guest" % (only_h, only_g)))
    print("  %-12s host %4d  guest %4d%s" % ("NPCs", host["npc"], guest["npc"],
                                              "" if host["npc"] == guest["npc"] else "   <-- differ (they come and go; recheck)"))
    hs, gs = dict(host["state"]), dict(guest["state"])
    diffs = [k for k in hs if hs[k] != gs.get(k)]
    clock = [k for k in diffs if k in ("Hour", "Minute")]
    if clock:
        # Read a second or two apart, and the guest's clock follows the host's
        # every few seconds: a few game minutes apart is in step.
        try:
            gap = abs((int(hs["Hour"]) * 60 + int(hs["Minute"])) - (int(gs["Hour"]) * 60 + int(gs["Minute"])))
        except (KeyError, ValueError):
            gap = 999
        if gap <= 5:
            diffs = [k for k in diffs if k not in clock]
    for k in diffs:
        ok = False
        print("  %-12s host %s  guest %s   <-- differs (money and the clock move; run again to confirm)"
              % (k, hs[k], gs.get(k)))
    if not diffs:
        print("  %-12s the same: %s" % ("store", ", ".join("%s %s" % (k, hs[k]) for k in hs)))
    return ok


def option(argv, name, default):
    if name in argv:
        i = argv.index(name)
        return float(argv[i + 1]), argv[:i] + argv[i + 2:]
    return default, argv


def check(slots, near):
    host = snapshot(slots[0])
    ok = True
    for s in slots[1:]:
        ok = compare(slots[0], s, host, snapshot(s), near) and ok
    return ok


def main(argv):
    near, argv = option(argv, "--near", 40.0)
    wait, argv = option(argv, "--wait", 0.0)
    slots = [s.upper() for s in argv] or (["A"] + [s for s in bridge.slots() if s != "A"])
    if len(slots) < 2:
        raise SystemExit("need a host and at least one guest with a live bridge (got %s)" % slots)
    t0 = time.time()
    ok = check(slots, near)
    while not ok and time.time() - t0 < wait:
        time.sleep(5)
        print("\n-- %.0f s --" % (time.time() - t0))
        ok = check(slots, near)
    print("\n" + ("everything matches" if ok else "DIFFERENCES FOUND")
          + (" (after %.0f s)" % (time.time() - t0) if wait else ""))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main(sys.argv[1:])
