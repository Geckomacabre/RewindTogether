"""
Drive / screenshot ONE of several game instances, by PID (um win only knows names).

    py dev/gw.py ps                          # pids of running game windows
    py dev/gw.py shot <pid> out.png [scale]  # gfxcapture of that window
    py dev/gw.py drive <pid> "focus" "click 100 200" "key 0x1B"
"""
import os
import subprocess
import sys

UM = os.path.expanduser(r"~\.claude\plugins\marketplaces\local-desktop-app-uploads\universal-modder")
sys.path.insert(0, UM)
from um import win  # noqa: E402

PROC = "RetroRewind-Win64-Shipping"
# A WinDrive.ps1 variant that targets one window by PID (um only knows
# process names). Point RT_WINDRIVE at your copy.
WD = os.environ.get("RT_WINDRIVE", "WinDrivePid.ps1")


def hwnd(pid):
    out = win.powershell("(Get-Process -Id %d).MainWindowHandle" % int(pid)).strip()
    return int(out)


def main(a):
    if a[0] == "ps":
        print(win.powershell("Get-Process -Name %s -ErrorAction SilentlyContinue | "
                             "ForEach-Object { '{0} {1}' -f $_.Id, $_.StartTime }" % PROC))
    elif a[0] == "shot":
        scale = float(a[3]) if len(a) > 3 else None
        print(win.shot(a[2], hwnd=hwnd(a[1]), scale=scale))
    elif a[0] == "drive":
        env = dict(os.environ, WD_PID=str(a[1]))
        p = subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", WD, "-Proc", PROC],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, env=env)
        print(p.stdout.readline().strip())
        for c in a[2:]:
            p.stdin.write(c + "\n")
            p.stdin.flush()
            print(c, "->", p.stdout.readline().strip())
        p.stdin.close()
        p.wait(timeout=30)


if __name__ == "__main__":
    main(sys.argv[1:])
