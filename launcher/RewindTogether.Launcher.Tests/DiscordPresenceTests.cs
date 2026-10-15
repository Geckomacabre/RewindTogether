using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json.Nodes;
using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

/// <summary>A stand-in for the Discord app: one named pipe speaking Discord's frames.</summary>
internal sealed class FakeDiscord : IDisposable
{
    private readonly NamedPipeServerStream _server;
    private readonly List<JsonObject> _received = new();

    public FakeDiscord(string? refuse = null, string? error = null)
    {
        Refuse = refuse;
        Error = error;
        _server = new NamedPipeServerStream(Prefix + "0", PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        new Thread(Serve) { IsBackground = true, Name = "fake Discord" }.Start();
    }

    public string Prefix { get; } = $"rt-test-discord-{Guid.NewGuid():N}-";
    /// <summary>Close the connection at the handshake, with this message.</summary>
    public string? Refuse { get; }
    /// <summary>Answer every SET_ACTIVITY with an error carrying this message.</summary>
    public string? Error { get; }
    public string? ClientId { get; private set; }

    public JsonObject[] Received { get { lock (_received) return _received.ToArray(); } }

    private void Serve()
    {
        try
        {
            _server.WaitForConnection();
            var (_, hello) = DiscordIpcClient.Read(_server);
            ClientId = (string?)hello?["client_id"];
            if (Refuse != null)
            {
                Send(DiscordIpcClient.OpClose, new JsonObject { ["code"] = 4000, ["message"] = Refuse });
                return;
            }
            Send(DiscordIpcClient.OpFrame, new JsonObject { ["cmd"] = "DISPATCH", ["evt"] = "READY", ["data"] = new JsonObject { ["v"] = 1 } });
            while (true)
            {
                var (_, msg) = DiscordIpcClient.Read(_server);
                lock (_received) _received.Add(msg!);
                string? nonce = (string?)msg?["nonce"];
                Send(DiscordIpcClient.OpFrame, Error != null
                    ? new JsonObject { ["cmd"] = "SET_ACTIVITY", ["evt"] = "ERROR", ["data"] = new JsonObject { ["code"] = 4000, ["message"] = Error }, ["nonce"] = nonce }
                    : new JsonObject { ["cmd"] = "SET_ACTIVITY", ["evt"] = null, ["data"] = msg?["args"]?["activity"]?.DeepClone(), ["nonce"] = nonce });
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { }   // the client went away
    }

    private void Send(int op, JsonObject payload)
    {
        _server.Write(DiscordIpcClient.Frame(op, payload));
        _server.Flush();
    }

    public void Dispose() => _server.Dispose();
}

public class DiscordPresenceTests
{
    private const string AppId = "123456789";

    private static ModStatus Mod(string mode, bool inStore, int players) => new("1.7.1", mode, inStore, players, 7777, "", 0);

    private static DiscordStatusInput Input(bool running = true, bool hosting = false, bool joining = false, ModStatus? mod = null) =>
        new(running, hosting, joining, mod, new DateTime(2026, 10, 15, 12, 0, 0, DateTimeKind.Utc), "https://github.com/Geckomacabre/RewindTogether");

    private static DiscordActivity Activity(string details) =>
        new(details, "Open to friends", 1_700_000_000, DiscordStatus.LogoKey, "Rewind Together", null, null);

    private static void Until(Func<bool> condition, int timeoutMs = 5000)
    {
        var sw = Stopwatch.StartNew();
        while (!condition())
        {
            Assert.True(sw.ElapsedMilliseconds < timeoutMs, "timed out waiting");
            Thread.Sleep(20);
        }
    }

    // ------------------------------------------------------------------ what it says

    [Fact]
    public void Nothing_is_shown_while_the_game_is_closed()
    {
        Assert.Null(DiscordStatus.For(Input(running: false, hosting: true)));
    }

    [Fact]
    public void A_host_shows_how_many_are_in_the_store()
    {
        var alone = DiscordStatus.For(Input(hosting: true, mod: Mod("ListenServer", true, 1)))!;
        Assert.Equal("Hosting a video store", alone.Details);
        Assert.Equal("Open to friends", alone.State);

        var three = DiscordStatus.For(Input(mod: Mod("ListenServer", true, 3)))!;   // the mod alone says so too
        Assert.Equal("Hosting a video store", three.Details);
        Assert.Equal("3 players in the store", three.State);
    }

    [Fact]
    public void A_guest_visits_a_friends_store_and_no_one_is_named()
    {
        var a = DiscordStatus.For(Input(joining: true, mod: Mod("Client", true, 2)))!;
        Assert.Equal("Visiting a friend's store", a.Details);
        Assert.Equal("2 players in the store", a.State);
        Assert.Equal("Working the store together", DiscordStatus.For(Input(joining: true))!.State);
    }

    [Fact]
    public void Solo_play_and_the_main_menu()
    {
        var solo = DiscordStatus.For(Input(mod: Mod("Standalone", true, 1)))!;
        Assert.Equal(("Running the store", "Solo"), (solo.Details, solo.State));
        var menu = DiscordStatus.For(Input(mod: Mod("Standalone", false, 1)))!;
        Assert.Equal("In the main menu", menu.Details);
        Assert.Null(menu.State);
        Assert.Equal("In the main menu", DiscordStatus.For(Input())!.Details);   // the mod has not reported yet
    }

    [Fact]
    public void The_activity_carries_the_logo_the_play_time_and_a_link()
    {
        var json = DiscordStatus.For(Input(hosting: true))!.ToJson();
        Assert.Equal(DiscordStatus.LogoKey, (string?)json["assets"]!["large_image"]);
        Assert.Equal(new DateTimeOffset(2026, 10, 15, 12, 0, 0, TimeSpan.Zero).ToUnixTimeSeconds(), (long)json["timestamps"]!["start"]!);
        var button = json["buttons"]![0]!;
        Assert.Equal("Get Rewind Together", (string?)button["label"]);
        Assert.Equal("https://github.com/Geckomacabre/RewindTogether", (string?)button["url"]);
    }

    [Fact]
    public void Text_is_kept_within_Discords_limits_and_odd_links_are_left_out()
    {
        var json = new DiscordActivity(new string('x', 300), "x", null, "logo", "Rewind Together", "Open", "http://example.com").ToJson();
        Assert.Equal(DiscordActivity.MaxText, ((string)json["details"]!).Length);
        Assert.EndsWith("…", (string)json["details"]!);
        Assert.Equal(2, ((string)json["state"]!).Length);        // Discord refuses one-character strings
        Assert.Null(json["buttons"]);                             // only https links
        Assert.Null(json["timestamps"]);
    }

    // ------------------------------------------------------------------ the pipe

    [Fact]
    public void Connects_with_the_application_id_and_sets_the_status_for_a_process()
    {
        using var discord = new FakeDiscord();
        using var client = new DiscordIpcClient(AppId, discord.Prefix);
        Assert.True(client.TryConnect(500));
        Assert.Equal(AppId, discord.ClientId);

        Assert.Null(client.SetActivity(4242, Activity("Hosting a video store")));
        var sent = discord.Received.Single();
        Assert.Equal("SET_ACTIVITY", (string?)sent["cmd"]);
        Assert.Equal(4242, (int)sent["args"]!["pid"]!);
        Assert.Equal("Hosting a video store", (string?)sent["args"]!["activity"]!["details"]);
        Assert.False(string.IsNullOrEmpty((string?)sent["nonce"]));
    }

    [Fact]
    public void Discords_complaints_come_back_as_text()
    {
        using var discord = new FakeDiscord(error: "child \"activity\" fails");
        using var client = new DiscordIpcClient(AppId, discord.Prefix);
        Assert.True(client.TryConnect(500));
        Assert.Equal("child \"activity\" fails", client.SetActivity(4242, Activity("x y")));
    }

    [Fact]
    public void Without_Discord_connecting_fails_quickly_and_quietly()
    {
        using var client = new DiscordIpcClient(AppId, $"rt-test-nobody-{Guid.NewGuid():N}-");
        var sw = Stopwatch.StartNew();
        Assert.False(client.TryConnect(20));
        Assert.True(sw.ElapsedMilliseconds < 3000, sw.ElapsedMilliseconds.ToString());
        Assert.False(client.Connected);
    }

    [Fact]
    public void A_refused_handshake_is_not_a_connection()
    {
        using var discord = new FakeDiscord(refuse: "Invalid Client ID");
        using var client = new DiscordIpcClient(AppId, discord.Prefix);
        Assert.False(client.TryConnect(50));
        Assert.Equal(AppId, discord.ClientId);
    }

    // ------------------------------------------------------------------ the service

    private static DiscordPresenceService Service(FakeDiscord discord) =>
        new(() => new DiscordIpcClient(AppId, discord.Prefix), TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(200));

    [Fact]
    public void Sends_only_on_a_change_and_clears_the_status_when_it_stops()
    {
        using var discord = new FakeDiscord();
        var service = Service(discord);
        service.Want(4242, Activity("Hosting a video store"));
        Until(() => discord.Received.Length == 1);
        Until(() => service.Shown != null);
        Assert.Contains("Hosting a video store", service.StatusText);

        service.Want(4242, Activity("Hosting a video store"));        // the same again: nothing sent
        Thread.Sleep(300);
        Assert.Single(discord.Received);

        service.Want(4242, Activity("Running the store"));
        Until(() => discord.Received.Length == 2);
        Assert.Equal("Running the store", (string?)discord.Received[1]["args"]!["activity"]!["details"]);

        service.Dispose();
        Until(() => discord.Received.Length == 3);
        var cleared = discord.Received[2]["args"]!;
        Assert.Equal(4242, (int)cleared["pid"]!);
        Assert.Null(cleared["activity"]);
    }

    [Fact]
    public void When_the_game_closes_the_status_is_cleared_for_the_games_process()
    {
        using var discord = new FakeDiscord();
        using var service = Service(discord);
        service.Want(4242, Activity("Hosting a video store"));
        Until(() => discord.Received.Length == 1);
        service.Want(0, null);
        Until(() => discord.Received.Length == 2);
        Assert.Equal(4242, (int)discord.Received[1]["args"]!["pid"]!);
        Assert.Null(discord.Received[1]["args"]!["activity"]);
        Until(() => service.StatusText.Contains("nothing shown"));
    }

    [Fact]
    public void Without_Discord_the_service_just_says_so()
    {
        var service = new DiscordPresenceService(() => new DiscordIpcClient(AppId, $"rt-test-nobody-{Guid.NewGuid():N}-"),
            TimeSpan.FromMilliseconds(50), TimeSpan.FromSeconds(30));
        service.Want(4242, Activity("Hosting a video store"));
        Until(() => service.StatusText.Contains("not running"));
        Assert.Null(service.Shown);
        var sw = Stopwatch.StartNew();
        service.Dispose();
        Assert.True(sw.ElapsedMilliseconds < 3500, sw.ElapsedMilliseconds.ToString());
    }

    [Fact]
    public void Nothing_to_show_means_Discord_is_never_even_asked()
    {
        using var discord = new FakeDiscord();
        using var service = Service(discord);
        service.Want(4242, null);
        Thread.Sleep(300);
        Assert.Null(discord.ClientId);
        Assert.Empty(discord.Received);
    }
}
