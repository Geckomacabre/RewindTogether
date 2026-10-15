using System.Text;
using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class LaunchFilesTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1760467200);

    [Fact]
    public void Host_request_matches_the_contract_exactly()
        => Assert.Equal("{\"action\":\"host\",\"written\":1760467200}", LaunchFiles.BuildLaunchJson(LaunchRequest.Host(Now)));

    [Fact]
    public void Join_request_matches_the_contract_exactly()
        => Assert.Equal("{\"action\":\"join\",\"address\":\"127.0.0.1:27016\",\"host_name\":\"Alex\",\"written\":1760467200}",
            LaunchFiles.BuildLaunchJson(LaunchRequest.Join("127.0.0.1:27016", "Alex", Now)));

    [Fact]
    public void Join_without_a_name_omits_host_name()
        => Assert.Equal("{\"action\":\"join\",\"address\":\"10.0.0.2\",\"written\":1760467200}",
            LaunchFiles.BuildLaunchJson(LaunchRequest.Join(" 10.0.0.2 ", "  ", Now)));

    [Fact]
    public void Names_stay_raw_UTF8_quotes_are_escaped_and_control_characters_dropped()
    {
        // The mod's flat JSON reader handles \" and \\ but not \uXXXX, so accented names must stay as UTF-8.
        string json = LaunchFiles.BuildLaunchJson(LaunchRequest.Join("1.2.3.4", "Zoë \"The\\Clerk\"\n", Now));
        Assert.Contains("\"host_name\":\"Zoë \\\"The\\\\Clerk\\\"\"", json);
        Assert.DoesNotContain("\\u", json);
    }

    [Fact]
    public void A_join_needs_an_address()
        => Assert.Throws<ArgumentException>(() => LaunchFiles.BuildLaunchJson(new LaunchRequest("join", "", null, 1)));

    [Fact]
    public void Writing_is_atomic_UTF8_without_BOM_and_replaces_an_old_request()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        File.WriteAllText(g.LaunchJson, "{ \"action\": \"host\", \"written\": 1 }");

        LaunchFiles.WriteLaunchRequest(g, LaunchRequest.Join("127.0.0.1:27016", "Alex", Now));

        byte[] bytes = File.ReadAllBytes(g.LaunchJson);
        Assert.NotEqual(0xEF, bytes[0]);
        Assert.Equal(LaunchFiles.BuildLaunchJson(LaunchRequest.Join("127.0.0.1:27016", "Alex", Now)), Encoding.UTF8.GetString(bytes));
        Assert.False(File.Exists(g.LaunchJson + ".tmp"));
        Assert.Empty(Directory.GetFiles(g.Win64, "*.tmp"));
    }

    [Fact]
    public async Task Atomic_write_waits_out_a_reader_that_briefly_holds_the_file()
    {
        using var t = new TempDir();
        string path = t.Write("RewindTogether.launch.json", "old");
        var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); // like Lua's io.open, no delete sharing
        var release = Task.Run(async () => { await Task.Delay(150); reader.Dispose(); });

        AtomicFile.WriteAllText(path, "new");
        await release;

        Assert.Equal("new", File.ReadAllText(path));
    }

    [Fact]
    public void Launcher_path_is_written_once_per_change()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        LaunchFiles.WriteLauncherPath(g, @"C:\Games\RewindTogetherLauncher.exe");
        Assert.Equal(@"C:\Games\RewindTogetherLauncher.exe", File.ReadAllText(g.LauncherTxt));
        var stamp = File.GetLastWriteTimeUtc(g.LauncherTxt);
        LaunchFiles.WriteLauncherPath(g, @"C:\Games\RewindTogetherLauncher.exe");
        Assert.Equal(stamp, File.GetLastWriteTimeUtc(g.LauncherTxt));
    }

    // ------------------------------------------------------------------ status.json

    private const string RealStatus = "{ \"version\": \"1.7.0\", \"mode\": \"ListenServer\", \"in_store\": true, \"players\": 3, \"port\": 27015, \"last_error\": \"\", \"updated\": 1760467200 }\n";

    [Fact]
    public void Reads_the_mods_heartbeat()
    {
        var s = LaunchFiles.ParseStatus(RealStatus)!;
        Assert.Equal("1.7.0", s.Version);
        Assert.True(s.IsHosting);
        Assert.True(s.InStore);
        Assert.Equal(3, s.Players);
        Assert.Equal(27015, s.Port);
        Assert.Equal("", s.LastError);
        Assert.Equal(1760467200, s.Updated);
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(6, false)]
    [InlineData(7, true)]
    [InlineData(600, true)]
    public void Is_stale_after_six_seconds(int ageSeconds, bool stale)
    {
        var s = LaunchFiles.ParseStatus(RealStatus)!;
        Assert.Equal(stale, s.IsStale(Now.AddSeconds(ageSeconds)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("{ \"version\": \"1.7.0\", \"mo")]   // caught mid-rewrite
    [InlineData("{ \"version\": \"1.7.0\" }")]      // no "updated"
    [InlineData("[1,2]")]
    public void Missing_partial_or_odd_files_read_as_null(string? json)
        => Assert.Null(LaunchFiles.ParseStatus(json));

    [Fact]
    public void Missing_optional_fields_get_safe_defaults()
    {
        var s = LaunchFiles.ParseStatus("{ \"updated\": 5, \"players\": 2.0 }")!;
        Assert.Equal("Standalone", s.Mode);
        Assert.True(s.IsStandalone);
        Assert.Equal(2, s.Players);
        Assert.Equal(27015, s.Port);
    }

    [Fact]
    public void ReadStatus_tolerates_the_file_being_absent()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        Assert.Null(LaunchFiles.ReadStatus(g));
        File.WriteAllText(g.StatusJson, RealStatus);
        Assert.True(LaunchFiles.ReadStatus(g)!.IsHosting);
    }

    // ------------------------------------------------------------------ addresses

    [Theory]
    [InlineData("192.168.1.50", "192.168.1.50")]
    [InlineData(" 100.101.102.103:27015 ", "100.101.102.103:27015")]
    [InlineData("my-pc.tail1234.ts.net", "my-pc.tail1234.ts.net")]
    [InlineData("udp://10.0.0.1:7777/", "10.0.0.1:7777")]
    public void Accepts_usable_addresses(string input, string expected)
        => Assert.Equal(expected, LaunchFiles.NormalizeAddress(input, out _));

    [Theory]
    [InlineData("")]
    [InlineData("1.2.3")]
    [InlineData("1.2.3.4:99999")]
    [InlineData("steam.76561198000000000")]
    [InlineData("fe80::1")]
    [InlineData("not an address")]
    public void Rejects_unusable_addresses_with_a_reason(string input)
    {
        Assert.Null(LaunchFiles.NormalizeAddress(input, out string? problem));
        Assert.False(string.IsNullOrWhiteSpace(problem));
    }
}

