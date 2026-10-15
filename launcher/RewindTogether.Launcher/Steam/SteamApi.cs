using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.Steam;

/// <summary>
/// Hand-written bindings to Steam's flat C API, adapted from RewindTunnel\Steam.cs.
///
/// The DLL is the GAME'S OWN copy (Engine\Plugins\Marketplace\SteamCorePro_5.4\...\steam_api64.dll),
/// loaded with NativeLibrary.Load - the launcher never ships Valve's DLL. Every export used here
/// was read from that DLL's export table.
///
/// Changes from the original tunnel:
///  - C++ bool returns/params are marshalled as 1 byte (I1). The default 4-byte BOOL reads three
///    bytes of garbage from EAX and can turn "false" into "true".
///  - P2PSessionState_t uses natural alignment (20 bytes) instead of Pack=1 (18 bytes), so the
///    native side cannot write past the end of the struct.
///  - Callbacks use manual dispatch (SteamAPI_ManualDispatch_*), which is the only way to see
///    P2PSessionRequest_t and GameRichPresenceJoinRequested_t through the flat API.
/// </summary>
internal static class SteamNative
{
    internal const string Lib = "steam_api64";
    private const CallingConvention CC = CallingConvention.Cdecl;

    private static IntPtr _handle;
    private static readonly object Gate = new();

    public static void Load(string path)
    {
        lock (Gate)
        {
            if (_handle != IntPtr.Zero) return;
            _handle = NativeLibrary.Load(path);
            NativeLibrary.SetDllImportResolver(typeof(SteamNative).Assembly, Resolve);
        }
    }

    private static IntPtr Resolve(string name, Assembly asm, DllImportSearchPath? search)
        => _handle != IntPtr.Zero && (name == Lib || name == Lib + ".dll") ? _handle : IntPtr.Zero;

    // --- lifecycle
    [DllImport(Lib, CallingConvention = CC)] public static extern int SteamAPI_InitFlat(byte[] errMsg1024);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_InitSafe();
    [DllImport(Lib, CallingConvention = CC)] public static extern void SteamAPI_Shutdown();
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_IsSteamRunning();
    [DllImport(Lib, CallingConvention = CC)] public static extern int SteamAPI_GetHSteamPipe();

    // --- manual dispatch
    [DllImport(Lib, CallingConvention = CC)] public static extern void SteamAPI_ManualDispatch_Init();
    [DllImport(Lib, CallingConvention = CC)] public static extern void SteamAPI_ManualDispatch_RunFrame(int pipe);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ManualDispatch_GetNextCallback(int pipe, out CallbackMsg msg);
    [DllImport(Lib, CallingConvention = CC)] public static extern void SteamAPI_ManualDispatch_FreeLastCallback(int pipe);

    [StructLayout(LayoutKind.Sequential)]
    public struct CallbackMsg
    {
        public int SteamUser;
        public int Callback;
        public IntPtr Param;
        public int ParamSize;
    }

    // --- interfaces
    [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr SteamAPI_SteamUser_v023();
    [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr SteamAPI_SteamFriends_v017();
    [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr SteamAPI_SteamNetworking_v006();

    [DllImport(Lib, CallingConvention = CC)] public static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);

    // --- friends
    [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr self);
    [DllImport(Lib, CallingConvention = CC)] public static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr self, int flags);
    [DllImport(Lib, CallingConvention = CC)] public static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr self, int index, int flags);
    [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr self, ulong id);
    [DllImport(Lib, CallingConvention = CC)] public static extern int SteamAPI_ISteamFriends_GetFriendPersonaState(IntPtr self, ulong id);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr self, ulong id, out FriendGameInfo info);
    [DllImport(Lib, CallingConvention = CC)] public static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr self, ulong id, byte[] keyUtf8);
    [DllImport(Lib, CallingConvention = CC)] public static extern void SteamAPI_ISteamFriends_RequestFriendRichPresence(IntPtr self, ulong id);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr self, byte[] keyUtf8, byte[] valueUtf8);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_HasFriend(IntPtr self, ulong id, int flags);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SteamAPI_ISteamFriends_InviteUserToGame(IntPtr self, ulong id, byte[] connectUtf8);

    [StructLayout(LayoutKind.Sequential)]
    public struct FriendGameInfo
    {
        public ulong GameId;       // CGameID; app id is the low 24 bits
        public uint GameIP;
        public ushort GamePort;
        public ushort QueryPort;
        public ulong SteamIdLobby;
    }

    // --- networking (ISteamNetworking, the classic P2P API with relay fallback)
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_SendP2PPacket(IntPtr self, ulong remote, byte[] data, uint size, int sendType, int channel);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_IsP2PPacketAvailable(IntPtr self, out uint size, int channel);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_ReadP2PPacket(IntPtr self, byte[] dest, uint destSize, out uint size, out ulong remote, int channel);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(IntPtr self, ulong remote);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(IntPtr self, ulong remote);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_AllowP2PPacketRelay(IntPtr self, [MarshalAs(UnmanagedType.I1)] bool allow);
    [DllImport(Lib, CallingConvention = CC)] [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamNetworking_GetP2PSessionState(IntPtr self, ulong remote, out P2PSessionState state);

    [StructLayout(LayoutKind.Sequential)]
    public struct P2PSessionState
    {
        public byte ConnectionActive;
        public byte Connecting;
        public byte P2PSessionError;
        public byte UsingRelay;
        public int BytesQueuedForSend;
        public int PacketsQueuedForSend;
        public uint RemoteIP;
        public ushort RemotePort;
    }

    public static byte[] Utf8Z(string? s)
    {
        var bytes = Encoding.UTF8.GetBytes(s ?? "");
        Array.Resize(ref bytes, bytes.Length + 1);
        return bytes;
    }
}

