using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace RewindTogether.Launcher.Core;

public enum ModKind
{
    /// <summary>A UE4SS Lua (or C++) mod: ue4ss\Mods\&lt;folder&gt;\ plus a mods.txt line.</summary>
    Ue4ssLua,
    /// <summary>A content pak: Content\Paks\~mods\.</summary>
    Pak,
    /// <summary>A Blueprint mod loaded by BPModLoaderMod: Content\Paks\LogicMods\.</summary>
    LogicMod,
}

public static class ModKinds
{
    public static string ToWire(ModKind k) => k switch
    {
        ModKind.Ue4ssLua => "ue4ss-lua",
        ModKind.Pak => "pak",
        ModKind.LogicMod => "logicmod",
        _ => "ue4ss-lua",
    };

    public static bool TryParse(string? s, out ModKind kind)
    {
        switch ((s ?? "").Trim().ToLowerInvariant())
        {
            case "ue4ss-lua": case "ue4ss": case "lua": kind = ModKind.Ue4ssLua; return true;
            case "pak": kind = ModKind.Pak; return true;
            case "logicmod": case "logicmods": kind = ModKind.LogicMod; return true;
            default: kind = default; return false;
        }
    }

    public static string Describe(ModKind k) => k switch
    {
        ModKind.Ue4ssLua => "UE4SS script mod",
        ModKind.Pak => "Content mod (.pak)",
        ModKind.LogicMod => "Blueprint mod (LogicMods)",
        _ => "Mod",
    };
}

/// <summary>One mod in the catalog. Field names match the catalog JSON exactly.</summary>
public sealed class CatalogEntry
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("author")] public string Author { get; set; } = "";
    [JsonPropertyName("description")] public string Description { get; set; } = "";
    [JsonPropertyName("version")] public string Version { get; set; } = "";
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
    [JsonPropertyName("size")] public long? Size { get; set; }
    [JsonPropertyName("homepage")] public string Homepage { get; set; } = "";

    /// <summary>
    /// Optional extension: the UE4SS mod folder name, when it differs from the id
    /// (Rewind Together's id is "rewind-together" but its folder must be "RewindTogether").
    /// </summary>
    [JsonPropertyName("folder")] public string? Folder { get; set; }

    /// <summary>
    /// Set by the launcher (never read from JSON) when the mod ships next to the exe: install from
    /// this folder instead of downloading. See <see cref="BundledMod"/>.
    /// </summary>
    [JsonIgnore] public string? LocalPath { get; set; }

    [JsonIgnore] public ModKind Kind => ModKinds.TryParse(Type, out var k) ? k : ModKind.Ue4ssLua;
    [JsonIgnore] public bool IsDownloadable => Url.Length > 0;
    [JsonIgnore] public bool IsInstallable => LocalPath != null || IsDownloadable;
    [JsonIgnore] public bool IsBundled => LocalPath != null;
    [JsonIgnore] public string FolderName => string.IsNullOrWhiteSpace(Folder) ? Id : Folder!;
    [JsonIgnore] public bool IsRewindTogether => Id.Equals(GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase);
}

public sealed class Catalog
{
    public List<CatalogEntry> Mods { get; init; } = new();
    public List<string> Warnings { get; init; } = new();
    /// <summary>"built in", the URL it came from, or "saved copy of ...".</summary>
    public string Source { get; init; } = "";

