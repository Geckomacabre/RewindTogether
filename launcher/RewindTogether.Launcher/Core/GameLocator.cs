using Microsoft.Win32;

namespace RewindTogether.Launcher.Core;

public interface ISteamRegistry
{
    /// <summary>HKCU\Software\Valve\Steam "SteamPath" (forward slashes on most machines), or null.</summary>
    string? GetSteamPath();
}

public sealed class WindowsSteamRegistry : ISteamRegistry
{
    public string? GetSteamPath()
    {
        try
        {
            using var hkcu = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
            if (hkcu?.GetValue("SteamPath") is string p && p.Length > 0) return p.Replace('/', '\\');
            using var hklm = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\WOW6432Node\Valve\Steam");
            if (hklm?.GetValue("InstallPath") is string q && q.Length > 0) return q;
        }
        catch (Exception ex)
        {
            Log.Warn("Could not read the Steam registry key: " + ex.Message);
        }
        return null;
    }
}

public sealed record AppManifest(string? InstallDir, string? BuildId, string? Name, string? StateFlags);

public sealed class LocateResult
{
    public GameInstall? Game { get; init; }
    public string? SteamPath { get; init; }
    public List<string> Libraries { get; init; } = new();
    /// <summary>Plain-English notes on what was tried, for diagnostics.</summary>
    public List<string> Notes { get; init; } = new();
}

/// <summary>
/// Finds Retro Rewind: the manual override if set, otherwise Steam's registry key, then every
/// library listed in libraryfolders.vdf, then the usual folder names on each drive.
/// </summary>
public sealed class GameLocator
{
    private readonly ISteamRegistry _registry;
    private readonly Func<IEnumerable<string>> _driveRoots;

    public GameLocator(ISteamRegistry registry, Func<IEnumerable<string>>? driveRoots = null)
    {
        _registry = registry;
        _driveRoots = driveRoots ?? DefaultDriveRoots;
    }

    public LocateResult Locate(string? manualRoot)
    {
        var notes = new List<string>();

        if (!string.IsNullOrWhiteSpace(manualRoot))
        {
            if (GameInstall.IsValidRoot(manualRoot))
            {
                var (mPath, manifest) = FindManifestNear(manualRoot);
                notes.Add("Using the folder you chose: " + manualRoot);
                return new LocateResult
                {
                    Game = new GameInstall(manualRoot, mPath, manifest?.BuildId, "Chosen by you"),
                    Notes = notes,
                };
            }
            notes.Add("The folder you chose no longer contains Retro Rewind: " + manualRoot);
        }

        string? steam = _registry.GetSteamPath();
        var libraries = new List<string>();
        if (steam != null)
        {
            notes.Add("Steam is installed at " + steam);
            libraries.AddRange(ReadLibraryFolders(steam, notes));
        }
        else
        {
            notes.Add("Steam's registry key was not found.");
        }

        foreach (string lib in libraries)
        {
            string acf = Path.Combine(lib, "steamapps", $"appmanifest_{GameInstall.AppId}.acf");
            if (!File.Exists(acf)) continue;
            AppManifest? m = TryReadManifest(acf, notes);
            string installDir = string.IsNullOrWhiteSpace(m?.InstallDir) ? "RetroRewind" : m!.InstallDir!;
            string root = Path.Combine(lib, "steamapps", "common", installDir);
            if (GameInstall.IsValidRoot(root))
            {
                notes.Add("Found Retro Rewind in the Steam library " + lib);
                return new LocateResult
                {
                    Game = new GameInstall(root, acf, m?.BuildId, "Steam library"),
                    SteamPath = steam,
                    Libraries = libraries,
                    Notes = notes,
                };
            }
            notes.Add($"{acf} exists but {root} does not contain the game executable.");
        }

        // Last resort: the common layouts on every fixed drive.
        foreach (string drive in _driveRoots())
        {
            foreach (string candidate in new[]
            {
                Path.Combine(drive, "SteamLibrary", "steamapps", "common", "RetroRewind"),
                Path.Combine(drive, "Program Files (x86)", "Steam", "steamapps", "common", "RetroRewind"),
                Path.Combine(drive, "Steam", "steamapps", "common", "RetroRewind"),
            })
            {
                if (!GameInstall.IsValidRoot(candidate)) continue;
                var (mPath, manifest) = FindManifestNear(candidate);
                notes.Add("Found Retro Rewind by searching drives: " + candidate);
                return new LocateResult
                {
                    Game = new GameInstall(candidate, mPath, manifest?.BuildId, "Drive search"),
                    SteamPath = steam,
                    Libraries = libraries,
                    Notes = notes,
                };
            }
        }

        notes.Add("Retro Rewind was not found in any Steam library.");
        return new LocateResult { SteamPath = steam, Libraries = libraries, Notes = notes };
    }

