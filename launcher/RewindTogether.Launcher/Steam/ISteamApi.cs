namespace RewindTogether.Launcher.Steam;

/// <summary>EP2PSend.</summary>
public enum P2PSend
{
    /// <summary>Like raw UDP. Max 1200 bytes.</summary>
    Unreliable = 0,
    UnreliableNoDelay = 1,
    /// <summary>Ordered, up to 1 MB. Used only for the rare datagram larger than 1200 bytes.</summary>
    Reliable = 2,
}

public readonly record struct P2PSessionInfo(bool Active, bool Connecting, int Error, bool UsingRelay, int BytesQueued, int PacketsQueued)
{
    public string Describe()
    {
        if (Active) return UsingRelay ? "relay" : "direct";
        if (Connecting) return "connecting";
        if (Error != 0) return "error " + Error;
        return "no session";
    }
}

/// <summary>The slice of ISteamNetworking the tunnel needs. Faked in tests.</summary>
public interface IP2PTransport
{
    bool IsPacketAvailable(out uint size, int channel);
    bool ReadPacket(byte[] buffer, out uint size, out ulong remote, int channel);
    bool SendPacket(ulong remote, byte[] data, int length, P2PSend mode, int channel);
    bool AcceptSession(ulong remote);
    bool CloseSession(ulong remote);
    bool TryGetSessionState(ulong remote, out P2PSessionInfo info);
}

public sealed record SteamFriend(ulong Id, string Name, int PersonaState, uint PlayingAppId)
{
    public bool Online => PersonaState != 0;
}

/// <summary>
/// Everything the launcher asks of Steam. The real implementation (<see cref="SteamApi"/>) is a
/// thin P/Invoke layer over the game's own steam_api64.dll; everything above it - tunnel,
/// agent, UI - is written against this interface and tested with fakes.
/// </summary>
public interface ISteamApi : IP2PTransport, IDisposable
{
    ulong LocalSteamId { get; }
    string LocalName { get; }

    /// <summary>Pumps Steam and hands each callback (id, payload bytes) to <paramref name="onCallback"/>.</summary>
    void RunFrame(Action<int, byte[]> onCallback);

    IReadOnlyList<SteamFriend> GetFriends();
    string GetPersonaName(ulong id);
    void RequestFriendRichPresence(ulong id);
    string GetFriendRichPresence(ulong id, string key);
    /// <summary>Sets a rich-presence key for this app; null or "" deletes it.</summary>
    bool SetRichPresence(string key, string? value);
    bool IsFriend(ulong id);
    bool InviteToGame(ulong id, string connect);
}

public static class SteamCallbackIds
{
    public const int PersonaStateChange = 304;
    public const int FriendRichPresenceUpdate = 336;
    public const int GameRichPresenceJoinRequested = 337;
    public const int P2PSessionRequest = 1202;
    public const int P2PSessionConnectFail = 1203;
}

public sealed class SteamInitException : Exception
{
    public SteamInitException(string code, string message, Exception? inner = null) : base(message, inner) => Code = code;

    /// <summary>dll_missing | steam_not_running | init_failed | no_interfaces</summary>
    public string Code { get; }
}
