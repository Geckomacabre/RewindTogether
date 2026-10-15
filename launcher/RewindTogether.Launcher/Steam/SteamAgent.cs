using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.Steam;

/// <summary>
/// The Steam helper. Runs as a separate, windowless copy of the launcher exe
/// ("RewindTogetherLauncher.exe --steam-agent"), talking JSON lines over stdin/stdout.
///
/// WHY A SEPARATE PROCESS
/// Initialising the Steam API with Retro Rewind's AppID makes Steam believe Retro Rewind is
/// running for as long as the PROCESS lives - calling SteamAPI_Shutdown is not a reliable way
/// to undo that, and re-initialising in the same process afterwards is not supported well. Steam
/// then refuses to start the real game ("already running") and shows the player as in-game while
/// they are only looking at the launcher. A helper process gives a hard boundary: when it exits,
/// Steam forgets it. So:
///   - the friends list is fetched by a short-lived agent that exits before the game is started;
///   - the tunnel and rich presence run in an agent started only once the game process exists,
///     and stopped when the game exits.
/// It also means a crash inside native Steam code can never take the launcher window down.
///
/// Commands (launcher -> agent), one JSON object per line:
///   {"cmd":"friends"}
///   {"cmd":"host","gamePort":27015,"friendsOnly":true,"maxGuests":7}
///   {"cmd":"join","host":"7656...","localPort":27016}
///   {"cmd":"presence","on":true,"mods":{"rt_ver":"1.7.1",...}}   (mods: ModFingerprint.ToPresence)
///   {"cmd":"invite","friend":"7656..."}
///   {"cmd":"stop"}
/// Events (agent -> launcher):
///   ready, fatal, friends, listening, stats, peer, joinRequest, error, log, stopped
/// </summary>
public sealed class SteamAgent
{
    private readonly Func<ISteamApi> _connect;
    private readonly TextReader _in;
    private readonly TextWriter _out;
    private readonly Func<DateTime> _clock;
    private readonly BlockingCollection<JsonObject> _commands = new();
    private readonly object _writeGate = new();

    private ISteamApi? _api;
    private TunnelHost? _host;
    private TunnelGuest? _guest;
    private bool _presenceOn;
    private Dictionary<string, string> _presenceMods = new();
    private bool _stop;
    private DateTime _nextStats;

    // friends query in flight
    private DateTime? _friendsDeadline;
    private HashSet<ulong> _friendsAwaiting = new();
    private List<SteamFriend> _friendsSnapshot = new();

