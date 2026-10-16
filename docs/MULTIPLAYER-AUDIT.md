# Multiplayer audit: every part of Retro Rewind, host vs guest

Started 16 Oct 2026 (Rewind Together 1.7.5), brought up to date for 1.9.0. Source: the game's cooked Blueprints, read with
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
| Choosing your character | character.lua, charscreen.lua, creator.lua | OK | The character screen (the game's own pause-menu frame, buttons and font): the 14 named regulars, or every body, skin, hair and colour, beard, glasses, top/bottom/shoes and colour, and height the town has; opens by itself the first time in each store (on the character made last), from the pause menu, on F4. Kept in RewindTogether.character.txt, one section per store (a key from the host's Steam ID and its "Save Slot Name", sent to guests as "chr"); a guest's choice reaches the host as FNames over ServerNotifyLoadedWorld. Height is the body's Character Scale, as for NPCs |
| Carrying, shelving tapes | PickupActor_C, Shelve_C | OK | |
| What another player carries | bodies.lua hand sockets | OK | The item sits on the body's hand (socket moved by minus the item's offset) |
| Till: scan, cash, change, card | MembershipMachine_C, CheckOut_C, Scanner_Checkout_C | OK | 1.7.5: bill and drawer within 0.1 s of a press |
| Build mode, skin tool, sell | MovingBox_C, AC_MeshSkin_C | OK | Shelf MODEL change: NO (mesh flow reads GameMode) |
| End of day, level-ups | UI_EndOfTheDay_C | OK | dayend.lua |
| The next morning | Core_Gamemode "Create a new day" | OK | The game puts only the host at the start zone; guests are now put beside them, facing the same way |
| Customers, staff, talk | AI_*, TalkSystem_C | OK | npcsync.lua, talksync.lua |
| A customer's request at the help desk (rent a console) | BTTask_ConsoleRent-Asking_C, Request-QuestZone_ConsoleRental_C, ConsoleRent-Case_C | PART (not committed) | The talk now opens on the guest who clicked (talksync adopts a talk begun in a guest's window; the task had noted the host) - measured live, and the guest's accept made the request the guest's. Measured live: the guest's left click handing the console over, the case and its lid on the guest, paying (the guest clicks the money), and a returning customer's case with the console on the guest's counter. Not tried live: the guest taking a returned console out of the case |
| Return desk (drop box, scan, rewind, store) | Return_C, DropBox_C, Scanner_Dropbox_C, Rewinder_C, Cursor-Movement_Distance_C | OK | machines.lua sits the guest at the host's desk and replays clicks and drags; mirror.lua shows the desk's screen, case and rewinder on the guest |
| Repair station (broken tapes) | RepairStation_C, Cartridge_BrokenTape_C, Cartridge_Screw_C | OK (1.9.0) | repairs.lua: a tape's Error is not replicated, so the host tells each guest the state of the tape in its hand ("rph") and the guest's copy is given it; the guest's own desk plays the minigame on its own screen (the zones, tools and tape model are the local player's) and at its end (Repair cartridge End, hooked) action 24 has the host mend the real tape in that guest's hand (Set Error 1, sticker off, Change XP 2). Leaving mid-repair puts the tape back in the guest's hands. Broken stickers through mirror.lua. Steam stat 16 is not counted for guests. Measured live: a whole repair with real clicks (open, screwdriver, three screws, scissors, two cuts), host XP +2 |

