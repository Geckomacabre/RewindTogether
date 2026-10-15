using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Input;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.UI;

/// <summary>One catalog entry on the shelf.</summary>
public sealed class CatalogItem : ObservableObject
{
    private readonly ModsViewModel _owner;

    public CatalogItem(ModsViewModel owner, CatalogEntry entry)
    {
        _owner = owner;
        Entry = entry;
    }

    public CatalogEntry Entry { get; }
    public string Name => Entry.Name;
    public string Author => string.IsNullOrWhiteSpace(Entry.Author) ? "" : "by " + Entry.Author;
    public string Description => Entry.Description;
    public string Version => "v" + Entry.Version;
    public string KindText => ModKinds.Describe(Entry.Kind);
    public string SizeText => Entry.Size is > 0 ? $"{Entry.Size.Value / 1024.0 / 1024.0:0.0} MB" : "";
    public bool HasHomepage => Entry.Homepage.Length > 0;

    private string? _installedVersion;
    private bool _enabled, _managed;

    public string? InstalledVersion { get => _installedVersion; set { Set(ref _installedVersion, value); RaiseState(); } }
    /// <summary>The launcher installed it (so it can uninstall/toggle it).</summary>
    public bool Managed { get => _managed; set { Set(ref _managed, value); RaiseState(); } }
    public bool Installed => _installedVersion != null;
    public bool UpdateAvailable => Installed && VersionCompare.IsNewer(Entry.Version, _installedVersion);

    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            Raise();
            if (!_suppress) _ = _owner.SetCatalogEnabledAsync(this, value);
        }
    }

    private bool _suppress;
    public void SetEnabledSilently(bool v)
    {
        _suppress = true;
        Enabled = v;
        _suppress = false;
    }

    public string StateText => !Installed ? (Entry.IsInstallable ? "Not installed" : "Not installed - download not available yet")
        : UpdateAvailable ? $"Installed {_installedVersion} - update available"
        : $"Installed {_installedVersion}";
    /// <summary>"Included with the launcher" when the mod ships next to the exe.</summary>
    public string SourceText => Entry.IsBundled ? "Included with the launcher" : "";
    public string StateTone => !Installed ? "idle" : UpdateAvailable ? "warn" : "ok";
    public string PrimaryText => !Installed ? "Install" : UpdateAvailable ? $"Update to {Entry.Version}" : "Reinstall";
    public bool CanUninstall => Installed && (Managed || Entry.IsRewindTogether);
    public bool CanToggle => Installed;

    private void RaiseState()
    {
        Raise(nameof(Installed));
        Raise(nameof(UpdateAvailable));
        Raise(nameof(StateText));
        Raise(nameof(StateTone));
        Raise(nameof(PrimaryText));
        Raise(nameof(CanUninstall));
        Raise(nameof(CanToggle));
    }
}

/// <summary>Something already in the game folder.</summary>
public sealed class GameModItem : ObservableObject
{
    private readonly ModsViewModel _owner;
    private bool _enabled;
    private bool _suppress;

    public GameModItem(ModsViewModel owner, GameModInfo info)
    {
        _owner = owner;
        Info = info;
        _enabled = info.Enabled;
    }

    public GameModInfo Info { get; }
    public string Name => Info.Name;
    public string KindText => Info.Kind switch { ModKind.Ue4ssLua => "UE4SS", ModKind.Pak => "PAK", _ => "LOGIC" };
    public string OriginText => Info.BuiltIn ? "comes with UE4SS" : Info.ManagedId != null ? "installed by the launcher" : "installed by hand";
    public bool CanUninstall => Info.ManagedId != null;
    public string Warning => Info.HasEntryPoint ? "" : "No Scripts\\main.lua - UE4SS cannot load this folder.";

    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            Raise();
            if (!_suppress) _ = _owner.SetGameModEnabledAsync(this, value);
        }
    }

    public void SetEnabledSilently(bool v)
    {
        _suppress = true;
        Enabled = v;
        _suppress = false;
    }
}

