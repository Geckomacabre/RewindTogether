using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace RewindTogether.Launcher.Core;

/// <summary>A published release the launcher can update its own folder to.</summary>
public sealed record ReleaseInfo(
    string Version, string Tag, string ZipName, string ZipUrl, long ZipSize,
    string? Sha256, string? Sha256Url, string PageUrl);

public sealed class UpdateException : Exception
{
    public UpdateException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>
/// Reads GitHub's "latest release" for the project. Releases, not commits: a commit holds
/// source, a release holds the built zip (launcher + mod + UE4SS) that the launcher installs.
/// </summary>
public static class ReleaseFeed
{
    public const string DefaultRepo = "Geckomacabre/RewindTogether";
    public const string DefaultApiBase = "https://api.github.com";

    /// <summary>The release zip out of GitHub's release JSON, or null when it has none usable.</summary>
    public static ReleaseInfo? Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var r = doc.RootElement;
        if (Bool(r, "draft") || Bool(r, "prerelease")) return null;
        string tag = Str(r, "tag_name") ?? "";
        string version = tag.TrimStart('v', 'V').Trim();
        if (version.Length == 0) return null;
        if (!r.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;

        JsonElement? zip = null;
        foreach (var a in assets.EnumerateArray())
            if (Str(a, "name") is string n && IsReleaseZip(n) && Str(a, "browser_download_url") != null) { zip = a; break; }
        if (zip is not { } z) return null;

        string zipName = Str(z, "name")!;
        string? shaUrl = null;
        foreach (var a in assets.EnumerateArray())
            if (string.Equals(Str(a, "name"), zipName + ".sha256", StringComparison.OrdinalIgnoreCase))
                shaUrl = Str(a, "browser_download_url");

        // GitHub publishes a sha256 for every release asset ("digest": "sha256:...").
        string? digest = Str(z, "digest") is string d && Hashing.IsSha256Hex(d) ? Hashing.NormalizeSha256(d) : null;
        long size = z.TryGetProperty("size", out var s) && s.TryGetInt64(out long sz) ? sz : 0;
        return new ReleaseInfo(version, tag, zipName, Str(z, "browser_download_url")!, size, digest, shaUrl,
            Str(r, "html_url") ?? "");
    }

    public static bool IsReleaseZip(string name) =>
        name.StartsWith("RewindTogether-", StringComparison.OrdinalIgnoreCase) &&
        name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);

    /// <summary>The hash out of a "&lt;sha256&gt;  file.zip" checksum file.</summary>
    public static string? ParseSha256File(string text)
    {
        foreach (string token in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            if (Hashing.IsSha256Hex(token)) return Hashing.NormalizeSha256(token);
        return null;
    }

    /// <summary>https anywhere; plain http only to this PC (the tests' fake release server).</summary>
    public static bool IsAllowedUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) &&
        (u.Scheme == Uri.UriSchemeHttps || (u.Scheme == Uri.UriSchemeHttp && u.IsLoopback));

