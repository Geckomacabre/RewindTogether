namespace RewindTogether.Launcher.Core;

/// <summary>Every path the launcher touches inside a Retro Rewind install, in one place.</summary>
public sealed class GameInstall
{
    public const uint AppId = 3552140;
    public const string ExeName = "RetroRewind-Win64-Shipping.exe";
    public const string ProcessName = "RetroRewind-Win64-Shipping";
    public const string RewindTogetherFolder = "RewindTogether";
    public const string RewindTogetherId = "rewind-together";

    public GameInstall(string root, string? manifestPath = null, string? buildId = null, string source = "Steam library")
    {
        Root = Path.GetFullPath(root).TrimEnd('\\', '/');
        ManifestPath = manifestPath;
        BuildId = buildId;
        Source = source;
    }

    /// <summary>...\steamapps\common\RetroRewind</summary>
    public string Root { get; }
    public string? ManifestPath { get; }
    /// <summary>Steam "buildid" from appmanifest_3552140.acf, if it could be read.</summary>
    public string? BuildId { get; }
    /// <summary>"Steam library", "Manual", ... for diagnostics.</summary>
    public string Source { get; }

    public string ProjectDir => Path.Combine(Root, "RetroRewind");
    public string Win64 => Path.Combine(ProjectDir, "Binaries", "Win64");
    public string Exe => Path.Combine(Win64, ExeName);

    public string Ue4ssDir => Path.Combine(Win64, "ue4ss");
    public string Ue4ssDll => Path.Combine(Ue4ssDir, "UE4SS.dll");
    public string Ue4ssProxyDll => Path.Combine(Win64, "dwmapi.dll");
    public string Ue4ssSettings => Path.Combine(Ue4ssDir, "UE4SS-settings.ini");
    public string Ue4ssModsDir => Path.Combine(Ue4ssDir, "Mods");
    public string ModsTxt => Path.Combine(Ue4ssModsDir, "mods.txt");
    public string ModsJson => Path.Combine(Ue4ssModsDir, "mods.json");
    public string Ue4ssLog => Path.Combine(Ue4ssDir, "UE4SS.log");

    public string RewindTogetherDir => Path.Combine(Ue4ssModsDir, RewindTogetherFolder);
    public string RewindTogetherModJson => Path.Combine(RewindTogetherDir, "mod.json");

    public string PaksDir => Path.Combine(ProjectDir, "Content", "Paks");
    public string PakModsDir => Path.Combine(PaksDir, "~mods");
    public string LogicModsDir => Path.Combine(PaksDir, "LogicMods");

    /// <summary>
    /// Disabled pak mods live OUTSIDE Content\Paks. Unreal mounts every .pak under Paks
    /// recursively, so a "_disabled" folder inside ~mods would still be loaded.
    /// </summary>
    public string DisabledPaksRoot => Path.Combine(ProjectDir, "Content", "_disabled");
    public string DisabledPakModsDir => Path.Combine(DisabledPaksRoot, "~mods");
    public string DisabledLogicModsDir => Path.Combine(DisabledPaksRoot, "LogicMods");

    // LAUNCHER_CONTRACT.md files, all in the game's working directory.
    public string LaunchJson => Path.Combine(Win64, "RewindTogether.launch.json");
    public string StatusJson => Path.Combine(Win64, "RewindTogether.status.json");
    public string LauncherTxt => Path.Combine(Win64, "RewindTogether.launcher.txt");
    public string ModLog => Path.Combine(Win64, "RewindTogether.log");

    /// <summary>The game's own steam_api64.dll. We load it at runtime; it is never redistributed.</summary>
    public string SteamApiDll => Path.Combine(Root, "Engine", "Plugins", "Marketplace", "SteamCorePro_5.4",
        "Source", "ThirdParty", "SteamLibrary", "redistributable_bin", "win64", "steam_api64.dll");

    public static bool IsValidRoot(string? root)
    {
        if (string.IsNullOrWhiteSpace(root)) return false;
        try
        {
            return File.Exists(Path.Combine(root, "RetroRewind", "Binaries", "Win64", ExeName));
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Accepts what a user is likely to pick in a folder browser - the install folder, the
    /// RetroRewind sub-folder, or even Binaries\Win64 - and walks up to the install root.
    /// </summary>
    public static string? NormalizeUserPick(string? picked)
    {
        if (string.IsNullOrWhiteSpace(picked)) return null;
        string? dir = picked.Trim().Trim('"');
        if (File.Exists(dir)) dir = Path.GetDirectoryName(dir);
        for (int i = 0; i < 5 && dir != null; i++)
        {
            if (IsValidRoot(dir)) return Path.GetFullPath(dir);
            dir = Path.GetDirectoryName(dir);
        }
        return null;
    }

    /// <summary>Converts an absolute path inside the install to one relative to <see cref="Root"/>.</summary>
    public string ToRelative(string fullPath) => Path.GetRelativePath(Root, fullPath);
    public string FromRelative(string relativePath) => Path.GetFullPath(Path.Combine(Root, relativePath));
}
