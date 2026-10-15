--[[
    Rewind Together - user configuration
    ------------------------------------
    Edit the values below, then restart the game (or run `rt.reload` in the
    game's console - press ~ twice) to apply. Every value has a safe default; if you break
    something, delete this file and reinstall.
]]

local Config = {}

-- Bumped whenever options are added, removed, or their defaults change in a
-- way that matters. The installer replaces (and backs up) an installed config
-- whose version differs, so an old file cannot silently undo a fix.
-- Bumped to 9 for 1.5.1: Config.SafeMode's DEFAULT changed from true to false.
-- That is the case this gate exists for. Without the bump, anyone upgrading
-- keeps their old file, keeps SafeMode = true, and silently gets none of the
-- fix - which is indistinguishable from the fix not working.
--
-- A new option whose absence equals its default still does NOT need a bump;
-- replacing someone's config.lua throws away their JoinTarget and their
-- PeerSteamIds, so this is a real cost and not a formality. The installer
-- backs the old one up either way.
Config.ConfigVersion = 9

--------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------

-- How many people can be in the store at once (including the host).
-- The engine is happy well past this; 4 is what the store layout comfortably fits.
Config.MaxPlayers = 4

-- Transport used for the UE replication channel.
--   "ip"     - Direct IP / LAN. Host must be reachable on Config.Port.
--   "steam"  - Steam P2P relay. No port forwarding, but see the warning below.
--
-- DEFAULT IS "ip", AND ON THIS BUILD THAT IS THE ONLY ONE THAT WORKS.
--
-- Why: asking for "steam" does not fail, it silently downgrades. The engine
-- creates the driver named in NetDriverDefinitions, calls IsAvailable() on it,
-- and quietly substitutes DriverClassNameFallback when that returns false.
-- SteamCoreSocketsNetDriver is present in this build but reports itself
-- unavailable, so every "steam" host actually came up on IpNetDriver - the log
-- said "net driver set to SteamCoreSockets (relay)" and then "net driver:
-- IpNetDriver" three seconds later. A steam.<id> address means nothing to
-- IpNetDriver, so the guest was bounced to the main menu with no error.
-- That is why joining by Steam ID and Steam's "Join Game" never worked.
Config.Transport = "ip"

-- The UDP port the host listens on and the guest connects to.
--
-- 27015, MEASURED - not assumed. With the game hosting, the listen server's
-- socket was read straight off the process: it binds 27015.
--
-- Two things that look true but are not:
--   * Unreal's documented default is 7777. This build does not use it; the
--     packaged DefaultEngine.ini sets [URL] Port=27015, and that is baked
--     into the pak where nothing can wipe it.
--   * "?Port=" on the travel URL does not move it. FURL takes the port from
--     the host:port part of an address, not from an option, so the listen
--     server ignores it entirely.
--
-- A previous build changed this to 7777 on the theory that the host bound the
-- engine default. It does not, and that change broke a setting which had been
-- correct all along - the guest dialled 7777 while the host sat on 27015.
--
-- If you ever need to check rather than trust this: host, then run
-- "Extras\CHECK CONNECTION - Double click me.bat". It reads the real socket.
--
-- Both players must have the same value here.
Config.Port = 27015

-- LEGACY - nothing here needs filling in any more.
--
-- Until 1.6.0, money, the clock and chat rode Steam's P2P API, which needs
-- both players to type in each other's Steam ID - and which 1.5.7 measured
-- cannot send on this build at all. Since 1.6.0 all of it rides the game's
-- own connection, which exists the moment a guest joins and needs nothing
-- from anybody (rpcchan.lua). These stay only so an old config.lua still
-- loads; they do nothing unless UseSteamP2P is switched on.
Config.UseSteamP2P = false
Config.P2PChannel  = 41
Config.PeerSteamIds = { }

--------------------------------------------------------------------------
-- Gameplay
--------------------------------------------------------------------------

-- Force replication onto these actor classes so guests can see them.
-- Names are matched against the class name (without the _C suffix).
-- Add your own here if you find props that do not show up for guests.
Config.ReplicatedClasses = {
    -- People
    "Player_Character",
    "AI_Character",
    "Staff",
    "Customer",

    -- Things the player moves around
    "PickupActor",
    "MovableActor",
    "Cartridge_Base",
    "MovingBox",
    "Shelve",
    "Shelve_Container",
    "BoxStorage_Container",
    "SnackBox",
    "SnackShelf",
    "Snack_Pack_4x",
    "Storage_Box",
    "Storage_Cartridge",
    "Decoration",
    "PosterFrame",
    "Standees",
    "TextSign",
    "Door",
    "Arcade",
    "CandyDispenser_Base",
    "ConsoleRental_Console-Base",
    "BP_Television_BASE",
    "Wall",
}

-- Let a GUEST also mark its own class defaults as replicating.
--
-- LEAVE THIS OFF. It is here to A/B test one specific problem, not to be used.
--
-- Symptom it exists for: on the guest, walls, shelves and the counter render
-- as yellow-and-black placeholder boxes, while everything the mod does NOT
-- touch - cobbles, planters, signs, doorways, NPCs - looks perfect. The
-- striped objects match the list above too closely to be coincidence.
--
-- Why a guest doing this would break things: an actor derives its Role and
-- RemoteRole from its class default object. Marking a CDO as replicating on a
-- CLIENT tells every level-placed actor of that class that it is a network
-- proxy waiting to be told what it looks like, instead of something the level
-- already fully describes - so it never configures itself and draws its bare
-- default. Replication is an authority-side decision; the guest receives
-- actors because the HOST chose to send them.
--
-- Turn it on only to confirm the stripes come back.
Config.PatchReplicationOnClients = false

-- How often (Hz) replicated props push updates. Higher = smoother, more bandwidth.
Config.PropNetUpdateFrequency = 10

-- How often (Hz) player characters push updates.
Config.PawnNetUpdateFrequency = 30

-- Give a joining player a character if the game does not.
--
-- LEAVE THIS ON. Without it a guest connects successfully and then sits at a
-- black screen forever: the game's GameMode was written for one player, so its
-- login path never hands a second one a pawn, and a controller with no pawn
-- renders the world from the origin - which here is inside solid geometry.
--
-- Deliberately NOT guarded by a ConfigVersion bump. The mod treats a missing
-- value as "on", so an older config.lua carried forward still gets the fix
-- rather than silently reintroducing the black screen it was written before.
--
-- Turn it off only to confirm that a problem is this and not something else.
Config.AutoSpawnGuestPawns = true

-- Move an arriving guest next to the host instead of leaving them wherever the
-- level's PlayerStart happens to be.
--
-- LEAVE THIS ON. The store level contains exactly one PlayerStart and the game
-- has never used it - Retro Rewind puts you in your shop from your save file,
-- not from a spawn marker, so nothing has ever had to be correct about where
-- that marker sits. A guest dropped on it can end up under the floor, outside
-- the building, or at the world origin. Appearing next to your friend is also
-- simply what you want when you join a co-op game.
Config.PlaceGuestsNextToHost = true

-- "Back to the store" in the pause menu (Escape), and a pause menu for guests
-- at all - the game only opens its own on the machine with the GameMode, the
-- host's. A guest who presses it is put beside the host; the host is put by
-- the register. rt.unstuck does the same from the console. Missing = on.
Config.PauseMenuBackToStore = true

-- If a guest ends up far below the host, pull them back up.
--
-- A guest who is merely spawned badly is fixed once. A guest who keeps ending
-- up underneath is falling through geometry that does not exist on their
-- machine, which is a different problem - so this gives up after a few tries
-- and says so rather than teleporting them forever.
Config.RescueFallingGuests = true

-- Give other players a visible body, borrowed from the store's own NPCs.
--
-- This game is first person. Player_Character_C derives from ACharacter so it
-- already HAS a mesh component - every ACharacter does - but a game nobody
-- ever sees themselves in had no reason to put a body in it. Two players can
-- therefore stand next to each other, replicating perfectly, and see nothing;
-- whatever they are carrying floats in mid-air, because a pickup is an
-- ordinary actor and replicates like one.
--
-- The staff and customers walking around the store are skeletal meshes that
-- are already loaded and already the right scale, so one gets borrowed.
--
-- Entirely cosmetic and entirely LOCAL: your machine decorates the pawns you
-- can see and never touches your own, so this needs no agreement with the
-- other player and nothing about it is sent anywhere.
--
-- Turn it off if you would rather see nothing than see your friend as a shop
-- assistant. rt.bodies shows what it found.
Config.BorrowNpcBodies = true

-- EXPERIMENTAL, OFF. Build a whole GameMode on the guest, automatically, once,
-- a few seconds after they get a pawn.
--
-- Measured in 1.7.0: it builds the HUD, and it also starts a complete new game
-- on the guest (tutorial, quests, the default store sign, locked expansions) and
-- loads - and could save - the guest's last save slot. The HUD is now built
-- without it (Config.GuestHud). Leave this off unless you are experimenting.
--
-- A guest has no GameMode. AGameMode is server-only by engine design and never
-- replicates, so on the client the object simply does not exist - which is why
-- a guest has no HUD, no clock, no money, no synced time, and why the store's
-- own terminals (the computer, the catalogue, the time clock, the employee
-- sheet) do nothing when they walk up to them. Every one of those reads from
-- the object that is missing.
--
-- The engine forbids REPLICATING a GameMode. It does not forbid a client from
-- owning an ordinary actor of that class, and the class is known on the client
-- for free because AGameStateBase replicates GameModeClass.
--
-- THIS IS AN EXPERIMENT. Nobody knows what this game's GameMode does in
-- BeginPlay - it may load the guest's own save and build them a second store,
-- which would be wrong but would say so plainly. It runs behind a crash
-- breadcrumb: if it takes the game down, the next launch switches it off and
-- explains itself.
--
-- It was a manual command for three test sessions and was never once run,
-- because it needs somebody to type into a console mid-session. Set this to
-- false to go back to that; rt.localgm still works by hand either way.
Config.GuestLocalGameMode = false

-- Drive the borrowed body's animation directly instead of letting the donor
-- NPC's animation blueprint do it.
--
-- The body is borrowed from a wandering pedestrian, and so is its animation
-- blueprint - a graph written to drive that NPC, reading that NPC's state.
-- On a player character it reads nothing and guesses, which is why the body
-- was reported "moving in a circle" and idling far more than it walked.
--
-- With this on, the mod finds idle/walk/run sequences that fit the borrowed
-- skeleton and plays them directly off the player's measured speed. If none
-- fit, the blueprint stays in charge and the log says so.
--
-- OFF BY DEFAULT, AND OFF FOR A REASON. Finding those sequences means asking
-- the engine for every loaded AnimSequence and reading a name off each one -
-- a sweep, which PROJECT.md warns about in as many words. In 1.6.0 it took the
-- host's process down the instant a guest joined. It is capped and
-- liveness-checked now and it is still the riskiest thing the mod can do.
--
-- Turn it on only if the circling idle bothers you more than the risk of one
-- bad launch. A crash retires it by itself and the next launch explains why.
Config.DriveBodyAnimation = false

-- Guest only: strip the yellow-and-black hazard stripes off the store.
--
-- On a guest the store renders with build-mode hazard stripes drawn OVER
-- correct geometry - the price signs are readable underneath, the counter is
-- the right colour. That is an OverlayMaterial pass, not a broken material,
-- and removing it is purely local and purely cosmetic.
--
-- If it turns out the stripes are not an overlay, this does nothing and the
-- log says so.
Config.ClearBuildModeOverlay = true

-- Make every replicated actor always relevant, bypassing distance culling.
-- Leave this OFF. Turning it on makes the server serialise every prop in the
-- store to every client on every update, which costs bandwidth and framerate
-- for no visible gain - 150m of cull distance already covers the whole store.
Config.AlwaysRelevant = false

--------------------------------------------------------------------------
-- Store state sync (host-authoritative)
--------------------------------------------------------------------------

-- Push the host's money, XP, clock, weekday, season and weather to guests
-- this many times per second. WHAT is pushed is not a setting any more: the
-- property names were read off the game in 1.7.0 and live in sync.lua.
Config.StateSyncHz = 4

-- Guest only: put the store HUD (money, clock, XP, toolbar) on screen. Only
-- the host's GameMode ever builds it, so a guest otherwise has none.
Config.GuestHud = true

-- Guest only: on that HUD, also show what is in your hands and what you are
-- looking at (the product panel, the button hints, the crosshair), as the
-- host's does. The game draws those through its GameMode, which a guest does
-- not have; RewindNative.dll stands in for it for exactly those calls and
-- nothing else (hud.lua explains). rt.native shows whether it is on. Turn it
-- off if a guest's HUD misbehaves - everything else keeps working.
Config.GuestHudDetails = true

-- Guest only: while you carry packed furniture, draw the see-through preview
-- of where it will land, green or red, as the host sees theirs. The host
-- tells your game what the furniture looks like; your own game draws it every
-- frame (guestinput.lua, "Build mode"). Missing counts as on.
Config.GuestBuildPreview = true

-- Host: a conversation a guest starts (the staff member, a customer at the
-- till, the telephone) goes up on that guest's screen, to be answered with
-- their mouse - not on the host's (talksync.lua). Missing counts as on.
Config.GuestConversations = true

--------------------------------------------------------------------------
-- Interaction forwarding
--------------------------------------------------------------------------

-- When a guest interacts with the world, forward the action to the host so the
-- host's simulation stays authoritative. Turn this off if it causes trouble;
-- guests will still be able to walk around and see everything.
--
-- THIS IS WHY A GUEST CAN SEE THE HOST PICK THINGS UP BUT NOT THE OTHER WAY
-- ROUND, and it is not a bug in the usual sense. In Unreal only the server has
-- authority: the host's actions replicate down to everyone automatically,
-- while a guest pressing "use" runs the Blueprint on their machine alone and
-- the server is never told. No amount of turning replication on fixes that
-- direction - the game's Blueprints have no server RPCs and none can be added
-- to a cooked build. So the guest's INTENT is forwarded over the game's own
-- connection and the host re-runs it with authority; whatever the host then
-- touches reaches everyone through normal replication.
Config.ForwardGuestInteractions = true

-- The key a GUEST presses to have their interaction forwarded to the host.
--
-- Set this to whatever key the game itself uses to pick things up, so one
-- press does both: your own client shows you the result immediately, and the
-- host performs the real one a moment later.
--
-- The mod cannot read the game's own binding, and it cannot hook the game's
-- interact function either - nobody has yet run  rt.funcs  to find out what
-- that function is called. Until then this keybind is the only trigger there
-- is. Set it to "" to disable.
Config.GuestInteractKey = "E"

--------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------

-- SAFE MODE - ON, and leave it on. This disables the two features that build
-- render components at runtime: floating nametags and the on-screen overlay.
-- Everything that makes co-op work is untouched.
--
-- 1.5.1 turned this OFF on a theory, and 1.5.4 turns it back on because the
-- theory was measured and was wrong. Recording both, because the wrong answer
-- was a good guess and somebody will have it again:
--
--   The call was
--     StaticConstructObject(cls, pawn, name, 0, 0, nil, false, false, nil)
--   against UE4SS's order (Class, Outer, Name, SetFlags, InternalSetFlags,
--   bCopyTransientsFromClassDefaults, bAssumeTemplateIsArchetype, InTemplate,
--   ...) - a nil where a bool belongs and a `false` where a UObject* belongs.
--   That looks exactly like a crash inside StaticConstructObject_Internal.
--
-- It was not. With the three-argument form - which cannot have the wrong types
-- in it, because there is nothing after Name to get wrong - construction still
-- does not produce a usable component: the object comes back, passes
-- UObject::IsValid, and then RegisterComponent reports the instance is
-- nullptr. Measured on BOTH machines, 1,275 times on one and 15,000 on the
-- other in a single session.
--
-- So the real fault is in constructing the component at all, and it is not
-- the argument list. That is still unsolved. Until it is, this stays on.
--
-- Chat and status go to RewindTogether.log (the launcher's Diagnostics shows
-- it) instead of on screen; rt.status in the game's console (~) shows status.
Config.SafeMode = true

