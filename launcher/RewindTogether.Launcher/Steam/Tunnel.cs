using System.Net;
using System.Net.Sockets;

namespace RewindTogether.Launcher.Steam;

/// <summary>
/// UDP over Steam P2P - adapted from RewindTunnel\Program.cs.
///
/// It is a wire, nothing more: it moves the game's own UDP datagrams between a loopback socket
/// and Steam's P2P service (which relays through Valve when the two PCs cannot reach each other
/// directly), without reading or changing a byte. The game keeps using real Unreal networking.
///
///     GUEST                                               HOST
///     game --UDP--> TunnelGuest --Steam P2P--> TunnelHost --UDP--> game :27015
///               127.0.0.1:27016                    (one loopback socket per guest)
///
/// Channel 7 is distinct from the mod's own side-channel (41) so the two cannot collide.
/// </summary>
public static class TunnelConstants
{
    public const int Channel = 7;
    /// <summary>Steam's unreliable P2P limit. Larger datagrams go reliable rather than being dropped.</summary>
    public const int MaxUnreliable = 1200;
    public const int UdpBuffer = 65536;

    /// <summary>SIO_UDP_CONNRESET: stop ICMP "port unreachable" from surfacing as WSAECONNRESET on recv.</summary>
    private const int SioUdpConnReset = unchecked((int)0x9800000C);

    public static Socket CreateLoopbackSocket(int port, bool exclusive)
    {
        var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try
        {
            if (exclusive) s.ExclusiveAddressUse = true;
            // Without this, the first datagram sent to a port nobody listens on yet (the host
            // before their store is open) poisons every later ReceiveFrom on Windows.
            s.IOControl(SioUdpConnReset, new byte[] { 0, 0, 0, 0 }, null);
            s.Blocking = false;
            s.ReceiveBufferSize = 1 << 20;
            s.SendBufferSize = 1 << 20;
            s.Bind(new IPEndPoint(IPAddress.Loopback, port));
            return s;
        }
        catch
        {
            s.Dispose();
            throw;
        }
    }
}

/// <summary>Traffic counters for one remote player.</summary>
public sealed class PeerStats
{
    public PeerStats(ulong id, DateTime now)
    {
        Id = id;
        Since = now;
        LastIn = now;
        LastOut = now;
    }

    public ulong Id { get; }
    public DateTime Since { get; }
    public long PacketsIn { get; set; }
    public long PacketsOut { get; set; }
    public long BytesIn { get; set; }
    public long BytesOut { get; set; }
    public long SentReliableOversize { get; set; }
    public long SendFailures { get; set; }
    public DateTime LastIn { get; set; }
    public DateTime LastOut { get; set; }
    /// <summary>"relay", "direct", "connecting", "error N" or "no session".</summary>
    public string Link { get; set; } = "connecting";
}

/// <summary>
/// Host side. Unlike the original tunnel (one guest), every remote SteamID gets its OWN loopback
/// socket, so the game's listen server sees each guest as a distinct client (127.0.0.1:&lt;port&gt;)
/// and replies reach the right person.
/// </summary>
public sealed class TunnelHost : IDisposable
{
    private sealed class Peer : IDisposable
    {
        public Peer(ulong id, Socket socket, DateTime now)
        {
            Socket = socket;
            Stats = new PeerStats(id, now);
        }

        public Socket Socket { get; }
        public PeerStats Stats { get; }
        public void Dispose() => Socket.Dispose();
    }

    private readonly IP2PTransport _p2p;
    private readonly IPEndPoint _game;
    private readonly Func<ulong, bool> _allow;
    private readonly int _maxPeers;
    private readonly Action<string> _log;
    private readonly Func<DateTime> _clock;
    private readonly TimeSpan _idleTimeout;
    private readonly Dictionary<ulong, Peer> _peers = new();
    private readonly HashSet<ulong> _refused = new();
    private byte[] _steamBuf = new byte[4096];
    private readonly byte[] _udpBuf = new byte[TunnelConstants.UdpBuffer];
    private EndPoint _from = new IPEndPoint(IPAddress.Any, 0);

    public TunnelHost(IP2PTransport p2p, int gamePort, Func<ulong, bool> allow, int maxPeers, Action<string> log,
        Func<DateTime>? clock = null, TimeSpan? idleTimeout = null)
    {
        _p2p = p2p;
        _game = new IPEndPoint(IPAddress.Loopback, gamePort);
        _allow = allow;
        _maxPeers = Math.Max(1, maxPeers);
        _log = log;
        _clock = clock ?? (() => DateTime.UtcNow);
        _idleTimeout = idleTimeout ?? TimeSpan.FromSeconds(30);
    }

    public event Action<ulong>? PeerJoined;
    public event Action<ulong, string>? PeerLeft;

