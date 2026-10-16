# Multiplayer audit: every part of Retro Rewind, host vs guest

Started 16 Oct 2026 (Rewind Together 1.7.5), brought up to date for 1.8.0. Source: the game's cooked Blueprints, read with
`bpdump` (482 Blueprint classes in the UE4SS header dump; 510 `GetGameMode` call sites in 150
Blueprints, `bp/_global_getgamemode_callsites.tsv` in the decomp folder). Nothing here is the
game's code; it is what the code does, so the mod can be planned. Status measured on two copies
of the game on one PC (`dev/coop_test.py`), host and guest.

## Why things break for a guest

1. **The GameMode exists only on the host.** Any Blueprint that reads `GetGameMode` stops on a
   guest. 510 places do. Most run only on the host anyway (customer AI, the market, rentals,
   quests, saving) and are fine. The rest are listed below.
2. **"Player 0" is the host.** Actors find the player with `GetPlayerPawn/Controller(0)`.
   RewindNative redirects those to the guest while the host replays a guest's press.
3. **Machines run on the player's own screen.** Sitting at a machine glides the camera,
   enables the machine's input on player 0, and shows hints on the GameMode's HUD.
4. **Most state does not replicate.** Only what the mod patches or mirrors reaches a guest.
5. **What the save sets, only the host's copy has.** The GameMode loads the save, so on a guest
   bought machines were "not bought", their power off (fixed: worldsync.lua sends them).

## Status by system

Legend: OK = works for a guest (verified live), PART = partly, NO = does not, HOST = host-only
by design, TODO = planned, UNTESTED = built, not yet seen working live.

### Core loop
| System | Classes | Guest status | Notes |
|---|---|---|---|
| Walking, bodies, looks | Player_Character_C, bodies.lua | OK | Bodies turn like people: head follows the view, body turns past 60 degrees or when walking. The "walking in circles" was the borrowed animation blueprint's turn-on-the-spot steps at full weight (its turn input sat at 0; 0.5 is standing still) |
| Choosing your character | character.lua, charscreen.lua, creator.lua | OK | The character screen (the game's own pause-menu frame, buttons and font): the 14 named regulars, or every body, skin, hair and colour, beard, glasses, top/bottom/shoes and colour, and height the town has; opens by itself the first time, from the pause menu, on F4. Kept in RewindTogether.character.txt; a guest's choice reaches the host as FNames over ServerNotifyLoadedWorld. Height is the body's Character Scale, as for NPCs |
| Carrying, shelving tapes | PickupActor_C, Shelve_C | OK | |
| What another player carries | bodies.lua hand sockets | OK | The item sits on the body's hand (socket moved by minus the item's offset) |
| Till: scan, cash, change, card | MembershipMachine_C, CheckOut_C, Scanner_Checkout_C | OK | 1.7.5: bill and drawer within 0.1 s of a press |
| Build mode, skin tool, sell | MovingBox_C, AC_MeshSkin_C | OK | Shelf MODEL change: NO (mesh flow reads GameMode) |
| End of day, level-ups | UI_EndOfTheDay_C | OK | dayend.lua |
| The next morning | Core_Gamemode "Create a new day" | OK | The game puts only the host at the start zone; guests are now put beside them, facing the same way |
| Customers, staff, talk | AI_*, TalkSystem_C | OK | npcsync.lua, talksync.lua |
| Return desk (drop box, scan, rewind, store) | Return_C, DropBox_C, Scanner_Dropbox_C, Rewinder_C, Cursor-Movement_Distance_C | OK | machines.lua sits the guest at the host's desk and replays clicks and drags; mirror.lua shows the desk's screen, case and rewinder on the guest |
| Repair station (broken tapes) | RepairStation_C, Cartridge_BrokenTape_C, Cartridge_Screw_C | NO (guarded) | A guest's click on it is not replayed: its Interaction never asks "Can Player use the machine?", so the replay would have sat the guest at the HOST's desk and its glide would have carried the host there. The repair itself is still the host's (plan: the guest's own desk plays it, the host applies the result) |

