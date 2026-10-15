"""
Talk to a running game through devbridge.lua.

    py dev/bridge.py A rt.status
    py dev/bridge.py B "lua return UE.NetModeName()"
    py dev/bridge.py A --file cmds.txt          # several lines, one answer each
    py dev/bridge.py --enable | --disable       # create/remove the switch file
    py dev/bridge.py --slots                    # which slots have a live heartbeat

Slot A is the first game launched, B the second (see devbridge.lua).
"""
import os
import sys
import time
import uuid

WIN64 = r"D:\SteamLibrary\steamapps\common\RetroRewind\RetroRewind\Binaries\Win64"
ENABLE = os.path.join(WIN64, "RewindTogether.devbridge")


def path(slot, ext):
    return os.path.join(WIN64, "RewindTogether.bridge.%s.%s" % (slot, ext))


def slots():
    now = time.time()
    live = []
    for s in "ABCD":
        try:
            beat = int(open(path(s, "beat")).read().strip())
        except Exception:
            continue
        if now - beat <= 6:
            live.append(s)
    return live


def send(slot, lines, timeout=float(os.environ.get("BRIDGE_TIMEOUT", "30"))):
    ids = []
    body = []
    for line in lines:
        i = uuid.uuid4().hex[:8]
        ids.append(i)
        body.append("@%s %s" % (i, line))
    out = path(slot, "out")
    start = os.path.getsize(out) if os.path.exists(out) else 0
    # Wait for the previous batch to be consumed, then drop ours in atomically.
    deadline = time.time() + timeout
    while os.path.exists(path(slot, "in")) and time.time() < deadline:
        time.sleep(0.05)
    tmp = path(slot, "in.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(body) + "\n")
    os.replace(tmp, path(slot, "in"))

    want = "<<< %s" % ids[-1]
    while time.time() < deadline:
        if os.path.exists(out) and os.path.getsize(out) > start:
            with open(out, "r", encoding="utf-8", errors="replace") as fh:
                fh.seek(start)
                text = fh.read()
            if want in text:
                return text
        time.sleep(0.1)
    raise SystemExit("timed out waiting for slot %s (is the game running with the bridge on?)" % slot)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    if argv[0] == "--enable":
        open(ENABLE, "w").write("on\n")
        print("bridge enabled:", ENABLE)
        return
    if argv[0] == "--disable":
        if os.path.exists(ENABLE):
            os.remove(ENABLE)
        print("bridge disabled")
        return
    if argv[0] == "--slots":
        print(" ".join(slots()) or "(none)")
        return
    slot = argv[0].upper()
    if len(argv) >= 3 and argv[1] == "--file":
        lines = [l for l in open(argv[2], encoding="utf-8").read().splitlines() if l.strip()]
    else:
        lines = [" ".join(argv[1:])]
    sys.stdout.write(send(slot, lines))


if __name__ == "__main__":
    main(sys.argv[1:])
