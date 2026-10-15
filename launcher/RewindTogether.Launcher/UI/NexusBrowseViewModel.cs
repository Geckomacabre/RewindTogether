using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.UI;

/// <summary>One Nexus mod in the browser.</summary>
public sealed class NexusModItem : ObservableObject
{
    private ImageSource? _thumbnail;
    private string? _installedVersion;
    private bool _installed, _waiting;

    public NexusModItem(NexusMod mod) => Mod = mod;

    public NexusMod Mod { get; }
    public string Name => Mod.Name;
    public string Author => Mod.Author.Length > 0 ? "by " + Mod.Author : "";
    public string Summary => Mod.Summary;
    public string VersionText => Mod.Version.Length == 0 ? "" : Mod.Version.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? Mod.Version : "v" + Mod.Version;
    public bool HasVersion => Mod.Version.Length > 0;
    public string Category => Mod.Category;
    public bool HasCategory => Mod.Category.Length > 0;
    public bool Adult => Mod.Adult;
    public string StatsText =>
        $"↓ {Short(Mod.Downloads)}    ♥ {Short(Mod.Endorsements)}" +
        (Mod.UpdatedAt is DateTime u ? $"    updated {u.ToLocalTime():d MMM yyyy}" : "");

    public ImageSource? Thumbnail { get => _thumbnail; set { if (Set(ref _thumbnail, value)) Raise(nameof(HasThumbnail)); } }
    public bool HasThumbnail => _thumbnail != null;

    /// <summary>Installed through the launcher from Nexus (it knows the mod's Nexus id).</summary>
    public bool Installed => _installed;
    public bool UpdateAvailable => _installed && VersionCompare.IsNewer(Mod.Version, _installedVersion);
    public bool UpToDate => _installed && !UpdateAvailable;
    public bool Waiting { get => _waiting; set { if (Set(ref _waiting, value)) RaiseState(); } }

    public void SetInstalled(bool installed, string? version)
    {
        _installed = installed;
        _installedVersion = version;
        RaiseState();
    }

    public string PrimaryText => _waiting ? "Waiting for the download..." : UpdateAvailable ? "⬇  Download update" : _installed ? "⬇  Download again" : "⬇  Download";
    public bool CanGet => !_waiting;
    public string StateText =>
        _waiting ? "Click the download button on the Nexus page that opened (free accounts: \"Slow download\"). It installs as soon as it lands in your Downloads folder."
        : UpdateAvailable ? $"Installed {_installedVersion} - {Mod.Version} is out"
        : _installed ? $"Installed{(string.IsNullOrEmpty(_installedVersion) ? "" : " " + _installedVersion)}"
        : "";
    public string StateTone => _waiting ? "info" : UpdateAvailable ? "warn" : _installed ? "ok" : "idle";
    public bool HasState => StateText.Length > 0;

    private void RaiseState()
    {
        foreach (string p in new[] { nameof(Installed), nameof(UpdateAvailable), nameof(UpToDate), nameof(PrimaryText), nameof(CanGet),
                     nameof(StateText), nameof(StateTone), nameof(HasState) })
            Raise(p);
    }

    private static string Short(long n) => n switch
    {
        >= 1_000_000 => $"{n / 1_000_000.0:0.#}M",
        >= 10_000 => $"{n / 1000.0:0}k",
        >= 1_000 => $"{n / 1000.0:0.#}k",
        _ => n.ToString(),
    };
}

public sealed record NexusSortOption(string Label, NexusSort Sort, string Key);

/// <summary>
/// The Mods tab's "Nexus Mods" side: Retro Rewind's mods on Nexus, searchable and sorted, with
/// thumbnails. "Get it on Nexus" opens the mod's Files page and the launcher installs the
/// download by itself (MainViewModel.GetFromNexusAsync). Adult-flagged mods are hidden unless
/// the player switches them on. It can also show just the mods a co-op host uses.
/// </summary>
public sealed class NexusBrowseViewModel : ObservableObject
{
    public const int PageSize = 20;

    private readonly MainViewModel _main;
    private CancellationTokenSource? _load, _debounce;
    private string _search = "", _status = "", _hostFilter = "";
    private bool _loading, _loaded, _canLoadMore;
    private int _total;
    private IReadOnlyList<int>? _onlyIds;
    private NexusSortOption _sort;

    public NexusBrowseViewModel(MainViewModel main)
    {
        _main = main;
        _sort = Sorts.FirstOrDefault(s => s.Key == main.Settings.NexusSort) ?? Sorts[0];
        LoadMoreCommand = new AsyncCommand(() => LoadPageAsync(append: true), () => CanLoadMore && !Loading);
        GetCommand = new AsyncCommand(p => p is NexusModItem i ? _main.GetFromNexusAsync(i.Mod) : Task.CompletedTask);
        OpenPageCommand = new RelayCommand(p => { if (p is NexusModItem i) GameProcess.OpenInShell(i.Mod.PageUrl); });
        StopWaitingCommand = new RelayCommand(p => { if (p is NexusModItem i) _main.StopWaitingForNexus(i.Mod.ModId); });
        ClearHostFilterCommand = new AsyncCommand(() => { _onlyIds = null; HostFilter = ""; return ReloadAsync(); });
        OpenNexusCommand = new RelayCommand(() => GameProcess.OpenInShell(NexusLinks.GamePage));
        RetryCommand = new AsyncCommand(ReloadAsync);
    }

