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
        await Play.HandleStartArgsAsync(StartArgs);
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
        if (Game == null) return;
        bool running = GameProcess.IsRunning(Game);
        if (running && !GameRunning) GameStartedSeenAt = DateTime.UtcNow;
        if (!running) GameStartedSeenAt = null;
        GameRunning = running;

        var fresh = LaunchFiles.ReadStatus(Game);
        if (fresh != null) Status = fresh;
        if (Status != null && (Status.IsStale(DateTimeOffset.UtcNow) || !running)) Status = null;

        Raise(nameof(GameRunning));
        Raise(nameof(Status));
        UpdateGameChip();
        Play.OnTick();
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

    /// <summary>Downloads (or reuses) the pinned UE4SS build and unpacks it into the game.</summary>
    public async Task<bool> InstallUe4ssAsync(string? localZip = null)
    {
        if (Game == null) { await InformAsync("Retro Rewind not found", "Find the game first (Diagnostics > Game folder > Browse).", "bad"); return false; }
        if (!await EnsureGameClosedAsync("press Install UE4SS again")) return false;

        try
        {
            await BackupSavesIfWantedAsync();
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

    /// <summary>
    /// Installs a package (zip, folder or pak) and records it. Asks before replacing anything the
    /// launcher did not install. Rewind Together always replaces its own folder.
    /// </summary>
    public async Task<bool> InstallPackageAsync(string sourcePath, CatalogEntry? entry, string origin)
    {
        if (Game == null) { await InformAsync("Retro Rewind not found", "Find the game first (Diagnostics > Game folder > Browse).", "bad"); return false; }
        if (!await EnsureGameClosedAsync("press Install again")) return false;

        PackageSource? src = null;
        try
        {
            src = PackageSource.Open(sourcePath);
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

            var who = MakeIdentity(pkg, entry, origin, src.DisplayName);
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

    private static ModIdentity MakeIdentity(PackageAnalysis pkg, CatalogEntry? entry, string origin, string displayName)
    {
        if (entry != null)
            return new ModIdentity(entry.Id, entry.Name, entry.Version, origin, entry.Sha256);
        if (pkg.IsRewindTogether)
            return new ModIdentity(GameInstall.RewindTogetherId, "Rewind Together", pkg.ModJsonVersion ?? ReadNetLuaVersion(pkg) ?? "local", origin);
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
            Filter = "Mod files (*.zip;*.pak)|*.zip;*.pak|All files (*.*)|*.*",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\Downloads",
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

    public void OnClosing(CancelEventArgs e)
    {
        _timer.Stop();
        Play.OnWindowClosing();
    }

    public void Dispose()
    {
        _timer.Stop();
        Play.Dispose();
    }
}
