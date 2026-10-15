using System.Globalization;
using System.IO.Compression;

namespace RewindTogether.Launcher.Core;

public sealed record BackupResult(bool Created, string? ZipPath, string Message);

/// <summary>
/// Zips %LOCALAPPDATA%\RetroRewind\Saved\SaveGames into Documents\RewindTogether Backups before
/// anything is installed. Old backups are never deleted.
/// </summary>
public static class SaveBackup
{
    private const string Prefix = "SaveGames-";
    private const string Stamp = "yyyyMMdd-HHmmss";

    /// <param name="force">Back up even if nothing changed since the newest backup.</param>
    public static BackupResult Run(string saveGamesDir, string backupsDir, bool force, DateTime? now = null)
    {
        if (!Directory.Exists(saveGamesDir))
            return new BackupResult(false, null, "No Retro Rewind saves were found on this PC, so there was nothing to back up.");

        var saves = Directory.EnumerateFiles(saveGamesDir, "*", SearchOption.AllDirectories).ToList();
        if (saves.Count == 0)
            return new BackupResult(false, null, "The save folder is empty, so there was nothing to back up.");

        DateTime newestSave = saves.Max(File.GetLastWriteTimeUtc);
        var latest = LatestBackup(backupsDir);
        if (!force && latest != null && File.GetLastWriteTimeUtc(latest) >= newestSave)
            return new BackupResult(false, latest, "Your saves have not changed since the last backup.");

        Directory.CreateDirectory(backupsDir);
        DateTime t = now ?? DateTime.Now;
        string zipPath = Path.Combine(backupsDir, Prefix + t.ToString(Stamp, CultureInfo.InvariantCulture) + ".zip");
        for (int i = 2; File.Exists(zipPath); i++)
            zipPath = Path.Combine(backupsDir, $"{Prefix}{t.ToString(Stamp, CultureInfo.InvariantCulture)}-{i}.zip");

        string tmp = zipPath + ".tmp";
        try
        {
            using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write))
            using (var zip = new ZipArchive(fs, ZipArchiveMode.Create))
            {
                foreach (string file in saves)
                {
                    string rel = Path.Combine("SaveGames", Path.GetRelativePath(saveGamesDir, file)).Replace('\\', '/');
                    var entry = zip.CreateEntry(rel, CompressionLevel.Optimal);
                    entry.LastWriteTime = File.GetLastWriteTime(file);
                    // The game may have a save open; share everything so we can still read it.
                    using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var output = entry.Open();
                    input.CopyTo(output);
                }
            }
            File.Move(tmp, zipPath);
        }
        catch (Exception ex)
        {
            try { File.Delete(tmp); } catch { }
            Log.Error("Save backup failed", ex);
            return new BackupResult(false, null, $"Your saves could not be backed up: {ex.Message}");
        }

        Log.Info($"Backed up {saves.Count} save file(s) to {zipPath}");
        return new BackupResult(true, zipPath, $"Backed up {saves.Count} save file(s) to {zipPath}.");
    }

    public static string? LatestBackup(string backupsDir)
    {
        if (!Directory.Exists(backupsDir)) return null;
        return Directory.EnumerateFiles(backupsDir, Prefix + "*.zip")
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
    }
}