/// <summary>The real <see cref="ISteamApi"/>. One instance per process; not thread-safe - use from one thread.</summary>
public sealed class SteamApi : ISteamApi
{
    private const int FriendFlagImmediate = 0x04;

    private readonly int _pipe;
    private readonly IntPtr _friends;
    private readonly IntPtr _net;
    private bool _disposed;

    private SteamApi(int pipe, IntPtr user, IntPtr friends, IntPtr net)
    {
        _pipe = pipe;
        _friends = friends;
        _net = net;
        LocalSteamId = SteamNative.SteamAPI_ISteamUser_GetSteamID(user);
        LocalName = Marshal.PtrToStringUTF8(SteamNative.SteamAPI_ISteamFriends_GetPersonaName(friends)) ?? "";
    }

    public ulong LocalSteamId { get; }
    public string LocalName { get; }

    /// <summary>
    /// Loads the game's steam_api64.dll and signs in to the local Steam client as Retro Rewind.
    /// Must only be called while the game is running (or briefly, in a helper process that exits
    /// before the game is launched) - otherwise Steam believes the game is already running.
    /// </summary>
    public static SteamApi Connect(string dllPath, uint appId)
    {
        if (!File.Exists(dllPath))
            throw new SteamInitException("dll_missing",
                "The game's Steam library (steam_api64.dll) is missing. In Steam, right-click Retro Rewind > Properties > " +
                "Installed Files > Verify integrity of game files, then try again.");

        // Tells steam_api which game we are, instead of a steam_appid.txt next to the exe.
        Environment.SetEnvironmentVariable("SteamAppId", appId.ToString());
        Environment.SetEnvironmentVariable("SteamGameId", appId.ToString());

        try
        {
            SteamNative.Load(dllPath);
        }
        catch (Exception ex)
        {
            throw new SteamInitException("dll_missing", "The game's Steam library could not be loaded: " + ex.Message, ex);
        }

        if (!SteamNative.SteamAPI_IsSteamRunning())
            throw new SteamInitException("steam_not_running", "Steam is not running. Start Steam and sign in, then try again.");

        string? error = null;
        try
        {
            var buf = new byte[1024];
            int r = SteamNative.SteamAPI_InitFlat(buf);
            if (r != 0)
            {
                string detail = Encoding.UTF8.GetString(buf, 0, Math.Max(0, Array.IndexOf(buf, (byte)0))).Trim();
                error = r switch
                {
                    2 => "Steam is not running, or is not signed in.",
                    3 => "Your Steam client is out of date. Restart Steam so it can update.",
                    _ => detail.Length > 0 ? detail : $"SteamAPI_InitFlat returned {r}",
                };
            }
        }
        catch (EntryPointNotFoundException)
        {
            if (!SteamNative.SteamAPI_InitSafe()) error = "SteamAPI_InitSafe failed";
        }
        if (error != null)
            throw new SteamInitException("init_failed",
                $"Steam would not let the launcher connect ({error}). Make sure you are signed in to the Steam account that owns " +
                "Retro Rewind and that Steam is not in Offline Mode.");

        SteamNative.SteamAPI_ManualDispatch_Init();
        int pipe = SteamNative.SteamAPI_GetHSteamPipe();
        IntPtr user = SteamNative.SteamAPI_SteamUser_v023();
        IntPtr friends = SteamNative.SteamAPI_SteamFriends_v017();
        IntPtr net = SteamNative.SteamAPI_SteamNetworking_v006();
        if (user == IntPtr.Zero || friends == IntPtr.Zero || net == IntPtr.Zero)
        {
            SteamNative.SteamAPI_Shutdown();
            throw new SteamInitException("no_interfaces", "Steam started but did not provide its friends/networking services. Restart Steam and try again.");
        }

        // Without relay, two players behind unfriendly routers never connect - the exact
        // situation the tunnel exists for.
        SteamNative.SteamAPI_ISteamNetworking_AllowP2PPacketRelay(net, true);
        var api = new SteamApi(pipe, user, friends, net);
        Log.Info($"Steam API ready as {api.LocalName} ({api.LocalSteamId}).");
        return api;
    }

