using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RewindTogether.Launcher.Core;

public static class JsonDefaults
{
    /// <summary>Indented, camelCase, raw UTF-8 (no \u escapes for accented names).</summary>
    public static readonly JsonSerializerOptions Pretty = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static readonly JsonSerializerOptions Compact = new(Pretty) { WriteIndented = false };
}

/// <summary>%APPDATA%\RewindTogether\launcher.json</summary>
public sealed class LauncherSettings
{
    /// <summary>
    /// The catalog the Mods tab reads. Empty = only the catalog built into the launcher.
    /// Set this to a hosted catalog.json (for example a raw GitHub URL) once one is published.
    /// </summary>
    public const string DefaultCatalogUrl = "";

    /// <summary>Manual "Browse..." override: the Retro Rewind install folder (the one containing RetroRewind\Binaries).</summary>
    public string? GameRoot { get; set; }

    public string CatalogUrl { get; set; } = DefaultCatalogUrl;

    /// <summary>Host side: only relay traffic for people on your Steam friends list.</summary>
    public bool HostFriendsOnly { get; set; } = true;

    public int MaxGuests { get; set; } = 7;

    /// <summary>The game's listen-server port (27015 on this build, see LAUNCHER_CONTRACT.md §4).</summary>
    public int HostGamePort { get; set; } = 27015;

    /// <summary>The guest-side tunnel's loopback port (LAUNCHER_CONTRACT.md §4).</summary>
    public int GuestTunnelPort { get; set; } = 27016;

    public bool BackupSavesBeforeInstall { get; set; } = true;

    public string? LastJoinAddress { get; set; }
    public string? LastJoinSteamId { get; set; }

    public static LauncherSettings Load(string path)
    {
        try
        {
            string? text = AtomicFile.TryReadShared(path);
            if (string.IsNullOrWhiteSpace(text)) return new LauncherSettings();
            var s = JsonSerializer.Deserialize<LauncherSettings>(text, JsonDefaults.Pretty) ?? new LauncherSettings();
            s.Sanitize();
            return s;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.json could not be read ({ex.Message}); using defaults.");
            return new LauncherSettings();
        }
    }

    public void Save(string path)
    {
        Sanitize();
        AtomicFile.WriteAllText(path, JsonSerializer.Serialize(this, JsonDefaults.Pretty));
    }

    private void Sanitize()
    {
        if (HostGamePort is < 1 or > 65535) HostGamePort = 27015;
        if (GuestTunnelPort is < 1 or > 65535) GuestTunnelPort = 27016;
        if (MaxGuests is < 1 or > 16) MaxGuests = 7;
        CatalogUrl ??= "";
    }
}
