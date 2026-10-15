using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Input;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.UI;

public sealed record InfoRow(string Label, string Value, string Tone = "idle");

/// <summary>The Diagnostics tab: what the launcher knows, the logs, save backups and settings.</summary>
public sealed class DiagnosticsViewModel : ObservableObject
{
    private readonly MainViewModel _main;
    private string _logText = "";
    private string _logName = "RewindTogether.log";

    public DiagnosticsViewModel(MainViewModel main)
    {
        _main = main;
        OpenGameFolderCommand = new RelayCommand(() => Reveal(_main.Game?.Root));
        OpenWin64Command = new RelayCommand(() => Reveal(_main.Game?.Win64));
        OpenModLogCommand = new RelayCommand(() => OpenFile(_main.Game?.ModLog));
        OpenUe4ssLogCommand = new RelayCommand(() => OpenFile(_main.Game?.Ue4ssLog));
        OpenLauncherLogCommand = new RelayCommand(() => OpenFile(_main.Paths.LogFile));
        OpenDataFolderCommand = new RelayCommand(() => Reveal(_main.Paths.DataDir));
        OpenBackupsCommand = new RelayCommand(() =>
        {
            Directory.CreateDirectory(_main.Paths.BackupsDir);
            Reveal(_main.Paths.BackupsDir);
        });
        CopyDiagnosticsCommand = new RelayCommand(CopyDiagnostics);
        BackupNowCommand = new AsyncCommand(BackupNowAsync);
        BrowseGameCommand = new AsyncCommand(_main.BrowseForGameAsync);
        AutoDetectCommand = new RelayCommand(_main.ResetGameFolder);
        SaveSettingsCommand = new RelayCommand(SaveSettings);
        ShowLogCommand = new RelayCommand(p => { LogName = p as string ?? "RewindTogether.log"; LoadLog(); });
        RefreshCommand = new RelayCommand(() => { _main.RefreshGame(); Refresh(); });
        CheckForUpdatesCommand = new AsyncCommand(() => _main.CheckForUpdatesAsync(manual: true));

        _catalogUrl = main.Settings.CatalogUrl;
        _guestPort = main.Settings.GuestTunnelPort.ToString();
    }

    public ObservableCollection<InfoRow> Rows { get; } = new();

    public string LogText { get => _logText; private set => Set(ref _logText, value); }
    public string LogName { get => _logName; private set => Set(ref _logName, value); }

    public string GameFolder => _main.Game?.Root ?? "(not found)";
    public bool GameFolderIsManual => !string.IsNullOrEmpty(_main.Settings.GameRoot);

    private string _catalogUrl;
    private string _guestPort;
    public string CatalogUrl { get => _catalogUrl; set => Set(ref _catalogUrl, value); }
    public string GuestPort { get => _guestPort; set => Set(ref _guestPort, value); }

    public bool HostFriendsOnly
    {
        get => _main.Settings.HostFriendsOnly;
        set { _main.Settings.HostFriendsOnly = value; _main.SaveSettings(); Raise(); }
    }

    public bool BackupBeforeInstall
    {
        get => _main.Settings.BackupSavesBeforeInstall;
        set { _main.Settings.BackupSavesBeforeInstall = value; _main.SaveSettings(); Raise(); }
    }

    public bool CheckForUpdates
    {
        get => _main.Settings.CheckForUpdates;
        set
        {
            _main.Settings.CheckForUpdates = value;
            _main.SaveSettings();
            Raise();
            if (value) _ = _main.CheckForUpdatesAsync(manual: false);
        }
    }

    public string UpdateStatus => _main.UpdateStatus;
    public ICommand CheckForUpdatesCommand { get; }
    public void RaiseUpdateStatus() => Raise(nameof(UpdateStatus));

    public bool DiscordStatus
    {
        get => _main.Settings.DiscordStatus;
        set { _main.Settings.DiscordStatus = value; _main.SaveSettings(); Raise(); }
    }

    public string DiscordStatusText => _main.DiscordStatusText;
    public void RaiseDiscordStatus() => Raise(nameof(DiscordStatusText));

    public string LastBackup => SaveBackup.LatestBackup(_main.Paths.BackupsDir) is { } b
        ? $"{Path.GetFileName(b)} ({File.GetLastWriteTime(b):g})" : "none yet";

    public ICommand OpenGameFolderCommand { get; }
    public ICommand OpenWin64Command { get; }
    public ICommand OpenModLogCommand { get; }
    public ICommand OpenUe4ssLogCommand { get; }
    public ICommand OpenLauncherLogCommand { get; }
    public ICommand OpenDataFolderCommand { get; }
    public ICommand OpenBackupsCommand { get; }
    public ICommand CopyDiagnosticsCommand { get; }
    public ICommand BackupNowCommand { get; }
    public ICommand BrowseGameCommand { get; }
    public ICommand AutoDetectCommand { get; }
    public ICommand SaveSettingsCommand { get; }
    public ICommand ShowLogCommand { get; }
    public ICommand RefreshCommand { get; }