    public ObservableCollection<NexusModItem> Items { get; } = new();

    public IReadOnlyList<NexusSortOption> Sorts { get; } = new[]
    {
        new NexusSortOption("Most downloaded", NexusSort.Downloads, "downloads"),
        new NexusSortOption("Recently updated", NexusSort.Updated, "updated"),
        new NexusSortOption("Most endorsed", NexusSort.Endorsements, "endorsements"),
        new NexusSortOption("Newest", NexusSort.Newest, "newest"),
    };

    public NexusSortOption SelectedSort
    {
        get => _sort;
        set
        {
            if (value == null || !Set(ref _sort, value)) return;
            _main.Settings.NexusSort = value.Key;
            _main.SaveSettings();
            _ = ReloadAsync();
        }
    }

    public bool ShowAdult
    {
        get => _main.Settings.NexusShowAdult;
        set
        {
            if (_main.Settings.NexusShowAdult == value) return;
            _main.Settings.NexusShowAdult = value;
            _main.SaveSettings();
            Raise();
            _ = ReloadAsync();
        }
    }

    /// <summary>What the toolbar's search box holds while this side is shown.</summary>
    public string SearchText
    {
        get => _search;
        set
        {
            if (!Set(ref _search, value ?? "")) return;
            _ = DebouncedReloadAsync();
        }
    }

    public string Status { get => _status; private set => Set(ref _status, value); }
    public bool Loading { get => _loading; private set { if (Set(ref _loading, value)) CommandManager.InvalidateRequerySuggested(); } }
    public bool CanLoadMore { get => _canLoadMore; private set { if (Set(ref _canLoadMore, value)) CommandManager.InvalidateRequerySuggested(); } }
    public bool Failed { get; private set; }
    public string HostFilter { get => _hostFilter; private set { if (Set(ref _hostFilter, value)) Raise(nameof(HostFilterVisible)); } }
    public bool HostFilterVisible => _hostFilter.Length > 0;

    public ICommand LoadMoreCommand { get; }
    public ICommand GetCommand { get; }
    public ICommand OpenPageCommand { get; }
    public ICommand StopWaitingCommand { get; }
    public ICommand ClearHostFilterCommand { get; }
    public ICommand OpenNexusCommand { get; }
    public ICommand RetryCommand { get; }

    /// <summary>Loads the first page the first time the side is shown.</summary>
    public void EnsureLoaded()
    {
        if (!_loaded && !Loading) _ = ReloadAsync();
    }

    /// <summary>Just the Nexus mods a co-op host uses ("Get their mods").</summary>
    public async Task ShowHostModsAsync(string hostName, IReadOnlyList<int> ids)
    {
        _onlyIds = ids.ToList();
        HostFilter = $"The Nexus mods {hostName} uses. Get each one the same way: it installs by itself once downloaded.";
        await ReloadAsync();
    }

    public async Task ReloadAsync()
    {
        _loaded = true;
        Items.Clear();
        _total = 0;
        await LoadPageAsync(append: false);
    }

    private async Task DebouncedReloadAsync()
    {
        _debounce?.Cancel();
        var cts = _debounce = new CancellationTokenSource();
        try { await Task.Delay(450, cts.Token); }
        catch (OperationCanceledException) { return; }
        if (_onlyIds == null) await ReloadAsync();
        else ApplyLocalFilter();
    }

