#!/bin/sh
# Copy the mod's scripts (not config.lua - that is the user's) to the game.
SRC="$(cd "$(dirname "$0")/.." && pwd)/Mods/RewindTogether/Scripts"
DST="/d/SteamLibrary/steamapps/common/RetroRewind/RetroRewind/Binaries/Win64/ue4ss/Mods/RewindTogether/Scripts"
for f in "$SRC"/*.lua; do
  b=$(basename "$f")
  [ "$b" = "config.lua" ] && [ "$1" != "--with-config" ] && continue
  cp "$f" "$DST/$b"
done
echo "deployed $(ls "$SRC"/*.lua | wc -l) files (config.lua $( [ "$1" = "--with-config" ] && echo included || echo kept ))"
cp "$SRC/../mod.json" "$DST/../mod.json"
# The native helper. A running game keeps it pinned, so this fails until the
# game is closed - which is the only time a new build should go in anyway.
mkdir -p "$DST/../native"
cp "$SRC/../native/RewindNative.dll" "$DST/../native/RewindNative.dll" 2>/dev/null || echo "RewindNative.dll in use - close the game to update it"