    public SteamAgent(Func<ISteamApi> connect, TextReader input, TextWriter output, Func<DateTime>? clock = null)
    {
        _connect = connect;
        _in = input;
        _out = output;
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    /// <summary>How long to wait for friends' rich presence after asking for it.</summary>
    public TimeSpan FriendsWait { get; init; } = TimeSpan.FromSeconds(2.5);

    public int Run(CancellationToken ct = default)
    {
        try
        {
            _api = _connect();
        }
        catch (SteamInitException ex)
        {
            Emit(new JsonObject { ["evt"] = "fatal", ["code"] = ex.Code, ["message"] = ex.Message });
            return 2;
        }
        catch (Exception ex)
        {
            Emit(new JsonObject { ["evt"] = "fatal", ["code"] = "init_failed", ["message"] = "The Steam helper could not start: " + ex.Message });
            return 2;
        }

        Emit(new JsonObject { ["evt"] = "ready", ["steamId"] = _api.LocalSteamId.ToString(), ["name"] = _api.LocalName });

        var reader = new Thread(ReadCommands) { IsBackground = true, Name = "agent-stdin" };
        reader.Start();

        try
        {
            while (!_stop && !ct.IsCancellationRequested)
            {
                bool work = Step();
                if (!work) Thread.Sleep(1);
            }
        }
        catch (Exception ex)
        {
            Emit(new JsonObject { ["evt"] = "fatal", ["code"] = "crashed", ["message"] = "The Steam helper stopped unexpectedly: " + ex.Message });
            Log.Error("Agent loop crashed", ex);
        }
        finally
        {
            Shutdown();
        }
        return 0;
    }

    /// <summary>One iteration of the loop. Public so tests can single-step the agent.</summary>
    public bool Step()
    {
        var api = _api ?? throw new InvalidOperationException("not started");
        bool work = false;

        api.RunFrame(OnCallback);

        while (_commands.TryTake(out var cmd))
        {
            work = true;
            Handle(cmd);
            if (_stop) return true;
        }

        if (_host != null) work |= _host.Pump();
        if (_guest != null) work |= _guest.Pump();

        if (_friendsDeadline != null && (_friendsAwaiting.Count == 0 || _clock() >= _friendsDeadline))
            FinishFriendsQuery();

        if (_clock() >= _nextStats)
        {
            _nextStats = _clock() + TimeSpan.FromSeconds(1);
            if (_host != null || _guest != null) EmitStats();
        }
        return work;
    }

    /// <summary>For tests: queue a command as if it arrived on stdin.</summary>
    public void Enqueue(string jsonLine)
    {
        if (JsonNode.Parse(jsonLine) is JsonObject o) _commands.Add(o);
    }

    /// <summary>For tests: connect without running the blocking loop.</summary>
    public void StartForTest()
    {
        _api = _connect();
        Emit(new JsonObject { ["evt"] = "ready", ["steamId"] = _api.LocalSteamId.ToString(), ["name"] = _api.LocalName });
    }

    public void ShutdownForTest() => Shutdown();

    // ------------------------------------------------------------------ commands

    private void ReadCommands()
    {
        try
        {
            string? line;
            while ((line = _in.ReadLine()) != null)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    if (JsonNode.Parse(line) is JsonObject o) _commands.Add(o);
                }
                catch (JsonException)
                {
                    EmitLog("Ignored an unreadable command.");
                }
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        // stdin closed = the launcher went away. Never outlive it holding Steam open.
        _commands.Add(new JsonObject { ["cmd"] = "stop" });
    }

    private void Handle(JsonObject cmd)
    {
        var api = _api!;
        string c = cmd["cmd"]?.GetValue<string>() ?? "";
        switch (c)
        {
            case "stop":
                _stop = true;
                break;

            case "friends":
                StartFriendsQuery();
                break;

            case "host":
            {
                if (_guest != null) { EmitError("Already joined to a friend; stop that first."); break; }
                if (_host != null) { EmitLog("Already hosting."); break; }
                int port = (int?)cmd["gamePort"] ?? 27015;
                bool friendsOnly = (bool?)cmd["friendsOnly"] ?? true;
                int max = (int?)cmd["maxGuests"] ?? 7;
                _host = new TunnelHost(api, port, id => !friendsOnly || api.IsFriend(id), max, EmitLog, _clock);
                _host.PeerJoined += id => Emit(new JsonObject { ["evt"] = "peer", ["id"] = id.ToString(), ["name"] = SafeName(id), ["state"] = "joined" });
                _host.PeerLeft += (id, why) => Emit(new JsonObject { ["evt"] = "peer", ["id"] = id.ToString(), ["name"] = SafeName(id), ["state"] = "left", ["reason"] = why });
                EmitLog($"Host tunnel ready: Steam friends -> 127.0.0.1:{port}.");
                Emit(new JsonObject { ["evt"] = "hosting", ["gamePort"] = port });
                break;
            }

            case "join":
            {
                if (_host != null) { EmitError("You are hosting; stop hosting before joining someone."); break; }
                if (!SteamIds.TryParse((string?)cmd["host"], out ulong hostId))
                {
                    EmitError("That Steam ID is not valid.");
                    break;
                }
                if (hostId == api.LocalSteamId)
                {
                    EmitError("That is your own Steam ID - you cannot join yourself.");
                    break;
                }
                _guest?.Dispose();
                int port = (int?)cmd["localPort"] ?? 27016;
                var guest = new TunnelGuest(api, hostId, port, EmitLog, _clock);
                try
                {
                    guest.Start();
                }
                catch (TunnelBindException ex)
                {
                    guest.Dispose();
                    Emit(new JsonObject { ["evt"] = "error", ["code"] = "port_in_use", ["message"] = ex.Message });
                    break;
                }
                _guest = guest;
                Emit(new JsonObject { ["evt"] = "listening", ["port"] = guest.LocalPort, ["host"] = hostId.ToString(), ["hostName"] = SafeName(hostId) });
                break;
            }

            case "presence":
                if (cmd["mods"] is JsonObject mods)
                    _presenceMods = mods
                        .Where(kv => ModFingerprint.PresenceKeys.Contains(kv.Key) && kv.Value is JsonValue)
                        .ToDictionary(kv => kv.Key, kv => (string?)kv.Value ?? "");
                SetPresence((bool?)cmd["on"] ?? false);
                break;

            case "invite":
                if (SteamIds.TryParse((string?)cmd["friend"], out ulong friend))
                {
                    bool ok = api.InviteToGame(friend, ConnectString(api.LocalSteamId));
                    if (ok) EmitLog($"Invite sent to {SafeName(friend)}.");
                    else EmitError($"Steam did not send the invite to {SafeName(friend)}.");
                }
                break;

            default:
                EmitLog($"Unknown command \"{c}\" ignored.");
                break;
        }
    }

    public static string ConnectString(ulong hostId) => "+rt_join " + hostId;

    private void SetPresence(bool on)
    {
        var api = _api!;
        if (on)
        {
            api.SetRichPresence("rt_host", "1");
            api.SetRichPresence("connect", ConnectString(api.LocalSteamId));
            api.SetRichPresence("status", "Hosting a Rewind Together co-op store");
            // What a guest must match (ModFingerprint): checked by their launcher before joining.
            foreach (var (key, value) in _presenceMods) api.SetRichPresence(key, value);
        }
        else
        {
            // Empty value deletes the key. Deliberately NOT ClearRichPresence: the game shares
            // this app's presence and may have keys of its own.
            api.SetRichPresence("rt_host", "");
            api.SetRichPresence("connect", "");
            api.SetRichPresence("status", "");
            foreach (string key in ModFingerprint.PresenceKeys) api.SetRichPresence(key, "");
        }
        _presenceOn = on;
        Emit(new JsonObject { ["evt"] = "presence", ["on"] = on });
    }

    // ------------------------------------------------------------------ friends

    private void StartFriendsQuery()
    {
        var api = _api!;
        _friendsSnapshot = api.GetFriends().Where(f => f.Online).ToList();
        _friendsAwaiting = new HashSet<ulong>();
        foreach (var f in _friendsSnapshot.Where(f => f.PlayingAppId == GameInstall.AppId))
        {
            _friendsAwaiting.Add(f.Id);
            api.RequestFriendRichPresence(f.Id);
        }
        _friendsDeadline = _clock() + FriendsWait;
    }

    private void FinishFriendsQuery()
    {
        var api = _api!;
        _friendsDeadline = null;
        var arr = new JsonArray();
        foreach (var f in _friendsSnapshot.OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            bool inGame = f.PlayingAppId == GameInstall.AppId;
            bool hosting = inGame && api.GetFriendRichPresence(f.Id, "rt_host") == "1";
            var friend = new JsonObject
            {
                ["id"] = f.Id.ToString(),
                ["name"] = f.Name,
                ["state"] = f.PersonaState,
                ["inGame"] = inGame,
                ["hosting"] = hosting,
            };
            if (hosting)
            {
                var mods = new JsonObject();
                foreach (string key in ModFingerprint.PresenceKeys)
                    if (api.GetFriendRichPresence(f.Id, key) is { Length: > 0 } v) mods[key] = v;
                if (mods.Count > 0) friend["mods"] = mods;
            }
            arr.Add(friend);
        }
        Emit(new JsonObject { ["evt"] = "friends", ["friends"] = arr });
    }

    // ------------------------------------------------------------------ callbacks

    private void OnCallback(int id, byte[] payload)
    {
        switch (id)
        {
            case SteamCallbackIds.P2PSessionRequest when payload.Length >= 8:
            {
                ulong remote = BitConverter.ToUInt64(payload, 0);
                _host?.OnSessionRequest(remote);
                _guest?.OnSessionRequest(remote);
                break;
            }
            case SteamCallbackIds.P2PSessionConnectFail when payload.Length >= 9:
            {
                ulong remote = BitConverter.ToUInt64(payload, 0);
                int err = payload[8];
                string why = err switch
                {
                    2 => "they do not own Retro Rewind on Steam",
                    4 => "the connection timed out - is their launcher still running?",
                    _ => "Steam error " + err,
                };
                Emit(new JsonObject { ["evt"] = "error", ["code"] = "p2p_failed", ["message"] = $"Could not connect to {SafeName(remote)}: {why}." });
                break;
            }
            case SteamCallbackIds.FriendRichPresenceUpdate when payload.Length >= 8:
                _friendsAwaiting.Remove(BitConverter.ToUInt64(payload, 0));
                break;
            case SteamCallbackIds.GameRichPresenceJoinRequested when payload.Length >= 8:
            {
                ulong friend = BitConverter.ToUInt64(payload, 0);
                string connect = payload.Length > 8 ? Encoding.UTF8.GetString(payload, 8, payload.Length - 8).Split('\0')[0] : "";
                ulong target = friend;
                int at = connect.IndexOf("+rt_join", StringComparison.OrdinalIgnoreCase);
                if (at >= 0 && SteamIds.TryParse(connect.Substring(at + 8).Trim().Split(' ')[0], out ulong parsed)) target = parsed;
                Emit(new JsonObject { ["evt"] = "joinRequest", ["host"] = target.ToString(), ["name"] = SafeName(target) });
                break;
            }
        }
    }

    // ------------------------------------------------------------------ output

    private void EmitStats()
    {
        var peers = new JsonArray();
        string mode = "idle";
        if (_host != null)
        {
            mode = "host";
            _host.RefreshLinkState();
            foreach (var p in _host.Peers) peers.Add(StatsJson(p));
        }
        else if (_guest != null)
        {
            mode = "guest";
            _guest.RefreshLinkState();
            var s = StatsJson(_guest.Stats);
            s["gameConnected"] = _guest.GameConnected;
            peers.Add(s);
        }
        Emit(new JsonObject { ["evt"] = "stats", ["mode"] = mode, ["presence"] = _presenceOn, ["peers"] = peers });
    }

    private JsonObject StatsJson(PeerStats p) => new()
    {
        ["id"] = p.Id.ToString(),
        ["name"] = SafeName(p.Id),
        ["link"] = p.Link,
        ["in"] = p.PacketsIn,
        ["out"] = p.PacketsOut,
        ["inBytes"] = p.BytesIn,
        ["outBytes"] = p.BytesOut,
        ["sinceIn"] = Math.Round((_clock() - p.LastIn).TotalSeconds, 1),
        ["oversize"] = p.SentReliableOversize,
        ["sendFailures"] = p.SendFailures,
    };

    private string SafeName(ulong id)
    {
        try { return _api?.GetPersonaName(id) ?? ""; } catch { return ""; }
    }

    private void EmitLog(string message)
    {
        Log.Info("[agent] " + message);
        Emit(new JsonObject { ["evt"] = "log", ["message"] = message });
    }

    private void EmitError(string message) => Emit(new JsonObject { ["evt"] = "error", ["message"] = message });

    private void Emit(JsonObject o)
    {
        lock (_writeGate)
        {
            try
            {
                _out.WriteLine(o.ToJsonString());
                _out.Flush();
            }
            catch (IOException) { _stop = true; }
            catch (ObjectDisposedException) { _stop = true; }
        }
    }

    private void Shutdown()
    {
        try
        {
            if (_presenceOn && _api != null) SetPresence(false);
            _host?.Dispose();
            _guest?.Dispose();
            _host = null;
            _guest = null;
        }
        catch (Exception ex)
        {
            Log.Warn("Agent cleanup: " + ex.Message);
        }
        _api?.Dispose();
        Emit(new JsonObject { ["evt"] = "stopped" });
    }

    // ------------------------------------------------------------------ process entry

    [System.Runtime.InteropServices.DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint ms);

    /// <summary>Entry point for "--steam-agent". stdin/stdout are pipes from the launcher.</summary>
    public static int RunProcess(string steamDll)
    {
        // 1 ms scheduler ticks: the loop sleeps 1 ms when idle, and the default 15.6 ms tick would
        // add that much latency to every packet.
        try { timeBeginPeriod(1); } catch { }
        var utf8 = new UTF8Encoding(false);
        var input = new StreamReader(Console.OpenStandardInput(), utf8);
        var output = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true };
        Log.Info($"Steam helper started (pid {Environment.ProcessId}).");
        var agent = new SteamAgent(() => SteamApi.Connect(steamDll, GameInstall.AppId), input, output);
        int code = agent.Run();
        Log.Info($"Steam helper exiting ({code}).");
        return code;
    }
}