    private async Task LoadPageAsync(bool append)
    {
        _load?.Cancel();
        var cts = _load = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        Loading = true;
        Failed = false;
        Raise(nameof(Failed));
        Status = "Asking Nexus Mods...";
        try
        {
            if (_onlyIds != null)
            {
                var mods = await _main.Nexus.ModsByIdAsync(_onlyIds, cts.Token);
                if (cts.IsCancellationRequested) return;
                _hostMods = mods.Select(m => new NexusModItem(m)).ToList();
                ApplyLocalFilter();
                CanLoadMore = false;
                return;
            }
            var page = await _main.Nexus.SearchAsync(_search, _sort.Sort, ShowAdult, append ? Items.Count : 0, PageSize, cts.Token);
            if (cts != _load) return;   // a newer search replaced this one
            if (!append) Items.Clear();
            foreach (var m in page.Mods.Where(m => Items.All(i => i.Mod.ModId != m.ModId)))
                Add(new NexusModItem(m));
            _total = page.Total;
            CanLoadMore = Items.Count < _total && page.Mods.Count > 0;
            Status = _total == 0
                ? (_search.Trim().Length > 0 ? $"Nothing on Nexus matches \"{_search.Trim()}\"." : "Nexus Mods lists no mods for Retro Rewind right now.")
                : $"{_total} mod{(_total == 1 ? "" : "s")} on Nexus Mods{(_search.Trim().Length > 0 ? $" matching \"{_search.Trim()}\"" : "")}" +
                  $"{(ShowAdult ? "" : ", adult mods hidden")} - showing {Items.Count}.";
        }
        catch (OperationCanceledException)
        {
            if (cts == _load) Status = "Nexus Mods did not answer in time.";
        }
        catch (NexusException ex)
        {
            Log.Warn("Nexus browse failed: " + ex.Message);
            Status = ex.Message;
            Failed = true;
            Raise(nameof(Failed));
        }
        finally
        {
            if (cts == _load) Loading = false;
        }
    }

    private List<NexusModItem> _hostMods = new();

    /// <summary>The host's list is short: the search box filters it here.</summary>
    private void ApplyLocalFilter()
    {
        string q = _search.Trim();
        Items.Clear();
        foreach (var i in _hostMods.Where(i => q.Length == 0 || i.Name.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                                               i.Mod.Author.Contains(q, StringComparison.OrdinalIgnoreCase)))
            Add(i);
        Status = _hostMods.Count == 0 ? "Nexus Mods did not find those mods (they may have been removed)." : $"{_hostMods.Count} mod{(_hostMods.Count == 1 ? "" : "s")}.";
    }

    private void Add(NexusModItem item)
    {
        Items.Add(item);
        ApplyInstalled(item, InstalledByNexusId());
        item.Waiting = _main.NexusDownloads.IsWaitingFor(item.Mod.ModId);
        if (item.Thumbnail == null && item.Mod.ThumbnailUrl is { } url)
            _ = LoadThumbnailAsync(item, url);
    }

    private async Task LoadThumbnailAsync(NexusModItem item, string url)
    {
        var img = await Thumbnails.GetAsync(url, Path.Combine(_main.Paths.DataDir, "thumbnails"));
        if (img != null) item.Thumbnail = img;
    }

    /// <summary>Re-reads which Nexus mods are installed (after an install, uninstall or rescan).</summary>
    public void RefreshInstalled()
    {
        var installed = InstalledByNexusId();
        foreach (var i in Items) ApplyInstalled(i, installed);
    }

    public void RefreshWaiting()
    {
        foreach (var i in Items) i.Waiting = _main.NexusDownloads.IsWaitingFor(i.Mod.ModId);
    }

    private static void ApplyInstalled(NexusModItem item, IReadOnlyDictionary<int, InstalledMod> installed)
    {
        if (installed.TryGetValue(item.Mod.ModId, out var rec)) item.SetInstalled(true, rec.NexusVersion ?? rec.Version);
        else item.SetInstalled(false, null);
    }

    private IReadOnlyDictionary<int, InstalledMod> InstalledByNexusId()
    {
        if (_main.Game == null) return new Dictionary<int, InstalledMod>();
        try
        {
            return new ModManager(_main.Game, _main.Paths.InstalledManifestFile).Managed()
                .Where(m => m.NexusModId is > 0)
                .GroupBy(m => m.NexusModId!.Value)
                .ToDictionary(g => g.Key, g => g.OrderByDescending(m => m.InstalledAt).First());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new Dictionary<int, InstalledMod>();
        }
    }
}

/// <summary>Mod thumbnails from Nexus: fetched a few at a time, kept on disk and in memory, decoded small.</summary>
internal static class Thumbnails
{
    private static readonly HttpClient Http = CreateHttp();
    private static readonly SemaphoreSlim Gate = new(4);
    private static readonly ConcurrentDictionary<string, ImageSource> Memory = new();

    private static HttpClient CreateHttp()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd($"RewindTogetherLauncher/{AppInfo.Version}");
        return h;
    }

    public static async Task<ImageSource?> GetAsync(string url, string cacheDir)
    {
        if (Memory.TryGetValue(url, out var known)) return known;
        if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return null;
        string file = Path.Combine(cacheDir, Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(url)))[..20].ToLowerInvariant() + ".img");
        byte[]? bytes = null;
        try { if (File.Exists(file)) bytes = await File.ReadAllBytesAsync(file); }
        catch (IOException) { }
        if (bytes == null)
        {
            await Gate.WaitAsync();
            try
            {
                bytes = await Http.GetByteArrayAsync(url);
                Directory.CreateDirectory(cacheDir);
                await File.WriteAllBytesAsync(file, bytes);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException or UnauthorizedAccessException)
            {
                if (bytes == null) return null;
            }
            finally
            {
                Gate.Release();
            }
        }
        if (bytes == null) return null;
        byte[] data = bytes;
        try
        {
            var img = await Task.Run(() =>
            {
                var b = new BitmapImage();
                b.BeginInit();
                b.CacheOption = BitmapCacheOption.OnLoad;
                b.DecodePixelWidth = 320;
                b.StreamSource = new MemoryStream(data);
                b.EndInit();
                b.Freeze();
                return (ImageSource)b;
            });
            Memory[url] = img;
            return img;
        }
        catch (Exception ex) when (ex is NotSupportedException or ArgumentException or InvalidOperationException or IOException)
        {
            try { File.Delete(file); } catch { }
            return null;
        }
    }
}
