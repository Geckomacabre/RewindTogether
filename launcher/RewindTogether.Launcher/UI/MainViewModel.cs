using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.UI;

/// <summary>
/// Window-level state: the game install, settings, the footer chips, dialogs, the busy overlay,
/// and the install operations both the Play and Mods tabs use.
/// </summary>
public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly DispatcherTimer _timer;
    private string _tab = "play";
    private bool _started;
    private bool _setupSawRunning;

    public MainViewModel(AppPaths paths, LaunchArgs args)
    {
        Paths = paths;
        StartArgs = args;
        Settings = LauncherSettings.Load(paths.SettingsFile);
        // The release zip ships the mod next to the exe: Mods\RewindTogether\mod.json.
        Bundled = BundledMod.Find(Path.GetDirectoryName(Environment.ProcessPath));
        if (Bundled != null) Log.Info($"Bundled Rewind Together {Bundled.Version} found at {Bundled.Folder}");
        Play = new PlayViewModel(this);
        Mods = new ModsViewModel(this);
        Diag = new DiagnosticsViewModel(this);
        if (args.Tab is "mods" or "diagnostics" or "play") _tab = args.Tab;

        AsyncCommand.OnError = ex => _ = InformAsync("Something went wrong", ex.Message, "bad");

        NavCommand = new RelayCommand(p => Tab = p as string ?? "play");
        DialogPrimaryCommand = new RelayCommand(() => CloseDialog(true));
        DialogSecondaryCommand = new RelayCommand(() => CloseDialog(false));
        DismissNoticeCommand = new RelayCommand(() => NoticeText = "");
        UpdateCommand = new AsyncCommand(UpdateNowAsync);
        DismissUpdateCommand = new RelayCommand(() => { _updateDismissed = true; Raise(nameof(UpdateVisible)); });

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => Tick();
    }

    public AppPaths Paths { get; }
    public LaunchArgs StartArgs { get; }
    public LauncherSettings Settings { get; }
    /// <summary>The copy of Rewind Together shipped next to the exe, if any: the install source for it.</summary>
    public BundledMod? Bundled { get; }
    public IDownloader Downloader { get; } = new HttpDownloader();

    public PlayViewModel Play { get; }
    public ModsViewModel Mods { get; }
    public DiagnosticsViewModel Diag { get; }

    public LocateResult? Locate { get; private set; }
    public GameInstall? Game { get; private set; }
    public Ue4ssStatus? Ue4ss { get; private set; }
    public RewindTogetherInfo? RewindTogether { get; private set; }
    public ModStatus? Status { get; private set; }
    public bool GameRunning { get; private set; }
    public DateTime? GameStartedSeenAt { get; private set; }

    public string VersionText => "Launcher v" + AppInfo.Version;

    // ------------------------------------------------------------------ navigation

    public ICommand NavCommand { get; }

    public string Tab
    {
        get => _tab;
        set
        {
            if (!Set(ref _tab, value)) return;
            Raise(nameof(IsPlayTab));
            Raise(nameof(IsModsTab));
            Raise(nameof(IsDiagTab));
            if (value == "diagnostics") Diag.Refresh();
        }
    }

    public bool IsPlayTab { get => _tab == "play"; set { if (value) Tab = "play"; } }
    public bool IsModsTab { get => _tab == "mods"; set { if (value) Tab = "mods"; } }
    public bool IsDiagTab { get => _tab == "diagnostics"; set { if (value) Tab = "diagnostics"; } }

    // ------------------------------------------------------------------ footer chips

    private string _gameChip = "Looking for Retro Rewind...", _gameTone = "idle";
    private string _modChip = "", _modTone = "idle", _ue4ssChip = "", _ue4ssTone = "idle", _steamChip = "Steam link: idle", _steamTone = "idle";

    public string GameChip { get => _gameChip; private set => Set(ref _gameChip, value); }
    public string GameChipTone { get => _gameTone; private set => Set(ref _gameTone, value); }
    public string ModChip { get => _modChip; private set => Set(ref _modChip, value); }
    public string ModChipTone { get => _modTone; private set => Set(ref _modTone, value); }
    public string Ue4ssChip { get => _ue4ssChip; private set => Set(ref _ue4ssChip, value); }
    public string Ue4ssChipTone { get => _ue4ssTone; private set => Set(ref _ue4ssTone, value); }
    public string SteamChip { get => _steamChip; set => Set(ref _steamChip, value); }
    public string SteamChipTone { get => _steamTone; set => Set(ref _steamTone, value); }

    // ------------------------------------------------------------------ startup

    public async Task StartAsync()
    {
        if (_started) return;
        _started = true;
        RefreshGame();
        _timer.Start();
        Tick();
        await Mods.LoadCatalogAsync();
        // First run (or a new release unzipped over the old one): install everything right away,
        // so the only thing left for the player is HOST or JOIN.
        await AutoSetUpAsync();
        await Play.HandleStartArgsAsync(StartArgs);
        if (StartArgs.UpdatedFrom is { Length: > 0 } from)
            Notify($"Updated from {from} to {CurrentReleaseVersion}.", "ok");
        _ = CheckForUpdatesAsync(manual: false);
    }

    public void HandleForwardedArgs(LaunchArgs args)
    {
        if (args.Tab != null) Tab = args.Tab;
        _ = Play.HandleStartArgsAsync(args);
    }

    /// <summary>Finds the game again and re-reads what is installed in it.</summary>
    public void RefreshGame()
    {
        string? manual = StartArgs.GameDir ?? Settings.GameRoot;
        Locate = new GameLocator(new WindowsSteamRegistry()).Locate(manual);
        Game = Locate.Game;
        foreach (var n in Locate.Notes) Log.Info("Locate: " + n);

        if (Game != null)
        {
            try
            {
                if (Environment.ProcessPath is { } exe) LaunchFiles.WriteLauncherPath(Game, exe);
            }
            catch (Exception ex)
            {
                Log.Warn("Could not write RewindTogether.launcher.txt: " + ex.Message);
            }
        }
        RefreshInstallState();
    }

    /// <summary>Re-reads UE4SS and Rewind Together state (after an install, or on demand).</summary>
    public void RefreshInstallState()
    {
        if (Game == null)
        {
            Ue4ss = null;
            RewindTogether = null;
            GameChip = "Retro Rewind not found";
            GameChipTone = "bad";
            Ue4ssChip = "";
            ModChip = "";
        }
        else
        {
            Ue4ss = Ue4ssSetup.Detect(Game);
            RewindTogether = RewindTogetherInfo.Read(Game);
            Ue4ssChip = Ue4ss.State == Ue4ssState.Installed ? "UE4SS ready" : "UE4SS missing";
            Ue4ssChipTone = Ue4ss.State == Ue4ssState.Installed ? (Ue4ss.IsPinnedBuild ? "ok" : "warn") : "bad";
            ModChip = RewindTogether.Installed ? $"Rewind Together {RewindTogether.Version ?? "?"}" : "Rewind Together not installed";
            ModChipTone = RewindTogether.Installed ? (RewindTogether.EnabledInModsTxt == false ? "warn" : "ok") : "bad";
        }
        Raise(nameof(Game));
        Raise(nameof(Ue4ss));
        Raise(nameof(RewindTogether));
        Play.RefreshSetup();
        Mods.RefreshInstalled();
        Diag.Refresh();
        UpdateGameChip();
    }

    private void Tick()
    {
        if (_started && Settings.CheckForUpdates && DateTime.UtcNow - _lastUpdateCheck > UpdateCheckEvery)
            _ = CheckForUpdatesAsync(manual: false);
        PollNexusDownloads();
        if (Game == null) return;
        _gamePid = GameProcess.FindProcessId(Game);
        bool running = _gamePid != null;
        if (running && !GameRunning) GameStartedSeenAt = DateTime.UtcNow;
        if (!running) GameStartedSeenAt = null;
        bool justClosed = GameRunning && !running;
        GameRunning = running;
        if (justClosed && _started)
        {
            // "Close the game to finish setting up" - the moment it closes, finish by itself.
            Play.RefreshSetup();
            _ = AutoSetUpAsync();
        }
        else if (running != _setupSawRunning) Play.RefreshSetup();
        _setupSawRunning = running;

        var fresh = LaunchFiles.ReadStatus(Game);
        if (fresh != null) Status = fresh;
        if (Status != null && (Status.IsStale(DateTimeOffset.UtcNow) || !running)) Status = null;

        Raise(nameof(GameRunning));
        Raise(nameof(Status));
        UpdateGameChip();
        Play.OnTick();
        UpdateDiscord();
    }

    private void UpdateGameChip()
    {
        if (Game == null) return;
        if (!GameRunning) { GameChip = "Game not running"; GameChipTone = "idle"; return; }
        if (Status == null) { GameChip = "Game running - waiting for the mod"; GameChipTone = "warn"; return; }
        (GameChip, GameChipTone) = Status.Mode switch
        {
            "ListenServer" => ($"Hosting - {Status.Players} player{(Status.Players == 1 ? "" : "s")}", "pink"),
            "Client" => ("Visiting a friend's store", "info"),
            _ => (Status.InStore ? "In your store" : "At the main menu", "ok"),
        };
    }

    // ------------------------------------------------------------------ settings

    public void SaveSettings()
    {
        try
        {
            Settings.Save(Paths.SettingsFile);
        }
        catch (Exception ex)
        {
            Notify("Settings could not be saved: " + ex.Message, "bad");
        }
    }

    public async Task BrowseForGameAsync()
    {
        var dlg = new OpenFolderDialog
        {
            Title = "Choose your Retro Rewind folder (the one that contains \"RetroRewind\" and \"Engine\")",
            InitialDirectory = Game?.Root ?? (Locate?.SteamPath != null ? Path.Combine(Locate.SteamPath, "steamapps", "common") : ""),
        };
        if (dlg.ShowDialog() != true) return;
        string? root = GameInstall.NormalizeUserPick(dlg.FolderName);
        if (root == null)
        {
            await InformAsync("That is not the Retro Rewind folder",
                $"\"{dlg.FolderName}\" does not contain RetroRewind\\Binaries\\Win64\\{GameInstall.ExeName}.\n\n" +
                "In Steam, right-click Retro Rewind > Manage > Browse local files to see where it is installed, and choose that folder.",
                "warn");
            return;
        }
        Settings.GameRoot = root;
        SaveSettings();
        RefreshGame();
        Notify("Using Retro Rewind at " + root, "ok");
        // Found it: carry straight on with setting up, as on startup.
        await AutoSetUpAsync();
    }

    public void ResetGameFolder()
    {
        Settings.GameRoot = null;
        SaveSettings();
        RefreshGame();
        Notify(Game != null ? "Found Retro Rewind at " + Game.Root : "Retro Rewind could not be found automatically.", Game != null ? "ok" : "warn");
    }

    // ------------------------------------------------------------------ shared install operations

    /// <summary>
    /// Installs need the game closed: a running game keeps Rewind Together's native DLL (and
    /// UE4SS) loaded and locked, and mods only load at start-up anyway.
    /// </summary>
    /// <param name="retry">What to press afterwards, e.g. "press Install again".</param>
    public async Task<bool> EnsureGameClosedAsync(string retry)
    {
        if (Game == null || !GameProcess.IsRunning(Game)) return true;
        await InformAsync("Close Retro Rewind first",
            $"Retro Rewind is running, and it keeps its mod files locked while it runs. Close Retro Rewind first, then {retry}.", "warn");
        return false;
    }

    /// <summary>The dialog for <see cref="GameFilesLockedException"/>: nothing was changed, close the game and retry.</summary>
    public Task ShowLockedAsync(GameFilesLockedException ex)
    {
        Log.Warn("Files in use: " + ex.Message);
        return InformAsync("Close Retro Rewind first",
            ex.Message + "\n\nNothing was changed - your current install is exactly as it was.", "warn");
    }

    public async Task BackupSavesIfWantedAsync()
    {
        if (!Settings.BackupSavesBeforeInstall) return;
        var r = await Task.Run(() => SaveBackup.Run(Paths.SaveGamesDir, Paths.BackupsDir, force: false));
        if (r.Created) Notify("Saves backed up before installing.", "ok");
        else if (r.ZipPath == null && Directory.Exists(Paths.SaveGamesDir)) Log.Warn(r.Message);
    }

    /// <summary>
    /// Unpacks the pinned UE4SS build into the game: from the copy in the release zip, else a
    /// cached download, else downloaded from GitHub now.
    /// </summary>
    public async Task<bool> InstallUe4ssAsync(string? localZip = null)
    {
        if (Game == null) { await InformAsync("Retro Rewind not found", "Find the game first (Diagnostics > Game folder > Browse).", "bad"); return false; }
        if (!await EnsureGameClosedAsync("press Set up again")) return false;

        try
        {
            await BackupSavesIfWantedAsync();
            localZip ??= await Task.Run(() => Ue4ssSetup.FindBundledZip(Path.GetDirectoryName(Environment.ProcessPath)));
            string zip = localZip ?? Path.Combine(Paths.DownloadsDir, Ue4ssSetup.PinnedFileName);
            List<string> notes = new();
            await RunBusyAsync("Installing UE4SS", async busy =>
            {
                if (localZip == null)
                {
                    bool cached = File.Exists(zip) && Hashing.Matches(await Task.Run(() => Hashing.Sha256OfFile(zip)), Ue4ssSetup.PinnedSha256);
                    if (!cached)
                    {
                        busy.Report($"Downloading {Ue4ssSetup.PinnedFileName} from GitHub...", null);
                        await Downloader.DownloadAsync(Ue4ssSetup.PinnedUrl, zip, Ue4ssSetup.PinnedSha256, Ue4ssSetup.PinnedSize,
                            new Progress<DownloadProgress>(p => busy.Report(
                                $"Downloading UE4SS... {p.BytesReceived / 1024 / 1024.0:0.0} MB", p.Fraction)), CancellationToken.None);
                    }
                }
                busy.Report("Unpacking into the game folder...", null);
                notes = await Task.Run(() => Ue4ssSetup.InstallFromZip(Game, zip));
            });
            RefreshInstallState();
            Notify(string.Join(" ", notes), "ok");
            return true;
        }
        catch (GameFilesLockedException ex)
        {
            await ShowLockedAsync(ex);
            return false;
        }
        catch (Exception ex) when (ex is DownloadException or ModInstallException or IOException or UnauthorizedAccessException)
        {
            Log.Error("UE4SS install failed", ex);
            bool manual = await AskAsync("UE4SS could not be installed",
                ex.Message + "\n\nYou can download it yourself from GitHub (file: " + Ue4ssSetup.PinnedFileName + ") and then pick the zip here.",
                "Choose a zip...", "Close", "bad");
            if (manual)
            {
                var dlg = new OpenFileDialog { Filter = "UE4SS zip (*.zip)|*.zip", Title = "Choose the UE4SS zip you downloaded" };
                if (dlg.ShowDialog() == true) return await InstallUe4ssAsync(dlg.FileName);
            }
            return false;
        }
    }

    // ------------------------------------------------------------------ one-click setup

    public enum SetupTrigger
    {
        /// <summary>The launcher opened, or the game just closed: silent, never closes the game.</summary>
        Startup,
        /// <summary>The "Set up" button: may close the game, with the player's OK.</summary>
        Button,
        /// <summary>HOST or JOIN: like Button, but a player may skip an update and play anyway.</summary>
        Session,
    }

    private bool _settingUp;

    /// <summary>True while <see cref="SetUpAsync"/> runs.</summary>
    public bool SettingUp { get => _settingUp; private set { if (Set(ref _settingUp, value)) Play.RefreshSetup(); } }

    /// <summary>The version an install or update of Rewind Together brings: the bundled copy's, else the catalog's.</summary>
    public string? ModSourceVersion =>
        Bundled?.Version ?? (Mods.Catalog?.Find(GameInstall.RewindTogetherId) is { IsInstallable: true } e ? e.Version : null);

    public SetupPlan CurrentPlan => SetupPlan.For(Ue4ss, RewindTogether, ModSourceVersion);

    /// <summary>UE4SS and an enabled, complete Rewind Together are in the game.</summary>
    public bool ModReady => Ue4ss?.State == Ue4ssState.Installed &&
                            RewindTogether is { Installed: true, HasMainLua: true } && RewindTogether.EnabledInModsTxt != false;

    /// <summary>
    /// True when the exe was started from inside the zip (Explorer's zip view copies just the exe
    /// to a temp folder, without the Mods folder next to it).
    /// </summary>
    public bool RunningFromZipPreview =>
        Bundled == null && Path.GetDirectoryName(Environment.ProcessPath) is { } dir &&
        Path.GetFullPath(dir).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Everything Rewind Together needs, in order: back up the saves, install UE4SS, install or
    /// update the mod, switch it on. True when it will load the next time the game starts.
    /// </summary>
    public async Task<bool> SetUpAsync(SetupTrigger trigger)
    {
        if (SettingUp) return false;
        if (Game == null)
        {
            if (trigger == SetupTrigger.Startup) return false;
            if (!await AskAsync("Retro Rewind was not found",
                    "The launcher could not find Retro Rewind in your Steam libraries. Show it where the game is installed.\n\n" +
                    "(In Steam: right-click Retro Rewind > Manage > Browse local files shows the folder.)",
                    "Browse...", "Cancel", "warn"))
                return false;
            await BrowseForGameAsync();
            if (Game == null) return false;
        }

        var plan = CurrentPlan;
        // On its own the launcher never switches back on a mod the player switched off.
        if (trigger == SetupTrigger.Startup) plan = plan with { SwitchOn = false };
        if (plan.NothingToDo) return ModReady;
        if (plan.InstallMod && RunningFromZipPreview)
        {
            // Nothing to install from: do not half-install (UE4SS alone) either.
            if (trigger != SetupTrigger.Startup) await InformAsync("Unzip the download first", UnzipFirstText, "warn");
            return false;
        }

        SettingUp = true;
        try
        {
            if (plan.InstallUe4ss || plan.InstallMod)
            {
                if (GameProcess.IsRunning(Game))
                {
                    if (trigger == SetupTrigger.Startup) return false;
                    bool canSkip = trigger == SetupTrigger.Session && !plan.InstallUe4ss && ModReady;
                    bool close = await AskAsync("Close Retro Rewind to finish setting up",
                        "Retro Rewind is running, and it keeps its mod files locked while it runs. Still to do: " +
                        plan.Describe(InstalledModVersion) + "\n\n" +
                        "The launcher can close the game for you (the same as quitting it yourself). Anything since the game last " +
                        "saved is lost, so finish your day first if you are in the middle of one." +
                        (canSkip ? "\n\nEveryone in a session needs the same Rewind Together version, so update before playing with friends." : ""),
                        "Close the game and set up", canSkip ? "Play without updating" : "Not now", "warn");
                    if (!close) return canSkip;
                    if (!await CloseGameAsync()) return false;
                }

                await BackupSavesIfWantedAsync();
                if (plan.InstallUe4ss && !await InstallUe4ssAsync()) return false;
                if (plan.InstallMod && !await InstallRewindTogetherAsync(askForZip: trigger != SetupTrigger.Startup)) return false;
            }
            if (plan.SwitchOn || (trigger != SetupTrigger.Startup && RewindTogether?.EnabledInModsTxt == false)) SwitchOnRewindTogether();

            RefreshInstallState();
            if (ModReady)
                Notify($"All set: Rewind Together {RewindTogether!.Version} is ready." +
                       (GameProcess.IsRunning(Game) ? " Restart Retro Rewind for it to load." : " Press HOST, or join a friend."), "ok");
            return ModReady;
        }
        finally
        {
            SettingUp = false;
        }
    }

    private string? InstalledModVersion => RewindTogether is { Installed: true } rt ? rt.Version ?? "" : null;

    /// <summary>Runs the silent setup when nothing else is going on (the launcher just opened, or the game just closed).</summary>
    private async Task AutoSetUpAsync()
    {
        if (Game == null || SettingUp || DialogVisible || BusyVisible || Play.InSession) return;
        var plan = CurrentPlan with { SwitchOn = false };
        if (plan.NothingToDo) return;
        // The Setup line says what to do instead: close the game (it finishes the moment the game
        // closes), or unzip the download properly.
        if (GameProcess.IsRunning(Game) || (plan.InstallMod && RunningFromZipPreview)) return;
        Log.Info("Setting up by itself: " + plan.Describe(InstalledModVersion));
        try
        {
            await SetUpAsync(SetupTrigger.Startup);
        }
        catch (Exception ex)
        {
            Log.Error("Automatic setup failed", ex);
            Notify("Setting up Rewind Together did not finish: " + ex.Message, "bad");
        }
    }

    /// <summary>Closes the game for the player (never kills it). False if it is still running.</summary>
    private async Task<bool> CloseGameAsync()
    {
        bool closed = false;
        await RunBusyAsync("Closing Retro Rewind", async busy =>
        {
            busy.Report("Waiting for the game to quit...", null);
            closed = await GameProcess.CloseAsync(Game!, TimeSpan.FromSeconds(30));
        });
        Tick();
        if (!closed)
            await InformAsync("Retro Rewind is still running",
                "The game did not close. Quit it yourself (from its main menu, or with Alt+F4), then press Set up again.", "warn");
        return closed;
    }

    public void SwitchOnRewindTogether()
    {
        if (Game == null) return;
        ModsTxt.Update(Game.ModsTxt, t => t.SetEnabled(GameInstall.RewindTogetherFolder, true));
        ModsJson.SetEnabled(Game.ModsJson, GameInstall.RewindTogetherFolder, true);
        RefreshInstallState();
        Notify(GameProcess.IsRunning(Game) ? "Rewind Together switched on. Restart the game for it to load." : "Rewind Together switched on.", "ok");
    }

    /// <summary>
    /// Installs or updates Rewind Together from the copy next to the launcher, else the catalog,
    /// else (if <paramref name="askForZip"/>) a zip the player picks.
    /// </summary>
    public async Task<bool> InstallRewindTogetherAsync(bool askForZip)
    {
        if (Bundled is { } bundled) return await InstallPackageAsync(bundled.Folder, null, "bundled");
        var entry = Mods.Catalog?.Find(GameInstall.RewindTogetherId);
        if (entry is { IsInstallable: true }) return await InstallFromCatalogAsync(entry);
        if (!askForZip) return false;
        bool pick = await AskAsync("Choose the Rewind Together download",
            "Pick the Rewind Together zip you downloaded (for example from Nexus Mods). The launcher installs it into the game, " +
            "keeps your settings, and switches it on.", "Choose the zip...", "Cancel", "info");
        if (!pick) return false;
        string? path = PickModFile();
        return path != null && await InstallPackageAsync(path, null, "file");
    }

    public const string UnzipFirstText =
        "The launcher was started from inside the zip, so the mod files next to it are missing. Close it, right-click the " +
        "Rewind Together zip > Extract All..., then open RewindTogetherLauncher.exe from the unzipped folder.";

    /// <summary>
    /// Installs a package (zip, folder or pak) and records it. Asks before replacing anything the
    /// launcher did not install. Rewind Together always replaces its own folder.
    /// </summary>
    public async Task<bool> InstallPackageAsync(string sourcePath, CatalogEntry? entry, string origin, NexusSource? nexus = null)
    {
        if (Game == null) { await InformAsync("Retro Rewind not found", "Find the game first (Diagnostics > Game folder > Browse).", "bad"); return false; }
        if (!await EnsureGameClosedAsync("press Install again")) return false;
        // A file picked by hand that looks like a Nexus download: ask Nexus which mod it is, so it
        // gets its Nexus id (update badges, the co-op mod check) like one installed from the browser.
        if (nexus == null && entry == null && origin == "file" && NexusFileName.LooksLikeNexusDownload(sourcePath))
            nexus = await IdentifyNexusFileAsync(sourcePath);

        PackageSource? src = null;
        try
        {
            string ext = Path.GetExtension(sourcePath).ToLowerInvariant();
            if (ext is ".7z" or ".rar")
                await RunBusyAsync("Unpacking " + Path.GetFileName(sourcePath), async busy =>
                {
                    busy.Report("Large mods can take a minute.", null);
                    src = await Task.Run(() => PackageSource.Open(sourcePath));
                });
            else
                src = PackageSource.Open(sourcePath);
            if (src == null) return false;
            var pkg = PackageAnalyzer.Analyze(src,
                fallbackName: entry?.FolderName,
                forcedFolder: entry?.Folder ?? (entry != null && entry.Kind == ModKind.Ue4ssLua ? entry.FolderName : null),
                pakKindHint: entry?.Kind is ModKind.Pak or ModKind.LogicMod ? entry.Kind : null);

            if (pkg.LuaFolders.Any() && Ue4ss?.State != Ue4ssState.Installed)
            {
                bool install = await AskAsync("UE4SS is needed first",
                    "This is a UE4SS script mod, and UE4SS (the mod loader) is not installed yet. Install UE4SS now?",
                    "Install UE4SS", "Cancel", "warn");
                if (!install || !await InstallUe4ssAsync()) return false;
            }

            var who = MakeIdentity(pkg, entry, origin, src.DisplayName, nexus, new ModManager(Game, Paths.InstalledManifestFile).Managed());
            if (pkg.IsRewindTogether && pkg.ModJsonGameBuild != null && Game.BuildId != null && pkg.ModJsonGameBuild != Game.BuildId)
                Notify($"Note: this Rewind Together build was tested on game build {pkg.ModJsonGameBuild}; you have {Game.BuildId}.", "warn");

            var manager = new ModManager(Game, Paths.InstalledManifestFile);
            await BackupSavesIfWantedAsync();
            InstallOutcome? outcome = null;
            try
            {
                outcome = await Task.Run(() => manager.Install(pkg, who, new InstallOptions { ReplaceUnmanaged = pkg.IsRewindTogether }));
            }
            catch (ModConflictException conflict)
            {
                bool replace = await AskAsync("Replace existing files?",
                    $"Installing {who.Name} would replace files that were not installed by this launcher:\n\n  " +
                    string.Join("\n  ", conflict.Conflicts) + "\n\nReplace them?", "Replace", "Cancel", "warn");
                if (!replace) return false;
                outcome = await Task.Run(() => manager.Install(pkg, who, new InstallOptions { ReplaceUnmanaged = true }));
            }

            RefreshInstallState();
            string extra = outcome.Notes.Count > 0 ? " " + string.Join(" ", outcome.Notes) : "";
            string ignored = pkg.IgnoredFiles > 0 ? $" ({pkg.IgnoredFiles} extra file(s) such as readmes were left out.)" : "";
            Notify($"Installed {who.Name} {who.Version}.{extra}{ignored}", "ok");
            foreach (var w in pkg.Warnings) Notify(w, "warn");
            return true;
        }
        catch (GameFilesLockedException ex)
        {
            await ShowLockedAsync(ex);
            return false;
        }
        catch (ModInstallException ex)
        {
            Log.Warn("Install failed: " + ex.Message);
            await InformAsync("That mod could not be installed", ex.Message, "bad");
            return false;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Error("Install failed", ex);
            await InformAsync("That mod could not be installed", ex.Message + "\n\nIf the game is running, close it and try again.", "bad");
            return false;
        }
        finally
        {
            src?.Dispose();
        }
    }

    internal static ModIdentity MakeIdentity(PackageAnalysis pkg, CatalogEntry? entry, string origin, string displayName,
        NexusSource? nexus = null, IReadOnlyList<InstalledMod>? managed = null)
    {
        if (entry != null)
            return new ModIdentity(entry.Id, entry.Name, entry.Version, origin, entry.Sha256);
        if (pkg.IsRewindTogether)
            return new ModIdentity(GameInstall.RewindTogetherId, "Rewind Together", pkg.ModJsonVersion ?? ReadNetLuaVersion(pkg) ?? "local", origin);
        if (nexus != null)
        {
            // An update of something already installed keeps that record (and its id): the same
            // Nexus mod, or the same folder / pak, installed earlier by hand.
            var lua = pkg.LuaFolders.ToHashSet(StringComparer.OrdinalIgnoreCase);
            var paks = pkg.Components.Where(c => c.Kind != ModKind.Ue4ssLua)
                .SelectMany(c => c.Files.Select(f => Path.GetFileName(f.Target))).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var previous = managed?.FirstOrDefault(m => m.NexusModId == nexus.ModId)
                ?? managed?.FirstOrDefault(m => m.LuaFolders.Any(lua.Contains) || m.Files.Any(f => paks.Contains(Path.GetFileName(f))));
            string recordId = previous != null && !previous.Id.Equals(GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase)
                ? previous.Id : $"nexus-{nexus.ModId}";
            return new ModIdentity(recordId, nexus.Name, nexus.Version.Length > 0 ? nexus.Version : "?", origin,
                NexusModId: nexus.ModId, NexusVersion: nexus.Version);
        }
        string id = PackageAnalyzer.SanitizeFolderName(pkg.ModJsonId ?? pkg.LuaFolders.FirstOrDefault() ?? displayName).ToLowerInvariant();
        return new ModIdentity("local-" + id, pkg.ModJsonName ?? pkg.SuggestedName, pkg.ModJsonVersion ?? "local", origin);
    }

    private static string? ReadNetLuaVersion(PackageAnalysis pkg)
    {
        var net = pkg.Components.SelectMany(c => c.Files).FirstOrDefault(f => f.Target.EndsWith("/Scripts/net.lua", StringComparison.OrdinalIgnoreCase));
        if (net.Source == null) return null;
        using var s = net.Source.Open();
        using var r = new StreamReader(s);
        var m = System.Text.RegularExpressions.Regex.Match(r.ReadToEnd(), @"Net\.VERSION\s*=\s*""([^""]+)""");
        return m.Success ? m.Groups[1].Value : null;
    }

    /// <summary>
    /// Installs a catalog entry: from the copy bundled next to the launcher if it has one,
    /// otherwise by downloading it (verifying its sha256).
    /// </summary>
    public async Task<bool> InstallFromCatalogAsync(CatalogEntry entry)
    {
        if (entry.LocalPath != null)
        {
            if (!Directory.Exists(entry.LocalPath))
            {
                await InformAsync($"{entry.Name} files are missing",
                    $"The copy of {entry.Name} that came with the launcher is gone from {entry.LocalPath}. " +
                    "Unzip the whole download again (keep the Mods folder next to RewindTogetherLauncher.exe).", "bad");
                return false;
            }
            return await InstallPackageAsync(entry.LocalPath, entry, "bundled");
        }
        if (!entry.IsDownloadable)
        {
            bool pick = await AskAsync($"{entry.Name} is not downloadable yet",
                "There is no download link for this mod in the catalog yet. If you already have its zip (for example from Nexus Mods), " +
                "choose it and the launcher will install it.", "Choose a file...", "Close", "info");
            if (!pick) return false;
            string? path = PickModFile();
            return path != null && await InstallPackageAsync(path, entry, "file");
        }
        if (Game == null || !await EnsureGameClosedAsync("press Install again")) return false;

        string ext = Path.GetExtension(new Uri(entry.Url).AbsolutePath);
        if (string.IsNullOrEmpty(ext)) ext = ".zip";
        string dest = Path.Combine(Paths.DownloadsDir, $"{entry.Id}-{entry.Version}{ext}");
        try
        {
            await RunBusyAsync($"Downloading {entry.Name}", async busy =>
            {
                bool cached = File.Exists(dest) && Hashing.Matches(await Task.Run(() => Hashing.Sha256OfFile(dest)), entry.Sha256);
                if (!cached)
                    await Downloader.DownloadAsync(entry.Url, dest, entry.Sha256, entry.Size is > 0 ? entry.Size : null,
                        new Progress<DownloadProgress>(p => busy.Report($"{p.BytesReceived / 1024 / 1024.0:0.0} MB downloaded", p.Fraction)),
                        CancellationToken.None);
            });
        }
        catch (DownloadException ex)
        {
            await InformAsync($"{entry.Name} could not be downloaded", ex.Message, "bad");
            return false;
        }
        return await InstallPackageAsync(dest, entry, "catalog");
    }

    public string? PickModFile()
    {
        var dlg = new OpenFileDialog
        {
            Title = "Choose a mod to add",
            Filter = "Mod files (*.zip;*.7z;*.rar;*.pak)|*.zip;*.7z;*.rar;*.pak|All files (*.*)|*.*",
            InitialDirectory = DownloadsFolder.Find(),
        };
        return dlg.ShowDialog() == true ? dlg.FileName : null;
    }

    public string? PickModFolder()
    {
        var dlg = new OpenFolderDialog { Title = "Choose the mod's folder (the one with Scripts\\main.lua inside, or with .pak files)" };
        return dlg.ShowDialog() == true ? dlg.FolderName : null;
    }

    // ------------------------------------------------------------------ dialog overlay

    private TaskCompletionSource<bool>? _dialog;
    private string _dialogTitle = "", _dialogMessage = "", _dialogPrimary = "OK", _dialogSecondary = "", _dialogTone = "info";
    private bool _dialogVisible;

    public bool DialogVisible { get => _dialogVisible; private set => Set(ref _dialogVisible, value); }
    public string DialogTitle { get => _dialogTitle; private set => Set(ref _dialogTitle, value); }
    public string DialogMessage { get => _dialogMessage; private set => Set(ref _dialogMessage, value); }
    public string DialogPrimary { get => _dialogPrimary; private set => Set(ref _dialogPrimary, value); }
    public string DialogSecondary { get => _dialogSecondary; private set => Set(ref _dialogSecondary, value); }
    public string DialogTone { get => _dialogTone; private set => Set(ref _dialogTone, value); }
    public ICommand DialogPrimaryCommand { get; }
    public ICommand DialogSecondaryCommand { get; }

    /// <summary>Shows the in-window dialog. Returns true for the primary button.</summary>
    public async Task<bool> AskAsync(string title, string message, string primary, string? secondary, string tone = "info")
    {
        while (_dialog != null) await _dialog.Task;
        var tcs = new TaskCompletionSource<bool>();
        _dialog = tcs;
        DialogTitle = title;
        DialogMessage = message;
        DialogPrimary = primary;
        DialogSecondary = secondary ?? "";
        DialogTone = tone;
        DialogVisible = true;
        Log.Info($"Dialog: {title} - {message.Replace('\n', ' ')}");
        bool result = await tcs.Task;
        return result;
    }

    public Task InformAsync(string title, string message, string tone = "info") => AskAsync(title, message, "OK", null, tone);

    private void CloseDialog(bool result)
    {
        var tcs = _dialog;
        _dialog = null;
        DialogVisible = false;
        tcs?.TrySetResult(result);
    }

    // ------------------------------------------------------------------ busy overlay

    private bool _busyVisible;
    private string _busyTitle = "", _busyDetail = "";
    private double _busyProgress;
    private bool _busyIndeterminate = true;

    public bool BusyVisible { get => _busyVisible; private set => Set(ref _busyVisible, value); }
    public string BusyTitle { get => _busyTitle; private set => Set(ref _busyTitle, value); }
    public string BusyDetail { get => _busyDetail; private set => Set(ref _busyDetail, value); }
    public double BusyProgress { get => _busyProgress; private set => Set(ref _busyProgress, value); }
    public bool BusyIndeterminate { get => _busyIndeterminate; private set => Set(ref _busyIndeterminate, value); }

    public sealed class BusyReporter
    {
        private readonly MainViewModel _vm;
        internal BusyReporter(MainViewModel vm) => _vm = vm;

        public void Report(string detail, double? fraction)
        {
            void Apply()
            {
                _vm.BusyDetail = detail;
                _vm.BusyIndeterminate = fraction == null;
                _vm.BusyProgress = fraction ?? 0;
            }
            if (Application.Current?.Dispatcher.CheckAccess() == true) Apply();
            else Application.Current?.Dispatcher.InvokeAsync(Apply);
        }
    }

    public async Task RunBusyAsync(string title, Func<BusyReporter, Task> work)
    {
        BusyTitle = title;
        BusyDetail = "";
        BusyIndeterminate = true;
        BusyVisible = true;
        try
        {
            await work(new BusyReporter(this));
        }
        finally
        {
            BusyVisible = false;
        }
    }

    // ------------------------------------------------------------------ notices

    private string _noticeText = "", _noticeTone = "info";
    private readonly DispatcherTimer _noticeTimer = new() { Interval = TimeSpan.FromSeconds(9) };

    public string NoticeText { get => _noticeText; private set { Set(ref _noticeText, value); Raise(nameof(NoticeVisible)); } }
    public string NoticeTone { get => _noticeTone; private set => Set(ref _noticeTone, value); }
    public bool NoticeVisible => NoticeText.Length > 0;
    public ICommand DismissNoticeCommand { get; }

    public void Notify(string text, string tone = "info")
    {
        Log.Info("Notice: " + text);
        void Apply()
        {
            NoticeTone = tone;
            NoticeText = text;
            _noticeTimer.Stop();
            _noticeTimer.Tick -= NoticeTimeout;
            _noticeTimer.Tick += NoticeTimeout;
            _noticeTimer.Interval = TimeSpan.FromSeconds(tone == "bad" ? 20 : 9);
            _noticeTimer.Start();
        }
        if (Application.Current?.Dispatcher.CheckAccess() == true) Apply();
        else Application.Current?.Dispatcher.InvokeAsync(Apply);
    }

    private void NoticeTimeout(object? s, EventArgs e)
    {
        _noticeTimer.Stop();
        NoticeText = "";
    }

    // ------------------------------------------------------------------ shutdown

    /// <summary>This PC's mods as a co-op guest or host sees them (ModFingerprint), or null without a game.</summary>
    public ModFingerprint? LocalModFingerprint()
    {
        if (Game == null) return null;
        try
        {
            return ModFingerprint.FromScan(RewindTogether?.Version, new ModManager(Game, Paths.InstalledManifestFile).ScanGame());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Warn("Could not list this PC's mods: " + ex.Message);
            return null;
        }
    }

    // ------------------------------------------------------------------ self-update (SelfUpdate.cs)

    private static readonly TimeSpan UpdateCheckEvery = TimeSpan.FromHours(6);
    private readonly UpdateChecker _updateChecker = new();
    private ReleaseInfo? _update;
    private bool _updateDismissed, _checkingUpdate;
    private DateTime _lastUpdateCheck = DateTime.MinValue;
    private string _updateStatus = "Not checked yet.";

    /// <summary>The release this launcher's folder holds: its bundled mod's version, else the launcher's own.</summary>
    public string CurrentReleaseVersion =>
        Bundled?.Version is { Length: > 0 } v && v != "unknown" ? v : AppInfo.Version;

    public bool UpdateVisible => _update != null && !_updateDismissed;
    public string UpdateText => _update is { } u
        ? $"Rewind Together {u.Version} is out - you have {CurrentReleaseVersion}. Updating takes a minute and keeps your saves and settings."
        : "";
    public string UpdateStatus { get => _updateStatus; private set { if (Set(ref _updateStatus, value)) Diag.RaiseUpdateStatus(); } }
    public ICommand UpdateCommand { get; }
    public ICommand DismissUpdateCommand { get; }

    /// <summary>Asks GitHub for the latest release. Quiet unless <paramref name="manual"/>.</summary>
    public async Task CheckForUpdatesAsync(bool manual)
    {
        if (_checkingUpdate) return;
        if (!manual && !Settings.CheckForUpdates) return;
        _lastUpdateCheck = DateTime.UtcNow;
        if (RunningFromZipPreview)
        {
            if (manual) Notify("Unzip the download first: a launcher opened from inside the zip cannot update itself.", "warn");
            return;
        }
        _checkingUpdate = true;
        try
        {
            var latest = await _updateChecker.LatestAsync(Settings.UpdateApiBase, Settings.UpdateRepo, CancellationToken.None);
            if (latest != null && VersionCompare.IsNewer(latest.Version, CurrentReleaseVersion))
            {
                Log.Info($"Update available: {latest.Version} ({latest.ZipName}, {latest.ZipSize:N0} bytes, sha256 {latest.Sha256 ?? "none"})");
                _update = latest;
                _updateDismissed = false;
                Raise(nameof(UpdateVisible));
                Raise(nameof(UpdateText));
                UpdateStatus = $"Version {latest.Version} is available (you have {CurrentReleaseVersion}).";
            }
            else
            {
                UpdateStatus = $"Up to date: {CurrentReleaseVersion} (checked {DateTime.Now:HH:mm}).";
                if (manual) Notify($"You have the latest version ({CurrentReleaseVersion}).", "ok");
            }
        }
        catch (UpdateException ex)
        {
            Log.Warn("Update check failed: " + ex.Message);
            UpdateStatus = "Could not check: " + ex.Message;
            if (manual) Notify("Could not check for updates: " + ex.Message, "warn");
        }
        finally
        {
            _checkingUpdate = false;
        }
    }

    /// <summary>The banner's Update button: download, check, swap in place, restart.</summary>
    public async Task UpdateNowAsync()
    {
        if (_update is not { } release) return;
        string appDir = Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;

        if (Play.InSession)
        {
            await InformAsync("Finish your session first",
                "Updating restarts the launcher, and the launcher is what carries your co-op connection. " +
                "Press STOP when you are done playing, then update.", "warn");
            return;
        }
        if (release.Sha256 == null || !UpdateInstaller.CanWrite(appDir))
        {
            string why = release.Sha256 == null
                ? "This release has no published checksum, so the launcher will not install it by itself."
                : "The launcher cannot write to its own folder (it may be inside Program Files).";
            if (await AskAsync("Update by hand", why + "\n\nDownload the new zip from the release page and unzip it over this folder.",
                    "Open the release page", "Cancel", "warn"))
                GameProcess.OpenInShell(release.PageUrl);
            return;
        }
        if (!await AskAsync($"Update to {release.Version}?",
                $"The launcher downloads Rewind Together {release.Version} from GitHub ({release.ZipSize / 1048576.0:N0} MB), " +
                "checks it, replaces itself and the mod files in this folder, and restarts.\n\n" +
                "Your saves and settings stay as they are. If the game is open, the launcher asks you to close it " +
                "before it updates the mod.",
                "Update now", "Later"))
            return;

        var installer = new UpdateInstaller(appDir, Downloader);
        try
        {
            await RunBusyAsync($"Updating to {release.Version}", async busy =>
            {
                var progress = new Progress<DownloadProgress>(p => busy.Report(
                    p.TotalBytes is > 0
                        ? $"Downloading... {p.BytesReceived / 1048576.0:N0} of {p.TotalBytes.Value / 1048576.0:N0} MB"
                        : $"Downloading... {p.BytesReceived / 1048576.0:N0} MB",
                    p.Fraction));
                string root = await installer.PrepareAsync(release, progress, CancellationToken.None);
                busy.Report("Putting the new version in place...", null);
                await Task.Run(() => installer.Install(root));
                busy.Report("Restarting...", null);
            });
        }
        catch (Exception ex) when (ex is UpdateException or DownloadException)
        {
            Log.Error("Update failed", ex);
            UpdateInstaller.CleanUp(appDir);
            await InformAsync("The update did not finish",
                ex.Message + "\n\nThe launcher was left as it was. Try again later, or download the new zip from the release page.", "bad");
            return;
        }

        Log.Info($"The launcher folder now holds {release.Version}; restarting.");
        try
        {
            installer.StartNewLauncher(CurrentReleaseVersion, StartArgs.PersistentArgs());
        }
        catch (Exception ex)
        {
            Log.Error("Could not start the updated launcher", ex);
            await InformAsync("Updated - open the launcher again",
                $"Rewind Together {release.Version} is in place, but the new launcher could not be started by itself. " +
                "Close this window and open RewindTogetherLauncher.exe again.", "warn");
        }
        Application.Current?.Shutdown();
    }

    // ------------------------------------------------------------------ Nexus Mods (Nexus.cs, NexusDownloads.cs)

    private NexusClient? _nexus;
    private NexusDownloadWatcher? _nexusDownloads;
    private DateTime _lastNexusPoll = DateTime.MinValue;
    private bool _installingNexus;

    /// <summary>Nexus Mods' public API (no account needed to browse).</summary>
    public NexusClient Nexus
    {
        get
        {
            if (_nexus != null) return _nexus;
            try { _nexus = new NexusClient(Settings.NexusApiBase); }
            catch (ArgumentException ex)
            {
                Log.Warn(ex.Message + " Using " + NexusClient.DefaultApiBase);
                _nexus = new NexusClient();
            }
            return _nexus;
        }
    }

    /// <summary>Waits for "Get it on Nexus" downloads to land in the player's Downloads folder.</summary>
    public NexusDownloadWatcher NexusDownloads => _nexusDownloads ??= new NexusDownloadWatcher(StartArgs.DownloadsDir ?? DownloadsFolder.Find());

    /// <summary>
    /// "Download": opens the mod's main file's download page on Nexus (Nexus lets an app download
    /// for a player only through its own site or, later, a registered sign-in, so the last click
    /// happens there), waits for the file in Downloads, then installs it by itself.
    /// </summary>
    public async Task GetFromNexusAsync(NexusMod mod)
    {
        IReadOnlyList<NexusFile> files = Array.Empty<NexusFile>();
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            files = await Nexus.FilesAsync(mod.ModId, cts.Token);
        }
        catch (Exception ex) when (ex is NexusException or OperationCanceledException)
        {
            Log.Warn($"Could not list {mod.Name}'s files (the name pattern still works): {ex.Message}");
        }
        NexusDownloads.Want(mod, files);
        Log.Info($"Waiting for a download of Nexus mod {mod.ModId} ({mod.Name}, {files.Count} known file names) in {NexusDownloads.Folder}");
        string page = NexusLinks.DownloadPage(mod.ModId, files);
        GameProcess.OpenInShell(page);
        Notify($"{mod.Name}: click the download button on the Nexus page that just opened (free accounts: \"Slow download\"). " +
               $"When it lands in {Path.GetFileName(NexusDownloads.Folder.TrimEnd('\\'))}, the launcher installs it by itself.", "info");
        Mods.Browse.RefreshWaiting();
    }

    public void StopWaitingForNexus(int modId)
    {
        NexusDownloads.Forget(modId);
        Mods.Browse.RefreshWaiting();
    }

    /// <summary>Every couple of seconds while something is wanted: install finished downloads.</summary>
    private void PollNexusDownloads()
    {
        if (_nexusDownloads is not { IsWaiting: true } watcher || _installingNexus || DateTime.UtcNow - _lastNexusPoll < TimeSpan.FromSeconds(2)) return;
        _lastNexusPoll = DateTime.UtcNow;
        var found = watcher.Poll();
        if (found.Count > 0) _ = InstallNexusDownloadsAsync(found);
        else if (!watcher.IsWaiting) Mods.Browse.RefreshWaiting();
    }

    private async Task InstallNexusDownloadsAsync(IReadOnlyList<NexusDownloadMatch> found)
    {
        _installingNexus = true;
        try
        {
            Mods.Browse.RefreshWaiting();
            foreach (var m in found)
            {
                Log.Info($"Nexus download arrived: {m.Path} = mod {m.Mod.ModId} {m.Version}{(m.File == null ? " (by name pattern)" : "")}");
                Notify($"{m.Mod.Name} downloaded - installing it.", "info");
                await InstallPackageAsync(m.Path, null, "nexus", new NexusSource(m.Mod.ModId, m.Mod.Name, m.Version));
            }
        }
        finally
        {
            _installingNexus = false;
            Mods.Browse.RefreshInstalled();
        }
    }

    /// <summary>Which Nexus mod a downloaded file is, by its MD5 (best effort, a few seconds at most).</summary>
    private async Task<NexusSource?> IdentifyNexusFileAsync(string path)
    {
        try
        {
            string md5 = await Task.Run(() =>
            {
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
                return Convert.ToHexString(System.Security.Cryptography.MD5.HashData(fs)).ToLowerInvariant();
            });
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            if (await Nexus.FileByMd5Async(md5, cts.Token) is not { } file) return null;
            var mod = (await Nexus.ModsByIdAsync(new[] { file.ModId }, cts.Token)).FirstOrDefault();
            Log.Info($"{Path.GetFileName(path)} is Nexus mod {file.ModId} ({mod?.Name ?? file.Name}) {file.Version}");
            return new NexusSource(file.ModId, mod?.Name ?? file.Name, file.Version.Length > 0 ? file.Version : mod?.Version ?? "");
        }
        catch (Exception ex) when (ex is NexusException or OperationCanceledException or IOException or UnauthorizedAccessException)
        {
            Log.Info($"Could not look {Path.GetFileName(path)} up on Nexus: {ex.Message}");
            return null;
        }
    }

    // ------------------------------------------------------------------ Discord status (DiscordPresence.cs)

    private DiscordPresenceService? _discord;
    private int? _gamePid, _gameStartPid;
    private DateTime? _gameStart;
    private string _discordStatusText = "Shows up while the game is running.";

    public string DiscordStatusText { get => _discordStatusText; private set { if (Set(ref _discordStatusText, value)) Diag.RaiseDiscordStatus(); } }

    /// <summary>Says on the player's Discord profile what they are doing; the service does the talking.</summary>
    private void UpdateDiscord()
    {
        if (!Settings.DiscordStatus)
        {
            StopDiscord(wait: false);
            DiscordStatusText = "Off.";
            return;
        }
        var activity = DiscordStatus.For(new DiscordStatusInput(GameRunning, Play.IsHosting, Play.IsJoining, Status, GameStartedAt(), ProjectUrl));
        if (activity == null && _discord == null)
        {
            DiscordStatusText = "Shows up while the game is running.";
            return;
        }
        _discord ??= new DiscordPresenceService();
        // Shown for the game's process, so Discord puts it in place of the plain "Playing Retro Rewind".
        _discord.Want(_gamePid ?? 0, activity);
        DiscordStatusText = _discord.StatusText;
    }

    private void StopDiscord(bool wait)
    {
        if (_discord is not { } d) return;
        _discord = null;
        if (wait) d.Dispose();       // clears the status and closes the pipe (a few seconds at most)
        else Task.Run(d.Dispose);
    }

    /// <summary>When the game process started (Discord counts the time played from it).</summary>
    private DateTime? GameStartedAt()
    {
        if (_gamePid is not int pid) return null;
        if (_gameStartPid != pid)
        {
            _gameStartPid = pid;
            try
            {
                using var p = System.Diagnostics.Process.GetProcessById(pid);
                _gameStart = p.StartTime.ToUniversalTime();
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception)
            {
                _gameStart = GameStartedSeenAt;
            }
        }
        return _gameStart;
    }

    /// <summary>The project page on GitHub, for the status's button.</summary>
    private string ProjectUrl =>
        "https://github.com/" + (System.Text.RegularExpressions.Regex.IsMatch(Settings.UpdateRepo, @"^[\w.-]+/[\w.-]+$") ? Settings.UpdateRepo : ReleaseFeed.DefaultRepo);

    public void OnClosing(CancelEventArgs e)
    {
        _timer.Stop();
        Play.OnWindowClosing();
        StopDiscord(wait: true);
    }

    public void Dispose()
    {
        _timer.Stop();
        Play.Dispose();
        StopDiscord(wait: true);
    }
}
