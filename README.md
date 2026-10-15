# Rewind Together

**Co-op multiplayer for Retro Rewind.** Open your video store to friends and run it
together: same shelves, same stock, same till, same clock.

Version 1.7.0 · for Retro Rewind Steam build 23896268 ("Changelist 2308") · Windows

---

## Quick start

1. Download and unzip **Rewind Together**.
2. Run **`RewindTogetherLauncher.exe`**. It finds Retro Rewind, installs the UE4SS
   loader if you don't have it, and installs the mod. Your saves are backed up first.
3. **Hosting:** press **HOST MY STORE**, pick your save in the game as usual, and walk into
   your store. It opens to friends by itself.
4. **Joining:** on the **Visit a friend** side, pick a friend whose store is open, or use
   *Other ways to join* to type an address. The game starts and connects straight from the
   main menu. You don't need a save of your own.

Everyone needs the same version of the mod and the same version of the game. If Steam
updates Retro Rewind, wait for a mod update before playing together.

---

## What you get

**One shared store.** The host's save is the store everyone plays in. Guests see the
host's shelves, stock, decorations, expansions and sign exactly as the host does.

**Guests can work the store.** Right-click picks up and uses things, left-click places
them, and E, V, B and K switch tools and sell, just like in single player. A guest's
actions are carried out on the host's game, so the result is identical on every screen.
Taking a tape off a shelf and putting it back has been verified in game, on both screens.

**The rest of the world matches too:**
- **Money, XP, level and the clock**, on the guest's own HUD.
- **Day, weekday, season and weather**, including the season scenery (snow, bare trees).
- **The sky, sun, fog and street lighting.**
- **The town's customers and passers-by:** their looks (body, clothes, colours, hair)
  and their animation.

**Only the host saves.** Guests' own saves are never read or written.

---

## Ways to connect

| Route | Setup | Status |
|---|---|---|
| Same house / LAN | none: *Join by address*, the host's local IP | works |
| VPN (Tailscale, ZeroTier, Radmin) | both join the same VPN, then *Join by address* | works (how the mod was first tested) |
| Port forward (UDP 27015) | `OPEN PORT FOR FRIENDS - Double click me.bat` on the host | works if your router allows it |
| Steam (friends list / *Join Game*) | nothing: the launcher carries the game over Steam's relay | **new in 1.7.0, needs real-world testing - please report** |

Hosting always uses UDP port **27015**; the mod sets it when it opens your store, and it
cannot be changed.

---

## In game

| Key | Does |
|---|---|
| **F7** | Host: open your store to friends (the launcher does this for you) |
| **F5** | Join `Config.JoinTarget` or a hosting friend |
| **F6** | Status (printed in the UE4SS console) |

The UE4SS console (the black window next to the game) takes these commands:

| Command | What it's for |
|---|---|
| `rt.status` | Version, who's connected, and whether the sync channel is carrying data |
| `rt.diag` | Everything worth sending with a bug report |
| `rt.join <ip>` | Join by address |
| `rt.native` | The native helper that lets guests act in the store |
| `rt.safety` | What switched itself off after a crash, and how to turn it back on |

---

## Known limitations (1.7.0)

- **The guest's HUD doesn't yet show the item in your hands or the "look at" details.**
  The item itself is in your hands and works; only the panel is missing. Money, the clock
  and XP do show.
- **A guest's own game also runs each click locally.** You may occasionally see an object
  jump for a moment before the host's version arrives. The host's version always wins.
- **The host decides end of day.** Closing up and starting a new day happen on the
  host's game, and guests follow.
- **Build mode, the skin tool and the mesh tool are untested for guests.** Stocking,
  picking up and placing are the tested paths.
- **NPC clothes and colours match the host's; their exact walking paths are the host's
  NPC positions,** so a customer can briefly look slightly different the moment it
  appears.

---

## If something goes wrong

1. In the launcher, open **Diagnostics** and press **Copy diagnostics**. Paste that into
   your bug report.
2. Logs:
   - `Retro Rewind\RetroRewind\Binaries\Win64\RewindTogether.log`
   - `...\Binaries\Win64\ue4ss\UE4SS.log`
3. **If the game crashes, just start it again.** The mod writes down what it was doing
   before each risky step. The next launch switches that one feature off and says which
   one (`rt.safety`), so you can't get stuck in a crash loop.

To remove the mod, use **Uninstall** in the launcher's Mods tab (close the game first).

---

## Compatibility and safety

- **What's changed in the game folder:** nothing. The mod runs entirely through UE4SS
  (Lua plus one small native helper, `RewindNative.dll`). No `.pak` file is touched. The
  helper's source is in the zip under `Source\RewindNative`.
- **Online services:** Retro Rewind has no online mode and no anti-cheat. Co-op runs on
  Unreal's own networking between you and your friends; nothing goes through a third-party
  server except Steam's relay, if you choose it.
- **Saves:** back them up anyway. The launcher does this before every install, into
  `Documents\RewindTogether Backups`.

---

## Credits

- **Rewind Together:** built by the Rewind Together team with heavy help from **Claude
  (Anthropic)** through Claude Code. Most of the code, the reverse engineering and the
  testing were done by an AI agent working on the team's own copy of the game, and every
  claim in this README was checked in the running game unless marked otherwise.
- **UE4SS** by the UE4SS team (github.com/UE4SS-RE/RE-UE4SS), MIT license.
- **Retro Rewind** by its developers. This mod is not affiliated with or endorsed by them.
  Please buy the game; the mod needs your own copy to work.
