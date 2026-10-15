using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using RewindTogether.Launcher.Steam;
using Xunit;

namespace RewindTogether.Launcher.Tests;

/// <summary>
/// The tunnel over a fake Steam: real loopback UDP sockets on both ends, an in-memory P2P in
/// between. This proves the routing (one socket per guest, replies to the right guest), not
/// that Steam itself delivers - that part is untested without two Steam accounts.
/// </summary>
public class TunnelTests
{
    private const ulong Host = 76561198000000100, GuestA = 76561198000000201, GuestB = 76561198000000202, Stranger = 76561198000000999;

    private static Socket Udp()
    {
        var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        s.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        s.ReceiveTimeout = 2000;
        return s;
    }

    private static int PortOf(Socket s) => ((IPEndPoint)s.LocalEndPoint!).Port;

    private static void PumpUntil(Func<bool> done, params Func<bool>[] pumps)
    {
        var until = DateTime.UtcNow.AddSeconds(3);
        while (!done())
        {
            foreach (var p in pumps) p();
            if (DateTime.UtcNow > until) throw new TimeoutException("tunnel did not deliver in time");
            Thread.Sleep(2);
        }
    }

    private static (string Text, int FromPort) Receive(Socket s)
    {
        var buf = new byte[65536];
        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
        int n = s.ReceiveFrom(buf, ref from);
        return (Encoding.UTF8.GetString(buf, 0, n), ((IPEndPoint)from).Port);
    }

    [Fact]
    public void Two_guests_reach_the_game_as_distinct_clients_and_get_their_own_replies()
    {
        var net = new FakeNet();
        var hostP2P = net.Add(Host);
        var log = new List<string>();
        using var game = Udp();
        using var host = new TunnelHost(hostP2P, PortOf(game), id => id != Stranger, maxPeers: 4, log.Add);
        using var a = new TunnelGuest(net.Add(GuestA), Host, 0, log.Add);
        using var b = new TunnelGuest(net.Add(GuestB), Host, 0, log.Add);
        a.Start();
        b.Start();
        using var clientA = Udp();
        using var clientB = Udp();

        clientA.SendTo(Encoding.UTF8.GetBytes("hello from A"), new IPEndPoint(IPAddress.Loopback, a.LocalPort));
        clientB.SendTo(Encoding.UTF8.GetBytes("hello from B"), new IPEndPoint(IPAddress.Loopback, b.LocalPort));
        PumpUntil(() => game.Available > 0 && host.Peers.Count == 2, a.Pump, b.Pump, host.Pump);
        PumpUntil(() => game.Available > 0, host.Pump);

        var got = new Dictionary<string, int>();
        for (int i = 0; i < 2; i++)
        {
            PumpUntil(() => game.Available > 0, a.Pump, b.Pump, host.Pump);
            var (text, port) = Receive(game);
            got[text] = port;
        }
        Assert.Equal(2, got.Count);
        Assert.NotEqual(got["hello from A"], got["hello from B"]); // distinct clients for the listen server
        Assert.Equal(host.LocalPortFor(GuestA), (int?)got["hello from A"]);

        // The game answers each client on the port it came from...
        game.SendTo(Encoding.UTF8.GetBytes("welcome A"), new IPEndPoint(IPAddress.Loopback, got["hello from A"]));
        game.SendTo(Encoding.UTF8.GetBytes("welcome B"), new IPEndPoint(IPAddress.Loopback, got["hello from B"]));
        // ...and each reply comes out at the right guest's game.
        PumpUntil(() => clientA.Available > 0 && clientB.Available > 0, host.Pump, a.Pump, b.Pump);
        Assert.Equal("welcome A", Receive(clientA).Text);
        Assert.Equal("welcome B", Receive(clientB).Text);

        Assert.Contains(GuestA, hostP2P.Accepted);
        Assert.Equal(1, a.Stats.PacketsOut);
        Assert.Equal(1, a.Stats.PacketsIn);
        Assert.True(a.GameConnected);
        host.RefreshLinkState();
        Assert.All(host.Peers, p => Assert.Equal("relay", p.Link));
    }