    public CatalogEntry? Find(string id)
        => Mods.FirstOrDefault(m => m.Id.Equals(id, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Makes the bundled copy the install source for Rewind Together: its version replaces the
    /// catalog's, and installs come from its folder. Adds the entry if the catalog lacks it.
    /// </summary>
    public void ApplyBundled(BundledMod? bundled)
    {
        if (bundled == null) return;
        var rt = Find(GameInstall.RewindTogetherId);
        if (rt == null)
        {
            rt = new CatalogEntry
            {
                Id = GameInstall.RewindTogetherId,
                Name = "Rewind Together",
                Author = "Rewind Together team",
                Description = "Co-op multiplayer for Retro Rewind. Open your video store to friends over Steam - no port forwarding, no IP addresses.",
                Type = "ue4ss-lua",
                Folder = GameInstall.RewindTogetherFolder,
            };
            Mods.Insert(0, rt);
        }
        rt.Version = bundled.Version;
        rt.LocalPath = bundled.Folder;
    }
}

public static class CatalogParser
{
    private static readonly Regex IdRx = new(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", RegexOptions.Compiled);
    private static readonly Regex FolderRx = new(@"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", RegexOptions.Compiled);

    /// <summary>
    /// Parses a catalog: either { "mods": [ ... ] } or a bare array. A bad entry is skipped with a
    /// warning; it does not take the rest of the catalog down with it. Malformed JSON throws.
    /// </summary>
    public static Catalog Parse(string json, string source)
    {
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling = JsonCommentHandling.Skip,
        });

        JsonElement arr = doc.RootElement;
        if (arr.ValueKind == JsonValueKind.Object)
        {
            if (!arr.TryGetProperty("mods", out arr) || arr.ValueKind != JsonValueKind.Array)
                throw new FormatException("The catalog has no \"mods\" list.");
        }
        else if (arr.ValueKind != JsonValueKind.Array)
        {
            throw new FormatException("The catalog must be a JSON object with a \"mods\" list.");
        }

        var mods = new List<CatalogEntry>();
        var warnings = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int index = 0;
        foreach (var el in arr.EnumerateArray())
        {
            index++;
            CatalogEntry? e;
            try { e = el.Deserialize<CatalogEntry>(JsonDefaults.Pretty); }
            catch (JsonException ex) { warnings.Add($"Entry {index}: {ex.Message}"); continue; }
            if (e == null) continue;

            string? problem = Validate(e);
            if (problem != null) { warnings.Add($"Entry {index} ({(e.Id.Length > 0 ? e.Id : "no id")}): {problem}"); continue; }
            if (!seen.Add(e.Id)) { warnings.Add($"Entry {index}: duplicate id \"{e.Id}\" ignored."); continue; }
            e.Sha256 = Hashing.NormalizeSha256(e.Sha256);
            if (string.IsNullOrWhiteSpace(e.Name)) e.Name = e.Id;
            mods.Add(e);
        }
        return new Catalog { Mods = mods, Warnings = warnings, Source = source };
    }

    public static string? Validate(CatalogEntry e)
    {
        if (!IdRx.IsMatch(e.Id ?? "")) return "id must be 1-64 letters, digits, '.', '_' or '-'.";
        if (!ModKinds.TryParse(e.Type, out _)) return $"unknown type \"{e.Type}\" (expected ue4ss-lua, pak or logicmod).";
        if (string.IsNullOrWhiteSpace(e.Version)) return "version is missing.";
        if (e.Folder != null && !FolderRx.IsMatch(e.Folder)) return "folder must be a plain folder name.";
        if (!string.IsNullOrEmpty(e.Url))
        {
            if (!Uri.TryCreate(e.Url, UriKind.Absolute, out var u) || u.Scheme is not ("https" or "file"))
                return "url must be an https:// link.";
            if (!Hashing.IsSha256Hex(e.Sha256)) return "a downloadable entry needs a 64-character sha256.";
        }
        if (!string.IsNullOrEmpty(e.Homepage) &&
            (!Uri.TryCreate(e.Homepage, UriKind.Absolute, out var h) || h.Scheme is not ("https" or "http")))
            e.Homepage = "";
        return null;
    }

    /// <summary>The sample catalog compiled into the exe, so the Mods tab works offline.</summary>
    public static Catalog LoadEmbedded()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("RewindTogether.Launcher.catalog.json");
        if (s == null) return new Catalog { Source = "built in", Warnings = { "The built-in catalog is missing." } };
        using var r = new StreamReader(s);
        return Parse(r.ReadToEnd(), "built in");
    }
}