    public void Refresh()
    {
        Rows.Clear();
        var g = _main.Game;
        Rows.Add(new InfoRow("Launcher", $"v{AppInfo.Version}  ({Environment.ProcessPath})"));
        if (g == null)
        {
            Rows.Add(new InfoRow("Retro Rewind", "Not found - use Browse below.", "bad"));
        }
        else
        {
            Rows.Add(new InfoRow("Game folder", $"{g.Root}  ({g.Source})", "ok"));
            Rows.Add(new InfoRow("Steam build", g.BuildId ?? "unknown (no appmanifest found)", g.BuildId != null ? "ok" : "warn"));
            var ue = _main.Ue4ss;
            if (ue != null) Rows.Add(new InfoRow("UE4SS", ue.Summary, ue.State == Ue4ssState.Installed ? (ue.IsPinnedBuild ? "ok" : "warn") : "bad"));
            var rt = _main.RewindTogether;
            if (rt != null)
            {
                Rows.Add(new InfoRow("Rewind Together", rt.Installed
                    ? $"{rt.Version ?? "unknown version"}{(rt.EnabledInModsTxt == false ? " (switched off)" : "")}"
                    : "not installed", rt.Installed && rt.EnabledInModsTxt != false ? "ok" : "bad"));
                if (rt.GameBuild != null)
                    Rows.Add(new InfoRow("Mod tested on build", rt.GameBuild, rt.BuildWarning(g.BuildId) == null ? "ok" : "warn"));
            }
            Rows.Add(new InfoRow("Steam library DLL", File.Exists(g.SteamApiDll) ? "present (loaded only while you host or join)" : "MISSING - verify game files in Steam",
                File.Exists(g.SteamApiDll) ? "ok" : "bad"));
            var s = _main.Status;
            Rows.Add(new InfoRow("Game status", !_main.GameRunning ? "not running"
                : s == null ? "running, mod not reporting"
                : $"{s.Mode}, {(s.InStore ? "in store" : "menu")}, {s.Players} player(s), port {s.Port}", _main.GameRunning && s == null ? "warn" : "idle"));
            if (s?.LastError is { Length: > 0 } err) Rows.Add(new InfoRow("Mod's last error", err, "bad"));
        }
        Rows.Add(new InfoRow("Saves", Directory.Exists(_main.Paths.SaveGamesDir) ? _main.Paths.SaveGamesDir : "no save folder yet"));
        Rows.Add(new InfoRow("Last save backup", LastBackup));
        Raise(nameof(GameFolder));
        Raise(nameof(GameFolderIsManual));
        Raise(nameof(LastBackup));
        LoadLog();
    }

    private void LoadLog()
    {
        string? path = LogName switch
        {
            "UE4SS.log" => _main.Game?.Ue4ssLog,
            "launcher.log" => _main.Paths.LogFile,
            _ => _main.Game?.ModLog,
        };
        if (path == null || !File.Exists(path)) { LogText = $"{LogName} does not exist yet.{Environment.NewLine}It appears after the game has run with mods."; return; }
        var lines = AtomicFile.TailLines(path, 200);
        LogText = lines.Count == 0 ? "(empty)" : string.Join(Environment.NewLine, lines);
    }

    private void CopyDiagnostics()
    {
        string text = DiagnosticsReport.Build(new DiagnosticsReport.Inputs
        {
            Paths = _main.Paths,
            Settings = _main.Settings,
            Locate = _main.Locate,
            Game = _main.Game,
            SteamSessionState = _main.SteamChip,
            ExtraLines = new[] { "Play tab: " + _main.Play.Phase },
        });
        try
        {
            Clipboard.SetText(text);
            _main.Notify($"Diagnostics copied ({text.Length / 1024} KB). Paste them into your bug report or Discord message.", "ok");
        }
        catch (Exception ex)
        {
            string file = Path.Combine(_main.Paths.DataDir, "diagnostics.txt");
            File.WriteAllText(file, text);
            _main.Notify($"The clipboard was busy ({ex.Message}), so the diagnostics were saved to {file}.", "warn");
            Reveal(file);
        }
    }

    private async Task BackupNowAsync()
    {
        var r = await Task.Run(() => SaveBackup.Run(_main.Paths.SaveGamesDir, _main.Paths.BackupsDir, force: true));
        _main.Notify(r.Message, r.Created ? "ok" : "warn");
        Refresh();
    }

    private void SaveSettings()
    {
        string url = (CatalogUrl ?? "").Trim();
        if (url.Length > 0 && (!Uri.TryCreate(url, UriKind.Absolute, out var u) || u.Scheme != Uri.UriSchemeHttps))
        {
            _ = _main.InformAsync("Check the catalog address", "The mod list address must start with https://.", "warn");
            return;
        }
        if (!int.TryParse(GuestPort, out int port) || port < 1024 || port > 65535 || port == _main.Settings.HostGamePort)
        {
            _ = _main.InformAsync("Check the port", $"The guest tunnel port must be a number from 1024 to 65535, and not {_main.Settings.HostGamePort} (the game's own port).", "warn");
            return;
        }
        _main.Settings.CatalogUrl = url;
        _main.Settings.GuestTunnelPort = port;
        _main.SaveSettings();
        _main.Notify("Settings saved.", "ok");
        _ = _main.Mods.LoadCatalogAsync();
    }

    private void Reveal(string? path)
    {
        if (path == null) { _main.Notify("Retro Rewind was not found.", "warn"); return; }
        try { GameProcess.RevealInExplorer(path); }
        catch (Exception ex) { _main.Notify(ex.Message, "warn"); }
    }

    private void OpenFile(string? path)
    {
        if (path == null) { _main.Notify("Retro Rewind was not found.", "warn"); return; }
        if (!File.Exists(path)) { _main.Notify($"{Path.GetFileName(path)} does not exist yet - it is created when the game runs with mods.", "info"); return; }
        try { GameProcess.OpenInShell(path); }
        catch (Exception ex) { _main.Notify(ex.Message, "warn"); }
    }
}
