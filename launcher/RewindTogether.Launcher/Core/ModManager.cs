using System.Text.RegularExpressions;

namespace RewindTogether.Launcher.Core;

/// <summary>Who a package is, once installed.</summary>
public sealed record ModIdentity(string Id, string Name, string Version, string Source, string? Sha256 = null);

public sealed class InstallOptions
{
    /// <summary>Replace a mod folder / pak that exists but was not installed by the launcher.</summary>
    public bool ReplaceUnmanaged { get; init; }
}

public sealed class InstallOutcome
{
    public InstalledMod Record { get; init; } = new();
    public List<string> Notes { get; } = new();
}

/// <summary>Thrown when an install would overwrite something the launcher does not own.</summary>
public sealed class ModConflictException : Exception
{
    public ModConflictException(IReadOnlyList<string> conflicts)
        : base("These already exist and were not installed by the launcher:\n  " + string.Join("\n  ", conflicts))
    {
        Conflicts = conflicts;
    }

    public IReadOnlyList<string> Conflicts { get; }
}

/// <summary>Something installed in the game, whoever put it there (the Mods tab's "In your game" list).</summary>
public sealed class GameModInfo
{
    public string Name { get; init; } = "";
    public ModKind Kind { get; init; }
    public bool Enabled { get; init; }
    public bool BuiltIn { get; init; }
    /// <summary>The launcher's id for it, if the launcher installed it.</summary>
    public string? ManagedId { get; init; }
    /// <summary>UE4SS mods: the folder. Paks: the .pak file (full path, current location).</summary>
    public string Path { get; init; } = "";
    public bool HasEntryPoint { get; init; } = true;
}

/// <summary>
/// Installs, updates, enables, disables and removes mods in one game install, and keeps
/// installed.json in step.
///
/// Every change to mod files goes through a <see cref="FileTransaction"/>: new files are staged
/// first, everything that will be replaced or removed is checked for being in use (a running game
/// keeps native\RewindNative.dll loaded), and only then are folders swapped in with renames that
/// are undone if any step fails. So a failed install or uninstall leaves the previous install
/// exactly as it was, and a locked file produces "Close Retro Rewind first, then press Install
/// again" rather than a half-updated mod.
/// </summary>
public sealed class ModManager
{
    /// <summary>The mods UE4SS ships with. Shown, toggleable, never uninstallable.</summary>
    public static readonly HashSet<string> BuiltInUe4ssMods = new(StringComparer.OrdinalIgnoreCase)
    {
        "ActorDumperMod", "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod",
        "ConsoleCommandsMod", "ConsoleEnablerMod", "jsbLuaProfilerMod", "Keybinds", "LineTraceMod", "SplitScreenMod",
    };

    private const string DisabledEnabledTxt = "enabled.txt.disabled-by-launcher";

    private readonly GameInstall _game;
    private readonly string _manifestPath;
    private readonly Func<bool> _gameRunning;

    /// <param name="gameRunning">Is Retro Rewind running from this install? Decides whether a failed
    /// rename is reported as "close the game first". Defaults to a process check.</param>
    public ModManager(GameInstall game, string manifestPath, Func<bool>? gameRunning = null)
    {
        _game = game;
        _manifestPath = manifestPath;
        _gameRunning = gameRunning ?? (() => GameProcess.IsRunning(game));
    }

    /// <summary>For tests: called before every rename inside a transaction (throw to simulate a failure).</summary>
    internal Action<string, string>? BeforeMove { get; set; }

    public InstalledManifest LoadManifest() => InstalledManifest.Load(_manifestPath);

    public IReadOnlyList<InstalledMod> Managed() => LoadManifest().For(_game).ToList();

    public InstalledMod? Find(string id) => LoadManifest().Find(_game, id);

    // ================================================================== install

