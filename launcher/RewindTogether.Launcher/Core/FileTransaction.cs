namespace RewindTogether.Launcher.Core;

/// <summary>
/// The game has files of ours open - in practice, a running Retro Rewind keeps
/// native\RewindNative.dll loaded (the DLL pins itself), and UE4SS.dll too. The message is the one
/// a player can act on.
/// </summary>
public sealed class GameFilesLockedException : ModInstallException
{
    /// <param name="retry">What to do after closing the game, e.g. "press Install again".</param>
    /// <param name="file">The file found in use, for the log and the curious; may be null.</param>
    public GameFilesLockedException(string retry, string? file, Exception? inner = null)
        : base($"Close Retro Rewind first, then {retry}." + (file != null ? $" (The game is using {Path.GetFileName(file)}.)" : ""), inner)
    {
        File = file;
    }

    public string? File { get; }
}

/// <summary>
/// All-or-nothing file changes inside one game install.
///
/// New content is copied into a staging folder first, then swapped in with renames; whatever it
/// replaces is moved aside, not deleted, until the whole change has succeeded. If any step fails,
/// every completed rename is undone, so the previous install is left exactly as it was - never
/// half old, half new.
///
/// Staging lives in &lt;game&gt;\RetroRewind\.rt-launcher-staging\, on the same volume as both
/// ue4ss\Mods and Content\Paks (so every swap is a plain rename) and outside every folder the
/// game, UE4SS or the pak loader scans.
///
/// WHY PROBE FOR OPEN FILES FIRST, rather than just trying: measured on Windows 11, a folder that
/// contains a LOADED dll can still be renamed. A running game would therefore not stop the swap:
/// the new copy would land while the game kept the old DLL mapped from the staging folder, which
/// then could not be deleted. A loaded dll does refuse an exclusive read/write open (sharing
/// violation 0x80070020) and deletion (access denied), and a file held open by a reader blocks a
/// folder rename. Probing every file we are about to replace with an exclusive open catches both
/// before anything is touched (<see cref="FindFileInUse"/>).
///
/// A journal of "moved aside" items lets the next run put an old copy back if the launcher was
/// killed between the two renames of a swap (<see cref="CleanupStale"/>).
/// </summary>
public sealed class FileTransaction : IDisposable
{
    public const string StagingFolderName = ".rt-launcher-staging";
    private const string JournalName = "journal.txt";

    private readonly string _root;
    private readonly List<(string From, string To, bool IsDir)> _moves = new();
    private int _counter;
    private bool _completed;