Config.ShowNametags       = true
Config.NametagMaxDistance = 3000.0   -- world units
Config.ShowOverlay        = true
Config.ShowPlayerList     = true
Config.ShowConnectionInfo = true

-- EXPERIMENTAL, OFF BY DEFAULT - this crashes the game on some setups.
--
-- Adds a "PLAY CO-OP" entry to the main menu, built from the game's own button
-- widget. It works by constructing a UMG widget at runtime and parenting it
-- into the live menu, and on this build that reliably took the game down at
-- the boot menu. You do not need it: Steam's "Join Game", rt.friends and
-- rt.join all do the same job without touching the UI.
--
-- Turn it on only if you want to help debug it. With LogLevel = "debug" the
-- log names the exact step that fails.
Config.ShowMainMenuButton = false

--------------------------------------------------------------------------
-- Steam integration
--------------------------------------------------------------------------

-- Publish a Steam rich-presence "connect" string while hosting, so friends
-- see "Join Game" next to your name in their Steam friends list.
--
-- OFF, because on this build that button is a trap. The presence string is
-- "+connect steam.<id>", and a steam.<id> address only means something to the
-- Steam relay net driver - which never starts here, so the game falls back to
-- IpNetDriver and the address is meaningless to it. Any friend who clicks
-- Join Game is dropped at the main menu with nothing logged.
--
-- Advertising a join route that cannot work is worse than advertising none:
-- it is the exact dead end that made this look broken for so long. Friends
-- join by IP instead - see Config.JoinTarget.
Config.PublishSteamPresence = false