/// <summary>The Mods tab: a catalog to install from, and everything already in the game.</summary>
public sealed class ModsViewModel : ObservableObject
{
    private readonly MainViewModel _main;
    private string _search = "";
    private string _catalogStatus = "";
    private bool _loading;
    private List<CatalogItem> _allItems = new();

    public ModsViewModel(MainViewModel main)
    {
        _main = main;
        InstallCommand = new AsyncCommand(p => p is CatalogItem c ? _main.InstallFromCatalogAsync(c.Entry) : Task.CompletedTask);
        UninstallCatalogCommand = new AsyncCommand(p => p is CatalogItem c ? UninstallAsync(c.Entry.Id, c.Name) : Task.CompletedTask);
        UninstallGameModCommand = new AsyncCommand(p => p is GameModItem g && g.Info.ManagedId != null ? UninstallAsync(g.Info.ManagedId, g.Name) : Task.CompletedTask);
        OpenHomepageCommand = new RelayCommand(p => { if (p is CatalogItem c && c.HasHomepage) GameProcess.OpenInShell(c.Entry.Homepage); });
        RevealCommand = new RelayCommand(p => { if (p is GameModItem g) Try(() => GameProcess.RevealInExplorer(g.Info.Path)); });
        AddFileCommand = new AsyncCommand(async () => { if (_main.PickModFile() is { } f) await _main.InstallPackageAsync(f, null, "file"); });
        AddFolderCommand = new AsyncCommand(async () => { if (_main.PickModFolder() is { } f) await _main.InstallPackageAsync(f, null, "folder"); });
        RefreshCommand = new AsyncCommand(async () => { await LoadCatalogAsync(); _main.RefreshInstallState(); });
        OpenModsFolderCommand = new RelayCommand(() => { if (_main.Game != null) Try(() => GameProcess.RevealInExplorer(_main.Game.Ue4ssModsDir)); });
    }

    public Catalog? Catalog { get; private set; }
    public ObservableCollection<CatalogItem> Items { get; } = new();
    public ObservableCollection<GameModItem> GameMods { get; } = new();

    public string Search
    {
        get => _search;
        set { if (Set(ref _search, value)) ApplyFilter(); }
    }

    public string CatalogStatus { get => _catalogStatus; private set => Set(ref _catalogStatus, value); }
    public bool Loading { get => _loading; private set => Set(ref _loading, value); }
    public string GameModsSummary => _main.Game == null ? "Retro Rewind not found." :
        $"{Plural(GameMods.Count(m => m.Info.Kind == ModKind.Ue4ssLua), "UE4SS mod")}, {Plural(GameMods.Count(m => m.Info.Kind != ModKind.Ue4ssLua), "pak mod")}. " +
        "Changes apply the next time the game starts.";

    private static string Plural(int n, string noun) => $"{n} {noun}{(n == 1 ? "" : "s")}";

    public ICommand InstallCommand { get; }
    public ICommand UninstallCatalogCommand { get; }
    public ICommand UninstallGameModCommand { get; }
    public ICommand OpenHomepageCommand { get; }
    public ICommand RevealCommand { get; }
    public ICommand AddFileCommand { get; }
    public ICommand AddFolderCommand { get; }
    public ICommand RefreshCommand { get; }
    public ICommand OpenModsFolderCommand { get; }