    public FileTransaction(GameInstall game)
    {
        StagingRoot = Path.Combine(game.ProjectDir, StagingFolderName);
        _root = Path.Combine(StagingRoot, DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6]);
        Directory.CreateDirectory(_root);
    }

    /// <summary>For tests: called before every rename; throw from it to simulate a failure.</summary>
    internal Action<string, string>? BeforeMove { get; set; }

    public string StagingRoot { get; }
    public string Folder => _root;

    /// <summary>A path inside staging to build new content in.</summary>
    public string NewStagingPath(params string[] parts)
        => Path.Combine(new[] { _root, "new" }.Concat(parts).ToArray());

    /// <summary>Puts <paramref name="staged"/> (a folder) at <paramref name="target"/>, moving any existing folder aside.</summary>
    public void ReplaceDirectory(string target, string staged)
    {
        if (Directory.Exists(target)) MoveAside(target, isDir: true);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        Move(staged, target, isDir: true);
    }

    /// <summary>Puts <paramref name="staged"/> (a file) at <paramref name="target"/>, moving any existing file aside.</summary>
    public void ReplaceFile(string target, string staged)
    {
        if (File.Exists(target)) MoveAside(target, isDir: false);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        Move(staged, target, isDir: false);
    }

    /// <summary>Moves a folder out of the game; it is deleted when the transaction completes.</summary>
    public void RemoveDirectory(string target)
    {
        if (Directory.Exists(target)) MoveAside(target, isDir: true);
    }

    public void RemoveFile(string target)
    {
        if (File.Exists(target)) MoveAside(target, isDir: false);
    }

    /// <summary>Undoes every rename, newest first. Returns how many could not be undone.</summary>
    public int Rollback()
    {
        int failed = 0;
        for (int i = _moves.Count - 1; i >= 0; i--)
        {
            var (from, to, isDir) = _moves[i];
            try
            {
                if (isDir) Directory.Move(to, from);
                else File.Move(to, from);
            }
            catch (Exception ex)
            {
                failed++;
                Log.Error($"Could not undo the move {from} -> {to}", ex);
            }
        }
        _moves.Clear();
        if (failed > 0) Log.Error($"Rollback left {failed} item(s) in {_root}; they are kept there, not deleted.");
        return failed;
    }

    /// <summary>The change succeeded: what was moved aside can go.</summary>
    public void Complete() => _completed = true;

    /// <summary>
    /// Deletes the staging folder when that is safe: after <see cref="Complete"/>, or after a full
    /// rollback. If a rollback could not finish, staging may hold the only copy of something, so
    /// it is kept (and <see cref="CleanupStale"/> tries to put it back later).
    /// </summary>
    public void Dispose()
    {
        bool safe = _completed || _moves.Count == 0 || Rollback() == 0;
        if (safe) DeleteTree(_root);
        try
        {
            if (Directory.Exists(StagingRoot) && !Directory.EnumerateFileSystemEntries(StagingRoot).Any())
                Directory.Delete(StagingRoot);
        }
        catch { }
    }

    private void MoveAside(string original, bool isDir)
    {
        string aside = Path.Combine(_root, "old", (++_counter).ToString(), Path.GetFileName(original));
        // Journal first, so an interrupted run can still find the old copy.
        File.AppendAllText(Path.Combine(_root, JournalName), $"{(isDir ? "D" : "F")}\t{original}\t{aside}{Environment.NewLine}");
        Move(original, aside, isDir);
    }

    private void Move(string from, string to, bool isDir)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(to)!);
        BeforeMove?.Invoke(from, to);
        if (isDir) Directory.Move(from, to);
        else File.Move(from, to);
        _moves.Add((from, to, isDir));
    }

    // ------------------------------------------------------------------ helpers

    /// <summary>
    /// The first file under <paramref name="paths"/> (files or folders) that another process has
    /// open, or null. Uses an exclusive read/write open, which a loaded DLL or an open file refuses.
    /// Nothing is written.
    /// </summary>
    public static string? FindFileInUse(IEnumerable<string> paths)
    {
        foreach (string p in paths)
        {
            IEnumerable<string> files = Directory.Exists(p)
                ? SafeEnumerate(p)
                : File.Exists(p) ? new[] { p } : Array.Empty<string>();
            foreach (string f in files)
            {
                try
                {
                    using var fs = new FileStream(f, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                }
                catch (IOException ex) when (IsInUse(ex))
                {
                    return f;
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException)
                {
                    // read-only or no permission: not "in use"; the rename step reports it if it matters
                }
            }
        }
        return null;
    }

    /// <summary>ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION or ERROR_USER_MAPPED_FILE.</summary>
    public static bool IsInUse(Exception ex) => ex is IOException && (ex.HResult & 0xFFFF) is 32 or 33 or 1224;

    /// <summary>Deletes a folder tree, clearing read-only flags; leaves it (logged) if something is still in use.</summary>
    public static void DeleteTree(string dir)
    {
        if (!Directory.Exists(dir)) return;
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                Directory.Delete(dir, recursive: true);
                return;
            }
            catch (UnauthorizedAccessException) when (attempt == 0)
            {
                foreach (string f in SafeEnumerate(dir))
                {
                    try { File.SetAttributes(f, FileAttributes.Normal); } catch { }
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"Could not clean up {dir} yet ({ex.Message}); it will be removed later.");
                return;
            }
        }
    }

    /// <summary>
    /// Finishes staging folders left by a run that was interrupted (older than
    /// <paramref name="minAge"/>, default 10 minutes, so an operation in progress is never touched):
    /// anything moved aside whose original place is now empty is put back, then the folder is removed.
    /// </summary>
    public static void CleanupStale(GameInstall game, TimeSpan? minAge = null)
    {
        string root = Path.Combine(game.ProjectDir, StagingFolderName);
        if (!Directory.Exists(root)) return;
        try
        {
            foreach (string d in Directory.EnumerateDirectories(root))
            {
                if (DateTime.UtcNow - Directory.GetCreationTimeUtc(d) < (minAge ?? TimeSpan.FromMinutes(10))) continue;
                bool allRestored = true;
                string journal = Path.Combine(d, JournalName);
                if (File.Exists(journal))
                {
                    foreach (string line in File.ReadAllLines(journal).Reverse())
                    {
                        var parts = line.Split('\t');
                        if (parts.Length != 3) continue;
                        bool isDir = parts[0] == "D";
                        string original = parts[1], aside = parts[2];
                        bool originalExists = isDir ? Directory.Exists(original) : File.Exists(original);
                        bool asideExists = isDir ? Directory.Exists(aside) : File.Exists(aside);
                        if (originalExists || !asideExists) continue;
                        try
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(original)!);
                            if (isDir) Directory.Move(aside, original);
                            else File.Move(aside, original);
                            Log.Warn($"Restored {original} from an interrupted install.");
                        }
                        catch (Exception ex)
                        {
                            allRestored = false;
                            Log.Error($"Could not restore {original} from {aside}", ex);
                        }
                    }
                }
                if (allRestored) DeleteTree(d);
            }
            if (!Directory.EnumerateFileSystemEntries(root).Any()) Directory.Delete(root);
        }
        catch (Exception ex)
        {
            Log.Warn("Staging cleanup: " + ex.Message);
        }
    }

    private static IEnumerable<string> SafeEnumerate(string dir)
    {
        try { return Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).ToList(); }
        catch { return Array.Empty<string>(); }
    }
}