    [Fact]
    public void Strangers_are_refused_and_never_reach_the_game()
    {
        var net = new FakeNet();
        var log = new List<string>();
        using var game = Udp();
        using var host = new TunnelHost(net.Add(Host), PortOf(game), id => id != Stranger, maxPeers: 4, log.Add);
        using var evil = new TunnelGuest(net.Add(Stranger), Host, 0, log.Add);
        evil.Start();
        using var client = Udp();
        client.SendTo(new byte[] { 1, 2, 3 }, new IPEndPoint(IPAddress.Loopback, evil.LocalPort));
        for (int i = 0; i < 50; i++) { evil.Pump(); host.Pump(); Thread.Sleep(2); }

        Assert.Empty(host.Peers);
        Assert.Equal(0, game.Available);
        Assert.Contains(log, l => l.Contains("Refused") && l.Contains("friends"));
    }

    [Fact]
    public void A_full_store_refuses_extra_guests()
    {
        var net = new FakeNet();
        var hostP2P = net.Add(Host);
        using var game = Udp();
        using var host = new TunnelHost(hostP2P, PortOf(game), _ => true, maxPeers: 1, _ => { });
        net.Add(GuestA).SendPacket(Host, new byte[] { 1 }, 1, P2PSend.Unreliable, TunnelConstants.Channel);
        net.Add(GuestB).SendPacket(Host, new byte[] { 2 }, 1, P2PSend.Unreliable, TunnelConstants.Channel);
        host.Pump();
        Assert.Single(host.Peers);
        host.OnSessionRequest(GuestB);
        Assert.DoesNotContain(GuestB, hostP2P.Accepted);
    }

    [Fact]
    public void Datagrams_over_1200_bytes_go_reliable_instead_of_being_dropped()
    {
        var net = new FakeNet();
        var guestP2P = net.Add(GuestA);
        net.Add(Host);
        using var guest = new TunnelGuest(guestP2P, Host, 0, _ => { });
        guest.Start();
        using var client = Udp();
        client.SendTo(new byte[1500], new IPEndPoint(IPAddress.Loopback, guest.LocalPort));
        client.SendTo(new byte[100], new IPEndPoint(IPAddress.Loopback, guest.LocalPort));
        PumpUntil(() => guestP2P.SendModes.Count == 2, guest.Pump);
        Assert.Equal(new[] { P2PSend.Reliable, P2PSend.Unreliable }, guestP2P.SendModes);
        Assert.Equal(1, guest.Stats.SentReliableOversize);
    }

    [Fact]
    public void Quiet_guests_are_dropped_and_their_session_closed()
    {
        var net = new FakeNet();
        var hostP2P = net.Add(Host);
        var now = new DateTime(2026, 10, 14, 12, 0, 0, DateTimeKind.Utc);
        using var game = Udp();
        using var host = new TunnelHost(hostP2P, PortOf(game), _ => true, 4, _ => { }, () => now, TimeSpan.FromSeconds(30));
        ulong left = 0;
        host.PeerLeft += (id, _) => left = id;
        net.Add(GuestA).SendPacket(Host, new byte[] { 1 }, 1, P2PSend.Unreliable, TunnelConstants.Channel);
        host.Pump();
        Assert.Single(host.Peers);

        now = now.AddSeconds(31);
        host.Pump();
        Assert.Empty(host.Peers);
        Assert.Equal(GuestA, left);
        Assert.Contains(GuestA, hostP2P.Closed);
    }

    [Fact]
    public void The_guest_tunnel_port_cannot_be_shared()
    {
        var net = new FakeNet();
        using var first = new TunnelGuest(net.Add(GuestA), Host, 0, _ => { });
        first.Start();
        using var second = new TunnelGuest(net.Add(GuestB), Host, first.LocalPort, _ => { });
        var ex = Assert.Throws<TunnelBindException>(second.Start);
        Assert.Contains("already in use", ex.Message);
    }
}

public class SteamAgentTests
{
    private const ulong Me = 76561198000000001, Alex = 76561198000000002, Sam = 76561198000000003, Off = 76561198000000004;

    private static (SteamAgent Agent, FakeSteamApi Api, StringWriter Out) Make(Func<DateTime>? clock = null)
    {
        var api = new FakeSteamApi(Me) { LocalName = "Me" };
        api.Friends.Add(new SteamFriend(Alex, "Alex", 1, 3552140));
        api.Friends.Add(new SteamFriend(Sam, "Sam", 1, 0));
        api.Friends.Add(new SteamFriend(Off, "Offline Olly", 0, 0));
        api.FriendPresence[(Alex, "rt_host")] = "1";
        var output = new StringWriter();
        var agent = new SteamAgent(() => api, new StringReader(""), output, clock) { FriendsWait = TimeSpan.FromSeconds(2) };
        agent.StartForTest();
        return (agent, api, output);
    }