-- If Steam launched the game because a friend clicked "Join Game", connect
-- to them automatically once the game finishes loading.
Config.AutoJoinFromSteam = true

-- Seconds to wait after startup before acting on a Steam join request.
-- The game needs to reach its menu first.
Config.AutoJoinDelay = 12

--------------------------------------------------------------------------
-- JOINING SOMEONE  (read this if you are the one joining)
--------------------------------------------------------------------------

-- THE EASY WAY: put your friend's address here, then just press F5 in game.
-- No console, no typing, no menus. It is remembered permanently.
--
-- Accepts either:
--   a Steam ID   e.g. Config.JoinTarget = "76561198000000101"
--   or an IP     e.g. Config.JoinTarget = "203.0.113.44"
--
-- Leave empty to disable.
Config.JoinTarget = ""

-- LOAD A SAVE, LAND IN YOUR FRIEND'S STORE.
--
-- With this on, loading ANY of your saves puts you straight into the co-op
-- session at Config.JoinTarget instead of your own store. No console, no
-- keypress, no menu entry - you just press Continue like normal.
--
-- This is deliberately NOT done by editing a save slot. Your save files are
-- never read, written or touched by this mod, so there is nothing to corrupt
-- and nothing to undo: turn this back to false (or remove the mod) and your
-- saves load exactly as they always did. What actually happens is that the
-- mod waits until the game has finished putting you in your own store - which
-- is what creates the player the engine needs in order to travel anywhere -
-- and then travels you to the host.
--
-- GUEST SETS THIS. The host must leave it false, or they will try to join
-- themselves the moment they load their save.
Config.JoinOnLoad = false

