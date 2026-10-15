using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;

namespace RewindTogether.Launcher.Core;

/// <summary>What the player's Discord status says. Null fields are left out.</summary>
public sealed record DiscordActivity(
    string Details, string? State, long? StartUnixSeconds,
    string LargeImage, string LargeText, string? ButtonLabel, string? ButtonUrl)
{
    /// <summary>Discord's limit for details, state and image text.</summary>
    public const int MaxText = 128;

    public JsonObject ToJson()
    {
        var a = new JsonObject { ["details"] = Cut(Details) };
        if (!string.IsNullOrWhiteSpace(State)) a["state"] = Cut(State!);
        if (StartUnixSeconds is long start) a["timestamps"] = new JsonObject { ["start"] = start };
        a["assets"] = new JsonObject { ["large_image"] = LargeImage, ["large_text"] = Cut(LargeText) };
        if (!string.IsNullOrWhiteSpace(ButtonLabel) && Uri.TryCreate(ButtonUrl, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps)
            a["buttons"] = new JsonArray(new JsonObject { ["label"] = ButtonLabel!.Length > 32 ? ButtonLabel[..32] : ButtonLabel, ["url"] = ButtonUrl });
        return a;
    }

    private static string Cut(string s)
    {
        s = s.Trim();
        if (s.Length < 2) s = s.PadRight(2);   // Discord refuses strings shorter than 2 characters
        return s.Length <= MaxText ? s : s[..(MaxText - 1)] + "…";
    }
}

/// <summary>The launcher's state, boiled down to what the Discord status shows.</summary>
public sealed record DiscordStatusInput(
    bool GameRunning, bool Hosting, bool Joining, ModStatus? Mod,
    DateTime? GameStartedUtc, string? ProjectUrl);

public static class DiscordStatus
{
    /// <summary>The "Rewind Together" application on Discord's developer portal: its name is what
    /// Discord shows ("Playing Rewind Together"), and its Art Assets hold the "logo" image.</summary>
    public const string ApplicationId = "1560334255547093155";
    public const string LogoKey = "logo";

    /// <summary>What to show, or null to show nothing (the game is not running).</summary>
    public static DiscordActivity? For(DiscordStatusInput s)
    {
        if (!s.GameRunning) return null;
        var mod = s.Mod;
        int players = mod?.Players ?? 0;
        string? withOthers = players > 1 ? $"{players} players in the store" : null;

        string details;
        string? state;
        if (s.Hosting || mod?.IsHosting == true)
        {
            details = "Hosting a video store";
            state = withOthers ?? "Open to friends";
        }
        else if (s.Joining || mod?.IsClient == true)
        {
            details = "Visiting a friend's store";   // no names: the status is public, and the friend never asked to be in it
            state = withOthers ?? "Working the store together";
        }
        else if (mod is { InStore: true })
        {
            details = "Running the store";
            state = "Solo";
        }
        else
        {
            details = "In the main menu";
            state = null;
        }

        long? start = s.GameStartedUtc is DateTime t ? new DateTimeOffset(DateTime.SpecifyKind(t, DateTimeKind.Utc)).ToUnixTimeSeconds() : null;
        return new DiscordActivity(details, state, start, LogoKey, "Rewind Together - co-op for Retro Rewind",
            s.ProjectUrl != null ? "Get Rewind Together" : null, s.ProjectUrl);
    }
}

/// <summary>
/// Discord's local RPC: a named pipe (\\.\pipe\discord-ipc-0 .. 9) carrying frames of
/// [opcode int32][length int32][UTF-8 JSON]. Handshake (opcode 0) with the application id, then
/// SET_ACTIVITY commands (opcode 1). No Discord running, or an old one: nothing happens.
/// </summary>
public sealed class DiscordIpcClient : IDisposable
{
    public const int OpHandshake = 0, OpFrame = 1, OpClose = 2;

    private readonly string _applicationId;
    private readonly string _pipePrefix;
    private NamedPipeClientStream? _pipe;

    public DiscordIpcClient(string applicationId, string pipePrefix = "discord-ipc-")
    {
        _applicationId = applicationId;
        _pipePrefix = pipePrefix;
    }

    public bool Connected => _pipe?.IsConnected == true;

    /// <summary>Connects to the first Discord that answers. False when none does.</summary>
    public bool TryConnect(int perPipeTimeoutMs = 250)
    {
        Close();
        for (int i = 0; i < 10; i++)
        {
            var pipe = new NamedPipeClientStream(".", _pipePrefix + i, PipeDirection.InOut, PipeOptions.None);
            try
            {
                pipe.Connect(perPipeTimeoutMs);
                Write(pipe, OpHandshake, new JsonObject { ["v"] = 1, ["client_id"] = _applicationId });
                var (op, reply) = Read(pipe);
                if (op == OpFrame && (string?)reply?["evt"] == "READY")
                {
                    _pipe = pipe;
                    return true;
                }
                Log.Warn($"Discord refused the connection: {reply?.ToJsonString() ?? "no answer"}");
            }
            catch (Exception ex) when (ex is TimeoutException or IOException or InvalidOperationException or UnauthorizedAccessException) { }
            pipe.Dispose();
        }
        return false;
    }

    /// <summary>Sets (or, with null, clears) the status shown for <paramref name="pid"/>. Returns Discord's error, or null.</summary>
    public string? SetActivity(int pid, DiscordActivity? activity)
    {
        var pipe = _pipe ?? throw new InvalidOperationException("Not connected to Discord.");
        var args = new JsonObject { ["pid"] = pid, ["activity"] = activity?.ToJson() };
        Write(pipe, OpFrame, new JsonObject { ["cmd"] = "SET_ACTIVITY", ["args"] = args, ["nonce"] = Guid.NewGuid().ToString("N") });
        var (op, reply) = Read(pipe);
        if (op == OpClose) throw new IOException("Discord closed the connection: " + reply?.ToJsonString());
        return (string?)reply?["evt"] == "ERROR" ? ((string?)reply?["data"]?["message"] ?? "unknown error") : null;
    }

    public void Close()
    {
        try { _pipe?.Dispose(); } catch { }
        _pipe = null;
    }

    public void Dispose() => Close();

    public static byte[] Frame(int op, JsonNode payload)
    {
        byte[] json = Encoding.UTF8.GetBytes(payload.ToJsonString());
        var frame = new byte[8 + json.Length];
        BinaryPrimitives.WriteInt32LittleEndian(frame.AsSpan(0, 4), op);
        BinaryPrimitives.WriteInt32LittleEndian(frame.AsSpan(4, 4), json.Length);
        json.CopyTo(frame, 8);
        return frame;
    }

    private static void Write(Stream s, int op, JsonNode payload)
    {
        s.Write(Frame(op, payload));
        s.Flush();
    }

    public static (int Op, JsonObject? Payload) Read(Stream s)
    {
        var header = new byte[8];
        s.ReadExactly(header);
        int op = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(0, 4));
        int len = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(4, 4));
        if (len is < 0 or > 1 << 20) throw new IOException("Discord sent a frame that makes no sense.");
        var body = new byte[len];
        s.ReadExactly(body);
        return (op, JsonNode.Parse(body) as JsonObject);
    }
}