/// <summary>A friend as reported by the agent.</summary>
public sealed record FriendInfo(ulong Id, string Name, int State, bool InGame, bool Hosting,
    IReadOnlyDictionary<string, string>? Mods = null)
{
    /// <summary>The mods a hosting friend published, or null (not hosting, or an older launcher).</summary>
    public ModFingerprint? Fingerprint =>
        Mods == null ? null : ModFingerprint.FromPresence(k => Mods.TryGetValue(k, out var v) ? v : null);
}

public sealed record PeerInfo(ulong Id, string Name, string Link, long In, long Out, long InBytes, long OutBytes, double SinceIn, bool? GameConnected);

public sealed record AgentStats(string Mode, bool Presence, IReadOnlyList<PeerInfo> Peers);

/// <summary>
/// The launcher's end of the agent: starts the helper process, sends commands, and turns its
/// output back into events. Events are raised on a background thread.
/// </summary>
public sealed class SteamAgentClient : IAsyncDisposable
{
    private Process? _proc;
    private readonly object _gate = new();
    private readonly TaskCompletionSource<(ulong Id, string Name)> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TaskCompletionSource<IReadOnlyList<FriendInfo>>? _friends;
    private TaskCompletionSource<int>? _listening;
    private TextWriter? _stdin;

    public event Action<AgentStats>? StatsReceived;
    public event Action<ulong, string, string, string?>? PeerChanged; // id, name, joined|left, reason
    public event Action<ulong, string>? JoinRequested;
    public event Action<string>? ErrorReceived;
    public event Action<string>? LogReceived;
    public event Action<bool>? PresenceChanged;
    public event Action<int>? Exited;