-- Seconds to wait after your store finishes loading before travelling.
-- Gives the game a moment to settle; raise it if joining this way is flaky.
Config.JoinOnLoadDelay = 3.0

-- Press F5 and, if JoinTarget is empty, look for any friend currently hosting
-- and join them. Needs them to be on your Steam friends list and hosting.
Config.QuickJoinFindsFriends = true

-- Automatically join a hosting friend a few seconds after the game reaches
-- the menu, without pressing anything. Off by default because it hijacks the
-- game when you might have wanted single player.
Config.AutoJoinFriend = false

--------------------------------------------------------------------------
-- Keybinds  (see https://docs.ue4ss.com for key names)
--------------------------------------------------------------------------

Config.Keys = {
    QuickJoin   = "F5",   -- JOIN your friend (uses Config.JoinTarget)
    ToggleMenu  = "F6",   -- status overlay
    HostGame    = "F7",   -- open your store to friends
    ToggleChat  = "F8",   -- chat
    InviteFriends = "F9", -- open Steam's invite window
    -- Was TAB, which is also the game's own "rotate object" key (read off its
    -- input mappings in 1.7.0). rt.players does the same job.
    TogglePlayerList = "",
}

--------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------

-- "error" | "warn" | "info" | "debug"
-- Use "debug" when reporting a problem; it logs discovered function
-- signatures and every packet type.
Config.LogLevel = "info"

-- Also write to RewindTogether.log next to the game's own log.
Config.LogToFile = true

return Config
