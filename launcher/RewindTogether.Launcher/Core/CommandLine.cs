namespace RewindTogether.Launcher.Core;

/// <summary>
/// Command line.
///
///   --join &lt;steamid64&gt;   join a friend's store (the mod passes this after Steam's "Join Game")
///   +rt_join &lt;steamid64&gt;  same, in the form Steam puts in a connect string
///   --host               open your store to friends
///   --game-dir &lt;path&gt;    use this Retro Rewind install (testing / unusual installs)
///   --data-dir &lt;path&gt;    keep settings and logs here instead of %APPDATA%\RewindTogether
///   --tab play|mods|diagnostics   start on a tab
///   --steam-agent        internal: run headless as the Steam helper process (see SteamAgent)
/// </summary>
public sealed class LaunchArgs
{
    public bool Host { get; private set; }
    public ulong? JoinSteamId { get; private set; }
    public string? GameDir { get; private set; }
    public string? DataDir { get; private set; }
    public string? Tab { get; private set; }
    public bool SteamAgent { get; private set; }
    public string? SteamDll { get; private set; }
    public List<string> Problems { get; } = new();

    public bool HasAction => Host || JoinSteamId != null;

    public static LaunchArgs Parse(IReadOnlyList<string> args)
    {
        var a = new LaunchArgs();
        for (int i = 0; i < args.Count; i++)
        {
            string arg = args[i];
            string? Next() => i + 1 < args.Count ? args[++i] : null;
            switch (arg.ToLowerInvariant())
            {
                case "--host":
                    a.Host = true;
                    break;
                case "--join":
                case "+rt_join":
                {
                    string? v = Next();
                    if (SteamIds.TryParse(v, out ulong id)) a.JoinSteamId = id;
                    else a.Problems.Add($"\"{v}\" is not a Steam ID, so the join request was ignored.");
                    break;
                }
                case "--game-dir": a.GameDir = Next(); break;
                case "--data-dir": a.DataDir = Next(); break;
                case "--tab": a.Tab = Next()?.ToLowerInvariant(); break;
                case "--steam-agent": a.SteamAgent = true; break;
                case "--steam-dll": a.SteamDll = Next(); break;
                default:
                    // Steam can hand over "+rt_join 7656..." as a single argument.
                    if (arg.StartsWith("+rt_join ", StringComparison.OrdinalIgnoreCase) &&
                        SteamIds.TryParse(arg.Substring(9), out ulong jid))
                        a.JoinSteamId = jid;
                    break;
            }
        }
        if (a.Host && a.JoinSteamId != null)
        {
            a.Problems.Add("Both --host and --join were given; joining.");
            a.Host = false;
        }
        return a;
    }

    /// <summary>The arguments worth forwarding to an already-running launcher.</summary>
    public string[] ForwardableArgs()
    {
        var list = new List<string>();
        if (Host) list.Add("--host");
        if (JoinSteamId is ulong id) { list.Add("--join"); list.Add(id.ToString()); }
        if (Tab != null) { list.Add("--tab"); list.Add(Tab); }
        return list.ToArray();
    }
}

public static class SteamIds
{
    /// <summary>Individual-account SteamID64s are 17 digits starting 7656119.</summary>
    public static bool TryParse(string? text, out ulong id)
    {
        id = 0;
        string s = (text ?? "").Trim();
        // Accept a pasted profile link: https://steamcommunity.com/profiles/7656119.../
        int p = s.IndexOf("/profiles/", StringComparison.OrdinalIgnoreCase);
        if (p >= 0) s = s.Substring(p + 10).Trim('/');
        if (s.Length != 17 || !s.StartsWith("7656119") || !s.All(char.IsDigit)) return false;
        return ulong.TryParse(s, out id);
    }
}