    public InstallOutcome Install(PackageAnalysis pkg, ModIdentity who, InstallOptions? options = null)
    {
        options ??= new InstallOptions();
        FileTransaction.CleanupStale(_game);
        var manifest = LoadManifest();
        var previous = manifest.Find(_game, who.Id);
        var notes = new List<string>();

        // ---- conflicts: never overwrite something another tool (or the user) put there
        var conflicts = new List<string>();
        foreach (var comp in pkg.Components)
        {
            if (comp.Kind == ModKind.Ue4ssLua)
            {
                string dir = Path.Combine(_game.Ue4ssModsDir, comp.Folder!);
                bool ours = previous?.LuaFolders.Contains(comp.Folder!, StringComparer.OrdinalIgnoreCase) == true;
                var otherOwner = manifest.For(_game).FirstOrDefault(m => m != previous &&
                    m.LuaFolders.Contains(comp.Folder!, StringComparer.OrdinalIgnoreCase));
                if (otherOwner != null)
                    throw new ModInstallException($"The folder {comp.Folder} belongs to \"{otherOwner.Name}\". Uninstall that mod first.");
                if (Directory.Exists(dir) && !ours) conflicts.Add($"ue4ss\\Mods\\{comp.Folder}");
            }
            else
            {
                foreach (var (_, target) in comp.Files)
                {
                    string rel = ToRel(target);
                    bool ours = previous?.Files.Contains(rel, StringComparer.OrdinalIgnoreCase) == true;
                    var otherOwner = manifest.For(_game).FirstOrDefault(m => m != previous &&
                        m.Files.Contains(rel, StringComparer.OrdinalIgnoreCase));
                    if (otherOwner != null)
                        throw new ModInstallException($"{Path.GetFileName(rel)} belongs to \"{otherOwner.Name}\". Uninstall that mod first.");
                    if (!ours && (File.Exists(_game.FromRelative(rel)) || File.Exists(DisabledPathFor(_game.FromRelative(rel)))))
                        conflicts.Add(rel);
                }
            }
        }
        if (conflicts.Count > 0 && !options.ReplaceUnmanaged)
            throw new ModConflictException(conflicts);

        var record = new InstalledMod
        {
            Id = who.Id,
            Name = who.Name,
            Version = who.Version,
            Type = ModKinds.ToWire(pkg.PrimaryKind),
            Source = who.Source,
            Sha256 = who.Sha256,
            GameRoot = _game.Root,
            InstalledAt = DateTime.UtcNow,
            Enabled = true,
        };

        foreach (var comp in pkg.Components)
        {
            if (comp.Kind == ModKind.Ue4ssLua) record.LuaFolders.Add(comp.Folder!);
            else record.Files.AddRange(comp.Files.Select(f => ToRel(f.Target)));
        }
        var removedFolders = previous?.LuaFolders.Where(f => !record.LuaFolders.Contains(f, StringComparer.OrdinalIgnoreCase)).ToList() ?? new();
        var removedFiles = previous?.Files.Where(f => !record.Files.Contains(f, StringComparer.OrdinalIgnoreCase)).ToList() ?? new();

        // ---- 1. everything that is about to be replaced or removed must not be in use - checked
        //         before anything is copied or written, so a running game changes nothing at all
        var touched = new List<string>();
        touched.AddRange(record.LuaFolders.Concat(removedFolders).Select(f => Path.Combine(_game.Ue4ssModsDir, f)));
        foreach (string rel in record.Files.Concat(removedFiles))
        {
            touched.Add(_game.FromRelative(rel));
            touched.Add(DisabledPathFor(_game.FromRelative(rel)));
        }
        if (FileTransaction.FindFileInUse(touched) is { } busy)
            throw new GameFilesLockedException("press Install again", busy);

        using var txn = new FileTransaction(_game) { BeforeMove = BeforeMove };

        // ---- 2. stage: copy the new version next to the game, touching nothing that exists
        var stagedFolders = new List<(string Folder, string Staged)>();
        var stagedPaks = new List<(string Rel, string Staged)>();
        foreach (var comp in pkg.Components)
        {
            if (comp.Kind == ModKind.Ue4ssLua)
            {
                string staged = txn.NewStagingPath("mods", comp.Folder!);
                string prefix = $"{PackageAnalyzer.Ue4ssModsRel}/{comp.Folder}/";
                Directory.CreateDirectory(staged);
                foreach (var (src, target) in comp.Files)
                {
                    string inside = target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                        ? target.Substring(prefix.Length)
                        : throw new ModInstallException($"Unexpected file location in the package ({src.Path}). It was not installed.");
                    CopyInto(src, staged, ToRel(inside));
                }
                // Rewind Together keeps the player's config.lua across updates (version-gated).
                if (pkg.IsRewindTogether && RewindTogetherConfig.DecidePreservation(_game, comp, notes) is { } keep)
                {
                    string cfg = Path.Combine(staged, "Scripts", "config.lua");
                    Directory.CreateDirectory(Path.GetDirectoryName(cfg)!);
                    File.WriteAllBytes(cfg, keep);
                }
                stagedFolders.Add((comp.Folder!, staged));
            }
            else
            {
                foreach (var (src, target) in comp.Files)
                {
                    string rel = ToRel(target);
                    string staged = txn.NewStagingPath("paks", rel);
                    CopyInto(src, Path.GetDirectoryName(staged)!, Path.GetFileName(staged));
                    stagedPaks.Add((rel, staged));
                }
            }
        }

        // ---- 3. swap in, all or nothing
        Commit(txn, "press Install again", () =>
        {
            foreach (var (folder, staged) in stagedFolders)
                txn.ReplaceDirectory(Path.Combine(_game.Ue4ssModsDir, folder), staged);
            foreach (var (rel, staged) in stagedPaks)
            {
                string full = _game.FromRelative(rel);
                txn.RemoveFile(DisabledPathFor(full)); // an older, disabled copy
                txn.ReplaceFile(full, staged);
            }
            foreach (string folder in removedFolders) txn.RemoveDirectory(Path.Combine(_game.Ue4ssModsDir, folder));
            foreach (string rel in removedFiles)
            {
                txn.RemoveFile(_game.FromRelative(rel));
                txn.RemoveFile(DisabledPathFor(_game.FromRelative(rel)));
            }
        });

        // ---- 4. shared Lua libraries: added or refreshed, never removed (other mods may use them)
        foreach (var (src, target) in pkg.SharedFiles)
        {
            try { CopyInto(src, _game.Root, ToRel(target)); }
            catch (ModInstallException ex) { notes.Add("A shared library could not be updated: " + ex.Message); }
        }

        // ---- 5. enable: mods.txt (above the keybinds block) + mods.json
        foreach (string folder in record.LuaFolders)
        {
            ModsTxt.Update(_game.ModsTxt, t => t.SetEnabled(folder, true));
            ModsJson.SetEnabled(_game.ModsJson, folder, true);
        }
        foreach (string old in removedFolders)
        {
            ModsTxt.Update(_game.ModsTxt, t => t.Remove(old));
            ModsJson.Remove(_game.ModsJson, old);
        }
        foreach (string rel in removedFiles) PruneEmptyDirs(Path.GetDirectoryName(_game.FromRelative(rel))!);

        manifest.Mods.RemoveAll(m => InstalledManifest.SameRoot(m.GameRoot, _game.Root) && m.Id.Equals(who.Id, StringComparison.OrdinalIgnoreCase));
        manifest.Mods.Add(record);
        manifest.Save(_manifestPath);

        Log.Info($"Installed {who.Name} {who.Version} ({record.Type}): {record.LuaFolders.Count} UE4SS folder(s), {record.Files.Count} pak file(s).");
        var outcome = new InstallOutcome { Record = record };
        outcome.Notes.AddRange(notes);
        return outcome;
    }