public class CommandLineTests
{
    [Fact]
    public void Join_from_the_mod()
    {
        var a = LaunchArgs.Parse(new[] { "--join", "76561198000000001" });
        Assert.Equal(76561198000000001UL, a.JoinSteamId);
        Assert.False(a.Host);
        Assert.Equal(new[] { "--join", "76561198000000001" }, a.ForwardableArgs());
    }

    [Fact]
    public void Steam_connect_string_forms()
    {
        Assert.Equal(76561198000000002UL, LaunchArgs.Parse(new[] { "+rt_join", "76561198000000002" }).JoinSteamId);
        Assert.Equal(76561198000000003UL, LaunchArgs.Parse(new[] { "+rt_join 76561198000000003" }).JoinSteamId);
    }

    [Fact]
    public void Bad_ids_are_reported_not_used()
    {
        var a = LaunchArgs.Parse(new[] { "--join", "12345" });
        Assert.Null(a.JoinSteamId);
        Assert.Single(a.Problems);
    }

    [Fact]
    public void Host_and_dev_options()
    {
        var a = LaunchArgs.Parse(new[] { "--host", "--game-dir", @"D:\x", "--data-dir", @"C:\d", "--tab", "MODS" });
        Assert.True(a.Host);
        Assert.Equal(@"D:\x", a.GameDir);
        Assert.Equal(@"C:\d", a.DataDir);
        Assert.Equal("mods", a.Tab);
    }

    [Theory]
    [InlineData("76561198000000000", true)]
    [InlineData("https://steamcommunity.com/profiles/76561198000000000/", true)]
    [InlineData("7656119800000000", false)]
    [InlineData("86561198000000000", false)]
    public void Steam_ids(string text, bool ok) => Assert.Equal(ok, SteamIds.TryParse(text, out _));
}

public class SaveBackupTests
{
    [Fact]
    public void Zips_the_saves_then_skips_until_they_change()
    {
        using var t = new TempDir();
        string saves = t.Combine("SaveGames");
        t.Write(Path.Combine("SaveGames", "Player_Save1.sav"), "save one");
        t.Write(Path.Combine("SaveGames", "Backups", "old.sav"), "older");
        string backups = t.Combine("Backups");

        var first = SaveBackup.Run(saves, backups, force: false, new DateTime(2026, 10, 14, 12, 0, 0));
        Assert.True(first.Created);
        using (var zip = System.IO.Compression.ZipFile.OpenRead(first.ZipPath!))
            Assert.Equal(new[] { "SaveGames/Backups/old.sav", "SaveGames/Player_Save1.sav" }, zip.Entries.Select(e => e.FullName).OrderBy(x => x));

        var second = SaveBackup.Run(saves, backups, force: false);
        Assert.False(second.Created);

        var forced = SaveBackup.Run(saves, backups, force: true, new DateTime(2026, 10, 14, 12, 0, 0));
        Assert.True(forced.Created);
        Assert.NotEqual(first.ZipPath, forced.ZipPath); // same second: a -2 suffix, never an overwrite
    }

    [Fact]
    public void No_saves_is_not_an_error()
    {
        using var t = new TempDir();
        var r = SaveBackup.Run(t.Combine("nope"), t.Combine("b"), force: true);
        Assert.False(r.Created);
        Assert.Contains("nothing to back up", r.Message);
    }

    [Fact]
    public void A_save_the_game_has_open_can_still_be_backed_up()
    {
        using var t = new TempDir();
        string file = t.Write(Path.Combine("SaveGames", "Player_Save1.sav"), "live");
        using var held = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        Assert.True(SaveBackup.Run(t.Combine("SaveGames"), t.Combine("b"), force: true).Created);
    }
}