    public ulong LocalSteamId { get; private set; }
    public string LocalName { get; private set; } = "";
    public bool IsRunning => _proc is { HasExited: false };
    public string? FatalCode { get; private set; }
    public string? FatalMessage { get; private set; }

    public static SteamAgentClient Start(string exePath, string steamDll, string? dataDir)
    {
        var c = new SteamAgentClient();
        var psi = new ProcessStartInfo(exePath)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            StandardInputEncoding = new UTF8Encoding(false),
        };
        psi.ArgumentList.Add("--steam-agent");
        psi.ArgumentList.Add("--steam-dll");
        psi.ArgumentList.Add(steamDll);
        if (!string.IsNullOrEmpty(dataDir))
        {
            psi.ArgumentList.Add("--data-dir");
            psi.ArgumentList.Add(dataDir);
        }
        psi.Environment["SteamAppId"] = GameInstall.AppId.ToString();
        psi.Environment["SteamGameId"] = GameInstall.AppId.ToString();

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) c.HandleLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Warn("[agent stderr] " + e.Data); };
        p.Exited += (_, _) => c.OnExited();
        if (!p.Start()) throw new InvalidOperationException("The Steam helper could not be started.");
        c._proc = p;
        c._stdin = p.StandardInput;
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        Log.Info($"Started Steam helper (pid {p.Id}).");
        return c;
    }

    /// <summary>Waits for Steam to come up in the helper. Throws <see cref="SteamInitException"/> with a readable message.</summary>
    public async Task<(ulong Id, string Name)> WaitReadyAsync(TimeSpan timeout)
    {
        var done = await Task.WhenAny(_ready.Task, Task.Delay(timeout));
        if (done != _ready.Task)
            throw new SteamInitException("timeout", "Steam did not answer within " + (int)timeout.TotalSeconds +
                " seconds. Is Steam signed in and online? Try again in a moment.");
        return await _ready.Task;
    }

    public async Task<IReadOnlyList<FriendInfo>> QueryFriendsAsync(TimeSpan timeout)
    {
        var tcs = new TaskCompletionSource<IReadOnlyList<FriendInfo>>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) _friends = tcs;
        Send(new JsonObject { ["cmd"] = "friends" });
        var done = await Task.WhenAny(tcs.Task, Task.Delay(timeout));
        if (done != tcs.Task) throw new TimeoutException("Steam did not return your friends list in time.");
        return await tcs.Task;
    }

    public void StartHost(int gamePort, bool friendsOnly, int maxGuests)
        => Send(new JsonObject { ["cmd"] = "host", ["gamePort"] = gamePort, ["friendsOnly"] = friendsOnly, ["maxGuests"] = maxGuests });

    /// <summary>Starts the guest tunnel; returns the local port once it is listening.</summary>
    public async Task<int> StartJoinAsync(ulong host, int localPort, TimeSpan timeout)
    {
        var tcs = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) _listening = tcs;
        Send(new JsonObject { ["cmd"] = "join", ["host"] = host.ToString(), ["localPort"] = localPort });
        var done = await Task.WhenAny(tcs.Task, Task.Delay(timeout));
        if (done != tcs.Task) throw new TimeoutException("The Steam tunnel did not start in time.");
        return await tcs.Task;
    }

    public void SetPresence(bool on, IReadOnlyDictionary<string, string>? mods = null)
    {
        var cmd = new JsonObject { ["cmd"] = "presence", ["on"] = on };
        if (mods != null)
        {
            var m = new JsonObject();
            foreach (var (k, v) in mods) m[k] = v;
            cmd["mods"] = m;
        }
        Send(cmd);
    }

    public void Invite(ulong friend) => Send(new JsonObject { ["cmd"] = "invite", ["friend"] = friend.ToString() });

    public async Task StopAsync(TimeSpan? grace = null)
    {
        var p = _proc;
        if (p == null) return;
        try
        {
            if (!p.HasExited)
            {
                Send(new JsonObject { ["cmd"] = "stop" });
                using var cts = new CancellationTokenSource(grace ?? TimeSpan.FromSeconds(4));
                try { await p.WaitForExitAsync(cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException)
                {
                    Log.Warn("Steam helper did not stop in time; ending it.");
                    try { p.Kill(entireProcessTree: true); } catch { }
                    await p.WaitForExitAsync().ConfigureAwait(false);
                }
            }
        }
        catch (InvalidOperationException) { }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _proc?.Dispose();
        _proc = null;
    }

    /// <summary>Synchronous stop for window shutdown (no awaits that need the UI thread).</summary>
    public void StopBlocking(TimeSpan grace)
    {
        var p = _proc;
        if (p == null) return;
        try
        {
            if (!p.HasExited)
            {
                Send(new JsonObject { ["cmd"] = "stop" });
                if (!p.WaitForExit((int)grace.TotalMilliseconds))
                {
                    try { p.Kill(entireProcessTree: true); } catch { }
                }
            }
        }
        catch (InvalidOperationException) { }
        p.Dispose();
        _proc = null;
    }

    private void Send(JsonObject o)
    {
        try
        {
            lock (_gate)
            {
                _stdin?.WriteLine(o.ToJsonString());
                _stdin?.Flush();
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException)
        {
            Log.Warn("Could not talk to the Steam helper: " + ex.Message);
        }
    }

    /// <summary>Parses one line of agent output. Public for tests.</summary>
    public void HandleLine(string line)
    {
        JsonObject? o;
        try { o = JsonNode.Parse(line) as JsonObject; }
        catch (JsonException) { Log.Warn("[agent] " + line); return; }
        if (o == null) return;

        string evt = (string?)o["evt"] ?? "";
        switch (evt)
        {
            case "ready":
                LocalSteamId = ulong.TryParse((string?)o["steamId"], out var me) ? me : 0;
                LocalName = (string?)o["name"] ?? "";
                _ready.TrySetResult((LocalSteamId, LocalName));
                break;
            case "fatal":
                FatalCode = (string?)o["code"];
                FatalMessage = (string?)o["message"] ?? "The Steam helper failed.";
                Log.Warn($"Steam helper: {FatalCode}: {FatalMessage}");
                var ex = new SteamInitException(FatalCode ?? "init_failed", FatalMessage);
                _ready.TrySetException(ex);
                lock (_gate)
                {
                    _friends?.TrySetException(ex);
                    _listening?.TrySetException(ex);
                }
                ErrorReceived?.Invoke(FatalMessage);
                break;
            case "friends":
            {
                var list = new List<FriendInfo>();
                if (o["friends"] is JsonArray arr)
                {
                    foreach (var n in arr.OfType<JsonObject>())
                    {
                        if (!ulong.TryParse((string?)n["id"], out ulong id)) continue;
                        var mods = (n["mods"] as JsonObject)?
                            .Where(kv => kv.Value is JsonValue)
                            .ToDictionary(kv => kv.Key, kv => (string?)kv.Value ?? "");
                        list.Add(new FriendInfo(id, (string?)n["name"] ?? "", (int?)n["state"] ?? 0,
                            (bool?)n["inGame"] ?? false, (bool?)n["hosting"] ?? false, mods));
                    }
                }
                lock (_gate) _friends?.TrySetResult(list);
                break;
            }
            case "listening":
                lock (_gate) _listening?.TrySetResult((int?)o["port"] ?? 0);
                break;
            case "stats":
            {
                var peers = new List<PeerInfo>();
                if (o["peers"] is JsonArray arr)
                {
                    foreach (var n in arr.OfType<JsonObject>())
                    {
                        ulong.TryParse((string?)n["id"], out ulong id);
                        peers.Add(new PeerInfo(id, (string?)n["name"] ?? "", (string?)n["link"] ?? "",
                            (long?)n["in"] ?? 0, (long?)n["out"] ?? 0, (long?)n["inBytes"] ?? 0, (long?)n["outBytes"] ?? 0,
                            (double?)n["sinceIn"] ?? 0, (bool?)n["gameConnected"]));
                    }
                }
                StatsReceived?.Invoke(new AgentStats((string?)o["mode"] ?? "idle", (bool?)o["presence"] ?? false, peers));
                break;
            }
            case "peer":
                if (ulong.TryParse((string?)o["id"], out ulong pid))
                    PeerChanged?.Invoke(pid, (string?)o["name"] ?? "", (string?)o["state"] ?? "", (string?)o["reason"]);
                break;
            case "joinRequest":
                if (ulong.TryParse((string?)o["host"], out ulong hid))
                    JoinRequested?.Invoke(hid, (string?)o["name"] ?? "");
                break;
            case "presence":
                PresenceChanged?.Invoke((bool?)o["on"] ?? false);
                break;
            case "error":
            {
                string msg = (string?)o["message"] ?? "Steam reported an error.";
                if ((string?)o["code"] == "port_in_use")
                    lock (_gate) _listening?.TrySetException(new TunnelBindException(msg, new IOException(msg)));
                ErrorReceived?.Invoke(msg);
                break;
            }
            case "log":
                LogReceived?.Invoke((string?)o["message"] ?? "");
                break;
            case "hosting":
            case "stopped":
                break;
        }
    }

    private void OnExited()
    {
        int code = -1;
        try { code = _proc?.ExitCode ?? -1; } catch { }
        var ex = new SteamInitException(FatalCode ?? "exited", FatalMessage ?? "The Steam helper closed unexpectedly.");
        _ready.TrySetException(ex);
        lock (_gate)
        {
            _friends?.TrySetException(ex);
            _listening?.TrySetException(ex);
        }
        Log.Info($"Steam helper exited ({code}).");
        Exited?.Invoke(code);
    }
}