    private static List<JsonObject> Events(StringWriter w)
        => w.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => (JsonObject)JsonNode.Parse(l)!).ToList();

    [Fact]
    public void Ready_reports_who_we_are()
    {
        var (_, _, output) = Make();
        var ready = Events(output).Single(e => (string?)e["evt"] == "ready");
        Assert.Equal(Me.ToString(), (string?)ready["steamId"]);
    }

    [Fact]
    public void Friends_query_asks_only_players_of_this_game_and_reports_who_hosts()
    {
        var (agent, api, output) = Make();
        agent.Enqueue("{\"cmd\":\"friends\"}");
        for (int i = 0; i < 5; i++) agent.Step();

        Assert.Equal(new[] { Alex }, api.PresenceRequests);
        var friends = Events(output).Single(e => (string?)e["evt"] == "friends")["friends"]!.AsArray();
        Assert.Equal(2, friends.Count); // offline friends are left out
        var alex = friends.Single(f => (string?)f!["name"] == "Alex")!;
        Assert.True((bool)alex["hosting"]!);
        Assert.True((bool)alex["inGame"]!);
        Assert.False((bool)friends.Single(f => (string?)f!["name"] == "Sam")!["hosting"]!);
    }

    [Fact]
    public void Friends_query_gives_up_waiting_after_the_deadline()
    {
        var now = DateTime.UtcNow;
        var (agent, api, output) = Make(() => now);
        api.AnswerPresenceRequests = false;
        agent.Enqueue("{\"cmd\":\"friends\"}");
        agent.Step();
        Assert.DoesNotContain(Events(output), e => (string?)e["evt"] == "friends");
        now = now.AddSeconds(3);
        agent.Step();
        Assert.Contains(Events(output), e => (string?)e["evt"] == "friends");
    }

    [Fact]
    public void Presence_advertises_the_connect_string_and_is_cleared_on_shutdown()
    {
        var (agent, api, _) = Make();
        agent.Enqueue("{\"cmd\":\"host\",\"gamePort\":27015,\"friendsOnly\":true}");
        agent.Enqueue("{\"cmd\":\"presence\",\"on\":true}");
        agent.Step();
        Assert.Equal("1", api.MyPresence["rt_host"]);
        Assert.Equal($"+rt_join {Me}", api.MyPresence["connect"]);

        agent.ShutdownForTest();
        Assert.False(api.MyPresence.ContainsKey("rt_host"));
        Assert.False(api.MyPresence.ContainsKey("connect"));
        Assert.True(api.Disposed);
    }

    [Fact]
    public void Host_accepts_session_requests_from_friends_only()
    {
        var (agent, api, _) = Make();
        agent.Enqueue("{\"cmd\":\"host\",\"gamePort\":27015,\"friendsOnly\":true}");
        agent.Step();
        api.QueueSessionRequest(Alex);
        api.QueueSessionRequest(76561198999999999);
        agent.Step();
        Assert.Contains(Alex, api.Accepted);
        Assert.DoesNotContain(76561198999999999UL, api.Accepted);
        agent.ShutdownForTest();
    }

    [Fact]
    public void Join_opens_the_guest_tunnel_and_reports_the_port()
    {
        var (agent, api, output) = Make();
        agent.Enqueue($"{{\"cmd\":\"join\",\"host\":\"{Alex}\",\"localPort\":0}}");
        agent.Step();
        var listening = Events(output).Single(e => (string?)e["evt"] == "listening");
        Assert.True((int)listening["port"]! > 0);
        Assert.Equal("Alex", (string?)listening["hostName"]);
        Assert.Contains(Alex, api.Accepted);
        agent.ShutdownForTest();
    }

    [Fact]
    public void Joining_yourself_is_refused_with_a_message()
    {
        var (agent, _, output) = Make();
        agent.Enqueue($"{{\"cmd\":\"join\",\"host\":\"{Me}\",\"localPort\":0}}");
        agent.Step();
        Assert.Contains(Events(output), e => (string?)e["evt"] == "error" && ((string?)e["message"])!.Contains("your own"));
    }

    [Fact]
    public void Steam_Join_Game_becomes_a_joinRequest_for_the_id_in_the_connect_string()
    {
        var (agent, api, output) = Make();
        api.QueueJoinRequest(Sam, $"+rt_join {Alex}");
        agent.Step();
        var ev = Events(output).Single(e => (string?)e["evt"] == "joinRequest");
        Assert.Equal(Alex.ToString(), (string?)ev["host"]);
    }

    [Fact]
    public void Invite_sends_our_connect_string()
    {
        var (agent, api, _) = Make();
        agent.Enqueue($"{{\"cmd\":\"invite\",\"friend\":\"{Sam}\"}}");
        agent.Step();
        Assert.Equal((Sam, $"+rt_join {Me}"), api.Invites.Single());
    }

    [Fact]
    public void A_failed_Steam_start_is_reported_as_fatal()
    {
        var output = new StringWriter();
        var agent = new SteamAgent(() => throw new SteamInitException("steam_not_running", "Steam is not running."), new StringReader(""), output);
        Assert.Equal(2, agent.Run());
        var fatal = Events(output).Single();
        Assert.Equal("fatal", (string?)fatal["evt"]);
        Assert.Equal("steam_not_running", (string?)fatal["code"]);
    }

    [Fact]
    public async Task The_agent_stops_when_its_stdin_closes()
    {
        var api = new FakeSteamApi(Me);
        var output = new StringWriter();
        var agent = new SteamAgent(() => api, new StringReader("{\"cmd\":\"presence\",\"on\":true}\n"), output);
        var run = Task.Run(() => agent.Run());
        Assert.Same(run, await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(5)))); // exits when the launcher goes away
        Assert.True(api.Disposed);
        Assert.False(api.MyPresence.ContainsKey("rt_host")); // presence never outlives the launcher
        Assert.Contains(Events(output), e => (string?)e["evt"] == "stopped");
    }
}

