using System.Net;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RewindTogether.Launcher.Core;

/// <summary>A one-shot request for the mod (LAUNCHER_CONTRACT.md §1).</summary>
/// <param name="Slot">host only: "Player_Save1".."Player_Save5" to have the mod load that save from the
/// main menu, or null to let the player pick their save in the game.</param>
public sealed record LaunchRequest(string Action, string? Address, string? HostName, long Written, string? Slot = null)
{
    /// <param name="slot">null or empty = "choose my save in the game" (no slot is written).</param>
    public static LaunchRequest Host(DateTimeOffset now, string? slot = null)
        => new("host", null, null, now.ToUnixTimeSeconds(), string.IsNullOrEmpty(slot) ? null : slot);

    public static LaunchRequest Join(string address, string? hostName, DateTimeOffset now)
        => new("join", address, string.IsNullOrWhiteSpace(hostName) ? null : hostName, now.ToUnixTimeSeconds());
}

/// <summary>The game's five save slots, as LAUNCHER_CONTRACT.md §1 names them.</summary>
public static class SaveSlotNames
{
    public const int Count = 5;

    /// <summary>Exactly "Player_Save1".."Player_Save5" - the mod rejects the whole request for anything else.</summary>
    public static bool IsValid(string? slot)
        => slot is { Length: 12 } && slot.StartsWith("Player_Save", StringComparison.Ordinal) && slot[11] is >= '1' and <= '5';

    public static string ForNumber(int n)
        => n is >= 1 and <= Count ? $"Player_Save{n}" : throw new ArgumentOutOfRangeException(nameof(n), "Save slots are 1 to 5.");

    public static int NumberOf(string slot)
        => IsValid(slot) ? slot[11] - '0' : throw new ArgumentException($"\"{slot}\" is not a save slot.", nameof(slot));
}

