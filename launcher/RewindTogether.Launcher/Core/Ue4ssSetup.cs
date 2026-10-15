using System.IO.Compression;

namespace RewindTogether.Launcher.Core;

public enum Ue4ssState
{
    NotInstalled,
    /// <summary>dwmapi.dll + ue4ss\UE4SS.dll: the layout Rewind Together is built for.</summary>
    Installed,
    /// <summary>A flat 2.x / 3.0.x-release layout (Win64\UE4SS.dll) - may not support UE 5.4.</summary>
    OldLayout,
    /// <summary>Half an install: the proxy DLL without the ue4ss folder or the other way round.</summary>
    Broken,
}

public sealed record Ue4ssStatus(Ue4ssState State, string? Version, bool IsPinnedBuild, string Summary);

/// <summary>
/// UE4SS - the script loader Rewind Together runs inside.
///
/// PINNED BUILD. The game runs UE4SS "3.0.1-944-g0196ef29" (it logs "UE4SS - v3.0.1 Beta #0 -
/// Git SHA #0196ef29"), published as UE4SS_v3.0.1-944-g0196ef29.zip under the RE-UE4SS
/// "experimental" release tag. Its files are byte-identical to the working install this mod is
/// developed against, and it unpacks to dwmapi.dll + ue4ss\. The asset literally named
/// UE4SS_v3.0.1.zip (tag v3.0.1, February 2024) is NOT used: it is a flat layout
/// (Win64\UE4SS.dll, Win64\Mods\) built before Unreal 5.4 existed, so it is not what this game
/// has been tested with. If the pin ever has to move, update all four constants together.
/// </summary>
public static class Ue4ssSetup
{
    public const string PinnedVersion = "3.0.1-944-g0196ef29";
    public const string PinnedFileName = "UE4SS_v3.0.1-944-g0196ef29.zip";
    public const string PinnedUrl = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-944-g0196ef29.zip";
    public const string PinnedSha256 = "b7be182458695a95d5d862d0a5f279e23fa5ef5b93566648e181191958ea45bd";
    public const long PinnedSize = 7_094_371;
    public const string ReleasesPage = "https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental";

    /// <summary>sha256 of ue4ss\UE4SS.dll in the pinned zip, to recognise an install of exactly that build.</summary>
    public const string PinnedDllSha256 = "df9e6e9a2280972b1c28ce590700feacc752b447204f8baadeb95f5776957055";

    private static readonly string[] ProxyNames = { "dwmapi.dll", "xinput1_3.dll", "d3d11.dll", "dxgi.dll", "version.dll" };

    /// <summary>Files from the zip that are never overwritten if the player already has them.</summary>
    private static readonly string[] KeepIfPresent = { "ue4ss/UE4SS-settings.ini", "ue4ss/Mods/mods.txt", "ue4ss/Mods/mods.json" };

    public static Ue4ssStatus Detect(GameInstall g)
    {
        bool proxy = ProxyNames.Any(p => File.Exists(Path.Combine(g.Win64, p)));
        bool newDll = File.Exists(g.Ue4ssDll);
        bool oldDll = File.Exists(Path.Combine(g.Win64, "UE4SS.dll"));
        string? version = ReadVersionFromLog(g);

        if (proxy && newDll)
        {
            bool pinned = IsPinnedDll(g.Ue4ssDll);
            string v = pinned ? PinnedVersion : version ?? "unknown version";
            return new Ue4ssStatus(Ue4ssState.Installed, v, pinned,
                pinned ? $"UE4SS {PinnedVersion} is installed."
                       : $"UE4SS is installed ({v}). Rewind Together is tested with {PinnedVersion}.");
        }
        if (oldDll)
            return new Ue4ssStatus(Ue4ssState.OldLayout, version, false,
                "An older UE4SS layout is installed (UE4SS.dll directly in Binaries\\Win64). Rewind Together needs the newer build that lives in a \"ue4ss\" folder.");
        if (proxy || newDll || Directory.Exists(g.Ue4ssDir))
            return new Ue4ssStatus(Ue4ssState.Broken, version, false,
                "UE4SS is only partly installed, so the game will not load mods.");
        return new Ue4ssStatus(Ue4ssState.NotInstalled, null, false,
            "UE4SS (the mod loader) is not installed.");
    }

    private static (string Path, long Length, DateTime Stamp, bool Pinned)? _hashCache;