    public IReadOnlyList<PeerStats> Peers => _peers.Values.Select(p => p.Stats).ToList();

    /// <summary>The local UDP port the game sees a given guest on (for tests and diagnostics).</summary>
    public int? LocalPortFor(ulong id) => _peers.TryGetValue(id, out var p) ? ((IPEndPoint)p.Socket.LocalEndPoint!).Port : null;

    /// <summary>P2PSessionRequest_t: accept the people we would relay for.</summary>
    public void OnSessionRequest(ulong remote)
    {
        if (Admit(remote, out _)) _p2p.AcceptSession(remote);
    }

    /// <summary>Moves whatever is waiting in either direction. Returns true if anything moved.</summary>
    public bool Pump()
    {
        bool work = false;
        DateTime now = _clock();

        // ---- Steam -> game
        for (int budget = 0; budget < 1024 && _p2p.IsPacketAvailable(out uint avail, TunnelConstants.Channel); budget++)
        {
            if (avail > _steamBuf.Length) _steamBuf = new byte[Math.Min((int)avail, 1 << 20)];
            if (!_p2p.ReadPacket(_steamBuf, out uint size, out ulong from, TunnelConstants.Channel)) break;
            work = true;

            if (!_peers.TryGetValue(from, out var peer))
            {
                if (!Admit(from, out string? why))
                {
                    if (_refused.Add(from)) _log($"Refused traffic from {from}: {why}");
                    continue;
                }
                Socket sock;
                try { sock = TunnelConstants.CreateLoopbackSocket(0, exclusive: false); }
                catch (SocketException ex) { _log($"Could not open a local socket for {from}: {ex.SocketErrorCode}"); continue; }
                peer = new Peer(from, sock, now);
                _peers[from] = peer;
                _p2p.AcceptSession(from);
                _log($"Guest connected: {from} (game sees them as 127.0.0.1:{((IPEndPoint)sock.LocalEndPoint!).Port})");
                PeerJoined?.Invoke(from);
            }

            try
            {
                peer.Socket.SendTo(_steamBuf, 0, (int)size, SocketFlags.None, _game);
            }
            catch (SocketException) { /* the listen server is not up yet; Unreal will resend */ }
            peer.Stats.PacketsIn++;
            peer.Stats.BytesIn += size;
            peer.Stats.LastIn = now;
        }

        // ---- game -> Steam, per guest socket
        foreach (var peer in _peers.Values)
        {
            for (int budget = 0; budget < 1024 && peer.Socket.Available > 0; budget++)
            {
                int n;
                try { n = peer.Socket.ReceiveFrom(_udpBuf, ref _from); }
                catch (SocketException) { break; }
                // Only the game's listen socket may speak through a guest's port.
                if (_from is not IPEndPoint ep || !ep.Equals(_game)) continue;
                work = true;
                Send(peer.Stats, n, now);
            }
        }

        // ---- forget guests that have gone quiet (Unreal itself times out long before this)
        if (_peers.Count > 0)
        {
            foreach (var gone in _peers.Values.Where(p => now - Max(p.Stats.LastIn, p.Stats.LastOut) > _idleTimeout).ToList())
                Drop(gone.Stats.Id, "no traffic for " + (int)_idleTimeout.TotalSeconds + " s");
        }
        return work;
    }

    /// <summary>Refreshes each guest's relay/direct flag from Steam's session state.</summary>
    public void RefreshLinkState()
    {
        foreach (var p in _peers.Values)
            p.Stats.Link = _p2p.TryGetSessionState(p.Stats.Id, out var s) ? s.Describe() : "no session";
    }

    public void Drop(ulong id, string reason)
    {
        if (!_peers.Remove(id, out var peer)) return;
        peer.Dispose();
        _p2p.CloseSession(id);
        _log($"Guest {id} disconnected ({reason}).");
        PeerLeft?.Invoke(id, reason);
    }

    private bool Admit(ulong id, out string? why)
    {
        why = null;
        if (_peers.ContainsKey(id)) return true;
        if (_peers.Count >= _maxPeers) { why = $"the store is full ({_maxPeers} guests)"; return false; }
        if (!_allow(id)) { why = "not on your Steam friends list"; return false; }
        return true;
    }

    private void Send(PeerStats stats, int n, DateTime now)
    {
        P2PSend mode = P2PSend.Unreliable;
        if (n > TunnelConstants.MaxUnreliable)
        {
            mode = P2PSend.Reliable;
            stats.SentReliableOversize++;
        }
        if (_p2p.SendPacket(stats.Id, _udpBuf, n, mode, TunnelConstants.Channel))
        {
            stats.PacketsOut++;
            stats.BytesOut += n;
            stats.LastOut = now;
        }
        else
        {
            stats.SendFailures++;
        }
    }

    private static DateTime Max(DateTime a, DateTime b) => a > b ? a : b;

