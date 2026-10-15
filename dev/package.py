"""Build the release zip: dist/RewindTogether-<version>.zip

    py dev/package.py            # stage into dist/RewindTogether-<version>/ and zip it

What goes in (the launcher installs the mod from the copy next to it; see
launcher/README.md, "Before a public release"):

    RewindTogetherLauncher.exe
    Mods/RewindTogether/mod.json, Scripts/*.lua, native/RewindNative.dll
    Mods/UE4SS/UE4SS_v<pinned>.zip - the exact UE4SS build the launcher
    installs, unmodified, plus its LICENSE (MIT). The launcher installs
    from it with no download; it is fetched once into dist/cache/ and
    checked against the sha256 pinned in Core/Ue4ssSetup.cs
    README.md, FRIEND - START HERE.txt, VERSION.txt
    Extras/ - the two port tools the README and the mod's own messages
    name (nobody needs them for Steam joining, so they stay out of sight)
    Source/RewindNative/ - the native helper's source, so nobody has to
    trust a DLL they cannot read

What stays out: dev/, test/, the launcher's source, the 1.6 installer and
tunnel (superseded by the launcher), the old Engine.ini profiles (the mod
sets the net driver and port at runtime), MODLOG.md and PROJECT.md, and
anything from the game.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "Mods", "RewindTogether")

FILES = [
    ("launcher/dist/RewindTogetherLauncher.exe", "RewindTogetherLauncher.exe"),
    ("LICENSE", "LICENSE.txt"),
    ("README.md", "README.md"),
    ("FRIEND - START HERE.txt", "FRIEND - START HERE.txt"),
    ("VERSION.txt", "VERSION.txt"),
    ("OPEN PORT FOR FRIENDS - Double click me.bat", "Extras/OPEN PORT FOR FRIENDS - Double click me.bat"),
    ("Enable-DirectHosting.ps1", "Extras/Enable-DirectHosting.ps1"),
    ("Disable-DirectHosting.bat", "Extras/Disable-DirectHosting.bat"),
    ("CHECK CONNECTION - Double click me.bat", "Extras/CHECK CONNECTION - Double click me.bat"),
    ("Check-Connection.ps1", "Extras/Check-Connection.ps1"),
    ("native/RewindNative/RewindNative.cpp", "Source/RewindNative/RewindNative.cpp"),
    ("native/RewindNative/build.bat", "Source/RewindNative/build.bat"),
]


def fail(msg):
    print("PACKAGE FAILED: " + msg)
    sys.exit(1)


EXTRAS_README = """You do not need anything in this folder to play.

HOST and JOIN in RewindTogetherLauncher.exe connect friends through Steam:
no IP addresses, no ports, nothing to open on your router.

These tools are only for playing WITHOUT Steam's connection (Join by address):

  OPEN PORT FOR FRIENDS - Double click me.bat
      On the HOST's PC: opens UDP 27015 in Windows Firewall and asks the
      router to forward it (UPnP). Disable-DirectHosting.bat undoes it.

  CHECK CONNECTION - Double click me.bat
      Shows your address and checks the game really is listening.