### Office and UI machines (show a UI on the player's own screen)
| Machine | Guest status | Plan |
|---|---|---|
| Office computer | OK (1.7.4) | computer.lua |
| Catalogue | OK (1.8.0) | uimachines.lua: cards uncovered as far as the store's level goes, station cards drawn from the guest's own machines (the card's own Generate Text, the machine's soft picture handed back); Buy = action 21, placed by the host's own widget handler (no card made: it is never read) one per tick. Verified: a poster frame and the cotton candy machine |
| Staff book (hire/fire) | NO | Both pages empty on a guest (Market / AI Director are host-only). Firing and jobs work through the employee's talk menu (talksync.lua). Plan: a probe widget on the host fires the game's own card events (an FStaff holds 7 TSets) |
| Calendar (rewards, weather) | NO | Placeholders on a guest; claims greyed. Plan: a claim is one no-argument event on the host's slot |
| Store expansion | OK (1.8.0) | The host names each room's expansion ("uim" x0..x5); the guest links its own map (Set Reference And Construct); a click = action 20, the host's own Click Map Button Event |
| Store level | OK (1.8.0) | Cross-mark and genre post-its drawn from the mirrored level, on each page turn |
| Store name | OK (1.8.0) | The guest's own editor; on close its sign goes to the host as one FName ("RTSN:", the name in hex), the host's sign takes it, worldsync gives it to all (and now the font) |
| Sidewalk sign | OK (1.8.0) | The host's ad on every sign ("uim" ss); a guest's pick = action 19 |
| Console rental mat | UNTESTED | Worked by world clicks, which are replayed (excluded from the screen-machine guard); needs level 21 and a returned console |
| Custom movie station | n/a | Not sold in this build (not in the catalogue's station list) |

### Concessions
| Machine | Guest status | How |
|---|---|---|
| Popcorn | OK | concessions.lua: the guest works its own copy (bought on the guest), its level goes to the host and back, its cup is made real on the host and put in the guest's hands, shown full on the guest |
| Slushie | OK (hand-off) | Same; flavour and fill travel with the cup. The minigame itself is the guest's own single-player copy |
| Cotton candy | OK | The hand-off verified (a cotton candy made on the guest's game is real in its hands on the host); its colour is the Color property, which Set Color alone does not write - written too |
| Snack / drink / toy shelves | OK | Host machine session (machines.lua). Adding and taking back verified - after the HUD stand-in below: before it, most adds charged and spawned the snack, then dropped it |
| Candy dispenser | UNTESTED | A catalogue Equipment product (CandyDispense_01_C); not bought in the test save |

### The store around you
| System | Guest status | Notes |
|---|---|---|
| Day/night lights and sounds | OK | worldsync.lua tells every time-of-day listener the host's time (94 told) |
| Sun, sky, snow, season scenery | OK | worldsync.lua |
| Seasonal events (fair, UFO, derby...) | NO? | EventSystem_C and Event_* bind through the GameMode |
| Telephone (reservations, questions) | OK | Answering: the conversation on the guest's screen (talksync.lua), answered there. Ringing, its light, shake and the handset are mirrored (mirror.lua) |
| TVs / movie player | OK | worldsync.lua starts the movie players and wires each TV (8/8 with a picture); the channel can differ from the host's |
| Arcades | PART? | Look-at and "Take money" read the GameMode; clicks replay on the host |
| Trash, recycling, toilet | PART | Picking trash up verified (host replay); throwing it in a bin not tried |
| Flyers | ? | Flyers-Stack "Is it interactable?" reads the GameMode |
| Posters, decorations, text signs | OK | skinsync.lua |
| Bought machines (popcorn, slushie, sidewalk sign...) | OK | worldsync.lua: "Make Machine Usable For Player" on the guest's copy |
| Tutorial quests | HOST | Shown on the host's HUD only |
| Achievements | HOST | Steam achievements go to the host's account |

## Found along the way

- **A guest window hid the host's HUD by setting the GameMode's "UI Game Interface" to nothing, and
  Change Money then answered "not enough money"** after writing the new total (Core_Gamemode @430 →
  @810 returns without setting it). Every guest action that checks the answer charged and gave up:
  the snack shelf spawned the snack, charged $0.50 and destroyed it. Now the window swaps in a
  second copy of the HUD that is never on screen (guestinput.lua `asGuest`).
- **A click on a screen machine was replayed on the host.** Most refuse a remote player, but the
  repair desk, the sidewalk sign and the store name sign do not ask, and the glide that follows
  runs on player 0 - the host. Clicks on screen machines (except the console rental mat) are no
  longer replayed.

## Three ways a machine works for a guest

1. **Host session** (machines.lua): what the machine works on is the host's (the drop box's
   tapes, the store's stock). The guest's own game sits down and says so; the host sits the guest
   down at ITS machine as the guest, stops the glide, and replays the guest's clicks and drags
   from the guest's camera. Cosmetics the host's copy plays are mirrored (mirror.lua).
2. **Guest's own copy, results made real** (concessions.lua): the machine is self-contained and
   driven by the local mouse or tick (the popcorn shovel follows the local mouse every tick; a
   full cup goes to player 0 a tick later), so it cannot be replayed. The guest plays its own
   copy; the host makes the results real (levels, the product in the guest's hands).
3. **UI on the guest's screen, data from the host** (computer.lua, uimachines.lua): the guest's UI
   is filled with the host's data; the guest's choices go to the host as actions, and the host's own
   machine does them (its widget's own handler, with no struct crossing Lua).
