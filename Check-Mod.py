"""
Check the mod without launching the game.

    py -m pip install luaparser lupa
    py Check-Mod.py

Two passes:

  1. PARSE every script, in both the source folder and the deployed one. There
     is no Lua binary on the dev machine, so without this a mistyped `end`
     costs a whole game launch to discover - UE4SS just declines to load the
     mod and the game comes up looking perfectly normal.

  2. RUN the mod against a fake UE4SS in test/. Every module is loaded,
     main.lua boots, the tick loop is driven, and every rt.* command is
     invoked. Then the two situations that have actually broken this project
     are replayed: a guest who needs a pawn (the ladder must fire) and a guest
     who is disconnecting (the ladder must NOT fire - that is the crash).

Pass 2 is skipped with a note if lupa is not installed, so pass 1 always works.
Exits non-zero on any failure, so it can gate a deploy.
"""

import os
import sys
import glob
import shutil
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "Mods", "RewindTogether", "Scripts")
DEPLOYED = os.path.normpath(os.path.join(
    HERE, "..", "RetroRewind", "Binaries", "Win64",
    "ue4ss", "Mods", "RewindTogether", "Scripts"))
# The project used to live inside the game folder; when it does not, look in
# the usual Steam library instead of silently checking nothing.
if not os.path.isdir(DEPLOYED):
    DEPLOYED = os.environ.get("RT_DEPLOYED", os.path.join(
        "D:\\", "SteamLibrary", "steamapps", "common", "RetroRewind", "RetroRewind",
        "Binaries", "Win64", "ue4ss", "Mods", "RewindTogether", "Scripts"))

failures = 0


def parse_pass():
    global failures
    try:
        from luaparser import ast
    except ImportError:
        print("SKIP  parse pass - run:  py -m pip install luaparser\n")
        return

    for root in (SOURCE, DEPLOYED):
        print(root)
        if not os.path.isdir(root):
            print("  (not present)\n")
            continue
        for path in sorted(glob.glob(os.path.join(root, "*.lua"))):
            raw = open(path, "rb").read()
            # config.lua carries a UTF-8 BOM; Lua tolerates it, the parser does not.
            try:
                ast.parse(raw.decode("utf-8-sig", errors="replace"))
                print("  OK   %s" % os.path.basename(path))
            except Exception as err:
                failures += 1
                msg = str(err).encode("ascii", "replace").decode("ascii")
                print("  FAIL %s\n       %s" % (os.path.basename(path), msg))
        print("")


def smoke_pass():
    global failures
    try:
        import lupa
    except ImportError:
        print("SKIP  smoke test - run:  py -m pip install lupa")
        return

    testdir = os.path.join(HERE, "test")
    if not os.path.isfile(os.path.join(testdir, "smoke.lua")):
        print("SKIP  smoke test - test/smoke.lua is missing")
        return

    print("running the mod against a fake UE4SS")
    # Lua's print goes straight to the C stdout, so anything Python still has
    # buffered would appear after it and read as though the passes ran out of
    # order.
    sys.stdout.flush()

    # The mod writes RewindTogether.log and its breadcrumb files into the
    # working directory. Give it a throwaway one so a test run never leaves
    # anything behind in the project or, worse, in the game folder.
    sandbox = tempfile.mkdtemp(prefix="rewindtogether-test-")
    previous = os.getcwd()
    try:
        os.chdir(sandbox)
        lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        lua.execute('package.path = %r .. "/?.lua;" .. package.path'
                    % testdir.replace("\\", "/"))
        chunk = lua.eval('loadfile(%r)' % os.path.join(testdir, "smoke.lua").replace("\\", "/"))
        if chunk is None:
            print("  FAIL could not load test/smoke.lua")
            failures += 1
            return
        try:
            chunk(SOURCE.replace("\\", "/"))
        except lupa.LuaError as err:
            # smoke.lua calls os.exit(1) on failure; anything else is a genuine
            # error escaping the mod, which is just as much a failure.
            text = str(err).encode("ascii", "replace").decode("ascii")
            print(text)
            failures += 1
        except SystemExit:
            failures += 1
    finally:
        os.chdir(previous)
        shutil.rmtree(sandbox, ignore_errors=True)


parse_pass()
smoke_pass()

print("")
if failures:
    sys.exit("%d failure(s) - do NOT launch until these are fixed." % failures)
print("Mod checks passed.")