### Office and UI machines (show a UI on the player's own screen)
| Machine | Guest status | Plan |
|---|---|---|
| Office computer | OK (1.7.4) | computer.lua |
| Catalogue | OK (1.8.0) | uimachines.lua: cards uncovered as far as the store's level goes, station cards drawn from the guest's own machines (the card's own Generate Text, the machine's soft picture handed back); Buy = action 21, placed by the host's own widget handler (no card made: it is never read) one per tick. Verified: a poster frame and the cotton candy machine |
| Staff book (hire/fire) | OK (1.9.0) | staffbook.lua: the host sends who is in the book ("stf": name, pay, skills, photo, traits, job, about, favourite movie; the traits TSet reads with ForEach); the guest's game draws its own cards (plain numbers into the card's Staff before AddChild, so its Construct writes pay and skill words; texts, photo and trait lines after; again after every tab switch). Hire, fire and job = action 22 (what, the card's place, its pay): the host builds an unseen copy of the book's screen, has it draw the page from its GameMode and clicks that card's own button, inside asGuest (a refusal goes to the stand-in HUD; the guest shows the game's own string-table words). Steam stat 8 and achievements 8/9 count on the host's account. Measured live: both pages drawn, a job change, the level-20 refusal, a fire (the employee walked out) and a hire (walked in on both screens) |
| Calendar (rewards, weather) | OK (1.9.0) | calendar.lua: the guest's own machine is given its weather actor and "Save Load", and its own Init Calendar draws the list (the guest's Steam), weather and check marks; the host's year and each day's events ("cal") are drawn with the game's own day cells (icons and bonus tooltips); each row's claimed mark is the store's. A Claim = action 23: the host clicks its own row (Achievement Reclame, +$100, +50 XP). Measured live: the guest's page identical to the host's, a claim paid the store once. A new day's redraw on a guest is untested live |
| Store expansion | OK (1.8.0) | The host names each room's expansion ("uim" x0..x5); the guest links its own map (Set Reference And Construct); a click = action 20, the host's own Click Map Button Event |
| Store level | OK (1.8.0) | Cross-mark and genre post-its drawn from the mirrored level, on each page turn |
| Store name | OK (1.8.0) | The guest's own editor; on close its sign goes to the host as one FName ("RTSN:", the name in hex), the host's sign takes it, worldsync gives it to all (and now the font) |
| Sidewalk sign | OK (1.8.0) | The host's ad on every sign ("uim" ss); a guest's pick = action 19 |
| Console rental (mat and station) | OK (1.9.0) | World clicks, replayed on the host (excluded from the screen-machine guard). The guest's copies get the host's monitor (Status For Monitor, the scan's progress bar), slot lights and console states ("crs"; the guest's copies always read State 1, so its own shelf and mat never act on their own), the mat's drawers and the stickers through mirror.lua, and a console copy whose own Verify turned its physics on is put back on its root. Measured live: put on the mat, the scan on the guest's monitor, taken back, shelved |
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
- **A guest carrying something who clicked a screen machine lost it on the host.** The guest's own
  game opened its own copy (the repair desk took the broken tape), while the host replayed the
  click: with something in hand the host's look-at did not land on the machine, so the click put
  the tape down on the floor in front of the desk (measured). The guest no longer sends a click
  whose look-at is a screen machine (guestinput.lua onPress).
- **A guest's console copy fell out of its own actor.** About 20 s after a console appears, the
  guest's copy runs its own "Verify if the console is stored somewhere", finds none of its guards
  hold on a guest, lifts itself and turns its physics on; its mesh then stays where it was while
  the actor follows the host (a VHS player on the host's mat was still on the guest's floor at the
  delivery spot). repairs.lua turns that physics off again and puts the copy where the host's is.
- **A customer asking for help gave the talk to the host, whoever clicked.** The asking tasks note
  player 0 when the customer reaches the desk, long before anyone clicks, so a guest's click opened
  the dialog on the host's screen. A talk that begins inside a guest's replayed click is now that
  guest's (talksync.lua).
- **Every customer carries a hidden console case, a child actor.** Sending those to guests gave each
  customer a second, floating case on the guest. A child actor is not yet linked to its parent when
  it appears, so GetParentActor cannot tell them apart at that moment; only the help desk's own case
  ("Case Slot") is sent, and Replication.patchActor refuses child actors.

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