    /// <summary>Built-in catalog first (works offline), then the configured URL if there is one.</summary>
    public async Task LoadCatalogAsync()
    {
        Loading = true;
        try
        {
            Catalog catalog = CatalogParser.LoadEmbedded();
            string url = _main.Settings.CatalogUrl?.Trim() ?? "";
            if (url.Length > 0)
            {
                try
                {
                    string tmp = Path.Combine(_main.Paths.DataDir, "catalog-download.json");
                    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                    await _main.Downloader.DownloadAsync(url, tmp, null, null, null, cts.Token);
                    string text = await File.ReadAllTextAsync(tmp);
                    catalog = CatalogParser.Parse(text, url);
                    File.Move(tmp, _main.Paths.CatalogCacheFile, overwrite: true);
                }
                catch (Exception ex) when (ex is DownloadException or IOException or FormatException or System.Text.Json.JsonException or OperationCanceledException)
                {
                    Log.Warn("Catalog download failed: " + ex.Message);
                    if (File.Exists(_main.Paths.CatalogCacheFile))
                    {
                        try { catalog = CatalogParser.Parse(await File.ReadAllTextAsync(_main.Paths.CatalogCacheFile), "saved copy of " + url); }
                        catch (Exception) { }
                    }
                    _main.Notify("The online mod list could not be loaded, so the saved/built-in list is shown. " + ex.Message, "warn");
                }
            }
            // A copy of Rewind Together shipped next to the exe is its install source.
            catalog.ApplyBundled(_main.Bundled);
            Catalog = catalog;
            foreach (var w in catalog.Warnings) Log.Warn("Catalog: " + w);
            CatalogStatus = $"{catalog.Mods.Count} mod{(catalog.Mods.Count == 1 ? "" : "s")} - list: {catalog.Source}" +
                            (catalog.Warnings.Count > 0 ? $" ({catalog.Warnings.Count} entries skipped, see the launcher log)" : "");
            _allItems = catalog.Mods.Select(e => new CatalogItem(this, e)).ToList();
            RefreshInstalled();
            _main.Play.RefreshSetup();
        }
        finally
        {
            Loading = false;
        }
    }

    /// <summary>Re-reads installed.json and the game folder.</summary>
    public void RefreshInstalled()
    {
        var game = _main.Game;
        var managed = game == null ? new List<InstalledMod>() : new ModManager(game, _main.Paths.InstalledManifestFile).Managed().ToList();
        var rt = _main.RewindTogether;
        foreach (var item in _allItems)
        {
            var rec = managed.FirstOrDefault(m => m.Id.Equals(item.Entry.Id, StringComparison.OrdinalIgnoreCase));
            if (item.Entry.IsRewindTogether && rt is { Installed: true })
            {
                item.Managed = rec != null;
                item.InstalledVersion = rt.Version ?? rec?.Version ?? "?";
                item.SetEnabledSilently(rt.EnabledInModsTxt != false);
            }
            else if (rec != null)
            {
                item.Managed = true;
                item.InstalledVersion = rec.Version;
                item.SetEnabledSilently(rec.Enabled);
            }
            else
            {
                item.Managed = false;
                item.InstalledVersion = null;
                item.SetEnabledSilently(false);
            }
        }
        ApplyFilter();

        GameMods.Clear();
        if (game != null)
        {
            try
            {
                foreach (var m in new ModManager(game, _main.Paths.InstalledManifestFile).ScanGame())
                    GameMods.Add(new GameModItem(this, m));
            }
            catch (Exception ex)
            {
                Log.Warn("Could not scan the game's mods: " + ex.Message);
            }
        }
        Raise(nameof(GameModsSummary));
    }

    private void ApplyFilter()
    {
        string q = _search.Trim();
        Items.Clear();
        foreach (var i in _allItems.Where(i => q.Length == 0
                     || i.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || i.Description.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || i.Entry.Author.Contains(q, StringComparison.OrdinalIgnoreCase)))
            Items.Add(i);
    }

    private async Task UninstallAsync(string id, string name)
    {
        var game = _main.Game;
        if (game == null || !await _main.EnsureGameClosedAsync("press Uninstall again")) return;
        bool isRt = id.Equals(GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase);
        if (!await _main.AskAsync($"Uninstall {name}?",
                isRt ? "Rewind Together will be removed from the game. Your config.lua is kept as RewindTogether-config.lua.uninstalled-backup in the Mods folder."
                     : $"{name} will be removed from the game folder.",
                "Uninstall", "Cancel", "warn"))
            return;
        try
        {
            var mgr = new ModManager(game, _main.Paths.InstalledManifestFile);
            if (mgr.Find(id) == null && isRt)
            {
                // Installed by hand (the old PowerShell installer): remove its folder the same safe way.
                await Task.Run(() => mgr.UninstallUnmanagedFolder(GameInstall.RewindTogetherFolder));
            }
            else
            {
                await Task.Run(() => mgr.Uninstall(id));
            }
            _main.RefreshInstallState();
            _main.Notify($"{name} uninstalled.", "ok");
        }
        catch (GameFilesLockedException ex)
        {
            await _main.ShowLockedAsync(ex);
        }
        catch (Exception ex) when (ex is ModInstallException or IOException or UnauthorizedAccessException)
        {
            await _main.InformAsync($"{name} could not be uninstalled", ex.Message, "bad");
        }
    }

