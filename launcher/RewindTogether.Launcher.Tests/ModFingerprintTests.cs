using System.Text.Json.Nodes;
using RewindTogether.Launcher.Core;
using RewindTogether.Launcher.Steam;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class ModFingerprintTests
{
    private const ulong Me = 76561198000000001, Alex = 76561198000000002;

    private static GameModInfo Pak(TempDir t, string name, int size, ModKind kind = ModKind.Pak, bool enabled = true)
    {
        string path = t.Combine("paks", kind.ToString(), name + ".pak");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, new byte[size]);
        return new GameModInfo { Name = name, Kind = kind, Enabled = enabled, Path = path };
    }

    private static GameModInfo Script(string name, bool builtIn = false, bool enabled = true) =>
        new() { Name = name, Kind = ModKind.Ue4ssLua, Enabled = enabled, BuiltIn = builtIn, Path = name };

    private static ModFingerprint RoundTrip(ModFingerprint f)
    {
        var p = f.ToPresence();
        return ModFingerprint.FromPresence(k => p.TryGetValue(k, out var v) ? v : null)!;
    }

    // ------------------------------------------------------------------ what counts

    [Fact]
    public void Counts_enabled_content_and_script_mods_but_not_UE4SSs_own_or_Rewind_Together()
    {
        using var t = new TempDir();
        var f = ModFingerprint.FromScan("1.7.1", new[]
        {
            Pak(t, "CoolShelves", 10),
            Pak(t, "NightMarket", 20, ModKind.LogicMod),
            Pak(t, "OldThing", 30, enabled: false),
            Script("BetterLights"),
            Script("Keybinds", builtIn: true),
            Script(GameInstall.RewindTogetherFolder),
            Script("SwitchedOff", enabled: false),
        });
        Assert.Equal("1.7.1", f.RtVersion);
        Assert.Equal(new[] { "CoolShelves", "NightMarket" }, f.Content.Names);
        Assert.Equal(new[] { "BetterLights" }, f.Scripts.Names);
    }

    [Fact]
    public void Reads_a_real_game_folder_through_the_mod_scan()
    {
        using var t = new TempDir();
        var game = Fixtures.FakeGame(t);
        Fixtures.WriteAt(Path.Combine(game.PakModsDir, "CoolShelves.pak"), "pak");
        Fixtures.WriteAt(Path.Combine(game.LogicModsDir, "NightMarket.pak"), "logic");
        Fixtures.WriteAt(Path.Combine(game.Ue4ssModsDir, "BetterLights", "Scripts", "main.lua"), "-- mod");
        Fixtures.WriteAt(Path.Combine(game.Ue4ssModsDir, "BetterLights", "enabled.txt"), "");
        Fixtures.WriteAt(Path.Combine(game.RewindTogetherDir, "Scripts", "main.lua"), "-- rt");

        var scan = new ModManager(game, t.Combine("installed.json")).ScanGame();
        var f = ModFingerprint.FromScan("1.7.1", scan);
        Assert.Equal(new[] { "CoolShelves", "NightMarket" }, f.Content.Names);
        Assert.Equal(new[] { "BetterLights" }, f.Scripts.Names);
    }

    [Fact]
    public void The_hash_ignores_order_but_not_file_size()
    {
        using var t = new TempDir();
        var a = ModFingerprint.FromScan("1", new[] { Pak(t, "A", 1), Pak(t, "B", 2) });
        var b = ModFingerprint.FromScan("1", new[] { Pak(t, "B", 2), Pak(t, "A", 1) });
        Assert.Equal(a.Content.Hash, b.Content.Hash);
        using var t2 = new TempDir();
        var c = ModFingerprint.FromScan("1", new[] { Pak(t2, "A", 1), Pak(t2, "B", 3) });
        Assert.NotEqual(a.Content.Hash, c.Content.Hash);
    }

    // ------------------------------------------------------------------ over Steam

    [Fact]
    public void Survives_the_trip_through_Steam_presence()
    {
        using var t = new TempDir();
        var f = ModFingerprint.FromScan("1.7.1", new[] { Pak(t, "CoolShelves", 10), Script("BetterLights") });
        var back = RoundTrip(f);
        Assert.Equal(f.RtVersion, back.RtVersion);
        Assert.Equal(f.Content.Hash, back.Content.Hash);
        Assert.Equal(f.Content.Names, back.Content.Names);
        Assert.Equal(f.Scripts.Names, back.Scripts.Names);
        Assert.Null(ModMismatch.Compare(f, back) is { Any: true } ? "differs" : null);
    }

    [Fact]
    public void Long_mod_lists_fit_Steams_limit_and_say_they_were_cut()
    {
        using var t = new TempDir();
        var mods = Enumerable.Range(0, 40).Select(i => Pak(t, $"A_Very_Long_Content_Mod_Name_Number_{i:00}", 1)).ToList();
        var f = ModFingerprint.FromScan("1.7.1", mods);
        Assert.All(f.ToPresence().Values, v => Assert.True(v.Length <= ModFingerprint.MaxValueLength, v.Length.ToString()));
        var back = RoundTrip(f);
        Assert.Equal(40, back.Content.Count);
        Assert.False(back.Content.NamesComplete);
        Assert.Equal(f.Content.Hash, back.Content.Hash);   // the hash still compares exactly
    }

    [Fact]
    public void A_host_with_an_older_launcher_publishes_nothing_and_nothing_is_compared()
    {
        Assert.Null(ModFingerprint.FromPresence(_ => null));
        Assert.Null(ModMismatch.Compare(ModFingerprint.FromScan("1.7.1", Array.Empty<GameModInfo>()), null));
    }

    // ------------------------------------------------------------------ comparing

    [Fact]
    public void Same_mods_mean_no_warning()
    {
        using var t = new TempDir();
        var mods = new[] { Pak(t, "CoolShelves", 10), Script("BetterLights") };
        var diff = ModMismatch.Compare(ModFingerprint.FromScan("1.7.1", mods), RoundTrip(ModFingerprint.FromScan("1.7.1", mods)));
        Assert.False(diff!.Any);
    }

    [Fact]
    public void A_different_Rewind_Together_version_is_the_strongest_warning()
    {
        var guest = ModFingerprint.FromScan("1.7.0", Array.Empty<GameModInfo>());
        var host = RoundTrip(ModFingerprint.FromScan("1.7.1", Array.Empty<GameModInfo>()));
        var diff = ModMismatch.Compare(guest, host)!;
        Assert.True(diff.VersionDiffers);
        Assert.Equal("bad", diff.Tone);
        Assert.Contains("1.7.1", diff.ShortText);
        Assert.Contains("same version", diff.Explain("Alex"));
    }

    [Fact]
    public void Missing_or_extra_content_mods_are_named()
    {
        using var t = new TempDir();
        var host = RoundTrip(ModFingerprint.FromScan("1.7.1", new[] { Pak(t, "CoolShelves", 10), Pak(t, "NightMarket", 5, ModKind.LogicMod) }));
        using var t2 = new TempDir();
        var guest = ModFingerprint.FromScan("1.7.1", new[] { Pak(t2, "CoolShelves", 10), Pak(t2, "BigSigns", 7) });
        var diff = ModMismatch.Compare(guest, host)!;
        Assert.Equal("warn", diff.Tone);
        Assert.Equal(new[] { "NightMarket" }, diff.ContentHostOnly);
        Assert.Equal(new[] { "BigSigns" }, diff.ContentGuestOnly);
        string text = diff.Explain("Alex");
        Assert.Contains("Alex has, you don't: NightMarket", text);
        Assert.Contains("You have, Alex doesn't: BigSigns", text);
    }

    [Fact]
    public void The_same_content_mods_in_different_versions_still_warn()
    {
        using var t = new TempDir();
        var host = RoundTrip(ModFingerprint.FromScan("1.7.1", new[] { Pak(t, "CoolShelves", 10) }));
        using var t2 = new TempDir();
        var guest = ModFingerprint.FromScan("1.7.1", new[] { Pak(t2, "CoolShelves", 11) });
        var diff = ModMismatch.Compare(guest, host)!;
        Assert.True(diff.ContentDiffers);
        Assert.Empty(diff.ContentHostOnly);
        Assert.Contains("different versions", diff.Explain("Alex"));
    }

    [Fact]
    public void Script_mods_alone_are_only_a_note()
    {
        var host = RoundTrip(ModFingerprint.FromScan("1.7.1", new[] { Script("BetterLights") }));
        var guest = ModFingerprint.FromScan("1.7.1", Array.Empty<GameModInfo>());
        var diff = ModMismatch.Compare(guest, host)!;
        Assert.False(diff.ContentDiffers);
        Assert.True(diff.ScriptsDiffer);
        Assert.Equal("info", diff.Tone);
        Assert.Contains("usually fine", diff.Explain("Alex"));
    }

    // ------------------------------------------------------------------ the Steam helper

    private static (SteamAgent Agent, FakeSteamApi Api, StringWriter Output) Agent()
    {
        var api = new FakeSteamApi(Me) { LocalName = "Me" };
        api.Friends.Add(new SteamFriend(Alex, "Alex", 1, 3552140));
        var output = new StringWriter();
        var agent = new SteamAgent(() => api, new StringReader(""), output) { FriendsWait = TimeSpan.FromSeconds(2) };
        agent.StartForTest();
        return (agent, api, output);
    }

    [Fact]
    public void The_host_publishes_its_mods_and_clears_them_with_its_presence()
    {
        var (agent, api, _) = Agent();
        agent.Enqueue("{\"cmd\":\"presence\",\"on\":true,\"mods\":{\"rt_ver\":\"1.7.1\",\"rt_cmods\":\"1:abc\",\"rt_cnames\":\"CoolShelves\",\"not_ours\":\"x\"}}");
        agent.Step();
        Assert.Equal("1.7.1", api.MyPresence["rt_ver"]);
        Assert.Equal("CoolShelves", api.MyPresence["rt_cnames"]);
        Assert.False(api.MyPresence.ContainsKey("not_ours"));

        agent.Enqueue("{\"cmd\":\"presence\",\"on\":false}");
        agent.Step();
        Assert.DoesNotContain(api.MyPresence.Keys, k => k.StartsWith("rt_"));
        agent.ShutdownForTest();
    }

    [Fact]
    public async Task A_guest_sees_a_hosting_friends_mods_in_the_friend_list()
    {
        var (agent, api, output) = Agent();
        api.FriendPresence[(Alex, "rt_host")] = "1";
        api.FriendPresence[(Alex, "rt_ver")] = "1.7.1";
        api.FriendPresence[(Alex, "rt_cmods")] = "1:abc";
        api.FriendPresence[(Alex, "rt_cnames")] = "CoolShelves";
        agent.Enqueue("{\"cmd\":\"friends\"}");
        for (int i = 0; i < 5; i++) agent.Step();

        string line = output.ToString().Split('\n').Single(l => l.Contains("\"evt\":\"friends\""));
        var client = new SteamAgentClient();
        var query = client.QueryFriendsAsync(TimeSpan.FromSeconds(2));
        client.HandleLine(line);
        var alex = (await query).Single();
        Assert.Equal("1.7.1", alex.Fingerprint!.RtVersion);
        Assert.Equal(new[] { "CoolShelves" }, alex.Fingerprint.Content.Names);
        Assert.Equal(1, alex.Fingerprint.Content.Count);
        agent.ShutdownForTest();
    }
}