    /// <summary>Hashing a 16 MB DLL on every refresh is wasteful; remember the answer until the file changes.</summary>
    private static bool IsPinnedDll(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            var c = _hashCache;
            if (c is { } hit && hit.Path == path && hit.Length == fi.Length && hit.Stamp == fi.LastWriteTimeUtc) return hit.Pinned;
            bool pinned = fi.Length > 1_000_000 && Hashing.Matches(Hashing.Sha256OfFile(path), PinnedDllSha256);
            _hashCache = (path, fi.Length, fi.LastWriteTimeUtc, pinned);
            return pinned;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>"3.0.1 Beta #0 - Git SHA #0196ef29" from the first lines of UE4SS.log, if the game has run with it.</summary>
    public static string? ReadVersionFromLog(GameInstall g)
    {
        try
        {
            if (!File.Exists(g.Ue4ssLog)) return null;
            using var fs = new FileStream(g.Ue4ssLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var r = new StreamReader(fs);
            for (int i = 0; i < 10; i++)
            {
                string? line = r.ReadLine();
                if (line == null) break;
                int at = line.IndexOf("UE4SS - v", StringComparison.Ordinal);
                if (at >= 0) return line.Substring(at + "UE4SS - v".Length).Trim();
            }
        }
        catch { }
        return null;
    }

    /// <summary>Checks the zip is the UE4SS layout we expect before a single file is written.</summary>
    public static string? ValidateZip(string zipPath)
    {
        try
        {
            using var zip = ZipFile.OpenRead(zipPath);
            var names = zip.Entries.Select(e => e.FullName.Replace('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
            bool newLayout = names.Contains("ue4ss/UE4SS.dll");
            if (!newLayout && names.Contains("UE4SS.dll"))
                return "This is an older UE4SS release that puts UE4SS.dll next to the game. Rewind Together needs the build " +
                       $"with a \"ue4ss\" folder ({Ue4ssSetup.PinnedFileName}).";
            if (!names.Contains("dwmapi.dll"))
                return "This zip does not contain dwmapi.dll, so it is not a UE4SS release.";
            if (!newLayout)
                return "This zip does not contain ue4ss\\UE4SS.dll, so it is not the UE4SS layout Rewind Together needs.";
            return null;
        }
        catch (InvalidDataException)
        {
            return "The UE4SS download is not a valid zip file. Delete it and try again.";
        }
    }

    /// <summary>
    /// Unpacks UE4SS into Binaries\Win64. Never overwrites an existing UE4SS-settings.ini,
    /// mods.txt or mods.json - those belong to the player.
    /// </summary>
    public static List<string> InstallFromZip(GameInstall g, string zipPath)
    {
        string? problem = ValidateZip(zipPath);
        if (problem != null) throw new ModInstallException(problem);

        var notes = new List<string>();
        string win64 = Path.GetFullPath(g.Win64);
        using var zip = ZipFile.OpenRead(zipPath);

        // A running game has dwmapi.dll and UE4SS.dll loaded. Check every file we would overwrite
        // before writing any, so a running game leaves the existing UE4SS untouched.
        var overwritten = zip.Entries
            .Where(e => !e.FullName.EndsWith('/') && !KeepIfPresent.Contains(e.FullName.Replace('\\', '/'), StringComparer.OrdinalIgnoreCase))
            .Select(e => Path.GetFullPath(Path.Combine(win64, e.FullName.Replace('\\', '/'))));
        if (FileTransaction.FindFileInUse(overwritten) is { } busy)
            throw new GameFilesLockedException("press Install UE4SS again", busy);

        int written = 0;
        foreach (var e in zip.Entries)
        {
            string name = e.FullName.Replace('\\', '/');
            if (name.EndsWith('/')) continue;
            string dest = Path.GetFullPath(Path.Combine(win64, name));
            if (!dest.StartsWith(win64 + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new ModInstallException("The UE4SS zip contains an unsafe path and was not installed.");

            if (KeepIfPresent.Contains(name, StringComparer.OrdinalIgnoreCase) && File.Exists(dest))
            {
                notes.Add($"Kept your existing {name.Replace('/', '\\')}.");
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            try
            {
                e.ExtractToFile(dest, overwrite: true);
            }
            catch (IOException ex) when (FileTransaction.IsInUse(ex))
            {
                throw new GameFilesLockedException("press Install UE4SS again", dest, ex);
            }
            catch (IOException ex)
            {
                throw new ModInstallException($"Could not write {dest}: {ex.Message}", ex);
            }
            written++;
        }
        Log.Info($"UE4SS unpacked into {win64} ({written} files).");
        notes.Insert(0, $"UE4SS installed ({written} files).");
        return notes;
    }
}

/// <summary>What is known about the installed Rewind Together mod.</summary>
public sealed record RewindTogetherInfo(bool Installed, string? Version, string? GameBuild, bool? EnabledInModsTxt, bool HasMainLua)
{
    public static RewindTogetherInfo Read(GameInstall g)
    {
        if (!Directory.Exists(g.RewindTogetherDir))
            return new RewindTogetherInfo(false, null, null, null, false);

        string? version = null, build = null;
        string? json = AtomicFile.TryReadShared(g.RewindTogetherModJson);
        if (json != null)
        {
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("version", out var v)) version = v.GetString();
                if (doc.RootElement.TryGetProperty("game_build", out var b)) build = b.GetString();
            }
            catch { }
        }
        // Builds before mod.json existed: Net.VERSION = "1.7.0" in Scripts\net.lua.
        if (version == null)
        {
            string? net = AtomicFile.TryReadShared(Path.Combine(g.RewindTogetherDir, "Scripts", "net.lua"));
            var m = net == null ? null : System.Text.RegularExpressions.Regex.Match(net, @"Net\.VERSION\s*=\s*""([^""]+)""");
            if (m is { Success: true }) version = m.Groups[1].Value;
        }
        bool hasMain = File.Exists(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua"));
        bool? enabled = ModsTxt.Load(g.ModsTxt).IsEnabled(GameInstall.RewindTogetherFolder);
        if (enabled == null && File.Exists(Path.Combine(g.RewindTogetherDir, "enabled.txt"))) enabled = true;
        return new RewindTogetherInfo(true, version, build, enabled, hasMain);
    }

    /// <summary>A warning sentence if the game's Steam build differs from the one the mod was tested on.</summary>
    public string? BuildWarning(string? steamBuildId)
    {
        if (string.IsNullOrWhiteSpace(GameBuild) || string.IsNullOrWhiteSpace(steamBuildId)) return null;
        if (GameBuild.Trim() == steamBuildId.Trim()) return null;
        return $"Retro Rewind has been updated since this version of Rewind Together was tested " +
               $"(your game build is {steamBuildId}, the mod was tested on {GameBuild}). It may still work - " +
               "if co-op misbehaves, check for a mod update.";
    }
}