/// <summary>The mod's heartbeat (LAUNCHER_CONTRACT.md §2).</summary>
public sealed record ModStatus(
    string Version,
    string Mode,
    bool InStore,
    int Players,
    int Port,
    string LastError,
    long Updated)
{
    public const int StaleAfterSeconds = 6;

    /// <summary>Older than 6 s = the game is not running (or the mod is not loaded).</summary>
    public bool IsStale(DateTimeOffset now) => now.ToUnixTimeSeconds() - Updated > StaleAfterSeconds;

    public bool IsHosting => Mode.Equals("ListenServer", StringComparison.OrdinalIgnoreCase);
    public bool IsClient => Mode.Equals("Client", StringComparison.OrdinalIgnoreCase);
    public bool IsStandalone => Mode.Equals("Standalone", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// The launcher's half of the file contract with the mod. Pure functions build/parse the JSON so
/// they can be tested; the Write* methods put the result on disk atomically.
/// </summary>
public static class LaunchFiles
{
    private static readonly JavaScriptEncoder RawUtf8 = JavaScriptEncoder.UnsafeRelaxedJsonEscaping;

    /// <summary>
    /// Builds the flat JSON object the mod's tiny reader understands: strings and numbers only,
    /// one level, no nesting. Display names are kept as raw UTF-8 (the Lua reader does not decode
    /// \u escapes) and stripped of control characters.
    /// </summary>
    public static string BuildLaunchJson(LaunchRequest req)
    {
        if (req.Action is not ("host" or "join"))
            throw new ArgumentException("action must be host or join", nameof(req));
        if (req.Action == "join" && string.IsNullOrWhiteSpace(req.Address))
            throw new ArgumentException("a join needs an address", nameof(req));
        if (req.Slot != null)
        {
            if (req.Action != "host") throw new ArgumentException("slot only applies to a host request", nameof(req));
            if (!SaveSlotNames.IsValid(req.Slot)) throw new ArgumentException($"\"{req.Slot}\" is not Player_Save1..Player_Save5", nameof(req));
        }

        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Encoder = RawUtf8, Indented = false }))
        {
            w.WriteStartObject();
            w.WriteString("action", req.Action);
            if (req.Action == "join")
            {
                w.WriteString("address", req.Address!.Trim());
                if (!string.IsNullOrWhiteSpace(req.HostName))
                    w.WriteString("host_name", StripControl(req.HostName!));
            }
            if (req.Slot != null) w.WriteString("slot", req.Slot);
            w.WriteNumber("written", req.Written);
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    public static void WriteLaunchRequest(GameInstall game, LaunchRequest req)
    {
        AtomicFile.WriteAllText(game.LaunchJson, BuildLaunchJson(req));
        Log.Info($"Wrote {game.LaunchJson}: {BuildLaunchJson(req)}");
    }

    /// <summary>Removes a request the mod has not consumed yet (e.g. the user cancelled).</summary>
    public static void CancelLaunchRequest(GameInstall game)
    {
        try { if (File.Exists(game.LaunchJson)) File.Delete(game.LaunchJson); } catch { }
    }

    /// <summary>
    /// WIN64\RewindTogether.launcher.txt: our own full exe path, so the mod can start us with
    /// --join when a friend used Steam's own "Join Game". Written on every start.
    /// </summary>
    public static void WriteLauncherPath(GameInstall game, string exePath)
    {
        if (!Directory.Exists(game.Win64)) return;
        string current = AtomicFile.TryReadShared(game.LauncherTxt) ?? "";
        if (current.Trim() == exePath) return;
        AtomicFile.WriteAllText(game.LauncherTxt, exePath);
        Log.Info("Wrote launcher path to " + game.LauncherTxt);
    }

    /// <summary>Parses status.json. Returns null if it is missing, mid-rewrite or not JSON - the caller retries.</summary>
    public static ModStatus? ParseStatus(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { AllowTrailingCommas = true });
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            if (!r.TryGetProperty("updated", out var upd) || !TryLong(upd, out long updated)) return null;
            return new ModStatus(
                Str(r, "version"),
                Str(r, "mode") is { Length: > 0 } m ? m : "Standalone",
                Bool(r, "in_store"),
                (int)Num(r, "players", 1),
                (int)Num(r, "port", 27015),
                Str(r, "last_error"),
                updated);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static ModStatus? ReadStatus(GameInstall game) => ParseStatus(AtomicFile.TryReadShared(game.StatusJson));

    // ------------------------------------------------------------------ address validation

    private static readonly Regex HostNameRx = new(@"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}))*\.?$", RegexOptions.Compiled);

    /// <summary>
    /// Normalises what a player types into "Join by address": "1.2.3.4", "1.2.3.4:27015",
    /// "my-pc.tailnet.ts.net". Returns null and a plain-English reason if it is not usable.
    /// </summary>
    public static string? NormalizeAddress(string? input, out string? problem)
    {
        problem = null;
        string s = (input ?? "").Trim();
        if (s.StartsWith("steam.", StringComparison.OrdinalIgnoreCase))
        {
            problem = "That is a Steam address. Use \"Join by Steam ID\" instead, or ask your friend for their IP address.";
            return null;
        }
        if (s.Length == 0) { problem = "Type your friend's address first, for example 192.168.1.50."; return null; }
        if (s.Contains("://")) s = s.Substring(s.IndexOf("://", StringComparison.Ordinal) + 3).TrimEnd('/');

        string host = s;
        int? port = null;
        int colon = s.LastIndexOf(':');
        if (colon > 0 && s.IndexOf(':') == colon)
        {
            host = s.Substring(0, colon);
            if (!int.TryParse(s.Substring(colon + 1), out int p) || p < 1 || p > 65535)
            {
                problem = "The part after the colon must be a port number between 1 and 65535.";
                return null;
            }
            port = p;
        }
        else if (s.Count(c => c == ':') > 1)
        {
            problem = "IPv6 addresses are not supported. Ask your friend for their IPv4 address (four numbers with dots).";
            return null;
        }

        bool ok = IPAddress.TryParse(host, out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
                  && host.Count(c => c == '.') == 3;
        if (!ok && !host.All(c => char.IsDigit(c) || c == '.')) ok = HostNameRx.IsMatch(host);
        if (!ok)
        {
            problem = $"\"{host}\" does not look like an IP address or computer name.";
            return null;
        }
        return port.HasValue ? $"{host}:{port}" : host;
    }

    // ------------------------------------------------------------------ helpers

    private static string StripControl(string s) => new string(s.Where(c => !char.IsControl(c)).ToArray()).Trim();

    private static string Str(JsonElement r, string name)
        => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    private static bool Bool(JsonElement r, string name)
        => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static long Num(JsonElement r, string name, long fallback)
        => r.TryGetProperty(name, out var v) && TryLong(v, out long n) ? n : fallback;

    private static bool TryLong(JsonElement v, out long n)
    {
        n = 0;
        if (v.ValueKind != JsonValueKind.Number) return false;
        if (v.TryGetInt64(out n)) return true;
        if (v.TryGetDouble(out double d)) { n = (long)d; return true; }
        return false;
    }
}