    internal async Task SetCatalogEnabledAsync(CatalogItem item, bool enabled)
    {
        var game = _main.Game;
        if (game == null) return;
        try
        {
            var mgr = new ModManager(game, _main.Paths.InstalledManifestFile);
            if (mgr.Find(item.Entry.Id) != null)
            {
                await Task.Run(() => mgr.SetEnabled(item.Entry.Id, enabled));
            }
            else if (item.Entry.IsRewindTogether)
            {
                var info = mgr.ScanGame().FirstOrDefault(m => m.Kind == ModKind.Ue4ssLua && m.Name.Equals(GameInstall.RewindTogetherFolder, StringComparison.OrdinalIgnoreCase));
                if (info != null) await Task.Run(() => mgr.SetEnabled(info, enabled));
            }
            AfterToggle(item.Name, enabled);
        }
        catch (GameFilesLockedException ex)
        {
            item.SetEnabledSilently(!enabled);
            await _main.ShowLockedAsync(ex);
        }
        catch (Exception ex) when (ex is ModInstallException or IOException)
        {
            item.SetEnabledSilently(!enabled);
            await _main.InformAsync($"{item.Name} could not be switched {(enabled ? "on" : "off")}", ex.Message, "bad");
        }
    }

    internal async Task SetGameModEnabledAsync(GameModItem item, bool enabled)
    {
        var game = _main.Game;
        if (game == null) return;
        if (item.Info.Kind != ModKind.Ue4ssLua && GameProcess.IsRunning(game))
        {
            item.SetEnabledSilently(!enabled);
            await _main.EnsureGameClosedAsync($"switch {item.Name} {(enabled ? "on" : "off")} again");
            return;
        }
        if (!enabled && item.Info.Name.Equals("BPModLoaderMod", StringComparison.OrdinalIgnoreCase) &&
            GameMods.Any(m => m.Info.Kind == ModKind.LogicMod && m.Enabled))
        {
            if (!await _main.AskAsync("Switch off BPModLoaderMod?",
                    "BPModLoaderMod is what loads Blueprint (LogicMods) mods. With it off, those mods stop working.", "Switch off", "Keep it on", "warn"))
            {
                item.SetEnabledSilently(true);
                return;
            }
        }
        try
        {
            await Task.Run(() => new ModManager(game, _main.Paths.InstalledManifestFile).SetEnabled(item.Info, enabled));
            AfterToggle(item.Name, enabled);
        }
        catch (GameFilesLockedException ex)
        {
            item.SetEnabledSilently(!enabled);
            await _main.ShowLockedAsync(ex);
        }
        catch (Exception ex) when (ex is ModInstallException or IOException or UnauthorizedAccessException)
        {
            item.SetEnabledSilently(!enabled);
            await _main.InformAsync($"{item.Name} could not be switched {(enabled ? "on" : "off")}", ex.Message, "bad");
        }
    }

    private void AfterToggle(string name, bool enabled)
    {
        _main.RefreshInstallState();
        bool running = _main.Game != null && GameProcess.IsRunning(_main.Game);
        _main.Notify($"{name} switched {(enabled ? "on" : "off")}.{(running ? " Restart the game for this to take effect." : "")}", "ok");
    }

    private void Try(Action a)
    {
        try { a(); }
        catch (Exception ex) { _main.Notify(ex.Message, "warn"); }
    }
}
