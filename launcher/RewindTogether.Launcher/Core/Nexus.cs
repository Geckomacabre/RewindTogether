using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace RewindTogether.Launcher.Core;

/// <summary>One mod on Nexus Mods, as the browser shows it.</summary>
public sealed record NexusMod(
    int ModId, string Name, string Summary, string Version, string Author,
    long Downloads, long Endorsements, DateTime? UpdatedAt, string? ThumbnailUrl, bool Adult, string Category)
{
    public string PageUrl => NexusLinks.ModPage(ModId);
    public string FilesUrl => NexusLinks.FilesTab(ModId);
}

/// <summary>One file of a mod. <see cref="FileName"/> is the name a manual download gets.</summary>
public sealed record NexusFile(int ModId, int FileId, string FileName, string Name, string Version, string Category);

/// <summary>Which Nexus mod (and version) a package being installed is.</summary>
public sealed record NexusSource(int ModId, string Name, string Version);

/// <summary>One page of results, and how many there are in all.</summary>
public sealed record NexusPage(IReadOnlyList<NexusMod> Mods, int Total);

public enum NexusSort { Downloads, Updated, Endorsements, Newest }

public static class NexusLinks
{
    /// <summary>Retro Rewind - Video Store Simulator on Nexus Mods.</summary>
    public const string GameDomain = "retrorewindvideostoresimulator";
    public const int GameId = 8977;

    public static string GamePage => $"https://www.nexusmods.com/{GameDomain}";
    public static string ModPage(int modId) => $"{GamePage}/mods/{modId}";
    public static string FilesTab(int modId) => ModPage(modId) + "?tab=files";
    /// <summary>One file's download page (signing in first returns here): one click away from the download.</summary>
    public static string FileDownload(int modId, int fileId) => FilesTab(modId) + "&file_id=" + fileId;

    /// <summary>
    /// Where "Download" goes: the mod's one main file, straight to its download page. With several
    /// main files (variants) or none listed, the Files tab, where the player picks.
    /// </summary>
    public static string DownloadPage(int modId, IReadOnlyList<NexusFile> files)
    {
        var main = files.Where(f => f.Category.Equals("MAIN", StringComparison.OrdinalIgnoreCase) && f.FileId > 0).ToList();
        return main.Count == 1 ? FileDownload(modId, main[0].FileId) : FilesTab(modId);
    }
}

public sealed class NexusException : Exception
{
    public NexusException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>
/// Reads Nexus Mods' public GraphQL API (api.nexusmods.com/v2/graphql): listing, searching and
/// looking up Retro Rewind mods needs no account, so no key is sent or kept. Downloads stay on
/// the website: the player downloads there, and <see cref="NexusDownloadWatcher"/> picks the file
/// up. Every request names the app (Application-Name/-Version), as Nexus's API policy asks.
/// </summary>
public sealed class NexusClient
{
    public const string DefaultApiBase = "https://api.nexusmods.com";
    public const string ApplicationName = "Rewind Together";

    private static readonly HttpClient SharedHttp = new() { Timeout = TimeSpan.FromSeconds(20) };

    private readonly string _endpoint;
    private readonly HttpClient _http;

    public NexusClient(string? apiBase = null, HttpClient? http = null)
    {
        string b = string.IsNullOrWhiteSpace(apiBase) ? DefaultApiBase : apiBase.Trim().TrimEnd('/');
        if (!ReleaseFeed.IsAllowedUrl(b + "/v2/graphql"))
            throw new ArgumentException("The Nexus API address must be https (or http on this PC, for tests): " + b);
        _endpoint = b + "/v2/graphql";
        _http = http ?? SharedHttp;
    }

    private const string ModFields = "modId name summary version author downloads endorsements updatedAt thumbnailUrl adultContent category status";