    // ================================================================== uninstall / toggle

    public void Uninstall(string id)
    {
        FileTransaction.CleanupStale(_game);
        var manifest = LoadManifest();
        var rec = manifest.Find(_game, id) ?? throw new ModInstallException($"\"{id}\" was not installed by the launcher.");

        var folders = rec.LuaFolders.Select(f => Path.Combine(_game.Ue4ssModsDir, f)).ToList();
        var files = rec.Files.SelectMany(r => new[] { _game.FromRelative(r), DisabledPathFor(_game.FromRelative(r)) }).ToList();
        if (FileTransaction.FindFileInUse(folders.Concat(files)) is { } busy)
            throw new GameFilesLockedException("press Uninstall again", busy);

        if (rec.Id.Equals(GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase))
            RewindTogetherConfig.BackupOnUninstall(_game);

        using (var txn = new FileTransaction(_game) { BeforeMove = BeforeMove })
        {
            Commit(txn, "press Uninstall again", () =>
            {
                foreach (string dir in folders) txn.RemoveDirectory(dir);
                foreach (string f in files) txn.RemoveFile(f);
            });
        }

        foreach (string folder in rec.LuaFolders)
        {
            ModsTxt.Update(_game.ModsTxt, t => t.Remove(folder));
            ModsJson.Remove(_game.ModsJson, folder);
        }
        foreach (string f in files) PruneEmptyDirs(Path.GetDirectoryName(f)!);
        manifest.Mods.Remove(rec);
        manifest.Save(_manifestPath);
        Log.Info($"Uninstalled {rec.Name} {rec.Version}.");
    }