"""


def ue4ss_pin():
    """The pinned UE4SS zip, as the launcher knows it (one source of truth)."""
    cs = open(os.path.join(ROOT, "launcher", "RewindTogether.Launcher", "Core", "Ue4ssSetup.cs"), encoding="utf-8").read()
    def const(name):
        m = re.search(r"const\s+\w+\s+" + name + r"\s*=\s*\"?([^\";]+)\"?;", cs)
        if not m:
            fail("cannot read " + name + " from Ue4ssSetup.cs")
        return m.group(1)
    return const("PinnedFileName"), const("PinnedUrl"), const("PinnedSha256"), int(const("PinnedSize").replace("_", ""))


def fetch_ue4ss():
    """Downloads the pinned UE4SS zip once into dist/cache/ and verifies it. Returns its path."""
    name, url, sha, size = ue4ss_pin()
    cache = os.path.join(ROOT, "dist", "cache")
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, name)
    if not (os.path.isfile(path) and os.path.getsize(path) == size and sha256(path) == sha):
        print(f"fetch   {url}")
        part = path + ".part"
        try:
            with urllib.request.urlopen(url, timeout=60) as r, open(part, "wb") as f:
                shutil.copyfileobj(r, f)
        except OSError as e:
            fail(f"could not download {name} ({e}). Put the file in {cache} by hand and run again.")
        if os.path.getsize(part) != size or sha256(part) != sha:
            os.remove(part)
            fail(f"{name} from GitHub is not the pinned build (size or sha256 differ) - nothing was packaged")
        os.replace(part, path)
    return path


def versions():
    mod_json = json.load(open(os.path.join(MOD, "mod.json"), encoding="utf-8"))
    net = open(os.path.join(MOD, "Scripts", "net.lua"), encoding="utf-8").read()
    m = re.search(r'Net\.VERSION\s*=\s*"([^"]+)"', net)
    ver_txt = open(os.path.join(ROOT, "VERSION.txt"), encoding="utf-8").read()
    v = re.search(r"Version:\s*([0-9][0-9.]*)", ver_txt)
    return mod_json.get("version"), m and m.group(1), v and v.group(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    mod_v, net_v, txt_v = versions()
    if not (mod_v and mod_v == net_v == txt_v):
        fail(f"versions disagree: mod.json {mod_v}, net.lua {net_v}, VERSION.txt {txt_v}")
    version = mod_v

    # The repo's config.lua must be the shipped default, not a tester's.
    cfg = open(os.path.join(MOD, "Scripts", "config.lua"), encoding="utf-8").read()
    if re.search(r"^\s*Config\.UseSteamP2P\s*=\s*true", cfg, re.M):
        fail("config.lua has UseSteamP2P = true - not the shipped default")
    dll = os.path.join(MOD, "native", "RewindNative.dll")
    if not os.path.isfile(dll):
        fail("native/RewindNative.dll is missing - run native\\RewindNative\\build.bat")

    stage = os.path.join(ROOT, "dist", f"RewindTogether-{version}")
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)

    for src, dst in FILES:
        s = os.path.join(ROOT, src)
        if not os.path.isfile(s):
            fail("missing " + src)
        d = os.path.join(stage, dst)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(s, d)

    target = os.path.join(stage, "Mods", "RewindTogether")
    os.makedirs(os.path.join(target, "Scripts"))
    os.makedirs(os.path.join(target, "native"))
    shutil.copy2(os.path.join(MOD, "mod.json"), target)
    for name in sorted(os.listdir(os.path.join(MOD, "Scripts"))):
        if name.endswith(".lua"):
            shutil.copy2(os.path.join(MOD, "Scripts", name), os.path.join(target, "Scripts"))
    shutil.copy2(dll, os.path.join(target, "native"))

    # UE4SS, unmodified (the launcher checks its sha256 before installing from it), and its licence.
    ue4ss_zip = fetch_ue4ss()
    ue4ss_dir = os.path.join(stage, "Mods", "UE4SS")
    os.makedirs(ue4ss_dir)
    shutil.copy2(ue4ss_zip, ue4ss_dir)
    with zipfile.ZipFile(ue4ss_zip) as z:
        with z.open("ue4ss/LICENSE") as src, open(os.path.join(ue4ss_dir, "LICENSE.txt"), "wb") as dst:
            shutil.copyfileobj(src, dst)

    # Notepad-friendly line ends, like the other .txt files in the zip.
    with open(os.path.join(stage, "Extras", "README.txt"), "w", encoding="utf-8", newline="\r\n") as f:
        f.write(EXTRAS_README)

    zpath = stage + ".zip"
    if os.path.exists(zpath):
        os.remove(zpath)
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for dirpath, _, files in os.walk(stage):
            for f in sorted(files):
                full = os.path.join(dirpath, f)
                z.write(full, os.path.join(f"RewindTogether-{version}", os.path.relpath(full, stage)))

    print(f"staged  {stage}")
    print(f"zip     {zpath}  ({os.path.getsize(zpath):,} bytes)")
    print(f"sha256  {sha256(zpath)}")
    for rel in ("RewindTogetherLauncher.exe", "Mods/RewindTogether/native/RewindNative.dll", "Mods/UE4SS/" + ue4ss_pin()[0]):
        print(f"        {rel}  {sha256(os.path.join(stage, rel))[:16]}")


if __name__ == "__main__":
    main()
