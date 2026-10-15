using System.Text;
using RewindTogether.Launcher.Steam;

namespace RewindTogether.Launcher.Tests;

/// <summary>An in-memory stand-in for Steam's P2P service: every endpoint has an inbox.</summary>
public sealed class FakeNet
{
    private readonly Dictionary<ulong, FakeP2P> _endpoints = new();
    public FakeP2P Add(ulong id) => _endpoints[id] = new FakeP2P(id, this);

    internal void Deliver(ulong from, ulong to, byte[] data, int channel)
    {
        if (_endpoints.TryGetValue(to, out var ep))
            lock (ep.Inbox) ep.Inbox.Add((from, data, channel));
    }
}

public class FakeP2P : IP2PTransport
{
    private readonly FakeNet? _net;

    public FakeP2P(ulong me, FakeNet? net)
    {
        Me = me;
        _net = net;
    }

    public ulong Me { get; }
    public List<(ulong From, byte[] Data, int Channel)> Inbox { get; } = new();
    public HashSet<ulong> Accepted { get; } = new();
    public List<ulong> Closed { get; } = new();
    public List<P2PSend> SendModes { get; } = new();

    public bool IsPacketAvailable(out uint size, int channel)
    {
        lock (Inbox)
        {
            var p = Inbox.FirstOrDefault(x => x.Channel == channel);
            size = p.Data == null ? 0 : (uint)p.Data.Length;
            return p.Data != null;
        }
    }

    public bool ReadPacket(byte[] buffer, out uint size, out ulong remote, int channel)
    {
        lock (Inbox)
        {
            int i = Inbox.FindIndex(x => x.Channel == channel);
            if (i < 0) { size = 0; remote = 0; return false; }
            var p = Inbox[i];
            Inbox.RemoveAt(i);
            Array.Copy(p.Data, buffer, p.Data.Length);
            size = (uint)p.Data.Length;
            remote = p.From;
            return true;
        }
    }

    public bool SendPacket(ulong remote, byte[] data, int length, P2PSend mode, int channel)
    {
        SendModes.Add(mode);
        _net?.Deliver(Me, remote, data.AsSpan(0, length).ToArray(), channel);
        return true;
    }

    public bool AcceptSession(ulong remote) => Accepted.Add(remote) || true;
    public bool CloseSession(ulong remote) { Closed.Add(remote); return true; }

    public bool TryGetSessionState(ulong remote, out P2PSessionInfo info)
    {
        info = new P2PSessionInfo(true, false, 0, UsingRelay: true, 0, 0);
        return true;
    }
}

/// <summary>A fake ISteamApi for agent tests: friends, rich presence and queued callbacks.</summary>
public sealed class FakeSteamApi : FakeP2P, ISteamApi
{
    public FakeSteamApi(ulong me, FakeNet? net = null) : base(me, net) { }

    public ulong LocalSteamId => Me;
    public string LocalName { get; set; } = "Me";
    public List<SteamFriend> Friends { get; } = new();
    public Dictionary<(ulong, string), string> FriendPresence { get; } = new();
    public Dictionary<string, string> MyPresence { get; } = new();
    public List<ulong> PresenceRequests { get; } = new();
    public Queue<(int Id, byte[] Payload)> PendingCallbacks { get; } = new();
    public List<(ulong, string)> Invites { get; } = new();
    public bool AnswerPresenceRequests { get; set; } = true;
    public bool Disposed { get; private set; }

    public void RunFrame(Action<int, byte[]> onCallback)
    {
        while (PendingCallbacks.Count > 0)
        {
            var (id, payload) = PendingCallbacks.Dequeue();
            onCallback(id, payload);
        }
    }

    public IReadOnlyList<SteamFriend> GetFriends() => Friends;
    public string GetPersonaName(ulong id) => Friends.FirstOrDefault(f => f.Id == id)?.Name ?? "";

    public void RequestFriendRichPresence(ulong id)
    {
        PresenceRequests.Add(id);
        if (AnswerPresenceRequests)
            PendingCallbacks.Enqueue((SteamCallbackIds.FriendRichPresenceUpdate, BitConverter.GetBytes(id).Concat(BitConverter.GetBytes(3552140u)).ToArray()));
    }

    public string GetFriendRichPresence(ulong id, string key) => FriendPresence.TryGetValue((id, key), out var v) ? v : "";

    public bool SetRichPresence(string key, string? value)
    {
        if (string.IsNullOrEmpty(value)) MyPresence.Remove(key);
        else MyPresence[key] = value;
        return true;
    }

    public bool IsFriend(ulong id) => Friends.Any(f => f.Id == id);
    public bool InviteToGame(ulong id, string connect) { Invites.Add((id, connect)); return true; }

    public void QueueJoinRequest(ulong friend, string connect)
    {
        var payload = new byte[8 + 256];
        BitConverter.GetBytes(friend).CopyTo(payload, 0);
        Encoding.UTF8.GetBytes(connect).CopyTo(payload, 8);
        PendingCallbacks.Enqueue((SteamCallbackIds.GameRichPresenceJoinRequested, payload));
    }

    public void QueueSessionRequest(ulong from)
        => PendingCallbacks.Enqueue((SteamCallbackIds.P2PSessionRequest, BitConverter.GetBytes(from)));

    public void Dispose() => Disposed = true;
}
