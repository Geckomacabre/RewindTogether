"""
Two-instance co-op test on ONE machine, driven end to end.

    py dev/coop_test.py up          # host loads save 1 and hosts, guest joins 127.0.0.1
    py dev/coop_test.py host-only   # just the host part
    py dev/coop_test.py guest-only  # launch a guest and join a host that is already up (again: a third player)
    py dev/coop_test.py up 127.0.0.1:27016   # guests join through dev/netsim.py (lag and loss)
    py dev/coop_test.py down        # kill both by PID
    py dev/coop_test.py log [N]     # last N lines of both instances' log since the last join

Instance A (first launched, through Steam) hosts. Instance B is the same exe
started directly with SteamAppId set, so Steam does not just refocus A.
Clicks only ever go to A, at native 1920x1080 client size (a resized window
keeps its old viewport scale and clicks miss). B is driven entirely through
the dev bridge - it joins from its main menu, no save needed.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bridge  # noqa: E402
import gw      # noqa: E402

WIN64 = bridge.WIN64
EXE = os.path.join(WIN64, "RetroRewind-Win64-Shipping.exe")
LOG = os.path.join(WIN64, "RewindTogether.log")

# Click points as fractions of the client area, measured once at 1920x1080.
PLAY_F = (242 / 1920, 675 / 1080)
SLOT1_F = (750 / 1920, 140 / 1080)


def claude_pid():
    out = gw.win.powershell("Get-Process -Name claude -ErrorAction SilentlyContinue | "
                            "Where-Object { $_.MainWindowTitle -eq 'Claude' } | "
                            "Select-Object -First 1 -ExpandProperty Id")
    return int(out.strip()) if out.strip() else 0


def windowed(slot):
    """The user's own settings are borderless full screen, and each copy goes
    back to that size on load and on joining - after which SetWindowPos alone
    does not hold. A windowed resolution of the layout's size does."""
    ask(slot, 'lua return tostring(require("ue").Exec("r.SetRes 1254x705w"))')


def layout():
    """The user watches all three: Claude left, host middle, guest right."""
    p = pids()
    args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            os.path.join(HERE, "layout.ps1"), "-ClaudePid", str(claude_pid())]
    if len(p) >= 1:
        args += ["-HostPid", str(p[0])]
    if len(p) >= 2:
        args += ["-GuestPid", str(p[-1])]
    subprocess.run(args)


def client_point(pid, frac):
    out = subprocess.run([sys.executable, os.path.join(HERE, "gw.py"), "drive", str(pid), "rect"],
                         capture_output=True, text=True).stdout
    w, h = 1920, 1080
    for line in out.splitlines():
        if line.startswith("rect ->"):
            parts = line.split()
            w, h = int(parts[-2]), int(parts[-1])
    return int(frac[0] * w), int(frac[1] * h)


def pids():
    out = gw.win.powershell("Get-Process -Name %s -ErrorAction SilentlyContinue | "
                            "Sort-Object StartTime | ForEach-Object { $_.Id }" % gw.PROC)
    return [int(x) for x in out.split()]


def drive(pid, *cmds):
    gw.main(["drive", str(pid)] + list(cmds))


def wait(pred, timeout, what):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            return True
        time.sleep(2)
    raise SystemExit("timed out waiting for " + what)


def ask(slot, line, timeout=30):
    os.environ["BRIDGE_TIMEOUT"] = str(timeout)
    return bridge.send(slot, [line], timeout=timeout)


def clean():
    # Keep the last run's crash traces: they are the only record of which
    # phase was running when a process died.
    keep = os.path.join(HERE, "runs", time.strftime("%Y%m%d-%H%M%S"))
    for f in os.listdir(WIN64):
        if f.startswith("RewindTogether.trace."):
            os.makedirs(keep, exist_ok=True)
            try:
                import shutil
                shutil.copy(os.path.join(WIN64, f), keep)
            except OSError:
                pass
    for f in os.listdir(WIN64):
        if f.startswith("RewindTogether.bridge.") or f.startswith("RewindTogether.trace.") \
                or f == "RewindTogether-inprogress.txt":
            try:
                os.remove(os.path.join(WIN64, f))
            except OSError:
                pass


def host_only(launch=True):
    if launch:
        clean()
        subprocess.run(["cmd", "/c", "start", "", "steam://rungameid/3552140"])
    wait(lambda: "A" in bridge.slots(), 150, "instance A's bridge")
    a = pids()[0]
    layout()
    time.sleep(3)
    PLAY = client_point(a, PLAY_F)
    SLOT1 = client_point(a, SLOT1_F)
    # No mouse: load save slot 1 the way the game's own menu does it (decompiled
    # UX_Boot_StartOption: GameInstance."Save Slot" = "Player_Save<N>", then
    # OpenLevel L_Player_Store_01). The user can keep using the PC meanwhile.
    print(ask("A", 'lua local UE=require("ue"); local gi=UE.GetGameInstance(); gi["Save Slot"]="Player_Save1"; '
                   'UE.GetGameplayStatics():OpenLevel(UE.GetWorld(), FName("L_Player_Store_01"), true, ""); return "loading"'))
    wait(lambda: "Core_Gamemode_C" in ask("A", 'lua return require("ue").ClassNameOf(require("ue").GetGameMode())'),
         120, "the host's store to load")
    time.sleep(5)
    print(ask("A", "rt.host"))
    wait(lambda: "ListenServer" in ask("A", 'lua return require("ue").NetModeName()'), 60, "listen server")
    windowed("A")
    layout()
    print("host up, pid", a)


def guest_only(address="127.0.0.1"):
    """Another guest. Each new copy takes the next free bridge slot (B, then C...)."""
    before = set(bridge.slots())
    env = dict(os.environ, SteamAppId="3552140", SteamGameId="3552140")
    subprocess.Popen([EXE, "RetroRewind"], cwd=WIN64, env=env)
    wait(lambda: set(bridge.slots()) - before, 150, "the new copy's bridge")
    slot = sorted(set(bridge.slots()) - before)[0]
    b = pids()[-1]
    layout()
    time.sleep(6)
    print(ask(slot, "rt.join " + address))
    wait(lambda: "Client" in ask(slot, 'lua return require("ue").NetModeName()'), 90, "guest %s to connect" % slot)
    time.sleep(5)              # the store loads on the guest after it connects
    windowed(slot)
    layout()
    print("guest %s joined, pid %d" % (slot, b))


def tail_log(n):
    lines = open(LOG, encoding="utf-8", errors="replace").read().splitlines()
    start = 0
    for i, l in enumerate(lines):
        if "joining: 127.0.0.1" in l:
            start = i
    for l in lines[start:][-n:]:
        if "RewindTogether:" in l:
            print(l[:200])


def main(a):
    cmd = a[0] if a else "up"
    # Where guests join: 127.0.0.1 straight to the host, or e.g. 127.0.0.1:27016
    # through dev/netsim.py (lag, jitter and loss).
    address = a[1] if len(a) > 1 else "127.0.0.1"
    if cmd == "up":
        host_only()
        guest_only(address)
    elif cmd == "host-only":
        host_only()
    elif cmd == "host-attach":
        host_only(launch=False)
    elif cmd == "guest-only":
        guest_only(address)
    elif cmd == "down":
        for p in pids():
            subprocess.run(["taskkill", "/PID", str(p), "/F"])
    elif cmd == "log":
        tail_log(int(a[1]) if len(a) > 1 else 80)


if __name__ == "__main__":
    main(sys.argv[1:])