    public void RunFrame(Action<int, byte[]> onCallback)
    {
        SteamNative.SteamAPI_ManualDispatch_RunFrame(_pipe);
        while (SteamNative.SteamAPI_ManualDispatch_GetNextCallback(_pipe, out var msg))
        {
            try
            {
                var payload = new byte[Math.Max(0, msg.ParamSize)];
                if (msg.Param != IntPtr.Zero && payload.Length > 0) Marshal.Copy(msg.Param, payload, 0, payload.Length);
                onCallback(msg.Callback, payload);
            }
            finally
            {
                SteamNative.SteamAPI_ManualDispatch_FreeLastCallback(_pipe);
            }
        }
    }

    public IReadOnlyList<SteamFriend> GetFriends()
    {
        int n = SteamNative.SteamAPI_ISteamFriends_GetFriendCount(_friends, FriendFlagImmediate);
        var list = new List<SteamFriend>(Math.Max(0, n));
        for (int i = 0; i < n; i++)
        {
            ulong id = SteamNative.SteamAPI_ISteamFriends_GetFriendByIndex(_friends, i, FriendFlagImmediate);
            if (id == 0) continue;
            int state = SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaState(_friends, id);
            uint app = SteamNative.SteamAPI_ISteamFriends_GetFriendGamePlayed(_friends, id, out var gi)
                ? (uint)(gi.GameId & 0xFFFFFF) : 0;
            list.Add(new SteamFriend(id, GetPersonaName(id), state, app));
        }
        return list;
    }

    public string GetPersonaName(ulong id)
        => Marshal.PtrToStringUTF8(SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaName(_friends, id)) ?? "";

    public void RequestFriendRichPresence(ulong id) => SteamNative.SteamAPI_ISteamFriends_RequestFriendRichPresence(_friends, id);

    public string GetFriendRichPresence(ulong id, string key)
        => Marshal.PtrToStringUTF8(SteamNative.SteamAPI_ISteamFriends_GetFriendRichPresence(_friends, id, SteamNative.Utf8Z(key))) ?? "";

    public bool SetRichPresence(string key, string? value)
        => SteamNative.SteamAPI_ISteamFriends_SetRichPresence(_friends, SteamNative.Utf8Z(key), SteamNative.Utf8Z(value ?? ""));

    public bool IsFriend(ulong id) => SteamNative.SteamAPI_ISteamFriends_HasFriend(_friends, id, FriendFlagImmediate);

    public bool InviteToGame(ulong id, string connect)
        => SteamNative.SteamAPI_ISteamFriends_InviteUserToGame(_friends, id, SteamNative.Utf8Z(connect));

    // --- P2P

    public bool IsPacketAvailable(out uint size, int channel)
        => SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(_net, out size, channel);

    public bool ReadPacket(byte[] buffer, out uint size, out ulong remote, int channel)
        => SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(_net, buffer, (uint)buffer.Length, out size, out remote, channel);

    public bool SendPacket(ulong remote, byte[] data, int length, P2PSend mode, int channel)
        => SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(_net, remote, data, (uint)length, (int)mode, channel);

    public bool AcceptSession(ulong remote) => SteamNative.SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(_net, remote);

    public bool CloseSession(ulong remote) => SteamNative.SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(_net, remote);

    public bool TryGetSessionState(ulong remote, out P2PSessionInfo info)
    {
        if (SteamNative.SteamAPI_ISteamNetworking_GetP2PSessionState(_net, remote, out var s))
        {
            info = new P2PSessionInfo(s.ConnectionActive != 0, s.Connecting != 0, s.P2PSessionError, s.UsingRelay != 0,
                s.BytesQueuedForSend, s.PacketsQueuedForSend);
            return true;
        }
        info = default;
        return false;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { SteamNative.SteamAPI_Shutdown(); } catch { }
        Log.Info("Steam API shut down.");
    }
}