    /// <summary>
    /// Removes a UE4SS mod folder the launcher did not install (e.g. Rewind Together put there by
    /// the old PowerShell installer), with the same in-use check and all-or-nothing removal.
    /// </summary>
    public void UninstallUnmanagedFolder(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || folder.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || folder is "." or "..")
            throw new ArgumentException("Not a mod folder name: " + folder, nameof(folder));
        string dir = Path.Combine(_game.Ue4ssModsDir, folder);
        if (FileTransaction.FindFileInUse(new[] { dir }) is { } busy)
            throw new GameFilesLockedException("press Uninstall again", busy);
        if (folder.Equals(GameInstall.RewindTogetherFolder, StringComparison.OrdinalIgnoreCase))
            RewindTogetherConfig.BackupOnUninstall(_game);
        using (var txn = new FileTransaction(_game) { BeforeMove = BeforeMove })
            Commit(txn, "press Uninstall again", () => txn.RemoveDirectory(dir));
        ModsTxt.Update(_game.ModsTxt, t => t.Remove(folder));
        ModsJson.Remove(_game.ModsJson, folder);
        Log.Info($"Removed {folder} (not installed by the launcher).");
    }

    public void SetEnabled(string id, bool enabled)
    {
        var manifest = LoadManifest();
        var rec = manifest.Find(_game, id) ?? throw new ModInstallException($"\"{id}\" was not installed by the launcher.");
        foreach (string folder in rec.LuaFolders) SetLuaEnabled(folder, enabled);
        foreach (string rel in rec.Files) MovePak(_game.FromRelative(rel), enabled);
        rec.Enabled = enabled;
        manifest.Save(_manifestPath);
        Log.Info($"{(enabled ? "Enabled" : "Disabled")} {rec.Name}.");
    }

    /// <summary>Toggle something the launcher did not install (built-in UE4SS mods, hand-installed paks).</summary>
    public void SetEnabled(GameModInfo item, bool enabled)
    {
        if (item.ManagedId != null) { SetEnabled(item.ManagedId, enabled); return; }
        if (item.Kind == ModKind.Ue4ssLua)
        {
            SetLuaEnabled(item.Name, enabled);
        }
        else
        {
            string enabledPath = item.Enabled ? item.Path : EnabledPathFor(item.Path);
            string stem = Path.Combine(Path.GetDirectoryName(enabledPath)!, Path.GetFileNameWithoutExtension(enabledPath));
            foreach (string ext in PackageSource.PakExtensions) MovePak(stem + ext, enabled);
        }
        Log.Info($"{(enabled ? "Enabled" : "Disabled")} {item.Name} (not installed by the launcher).");
    }

    private void SetLuaEnabled(string folder, bool enabled)
    {
        ModsTxt.Update(_game.ModsTxt, t => t.SetEnabled(folder, enabled));
        ModsJson.SetEnabled(_game.ModsJson, folder, enabled);

        // UE4SS also starts any mod that has enabled.txt, whatever mods.txt says - so a disable
        // must move that file out of the way, and an enable puts back what we moved.
        string dir = Path.Combine(_game.Ue4ssModsDir, folder);
        string on = Path.Combine(dir, "enabled.txt");
        string off = Path.Combine(dir, DisabledEnabledTxt);
        try
        {
            if (!enabled && File.Exists(on)) File.Move(on, off, overwrite: true);
            if (enabled && File.Exists(off) && !File.Exists(on)) File.Move(off, on);
        }
        catch (IOException ex)
        {
            throw new ModInstallException($"Could not change {on}: {ex.Message}", ex);
        }
    }

    // ================================================================== scan

    /// <summary>Everything in the game's UE4SS Mods folder and pak folders, managed or not.</summary>
    public List<GameModInfo> ScanGame()
    {
        var list = new List<GameModInfo>();
        var managed = Managed();
        var txt = ModsTxt.Load(_game.ModsTxt);

        if (Directory.Exists(_game.Ue4ssModsDir))
        {
            foreach (string dir in Directory.EnumerateDirectories(_game.Ue4ssModsDir).OrderBy(d => d, StringComparer.OrdinalIgnoreCase))
            {
                string name = Path.GetFileName(dir);
                if (name.Equals("shared", StringComparison.OrdinalIgnoreCase)) continue;
                bool enabled = txt.IsEnabled(name) ?? File.Exists(Path.Combine(dir, "enabled.txt"));
                bool hasEntry = File.Exists(Path.Combine(dir, "Scripts", "main.lua")) || File.Exists(Path.Combine(dir, "dlls", "main.dll"));
                list.Add(new GameModInfo
                {
                    Name = name,
                    Kind = ModKind.Ue4ssLua,
                    Enabled = enabled,
                    BuiltIn = BuiltInUe4ssMods.Contains(name),
                    ManagedId = managed.FirstOrDefault(m => m.LuaFolders.Contains(name, StringComparer.OrdinalIgnoreCase))?.Id,
                    Path = dir,
                    HasEntryPoint = hasEntry,
                });
            }
        }

        void ScanPaks(string dir, ModKind kind, bool enabled)
        {
            if (!Directory.Exists(dir)) return;
            foreach (string pak in Directory.EnumerateFiles(dir, "*.pak", SearchOption.AllDirectories).OrderBy(p => p, StringComparer.OrdinalIgnoreCase))
            {
                string rel = ToRel(_game.ToRelative(enabled ? pak : EnabledPathFor(pak)));
                list.Add(new GameModInfo
                {
                    Name = Path.GetFileNameWithoutExtension(pak),
                    Kind = kind,
                    Enabled = enabled,
                    ManagedId = managed.FirstOrDefault(m => m.Files.Contains(rel, StringComparer.OrdinalIgnoreCase))?.Id,
                    Path = pak,
                });
            }
        }
        ScanPaks(_game.PakModsDir, ModKind.Pak, true);
        ScanPaks(_game.DisabledPakModsDir, ModKind.Pak, false);
        ScanPaks(_game.LogicModsDir, ModKind.LogicMod, true);
        ScanPaks(_game.DisabledLogicModsDir, ModKind.LogicMod, false);
        return list;
    }

    // ================================================================== helpers

    /// <summary>
    /// Runs the renames of a change; on any failure undoes them all and reports a locked game file
    /// as "close the game first" (with <paramref name="retry"/>), anything else as a plain error.
    /// </summary>
    private void Commit(FileTransaction txn, string retry, Action renames)
    {
        try
        {
            renames();
            txn.Complete();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            int stuck = txn.Rollback();
            Log.Error($"File change failed and was rolled back ({stuck} item(s) could not be restored)", ex);
            if (FileTransaction.IsInUse(ex) || _gameRunning())
                throw new GameFilesLockedException(retry, null, ex);
            throw new ModInstallException(
                $"The files could not be changed ({ex.Message}). Nothing was changed. If a file from this mod is open in another program, " +
                "close it and try again." + (stuck > 0 ? $" Some files were left in {txn.Folder} - see the launcher log." : ""), ex);
        }
    }

    /// <summary>Content\Paks\~mods\x.pak ↔ Content\_disabled\~mods\x.pak</summary>
    public string DisabledPathFor(string enabledFullPath)
    {
        string rel = Path.GetRelativePath(_game.PaksDir, enabledFullPath);
        if (rel.StartsWith("..")) return enabledFullPath + ".disabled";
        return Path.Combine(_game.DisabledPaksRoot, rel);
    }

    public string EnabledPathFor(string disabledFullPath)
    {
        string rel = Path.GetRelativePath(_game.DisabledPaksRoot, disabledFullPath);
        if (rel.StartsWith("..")) return disabledFullPath;
        return Path.Combine(_game.PaksDir, rel);
    }

    private void MovePak(string enabledFullPath, bool enable)
    {
        string disabled = DisabledPathFor(enabledFullPath);
        string from = enable ? disabled : enabledFullPath;
        string to = enable ? enabledFullPath : disabled;
        if (!File.Exists(from)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(to)!);
        try
        {
            File.Move(from, to, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            if (FileTransaction.IsInUse(ex) || _gameRunning())
                throw new GameFilesLockedException($"switch {Path.GetFileNameWithoutExtension(from)} {(enable ? "on" : "off")} again", from, ex);
            throw new ModInstallException($"Could not move {Path.GetFileName(from)}: {ex.Message}", ex);
        }
        PruneEmptyDirs(Path.GetDirectoryName(from)!);
    }

    /// <summary>Copies one package file to <paramref name="root"/>\<paramref name="relative"/>, refusing anything that escapes the root.</summary>
    private static void CopyInto(PackageFile src, string root, string relative)
    {
        string rootFull = Path.GetFullPath(root).TrimEnd('\\');
        string full = Path.GetFullPath(Path.Combine(rootFull, relative));
        if (!full.StartsWith(rootFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new ModInstallException($"The package tried to write outside its folder ({src.Path}). It was not installed.");
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        try
        {
            using var input = src.Open();
            using var output = new FileStream(full, FileMode.Create, FileAccess.Write, FileShare.None);
            input.CopyTo(output);
        }
        catch (IOException ex)
        {
            throw new ModInstallException($"Could not write {full}: {ex.Message}", ex);
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new ModInstallException($"Windows refused to write {full}. If the game is installed under Program Files, " +
                "run the launcher once as administrator or move the game to another Steam library.", ex);
        }
    }

    /// <summary>Removes now-empty sub-folders up to (not including) ~mods, LogicMods or _disabled.</summary>
    private void PruneEmptyDirs(string dir)
    {
        var stops = new[] { _game.PakModsDir, _game.LogicModsDir, _game.DisabledPakModsDir, _game.DisabledLogicModsDir, _game.PaksDir, _game.DisabledPaksRoot }
            .Select(p => Path.GetFullPath(p).TrimEnd('\\')).ToHashSet(StringComparer.OrdinalIgnoreCase);
        string? d = dir;
        while (d != null && !stops.Contains(Path.GetFullPath(d).TrimEnd('\\'))
               && d.StartsWith(_game.ProjectDir, StringComparison.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(d) || Directory.EnumerateFileSystemEntries(d).Any()) break;
            try { Directory.Delete(d); } catch { break; }
            d = Path.GetDirectoryName(d);
        }
    }

    private static string ToRel(string forwardSlashRel) => forwardSlashRel.Replace('/', '\\');
}

/// <summary>
/// Rewind Together's config.lua rules, carried over from Install-RewindTogether.ps1:
/// a user-edited config.lua survives updates as long as its Config.ConfigVersion matches the
/// new one. When the version changed, the old file is kept beside the mod folder
/// (RewindTogether-config.lua.v&lt;N&gt;-backup) and the new default is installed, because keeping an
/// old config across a schema change silently re-applies settings the new code no longer expects
/// (PROJECT.md §8).
/// </summary>
public static class RewindTogetherConfig
{
    private static readonly Regex VersionRx = new(@"ConfigVersion\s*=\s*(\d+)", RegexOptions.Compiled);

    public static int? ReadConfigVersion(string? luaText)
    {
        if (luaText == null) return null;
        var m = VersionRx.Match(luaText);
        return m.Success && int.TryParse(m.Groups[1].Value, out int v) ? v : null;
    }

    /// <summary>The player's config.lua bytes to keep in the new install, or null to use the new default.</summary>
    internal static byte[]? DecidePreservation(GameInstall game, ModComponent comp, List<string> notes)
    {
        string existing = Path.Combine(game.Ue4ssModsDir, comp.Folder!, "Scripts", "config.lua");
        if (!File.Exists(existing)) return null;

        byte[] userBytes = File.ReadAllBytes(existing);
        string userText = AtomicFile.Utf8NoBom.GetString(userBytes);
        var incoming = comp.Files.FirstOrDefault(f => f.Target.EndsWith("/Scripts/config.lua", StringComparison.OrdinalIgnoreCase));
        string? newText = null;
        if (incoming.Source != null)
        {
            using var s = incoming.Source.Open();
            using var r = new StreamReader(s);
            newText = r.ReadToEnd();
        }

        int? userVer = ReadConfigVersion(userText);
        int? newVer = ReadConfigVersion(newText);

        if (newText == null || newVer == null || userVer == newVer)
        {
            notes.Add("Kept your existing config.lua.");
            return userBytes;
        }

        string backup = Path.Combine(game.Ue4ssModsDir, $"RewindTogether-config.lua.v{userVer ?? 0}-backup");
        File.WriteAllBytes(backup, userBytes);
        notes.Add($"This version uses a new settings layout (config v{newVer}, yours was v{userVer ?? 0}), so the new default " +
                  $"config.lua was installed. Your old one is saved as {Path.GetFileName(backup)}.");
        return null;
    }

    internal static void BackupOnUninstall(GameInstall game)
    {
        string cfg = Path.Combine(game.RewindTogetherDir, "Scripts", "config.lua");
        if (!File.Exists(cfg)) return;
        try
        {
            File.Copy(cfg, Path.Combine(game.Ue4ssModsDir, "RewindTogether-config.lua.uninstalled-backup"), overwrite: true);
        }
        catch (IOException ex)
        {
            Log.Warn("Could not back up config.lua before uninstalling: " + ex.Message);
        }
    }
}