    private static string? Str(JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static bool Bool(JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}

public sealed class UpdateChecker
{
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        c.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RewindTogetherLauncher", AppInfo.Version));
        c.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return c;
    }

    /// <summary>The latest release, or null when the project has none yet.</summary>
    public async Task<ReleaseInfo?> LatestAsync(string apiBase, string repo, CancellationToken ct)
    {
        string url = $"{apiBase.TrimEnd('/')}/repos/{repo.Trim('/')}/releases/latest";
        if (!ReleaseFeed.IsAllowedUrl(url)) throw new UpdateException($"\"{url}\" is not an https address.");
        try
        {
            using var resp = await Http.GetAsync(url, ct);
            if (resp.StatusCode == HttpStatusCode.NotFound) return null;
            if (!resp.IsSuccessStatusCode)
                throw new UpdateException(resp.StatusCode == HttpStatusCode.Forbidden
                    ? "GitHub is limiting how often this PC can check for updates. Try again in an hour."
                    : $"GitHub answered \"{(int)resp.StatusCode} {resp.ReasonPhrase}\".");
            var release = ReleaseFeed.Parse(await resp.Content.ReadAsStringAsync(ct));
            if (release is { Sha256: null, Sha256Url: string shaUrl } && ReleaseFeed.IsAllowedUrl(shaUrl))
                release = release with { Sha256 = ReleaseFeed.ParseSha256File(await Http.GetStringAsync(shaUrl, ct)) };
            return release;
        }
        catch (HttpRequestException ex)
        {
            throw new UpdateException("Could not reach GitHub. Check that you are online.", ex);
        }
        catch (TaskCanceledException ex) when (!ct.IsCancellationRequested)
        {
            throw new UpdateException("GitHub did not answer in time.", ex);
        }
        catch (JsonException ex)
        {
            throw new UpdateException("GitHub's answer could not be read.", ex);
        }
    }
}

/// <summary>
/// Replaces the launcher's own folder with a newer release:
///
///   1. download the release zip into &lt;folder&gt;\.rt-update and check its sha256;
///   2. unpack it there and check it really is a Rewind Together release of that version;
///   3. move each item it contains into place, the old one aside first - the running exe
///      included, which Windows allows to be renamed, though not deleted. Anything that fails
///      puts every moved item back.
///
/// The new launcher is then started with --after-update; it waits for this one to exit,
/// deletes .rt-update (the old exe with it) and installs the bundled mod update as it does for
/// any newer zip. Files of the player's own in the folder are not touched.
/// </summary>
public sealed class UpdateInstaller
{
    public const string WorkFolderName = ".rt-update";
    public const string ExeName = "RewindTogetherLauncher.exe";

    private readonly string _appDir;
    private readonly IDownloader _downloader;

    public UpdateInstaller(string appDir, IDownloader downloader)
    {
        _appDir = Path.GetFullPath(appDir);
        _downloader = downloader;
    }

    public string WorkDir => Path.Combine(_appDir, WorkFolderName);

