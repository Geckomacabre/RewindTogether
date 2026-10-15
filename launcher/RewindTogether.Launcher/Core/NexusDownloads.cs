using System.Runtime.InteropServices;

namespace RewindTogether.Launcher.Core;

/// <summary>A mod the player went to Nexus to download, with the file names its downloads can have.</summary>
public sealed record NexusWanted(NexusMod Mod, IReadOnlyList<NexusFile> Files, DateTime SinceUtc);

/// <summary>A finished download of a wanted mod. <see cref="File"/> is null when only the name pattern matched.</summary>
public sealed record NexusDownloadMatch(string Path, NexusMod Mod, NexusFile? File)
{
    /// <summary>The version to record: the file's own, else the mod's.</summary>
    public string Version => File?.Version is { Length: > 0 } v ? v : Mod.Version;
}

/// <summary>
/// "Get it on Nexus" opens the mod's Files page; the player downloads there as usual (a free
/// Nexus account is enough), and this notices the file landing in their Downloads folder.
/// A file counts when its name is one of the mod's files on Nexus (a browser's " (1)" copy too)
/// or follows Nexus's "Name-modId-version-time.zip" pattern with that mod's id, it appeared after
/// the click, and it has finished downloading: not empty, the same size twice in a row, and no
/// other program writing to it (browsers write to .crdownload/.part files, or into the final
/// name, until they are done). Each file is reported once, and a wanted mod stops being waited
/// for once its file is found, or after a couple of hours.
/// </summary>
public sealed class NexusDownloadWatcher
{
    private readonly Func<DateTime> _clock;
    private readonly TimeSpan _keepWaiting;
    private readonly Dictionary<int, NexusWanted> _wanted = new();
    private readonly Dictionary<string, long> _sizeSeen = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _reported = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _gate = new();

    public NexusDownloadWatcher(string folder, TimeSpan? keepWaiting = null, Func<DateTime>? clock = null)
    {
        Folder = folder;
        _keepWaiting = keepWaiting ?? TimeSpan.FromHours(2);
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    public string Folder { get; }

    public bool IsWaiting { get { lock (_gate) return _wanted.Count > 0; } }
    public bool IsWaitingFor(int modId) { lock (_gate) return _wanted.ContainsKey(modId); }

    /// <summary>Wait for a download of <paramref name="mod"/> (replacing an earlier wait for it).</summary>
    public void Want(NexusMod mod, IReadOnlyList<NexusFile> files)
    {
        lock (_gate) _wanted[mod.ModId] = new NexusWanted(mod, files, _clock());
    }

    public void Forget(int modId)
    {
        lock (_gate) _wanted.Remove(modId);
    }

    /// <summary>Finished downloads of wanted mods that have appeared since the last call.</summary>
    public IReadOnlyList<NexusDownloadMatch> Poll()
    {
        lock (_gate)
        {
            DateTime now = _clock();
            foreach (var old in _wanted.Values.Where(w => now - w.SinceUtc > _keepWaiting).ToList())
            {
                Log.Info($"Stopped waiting for a download of {old.Mod.Name}.");
                _wanted.Remove(old.Mod.ModId);
            }
            if (_wanted.Count == 0) { _sizeSeen.Clear(); return Array.Empty<NexusDownloadMatch>(); }

            DateTime since = _wanted.Values.Min(w => w.SinceUtc) - TimeSpan.FromSeconds(5);   // clock and file-time slack
            var found = new List<NexusDownloadMatch>();
            IEnumerable<FileInfo> files;
            try
            {
                files = new DirectoryInfo(Folder).EnumerateFiles().Where(f =>
                    NexusFileName.ArchiveExtensions.Contains(f.Extension, StringComparer.OrdinalIgnoreCase) &&
                    !_reported.Contains(f.FullName) &&
                    (f.LastWriteTimeUtc >= since || f.CreationTimeUtc >= since)).ToList();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return found;
            }

            foreach (var f in files)
            {
                var match = Match(f.Name);
                if (match == null || !Finished(f)) continue;
                _reported.Add(f.FullName);
                _sizeSeen.Remove(f.FullName);
                _wanted.Remove(match.Value.Wanted.Mod.ModId);
                found.Add(new NexusDownloadMatch(f.FullName, match.Value.Wanted.Mod, match.Value.File));
            }
            return found;
        }
    }

    private (NexusWanted Wanted, NexusFile? File)? Match(string fileName)
    {
        string name = NexusFileName.WithoutCopySuffix(fileName);
        foreach (var w in _wanted.Values)
            if (w.Files.FirstOrDefault(f => f.FileName.Equals(name, StringComparison.OrdinalIgnoreCase)) is { } file)
                return (w, file);
        // A file uploaded after the list was read: the name pattern with the mod's id, if only one wanted mod fits.
        var byPattern = _wanted.Values.Where(w => NexusFileName.MentionsMod(name, w.Mod.ModId)).ToList();
        return byPattern.Count == 1 ? (byPattern[0], null) : null;
    }

    /// <summary>Not empty, the same size as last time, and nothing is writing to it.</summary>
    private bool Finished(FileInfo f)
    {
        long size;
        try { f.Refresh(); size = f.Length; }
        catch (IOException) { return false; }
        if (size <= 0) return false;
        bool steady = _sizeSeen.TryGetValue(f.FullName, out long before) && before == size;
        _sizeSeen[f.FullName] = size;
        if (!steady) return false;
        try
        {
            using var s = new FileStream(f.FullName, FileMode.Open, FileAccess.Read, FileShare.Read);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}

/// <summary>The player's Downloads folder, wherever they moved it.</summary>
public static class DownloadsFolder
{
    private static readonly Guid FolderIdDownloads = new("374DE290-123F-4565-9164-39C4925E467B");

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);

    public static string Find()
    {
        try
        {
            if (SHGetKnownFolderPath(FolderIdDownloads, 0, IntPtr.Zero, out IntPtr p) == 0)
            {
                try
                {
                    string? path = Marshal.PtrToStringUni(p);
                    if (!string.IsNullOrWhiteSpace(path)) return path;
                }
                finally
                {
                    Marshal.FreeCoTaskMem(p);
                }
            }
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException) { }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }
}