    /// <summary>A page of the game's mods, optionally matching <paramref name="text"/>. Adult mods are left out unless asked for.</summary>
    public async Task<NexusPage> SearchAsync(string? text, NexusSort sort, bool includeAdult, int offset, int count, CancellationToken ct)
    {
        var filter = new JsonObject { ["gameDomainName"] = new JsonArray(new JsonObject { ["value"] = NexusLinks.GameDomain }) };
        if (!string.IsNullOrWhiteSpace(text))
            filter["nameStemmed"] = new JsonArray(new JsonObject { ["value"] = text.Trim(), ["op"] = "MATCHES" });
        if (!includeAdult)
            filter["adultContent"] = new JsonArray(new JsonObject { ["value"] = false });
        string sortField = sort switch
        {
            NexusSort.Updated => "updatedAt",
            NexusSort.Endorsements => "endorsements",
            NexusSort.Newest => "createdAt",
            _ => "downloads",
        };
        var vars = new JsonObject
        {
            ["filter"] = filter,
            ["sort"] = new JsonArray(new JsonObject { [sortField] = new JsonObject { ["direction"] = "DESC" } }),
            ["offset"] = Math.Max(0, offset),
            ["count"] = Math.Clamp(count, 1, 50),
        };
        var data = await QueryAsync(
            "query Browse($filter: ModsFilter, $sort: [ModsSort!], $offset: Int, $count: Int) " +
            "{ mods(filter: $filter, sort: $sort, offset: $offset, count: $count) { totalCount nodes { " + ModFields + " } } }", vars, ct);
        var mods = data["mods"];
        return new NexusPage(ReadMods(mods?["nodes"], includeAdult), (int?)mods?["totalCount"] ?? 0);
    }

    /// <summary>These mods, by id, in the order asked for (unknown or removed ones are left out).</summary>
    public async Task<IReadOnlyList<NexusMod>> ModsByIdAsync(IEnumerable<int> ids, CancellationToken ct)
    {
        var list = ids.Distinct().Take(50).ToList();
        if (list.Count == 0) return Array.Empty<NexusMod>();
        var arr = new JsonArray(list.Select(id => (JsonNode)new JsonObject { ["gameDomain"] = NexusLinks.GameDomain, ["modId"] = id }).ToArray());
        var data = await QueryAsync(
            "query ById($ids: [CompositeDomainWithIdInput!]!) { legacyModsByDomain(ids: $ids, count: 50) { nodes { " + ModFields + " } } }",
            new JsonObject { ["ids"] = arr }, ct);
        var found = ReadMods(data["legacyModsByDomain"]?["nodes"], includeAdult: true).ToDictionary(m => m.ModId);
        return list.Where(found.ContainsKey).Select(id => found[id]).ToList();
    }