public class AgentClientParsingTests
{
    [Fact]
    public async Task Parses_ready_friends_and_listening_into_results()
    {
        var c = new SteamAgentClient();
        c.HandleLine("{\"evt\":\"ready\",\"steamId\":\"76561198000000001\",\"name\":\"Me\"}");
        var ready = await c.WaitReadyAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(76561198000000001UL, ready.Id);

        var query = c.QueryFriendsAsync(TimeSpan.FromSeconds(2));
        c.HandleLine("{\"evt\":\"friends\",\"friends\":[{\"id\":\"76561198000000002\",\"name\":\"Alex\",\"state\":1,\"inGame\":true,\"hosting\":true}]}");
        var friends = await query;
        Assert.True(friends.Single().Hosting);

        var join = c.StartJoinAsync(76561198000000002, 27016, TimeSpan.FromSeconds(2));
        c.HandleLine("{\"evt\":\"listening\",\"port\":27016}");
        Assert.Equal(27016, await join);
    }

    [Fact]
    public async Task A_fatal_event_fails_waiters_with_the_readable_message()
    {
        var c = new SteamAgentClient();
        c.HandleLine("{\"evt\":\"fatal\",\"code\":\"steam_not_running\",\"message\":\"Steam is not running.\"}");
        var ex = await Assert.ThrowsAsync<SteamInitException>(() => c.WaitReadyAsync(TimeSpan.FromSeconds(1)));
        Assert.Equal("Steam is not running.", ex.Message);
    }

    [Fact]
    public async Task Port_in_use_fails_the_join_waiter()
    {
        var c = new SteamAgentClient();
        var join = c.StartJoinAsync(76561198000000002, 27016, TimeSpan.FromSeconds(2));
        c.HandleLine("{\"evt\":\"error\",\"code\":\"port_in_use\",\"message\":\"Port 27016 on this PC is already in use.\"}");
        await Assert.ThrowsAsync<TunnelBindException>(() => join);
    }

    [Fact]
    public void Stats_and_peer_events_are_raised()
    {
        var c = new SteamAgentClient();
        AgentStats? stats = null;
        string? peerState = null;
        c.StatsReceived += s => stats = s;
        c.PeerChanged += (_, _, state, _) => peerState = state;
        c.HandleLine("{\"evt\":\"stats\",\"mode\":\"host\",\"presence\":true,\"peers\":[{\"id\":\"76561198000000002\",\"name\":\"Alex\",\"link\":\"relay\",\"in\":10,\"out\":12,\"inBytes\":1000,\"outBytes\":1200,\"sinceIn\":0.1}]}");
        c.HandleLine("{\"evt\":\"peer\",\"id\":\"76561198000000002\",\"name\":\"Alex\",\"state\":\"joined\"}");
        c.HandleLine("not json at all");
        Assert.Equal("relay", stats!.Peers.Single().Link);
        Assert.Equal("joined", peerState);
    }
}
