namespace RewindTogether.Launcher.Core;

/// <summary>
/// Where the launcher keeps its own files. Everything lives in the user's profile, never next
/// to the exe (which may be in Downloads, on a read-only share, or inside a Vortex staging folder).
/// </summary>
public sealed class AppPaths
{
    public AppPaths(string? dataDirOverride = null)
    {
        DataDir = string.IsNullOrWhiteSpace(dataDirOverride)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RewindTogether")
            : Path.GetFullPath(dataDirOverride);

        string docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        BackupsDir = string.IsNullOrWhiteSpace(dataDirOverride)
            ? Path.Combine(docs, "RewindTogether Backups")
            : Path.Combine(DataDir, "Backups");

        SaveGamesDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RetroRewind", "Saved", "SaveGames");
    }

    /// <summary>%APPDATA%\RewindTogether (or the --data-dir override).</summary>
    public string DataDir { get; }

    /// <summary>Documents\RewindTogether Backups.</summary>
    public string BackupsDir { get; }

    /// <summary>%LOCALAPPDATA%\RetroRewind\Saved\SaveGames.</summary>
    public string SaveGamesDir { get; }

    public string SettingsFile => Path.Combine(DataDir, "launcher.json");
    public string InstalledManifestFile => Path.Combine(DataDir, "installed.json");
    public string LogFile => Path.Combine(DataDir, "launcher.log");
    public string AgentLogFile => Path.Combine(DataDir, "steam-agent.log");
    public string DownloadsDir => Path.Combine(DataDir, "downloads");
    public string CatalogCacheFile => Path.Combine(DataDir, "catalog-cache.json");

    public void EnsureCreated() => Directory.CreateDirectory(DataDir);
}