    /// <summary>Steam's own folder plus every "path" in libraryfolders.vdf (both known locations).</summary>
    public static List<string> ReadLibraryFolders(string steamPath, List<string>? notes = null)
    {
        var result = new List<string>();
        void AddLib(string p)
        {
            if (string.IsNullOrWhiteSpace(p)) return;
            string full;
            try { full = Path.GetFullPath(p.Replace('/', '\\')); } catch { return; }
            if (!result.Any(r => string.Equals(r.TrimEnd('\\'), full.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)))
                result.Add(full);
        }

        AddLib(steamPath);
        foreach (string vdfPath in new[]
        {
            Path.Combine(steamPath, "steamapps", "libraryfolders.vdf"),
            Path.Combine(steamPath, "config", "libraryfolders.vdf"),
        })
        {
            if (!File.Exists(vdfPath)) continue;
            try
            {
                foreach (string p in ParseLibraryFolders(File.ReadAllText(vdfPath)))
                    AddLib(p);
            }
            catch (Exception ex)
            {
                notes?.Add($"Could not read {vdfPath}: {ex.Message}");
            }
        }
        return result;
    }

    /// <summary>
    /// Library paths from libraryfolders.vdf. Handles both the current format
    /// ("0" { "path" "..." "apps" {...} }) and the pre-2021 one ("1" "D:\\SteamLibrary").
    /// Libraries that list app 3552140 in their "apps" block come first.
    /// </summary>
    public static List<string> ParseLibraryFolders(string vdfText)
    {
        var root = Vdf.Parse(vdfText);
        var top = root.GetObject("libraryfolders") ?? root.GetObject("LibraryFolders") ?? root;
        var withGame = new List<string>();
        var others = new List<string>();
        foreach (var kv in top.Items)
        {
            if (!int.TryParse(kv.Key, out _)) continue; // skip "contentstatsid" etc.
            if (kv.Value is string legacyPath)
            {
                others.Add(legacyPath);
            }
            else if (kv.Value is VdfObject lib)
            {
                string? path = lib.GetString("path");
                if (string.IsNullOrWhiteSpace(path)) continue;
                bool hasGame = lib.GetObject("apps")?.GetString(GameInstall.AppId.ToString()) != null;
                (hasGame ? withGame : others).Add(path);
            }
        }
        withGame.AddRange(others);
        return withGame;
    }

    public static AppManifest ParseAppManifest(string acfText)
    {
        var root = Vdf.Parse(acfText);
        var state = root.GetObject("AppState") ?? throw new FormatException("No AppState block.");
        return new AppManifest(
            state.GetString("installdir"),
            state.GetString("buildid"),
            state.GetString("name"),
            state.GetString("StateFlags"));
    }

    private static AppManifest? TryReadManifest(string acfPath, List<string>? notes)
    {
        try
        {
            return ParseAppManifest(File.ReadAllText(acfPath));
        }
        catch (Exception ex)
        {
            notes?.Add($"Could not read {acfPath}: {ex.Message}");
            return null;
        }
    }

    /// <summary>For a game root like X\steamapps\common\RetroRewind, the manifest is X\steamapps\appmanifest_3552140.acf.</summary>
    public static (string? path, AppManifest? manifest) FindManifestNear(string gameRoot)
    {
        try
        {
            var common = Directory.GetParent(Path.GetFullPath(gameRoot).TrimEnd('\\'));
            var steamapps = common?.Parent;
            if (steamapps == null) return (null, null);
            string acf = Path.Combine(steamapps.FullName, $"appmanifest_{GameInstall.AppId}.acf");
            if (!File.Exists(acf)) return (null, null);
            return (acf, TryReadManifest(acf, null));
        }
        catch
        {
            return (null, null);
        }
    }

    private static IEnumerable<string> DefaultDriveRoots()
    {
        foreach (var d in DriveInfo.GetDrives())
        {
            bool ok;
            try { ok = d.DriveType == DriveType.Fixed && d.IsReady; } catch { ok = false; }
            if (ok) yield return d.RootDirectory.FullName;
        }
    }
}