    /// <summary>Can the launcher write next to itself? (Not when it was unpacked into Program Files.)</summary>
    public static bool CanWrite(string appDir)
    {
        try
        {
            string probe = Path.Combine(appDir, $".rt-write-test-{Environment.ProcessId}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    /// <summary>Downloads, checks and unpacks the release. Returns the folder holding its files.</summary>
    public async Task<string> PrepareAsync(ReleaseInfo release, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        if (release.Sha256 == null)
            throw new UpdateException("This release has no published checksum, so it is not installed automatically. Download it from the release page instead.");
        if (!ReleaseFeed.IsAllowedUrl(release.ZipUrl))
            throw new UpdateException($"\"{release.ZipUrl}\" is not an https address.");

        CleanUp(_appDir);
        Directory.CreateDirectory(WorkDir);
        string zip = Path.Combine(WorkDir, Path.GetFileName(release.ZipName));
        await _downloader.DownloadAsync(release.ZipUrl, zip, release.Sha256, release.ZipSize > 0 ? release.ZipSize : null, progress, ct);

        string unpacked = Path.Combine(WorkDir, "new");
        try
        {
            // Refuses entries that would land outside the folder.
            ZipFile.ExtractToDirectory(zip, unpacked);
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException)
        {
            throw new UpdateException("The downloaded release could not be unpacked: " + ex.Message, ex);
        }
        finally
        {
            TryDeleteFile(zip);
        }

        // The zip holds one folder, RewindTogether-<version>\, with the release inside it.
        var top = new DirectoryInfo(unpacked).GetFileSystemInfos();
        string root = top.Length == 1 && top[0] is DirectoryInfo only ? only.FullName : unpacked;

        if (!File.Exists(Path.Combine(root, ExeName)))
            throw new UpdateException($"The downloaded release has no {ExeName} in it.");
        var mod = BundledMod.Find(root)
                  ?? throw new UpdateException("The downloaded release has no complete Rewind Together mod in it.");
        if (VersionCompare.Compare(mod.Version, release.Version) != 0)
            throw new UpdateException($"The downloaded release says it is version {mod.Version}, not {release.Version}.");
        return root;
    }

    /// <summary>Moves the release's files into the launcher's folder. All or nothing.</summary>
    public void Install(string root)
    {
        string aside = Path.Combine(WorkDir, "old");
        Directory.CreateDirectory(aside);
        var setAside = new List<string>();   // names moved from the app folder to "old"
        var placed = new List<string>();     // names moved from the release into the app folder
        try
        {
            foreach (var item in new DirectoryInfo(root).GetFileSystemInfos())
            {
                string target = Path.Combine(_appDir, item.Name);
                if (Exists(target))
                {
                    Move(target, Path.Combine(aside, item.Name));
                    setAside.Add(item.Name);
                }
                Move(item.FullName, target);
                placed.Add(item.Name);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            foreach (string name in placed) TryMove(Path.Combine(_appDir, name), Path.Combine(root, name));
            foreach (string name in setAside) TryMove(Path.Combine(aside, name), Path.Combine(_appDir, name));
            throw new UpdateException(
                "The new version could not be put in place, so the launcher was left as it was. " +
                "If the game or another program has a file from this folder open, close it and try again. (" + ex.Message + ")", ex);
        }
    }

    /// <summary>Starts the launcher that now sits in the folder, telling it to wait for this one.</summary>
    public Process? StartNewLauncher(string fromVersion, IEnumerable<string> keepArgs)
    {
        var psi = new ProcessStartInfo(Path.Combine(_appDir, ExeName))
        {
            UseShellExecute = false,
            WorkingDirectory = _appDir,
        };
        psi.ArgumentList.Add("--after-update");
        psi.ArgumentList.Add(Environment.ProcessId.ToString());
        psi.ArgumentList.Add("--updated-from");
        psi.ArgumentList.Add(fromVersion);
        foreach (string a in keepArgs) psi.ArgumentList.Add(a);   // --data-dir / --game-dir
        return Process.Start(psi);
    }

    /// <summary>Removes what an update left behind (the old exe among it). Quiet on failure.</summary>
    public static void CleanUp(string appDir)
    {
        string work = Path.Combine(appDir, WorkFolderName);
        // Windows can hold an exe for a moment after its process exits, so the old launcher may
        // not be deletable straight away. A few short tries; anything left goes next start.
        for (int attempt = 1; Directory.Exists(work); attempt++)
        {
            try
            {
                Directory.Delete(work, recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                if (attempt >= 10)
                {
                    Log.Warn($"Could not remove {work} yet: {ex.Message}");
                    return;
                }
                Thread.Sleep(150);
            }
        }
    }

    /// <summary>Waits for the launcher that started us to exit (it is closing to make room).</summary>
    public static void WaitForExit(int pid, TimeSpan timeout)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            if (!p.WaitForExit(timeout)) Log.Warn($"The previous launcher (pid {pid}) is still running after the update.");
        }
        catch (ArgumentException) { }          // already gone
        catch (InvalidOperationException) { }
    }

    private static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    /// <summary>
    /// A rename, retried for up to two seconds: an antivirus scan or the search indexer can hold
    /// a file briefly. MEASURED in the tests: renaming a freshly written, running exe failed
    /// about one time in eight with "being used by another process", and a retry went through.
    /// </summary>
    private static void Move(string from, string to)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                if (Directory.Exists(from)) Directory.Move(from, to);
                else File.Move(from, to);
                return;
            }
            catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && attempt < 10 && Exists(from))
            {
                Thread.Sleep(200);
            }
        }
    }

    private static void TryMove(string from, string to)
    {
        try { if (Exists(from) && !Exists(to)) Move(from, to); }
        catch (Exception ex) { Log.Error($"Rolling back the update: could not move {from} back", ex); }
    }

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