/// <summary>
/// Keeps the Discord status in step with the launcher, on its own thread: the window only says
/// what it wants shown, and connecting, sending and retrying never hold it up. Sends only on a
/// change and at most every few seconds (Discord allows 5 updates per 20 seconds).
/// </summary>
public sealed class DiscordPresenceService : IDisposable
{
    private readonly Func<DiscordIpcClient> _connect;
    private readonly TimeSpan _minInterval, _retryAfter;
    private readonly object _gate = new();
    private readonly Thread _thread;
    private readonly AutoResetEvent _wake = new(false);
    private (int Pid, DiscordActivity? Activity) _wanted;
    private volatile bool _stop;

    public DiscordPresenceService(Func<DiscordIpcClient>? connect = null, TimeSpan? minInterval = null, TimeSpan? retryAfter = null)
    {
        _connect = connect ?? (() => new DiscordIpcClient(DiscordStatus.ApplicationId));
        _minInterval = minInterval ?? TimeSpan.FromSeconds(4);
        _retryAfter = retryAfter ?? TimeSpan.FromSeconds(30);
        _thread = new Thread(Run) { IsBackground = true, Name = "Discord status" };
        _thread.Start();
    }

    /// <summary>The last status Discord accepted (null = none shown). For tests and diagnostics.</summary>
    public DiscordActivity? Shown { get; private set; }
    public string StatusText { get; private set; } = "Not connected to Discord yet.";

    /// <summary>Show <paramref name="activity"/> for process <paramref name="pid"/>; null clears it.</summary>
    public void Want(int pid, DiscordActivity? activity)
    {
        lock (_gate)
        {
            if (activity == null) pid = _wanted.Pid;   // clear it for the process it was shown for
            if (_wanted.Pid == pid && Equals(_wanted.Activity, activity)) return;
            _wanted = (pid, activity);
        }
        _wake.Set();
    }

    private void Run()
    {
        DiscordIpcClient? client = null;
        (int Pid, DiscordActivity? Activity) sent = (0, null);
        DateTime lastSend = DateTime.MinValue, nextTry = DateTime.MinValue;
        while (!_stop)
        {
            _wake.WaitOne(TimeSpan.FromSeconds(1));
            (int Pid, DiscordActivity? Activity) want;
            lock (_gate) want = _wanted;
            bool same = want.Pid == sent.Pid && Equals(want.Activity, sent.Activity);
            if ((same && (client?.Connected == true || want.Activity == null)) || DateTime.UtcNow - lastSend < _minInterval) continue;
            if (want.Activity == null && client?.Connected != true) { sent = want; continue; }   // nothing shown, nothing to clear

            try
            {
                if (client?.Connected != true)
                {
                    if (DateTime.UtcNow < nextTry) continue;
                    client?.Dispose();
                    client = _connect();
                    if (!client.TryConnect())
                    {
                        StatusText = "Discord is not running (or not signed in).";
                        nextTry = DateTime.UtcNow + _retryAfter;
                        continue;
                    }
                }
                string? error = client.SetActivity(want.Pid == 0 ? Environment.ProcessId : want.Pid, want.Activity);
                lastSend = DateTime.UtcNow;
                sent = want;
                if (error != null)
                {
                    StatusText = "Discord did not take the status: " + error;
                    Log.Warn(StatusText);
                }
                else
                {
                    Shown = want.Activity;
                    StatusText = want.Activity == null ? "Connected to Discord - nothing shown." : $"Discord shows: {want.Activity.Details}.";
                    Log.Info(StatusText);
                }
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or ObjectDisposedException)
            {
                Log.Info("Discord connection lost: " + ex.Message);
                StatusText = "Lost the connection to Discord; trying again.";
                client?.Dispose();
                client = null;
                nextTry = DateTime.UtcNow + TimeSpan.FromSeconds(5);
            }
        }

        // Leave nothing behind: an empty status is cleared, the pipe is closed.
        try { if (client?.Connected == true && sent.Activity != null) client.SetActivity(sent.Pid == 0 ? Environment.ProcessId : sent.Pid, null); }
        catch { }
        client?.Dispose();
    }

    public void Dispose()
    {
        _stop = true;
        _wake.Set();
        _thread.Join(TimeSpan.FromSeconds(3));
    }
}