    public void Dispose()
    {
        foreach (ulong id in _peers.Keys.ToList()) Drop(id, "hosting stopped");
    }
}

public sealed class TunnelBindException : Exception
{
    public TunnelBindException(string message, Exception inner) : base(message, inner) { }
}

/// <summary>
/// Guest side: pretends to be the host on 127.0.0.1:&lt;port&gt;. The mod is told to join that
/// address; whatever the game sends goes to the host over Steam, and whatever comes back is
/// handed to whichever local port the game used.
/// </summary>
public sealed class TunnelGuest : IDisposable
{
    private readonly IP2PTransport _p2p;
    private readonly ulong _host;
    private readonly int _port;
    private readonly Action<string> _log;
    private readonly Func<DateTime> _clock;
    private Socket? _socket;
    private EndPoint? _gameEp;
    private EndPoint _from = new IPEndPoint(IPAddress.Any, 0);
    private byte[] _steamBuf = new byte[4096];
    private readonly byte[] _udpBuf = new byte[TunnelConstants.UdpBuffer];
    private bool _warnedStranger;

    public TunnelGuest(IP2PTransport p2p, ulong host, int localPort, Action<string> log, Func<DateTime>? clock = null)
    {
        _p2p = p2p;
        _host = host;
        _port = localPort;
        _log = log;
        _clock = clock ?? (() => DateTime.UtcNow);
        Stats = new PeerStats(host, _clock());
    }

    public ulong Host => _host;
    public PeerStats Stats { get; }
    public int LocalPort => _socket?.LocalEndPoint is IPEndPoint ep ? ep.Port : _port;
    public bool GameConnected => _gameEp != null;

    public void Start()
    {
        try
        {
            _socket = TunnelConstants.CreateLoopbackSocket(_port, exclusive: true);
        }
        catch (SocketException ex)
        {
            throw new TunnelBindException(
                $"Port {_port} on this PC is already in use ({ex.SocketErrorCode}). If Retro Rewind is hosting on this PC, " +
                "stop hosting first - or change the guest tunnel port in Diagnostics > Settings.", ex);
        }
        _p2p.AcceptSession(_host);
        _log($"Guest tunnel listening on 127.0.0.1:{LocalPort} for host {_host}.");
    }

    public void OnSessionRequest(ulong remote)
    {
        if (remote == _host) _p2p.AcceptSession(remote);
    }

    public bool Pump()
    {
        if (_socket == null) return false;
        bool work = false;
        DateTime now = _clock();

        // ---- game -> Steam
        for (int budget = 0; budget < 1024 && _socket.Available > 0; budget++)
        {
            int n;
            try { n = _socket.ReceiveFrom(_udpBuf, ref _from); }
            catch (SocketException) { break; }
            work = true;
            if (_gameEp == null || !_gameEp.Equals(_from))
            {
                _log(_gameEp == null ? $"The game connected to the tunnel from {_from}." : $"The game reconnected from {_from}.");
                _gameEp = new IPEndPoint(((IPEndPoint)_from).Address, ((IPEndPoint)_from).Port);
            }
            P2PSend mode = n > TunnelConstants.MaxUnreliable ? P2PSend.Reliable : P2PSend.Unreliable;
            if (mode == P2PSend.Reliable) Stats.SentReliableOversize++;
            if (_p2p.SendPacket(_host, _udpBuf, n, mode, TunnelConstants.Channel))
            {
                Stats.PacketsOut++;
                Stats.BytesOut += n;
                Stats.LastOut = now;
            }
            else
            {
                Stats.SendFailures++;
            }
        }

        // ---- Steam -> game
        for (int budget = 0; budget < 1024 && _p2p.IsPacketAvailable(out uint avail, TunnelConstants.Channel); budget++)
        {
            if (avail > _steamBuf.Length) _steamBuf = new byte[Math.Min((int)avail, 1 << 20)];
            if (!_p2p.ReadPacket(_steamBuf, out uint size, out ulong from, TunnelConstants.Channel)) break;
            work = true;
            if (from != _host)
            {
                if (!_warnedStranger) { _log($"Ignored traffic from {from} (not the host)."); _warnedStranger = true; }
                continue;
            }
            Stats.PacketsIn++;
            Stats.BytesIn += size;
            Stats.LastIn = now;
            if (_gameEp != null)
            {
                try { _socket.SendTo(_steamBuf, 0, (int)size, SocketFlags.None, _gameEp); }
                catch (SocketException) { }
            }
        }
        return work;
    }

    public void RefreshLinkState()
        => Stats.Link = _p2p.TryGetSessionState(_host, out var s) ? s.Describe() : "no session";

    public void Dispose()
    {
        _socket?.Dispose();
        _socket = null;
        try { _p2p.CloseSession(_host); } catch { }
    }
}
