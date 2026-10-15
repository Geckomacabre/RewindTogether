"""Build the release zip: dist/RewindTogether-<version>.zip

    py dev/package.py            # stage into dist/RewindTogether-<version>/ and zip it

What goes in (the launcher installs the mod from the copy next to it; see
launcher/README.md, "Before a public release"):

    RewindTogetherLauncher.exe
    Mods/RewindTogether/mod.json, Scripts/*.lua, native/RewindNative.dll
    README.md, FRIEND - START HERE.txt, VERSION.txt
    the two port tools the README and the mod's own messages name
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
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "Mods", "RewindTogether")

FILES = [
    ("launcher/dist/RewindTogetherLauncher.exe", "RewindTogetherLauncher.exe"),
    ("README.md", "README.md"),
    ("FRIEND - START HERE.txt", "FRIEND - START HERE.txt"),
    ("VERSION.txt", "VERSION.txt"),
    ("OPEN PORT FOR FRIENDS - Double click me.bat", "OPEN PORT FOR FRIENDS - Double click me.bat"),
    ("Enable-DirectHosting.ps1", "Enable-DirectHosting.ps1"),
    ("Disable-DirectHosting.bat", "Disable-DirectHosting.bat"),
    ("CHECK CONNECTION - Double click me.bat", "CHECK CONNECTION - Double click me.bat"),
    ("Check-Connection.ps1", "Check-Connection.ps1"),
    ("native/RewindNative/RewindNative.cpp", "Source/RewindNative/RewindNative.cpp"),
    ("native/RewindNative/build.bat", "Source/RewindNative/build.bat"),
]


def fail(msg):
    print("PACKAGE FAILED: " + msg)
    sys.exit(1)


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
    for rel in ("RewindTogetherLauncher.exe", "Mods/RewindTogether/native/RewindNative.dll"):
        print(f"        {rel}  {sha256(os.path.join(stage, rel))[:16]}")


if __name__ == "__main__":
    main()
