using System.Runtime.InteropServices;
using System.Text;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// The text behind "Copy diagnostics": everything a helper needs in one paste - versions,
/// paths, the Steam build, the mod's own heartbeat, and the tail of every log.
/// </summary>
public static class DiagnosticsReport
{
    public sealed class Inputs
    {
        public AppPaths Paths { get; init; } = new();
        public LauncherSettings Settings { get; init; } = new();
        public LocateResult? Locate { get; init; }
        public GameInstall? Game { get; init; }
        public string? SteamSessionState { get; init; }
        public IEnumerable<string> ExtraLines { get; init; } = Array.Empty<string>();
    }

    public static string Build(Inputs i, int logLines = 200)
    {
        var sb = new StringBuilder();
        void Line(string k, string? v) => sb.Append("  ").Append(k.PadRight(22)).Append(": ").AppendLine(v ?? "(none)");

        sb.AppendLine("===== Rewind Together - diagnostics =====");
        Line("Created", DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"));
        Line("Launcher version", AppInfo.Version);
        Line("Launcher exe", Environment.ProcessPath);
        Line("Windows", RuntimeInformation.OSDescription);
        Line(".NET", RuntimeInformation.FrameworkDescription);
        Line("Launcher data", i.Paths.DataDir);
        sb.AppendLine();

        sb.AppendLine("--- Game");
        var g = i.Game;
        if (g == null)
        {
            Line("Retro Rewind", "NOT FOUND");
        }
        else
        {
            Line("Install folder", g.Root);
            Line("Found via", g.Source);
            Line("Steam buildid", g.BuildId ?? "(unknown)");
            Line("App manifest", g.ManifestPath);
            Line("Game exe present", File.Exists(g.Exe).ToString());
            Line("Game running", GameProcess.IsRunning(g).ToString());
            Line("steam_api64.dll", File.Exists(g.SteamApiDll) ? "present" : "MISSING " + g.SteamApiDll);

            var ue = Ue4ssSetup.Detect(g);
            Line("UE4SS", $"{ue.State} - {ue.Summary}");
            var rt = RewindTogetherInfo.Read(g);
            Line("Rewind Together", rt.Installed ? $"{rt.Version ?? "unknown version"} (enabled in mods.txt: {rt.EnabledInModsTxt?.ToString() ?? "no line"})" : "not installed");
            Line("Mod tested on build", rt.GameBuild ?? "(no mod.json)");
            if (rt.BuildWarning(g.BuildId) is { } w) Line("Build check", w);

            string? status = AtomicFile.TryReadShared(g.StatusJson);
            var parsed = LaunchFiles.ParseStatus(status);
            Line("status.json", status?.Trim() ?? "(not present)");
            if (parsed != null) Line("status age", $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds() - parsed.Updated} s (stale after {ModStatus.StaleAfterSeconds} s)");
            Line("launch.json pending", File.Exists(g.LaunchJson) ? AtomicFile.TryReadShared(g.LaunchJson)?.Trim() : "no");

            sb.AppendLine();
            sb.AppendLine("--- mods.txt");
            foreach (var (name, en) in ModsTxt.Load(g.ModsTxt).Entries) sb.AppendLine($"  {name} : {(en ? 1 : 0)}");
        }
        sb.AppendLine();

        sb.AppendLine("--- Locating the game");
        if (i.Locate != null)
        {
            Line("Steam path", i.Locate.SteamPath);
            foreach (var lib in i.Locate.Libraries) sb.AppendLine("  library: " + lib);
            foreach (var n in i.Locate.Notes) sb.AppendLine("  note: " + n);
        }
        Line("Manual game folder", i.Settings.GameRoot);
        Line("Catalog URL", string.IsNullOrEmpty(i.Settings.CatalogUrl) ? "(built-in only)" : i.Settings.CatalogUrl);
        Line("Host: friends only", i.Settings.HostFriendsOnly.ToString());
        Line("Ports", $"host game {i.Settings.HostGamePort}, guest tunnel {i.Settings.GuestTunnelPort}");
        Line("Steam session", i.SteamSessionState ?? "not running");
        foreach (var l in i.ExtraLines) sb.AppendLine("  " + l);
        sb.AppendLine();

        if (g != null)
        {
            AppendTail(sb, "RewindTogether.log", g.ModLog, logLines);
            AppendTail(sb, "UE4SS.log", g.Ue4ssLog, logLines);
        }
        AppendTail(sb, "launcher.log", i.Paths.LogFile, 100);
        AppendTail(sb, "steam-agent.log", i.Paths.AgentLogFile, 60);
        sb.AppendLine("===== end =====");
        return sb.ToString();
    }

    private static void AppendTail(StringBuilder sb, string title, string path, int lines)
    {
        sb.AppendLine($"--- last {lines} lines of {title} ({path})");
        var tail = AtomicFile.TailLines(path, lines);
        if (tail.Count == 0) sb.AppendLine("  (empty or not found)");
        foreach (var l in tail) sb.AppendLine(l);
        sb.AppendLine();
    }
}
