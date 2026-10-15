# Rewind Together

**Co-op multiplayer for Retro Rewind.** Open your video store to friends and run it
together: same shelves, same stock, same till, same clock.

Version 1.7.0 · for Retro Rewind Steam build 23896268 ("Changelist 2308") · Windows

---

## Quick start

New to this? **[HOW TO PLAY - START HERE.txt](HOW%20TO%20PLAY%20-%20START%20HERE.txt)** (also in the
download) walks hosts and guests through every step.

1. Download **Rewind Together**, right-click the zip and choose **Extract All...**
2. Open **`RewindTogetherLauncher.exe`** from the unzipped folder. That's the whole install:
   it finds Retro Rewind, backs up your saves, and installs the UE4SS loader and the mod by
   itself (both come in the zip, so nothing is downloaded). If the game is open, it offers
   to close it first. If Windows shows "Windows protected your PC", click **More info**,
   then **Run anyway** (the exe isn't code-signed).
3. **Hosting:** press **HOST MY STORE**, pick your save in the game as usual, and walk into
   your store. It opens to friends by itself.
4. **Joining:** on the **Visit a friend** side, pick a friend whose store is open, or use
   *Other ways to join* to type an address. The game starts and connects straight from the
   main menu. You don't need a save of your own.

Everyone needs the same version of the mod and the same version of the game. If Steam
updates Retro Rewind, wait for a mod update before playing together.

**Updating:** when a new version is out, the launcher shows a green banner. Press **Update**: it
downloads the new version from this project's GitHub releases, checks it, replaces itself and
the mod, and restarts, in about a minute. Your saves and settings stay as they are. Update when
you're not in a co-op session, and update together so you both have the same version. (From
1.7.1 on; a 1.7.0 launcher needs one last manual download.)

---

## What you get

**One shared store.** The host's save is the store everyone plays in. Guests see the
host's shelves, stock, decorations, expansions and sign exactly as the host does.

**Guests can work the store.** Right-click picks up and uses things, left-click places
them, and E, V, B and K switch tools and sell, just like in single player. A guest's
actions are carried out on the host's game, so the result is identical on every screen.
Verified in game, on both screens:
- taking a tape off a shelf and putting it back, with the item and its details on the
  guest's own HUD;
- **ringing customers up at the till**: the register's screen, the bill, the customer's
  cash and the change on the counter;
- **build mode**: packing furniture and placing it, with the guest's own green/red
  placement preview;
- **the skin tool**: picking colours for the carpet and the shelves;
- **talking to the staff member**: the conversation opens on the guest's screen and the
  guest answers it (other conversations, such as a customer's, take the same path but
  were not each tried).

**The rest of the world matches too:**
- **Money, XP, level and the clock**, on the guest's own HUD.
- **Day, weekday, season and weather**, including the season scenery (snow, bare trees).
- **The sky, sun, fog and street lighting.**
- **The town's customers and passers-by:** their looks (body, clothes, colours, hair),
  their animation, what they say, and the basket or cash in their hands.
- **Shelf titles, the signs you wrote and the film posters.**
- **The end of the day:** the host's summary, the XP bar and the level-up unlocks, then
  the new-day banner.

**Only the host saves.** Guests' own saves are never read or written.

**Other mods.** Rewind Together doesn't share or download mods. Before you join, the launcher
compares your mods with the host's and tells you what differs: the Rewind Together version
(must match), content mods such as `.pak` and Blueprint mods (should match, or things go
missing), and UE4SS script mods (usually fine). You can still choose "Join anyway".

**Discord.** While the game runs, your Discord profile says **Playing Rewind Together** and what
you're doing: hosting a video store, visiting a friend's store, running the store solo, or in
the main menu. It also shows how many players are in the store and gives a link to this
project. Nobody's name, address or Steam ID is shown. It needs the Discord app running on the
same PC, and you can switch it off under Diagnostics.

---

## Ways to connect

| Route | Setup | Status |
|---|---|---|
| Same house / LAN | none: *Join by address*, the host's local IP | works |
| VPN (Tailscale, ZeroTier, Radmin) | both join the same VPN, then *Join by address* | works (how the mod was first tested) |
| Port forward (UDP 27015) | `Extras\OPEN PORT FOR FRIENDS - Double click me.bat` on the host | works if your router allows it |
| Steam (friends list / *Join Game*) | nothing: the launcher carries the game over Steam's relay | **new in 1.7.0, needs real-world testing - please report** |

Hosting always uses UDP port **27015**; the mod sets it when it opens your store, and it
cannot be changed.

---

## In game

| Key | Does |
|---|---|
| **F7** | Host: open your store to friends (the launcher does this for you) |
| **F5** | Join `Config.JoinTarget` or a hosting friend |
| **F6** | Status: a short box in the middle of the screen for 8 seconds (in a store), and the full report in `RewindTogether.log` |

The game's own console takes these commands: press **~** twice (or **F10** twice) to open
it, type the command, press **Enter**; press **~** once more to close it. (UE4SS's GUI
console window takes them too, if you have turned it on. A fresh install doesn't show one.)

| Command | What it's for |
|---|---|
| `rt.status` | Version, who's connected, and whether the sync channel is carrying data |
| `rt.diag` | Everything worth sending with a bug report |
| `rt.join <ip>` | Join by address |
| `rt.native` | The native helper that lets guests act in the store |
| `rt.safety` | What switched itself off after a crash, and how to turn it back on |

---

## Known limitations (1.7.1)

- **A guest's own game also runs each click locally.** You may occasionally see an object
  jump for a moment before the host's version arrives. The host's version always wins.
- **The host decides end of day.** Closing up and starting a new day happen on the
  host's game, and guests follow (the guest sees the summary; its buttons are the host's).
- **Guests can't change a shelf's model** (the mesh tool). Colours (the skin tool) work.
- **The mouse wheel's tool switching isn't sent to the host;** use E, V and B.
- **Tested with two copies of the game on one PC.** Two players on two PCs over the
  internet, and the Steam route in particular, still need real-world testing.
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

## License

Rewind Together is free to use, change and share for **noncommercial** purposes under the
[PolyForm Noncommercial License 1.0.0](LICENSE) (`LICENSE.txt` in the download). Nobody may
sell it. The developer and publisher of Retro Rewind are additionally allowed to use it for
any purpose, including building it into the game. UE4SS, which the launcher installs, is
under its own MIT license.