    /// <summary>The files a mod offers (main, optional, old versions...).</summary>
    public async Task<IReadOnlyList<NexusFile>> FilesAsync(int modId, CancellationToken ct)
    {
        var data = await QueryAsync(
            "query Files($modId: ID!, $gameId: ID!) { modFiles(modId: $modId, gameId: $gameId) { fileId uri name version category } }",
            new JsonObject { ["modId"] = modId.ToString(), ["gameId"] = NexusLinks.GameId.ToString() }, ct);
        return (data["modFiles"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select(f => ReadFile(f, modId)).Where(f => f != null).Select(f => f!).ToList();
    }

    /// <summary>Which Retro Rewind mod file this is, from its MD5; null when Nexus does not know it (or it belongs to another game).</summary>
    public async Task<NexusFile?> FileByMd5Async(string md5, CancellationToken ct)
    {
        var data = await QueryAsync(
            "query Hash($md5: String!) { fileHash(md5: $md5) { gameId modFile { modId fileId uri name version category } } }",
            new JsonObject { ["md5"] = md5.Trim().ToLowerInvariant() }, ct);
        foreach (var hit in (data["fileHash"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            if ((int?)hit["gameId"] != NexusLinks.GameId || hit["modFile"] is not JsonObject f) continue;
            if (ReadFile(f, (int?)f["modId"] ?? 0) is { ModId: > 0 } file) return file;
        }
        return null;
    }

    private async Task<JsonObject> QueryAsync(string query, JsonObject variables, CancellationToken ct)
    {
        var body = new JsonObject { ["query"] = query, ["variables"] = variables };
        using var req = new HttpRequestMessage(HttpMethod.Post, _endpoint)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        req.Headers.TryAddWithoutValidation("Application-Name", ApplicationName);
        req.Headers.TryAddWithoutValidation("Application-Version", AppInfo.Version);
        req.Headers.UserAgent.ParseAdd($"RewindTogetherLauncher/{AppInfo.Version}");
        try
        {
            using var resp = await _http.SendAsync(req, ct);
            string text = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode)
                throw new NexusException((int)resp.StatusCode == 429
                    ? "Nexus Mods is busy (too many requests). Try again in a minute."
                    : $"Nexus Mods answered {(int)resp.StatusCode} {resp.ReasonPhrase}.");
            var root = JsonNode.Parse(text) as JsonObject ?? throw new NexusException("Nexus Mods sent something that is not JSON.");
            if (root["errors"] is JsonArray { Count: > 0 } errors)
                throw new NexusException("Nexus Mods refused the request: " + ((string?)errors[0]?["message"] ?? "unknown error"));
            return root["data"] as JsonObject ?? throw new NexusException("Nexus Mods sent no data.");
        }
        catch (HttpRequestException ex)
        {
            throw new NexusException("Could not reach Nexus Mods: " + ex.Message, ex);
        }
        catch (TaskCanceledException ex) when (!ct.IsCancellationRequested)
        {
            throw new NexusException("Nexus Mods did not answer in time.", ex);
        }
        catch (System.Text.Json.JsonException ex)
        {
            throw new NexusException("Nexus Mods sent something that is not JSON.", ex);
        }
    }

    private static List<NexusMod> ReadMods(JsonNode? nodes, bool includeAdult)
    {
        var list = new List<NexusMod>();
        foreach (var n in (nodes as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            int id = (int?)n["modId"] ?? 0;
            string status = (string?)n["status"] ?? "published";
            bool adult = (bool?)n["adultContent"] ?? false;
            if (id <= 0 || !status.Equals("published", StringComparison.OrdinalIgnoreCase) || (adult && !includeAdult)) continue;
            string? thumb = (string?)n["thumbnailUrl"];
            list.Add(new NexusMod(id,
                Clean((string?)n["name"]) is { Length: > 0 } name ? name : $"Mod {id}",
                Clean((string?)n["summary"]),
                Clean((string?)n["version"]),
                Clean((string?)n["author"]),
                Long(n["downloads"]), Long(n["endorsements"]),
                DateTime.TryParse((string?)n["updatedAt"], null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var u) ? u : null,
                thumb != null && thumb.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ? thumb : null,
                adult,
                Clean((string?)n["category"])));
        }
        return list;
    }

    private static NexusFile? ReadFile(JsonObject f, int modId)
    {
        string uri = Clean((string?)f["uri"]);
        int fileId = (int?)f["fileId"] ?? 0;
        if (uri.Length == 0 && fileId == 0) return null;
        return new NexusFile(modId, fileId, uri, Clean((string?)f["name"]), Clean((string?)f["version"]), Clean((string?)f["category"]));
    }

    private static long Long(JsonNode? n)
    {
        try { return n?.GetValue<long>() ?? 0; }
        catch (Exception) { return long.TryParse(n?.ToString(), out long v) ? v : 0; }
    }

    /// <summary>Nexus text can carry HTML entities and stray whitespace.</summary>
    private static string Clean(string? s) => System.Net.WebUtility.HtmlDecode(s ?? "").Trim();
}

/// <summary>What Nexus's download file names look like: "Real VHS-97-1-2-0-1777574324.zip".</summary>
public static class NexusFileName
{
    public static readonly string[] ArchiveExtensions = { ".zip", ".7z", ".rar" };

    // name - modId - version parts - upload time (unix seconds) . extension
    private static readonly Regex Pattern = new(@"-\d+(?:-[0-9A-Za-z]+)*-\d{9,11}\.(?:zip|7z|rar)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex BrowserCopy = new(@" \(\d+\)(?=\.[^.]+$)", RegexOptions.Compiled);

    /// <summary>Does this look like a file downloaded from Nexus Mods (by name alone)?</summary>
    public static bool LooksLikeNexusDownload(string fileName) => Pattern.IsMatch(WithoutCopySuffix(Path.GetFileName(fileName)));

    /// <summary>"Real VHS-97-1-2-0-1777574324 (1).zip" → "Real VHS-97-1-2-0-1777574324.zip": browsers number a second download.</summary>
    public static string WithoutCopySuffix(string fileName) => BrowserCopy.Replace(fileName, "");

    /// <summary>Could this file be one of <paramref name="modId"/>'s? (The id appears as its own dash-separated part.)</summary>
    public static bool MentionsMod(string fileName, int modId) =>
        LooksLikeNexusDownload(fileName) && WithoutCopySuffix(Path.GetFileName(fileName)).Contains($"-{modId}-", StringComparison.Ordinal);
}
