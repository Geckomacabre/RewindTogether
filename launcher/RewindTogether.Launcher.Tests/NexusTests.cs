using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using RewindTogether.Launcher.Core;
using RewindTogether.Launcher.UI;
using Xunit;

namespace RewindTogether.Launcher.Tests;

/// <summary>A stand-in for Nexus Mods' GraphQL endpoint on 127.0.0.1: answers each POST through a handler and keeps the requests.</summary>
internal sealed class FakeNexusServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly List<(Dictionary<string, string> Headers, JsonObject Body)> _requests = new();

    public FakeNexusServer(Func<JsonObject, (int Status, string Body)> handler)
    {
        Handler = handler;
        _listener.Start();
        _ = Task.Run(AcceptLoop);
    }

    public Func<JsonObject, (int Status, string Body)> Handler { get; set; }
    public string Base => $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
    public (Dictionary<string, string> Headers, JsonObject Body)[] Requests { get { lock (_requests) return _requests.ToArray(); } }

    private async Task AcceptLoop()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch { return; }
            _ = Task.Run(() => Handle(client));
        }
    }

    private void Handle(TcpClient client)
    {
        using (client)
        using (var stream = client.GetStream())
        {
            var head = new List<byte>();
            while (!(head.Count >= 4 && head[^4] == '\r' && head[^3] == '\n' && head[^2] == '\r' && head[^1] == '\n'))
            {
                int b = stream.ReadByte();
                if (b < 0) return;
                head.Add((byte)b);
            }
            var lines = Encoding.ASCII.GetString(head.ToArray()).Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
            var headers = lines.Skip(1).Select(l => l.Split(':', 2)).Where(p => p.Length == 2)
                .ToDictionary(p => p[0].Trim(), p => p[1].Trim(), StringComparer.OrdinalIgnoreCase);
            int length = headers.TryGetValue("Content-Length", out var cl) ? int.Parse(cl) : 0;
            var body = new byte[length];
            int read = 0;
            while (read < length) { int n = stream.Read(body, read, length - read); if (n <= 0) break; read += n; }
            var json = JsonNode.Parse(body) as JsonObject ?? new JsonObject();
            lock (_requests) _requests.Add((headers, json));
            var (status, text) = Handler(json);
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            stream.Write(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {(status == 200 ? "OK" : "Error")}\r\nContent-Type: application/json\r\n" +
                                                 $"Content-Length: {bytes.Length}\r\nConnection: close\r\n\r\n"));
            stream.Write(bytes);
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
    }
}

public class NexusTests
{
    private static string ModJson(int id, string name, bool adult = false, string status = "published", string version = "1.0",
        string thumb = "https://staticdelivery.nexusmods.com/mods/8977/images/thumbnails/1/1.jpg") =>
        $$"""{"modId":{{id}},"name":"{{name}}","summary":"A &amp; B","version":"{{version}}","author":"Someone","downloads":1234,"endorsements":56,"updatedAt":"2026-10-12T10:00:00Z","thumbnailUrl":"{{thumb}}","adultContent":{{(adult ? "true" : "false")}},"category":"Gameplay","status":"{{status}}"}""";

    private static string ModsPage(int total, params string[] nodes) =>
        "{\"data\":{\"mods\":{\"totalCount\":" + total + ",\"nodes\":[" + string.Join(",", nodes) + "]}}}";

    private static string ById(params string[] nodes) =>
        "{\"data\":{\"legacyModsByDomain\":{\"nodes\":[" + string.Join(",", nodes) + "]}}}";

    private static NexusMod Mod(int id, string name = "Real VHS", string version = "1.2.0") =>
        new(id, name, "", version, "Someone", 0, 0, null, null, false, "");

    // ------------------------------------------------------------------ the API

    [Fact]
    public async Task Search_asks_for_Retro_Rewinds_mods_with_adult_mods_hidden_and_names_the_app()
    {
        using var nexus = new FakeNexusServer(_ => (200,
            ModsPage(2, ModJson(97, "Real VHS"), ModJson(98, "Spicy", adult: true), ModJson(99, "Gone", status: "hidden"), ModJson(100, "Plain thumb", thumb: "http://example.com/t.jpg"))));
        var client = new NexusClient(nexus.Base);
        var page = await client.SearchAsync("movie", NexusSort.Updated, includeAdult: false, offset: 20, count: 10, CancellationToken.None);

        var (headers, body) = nexus.Requests.Single();
        Assert.Equal("Rewind Together", headers["Application-Name"]);
        Assert.False(string.IsNullOrEmpty(headers["Application-Version"]));
        var vars = body["variables"]!;
        Assert.Equal(NexusLinks.GameDomain, (string?)vars["filter"]!["gameDomainName"]![0]!["value"]);
        Assert.Equal("movie", (string?)vars["filter"]!["nameStemmed"]![0]!["value"]);
        Assert.Equal("MATCHES", (string?)vars["filter"]!["nameStemmed"]![0]!["op"]);
        Assert.False((bool)vars["filter"]!["adultContent"]![0]!["value"]!);
        Assert.Equal("DESC", (string?)vars["sort"]![0]!["updatedAt"]!["direction"]);
        Assert.Equal(20, (int)vars["offset"]!);
        Assert.Equal(10, (int)vars["count"]!);

        Assert.Equal(2, page.Total);
        Assert.Equal(new[] { 97, 100 }, page.Mods.Select(m => m.ModId));   // the adult and the unpublished one are left out
        var vhs = page.Mods[0];
        Assert.Equal("A & B", vhs.Summary);
        Assert.Equal(1234, vhs.Downloads);
        Assert.Equal(new DateTime(2026, 10, 12, 10, 0, 0, DateTimeKind.Utc), vhs.UpdatedAt);
        Assert.StartsWith("https://", vhs.ThumbnailUrl);
        Assert.Null(page.Mods[1].ThumbnailUrl);                              // only https pictures
        Assert.Equal("https://www.nexusmods.com/retrorewindvideostoresimulator/mods/97?tab=files", vhs.FilesUrl);
    }

    [Fact]
    public async Task Adult_mods_come_back_only_when_asked_for()
    {
        using var nexus = new FakeNexusServer(_ => (200, ModsPage(1, ModJson(98, "Spicy", adult: true))));
        var page = await new NexusClient(nexus.Base).SearchAsync(null, NexusSort.Downloads, includeAdult: true, 0, 20, CancellationToken.None);
        Assert.Null(nexus.Requests.Single().Body["variables"]!["filter"]!["adultContent"]);
        Assert.Null(nexus.Requests.Single().Body["variables"]!["filter"]!["nameStemmed"]);
        Assert.True(page.Mods.Single().Adult);
    }

    [Fact]
    public async Task Mods_by_id_come_back_in_the_order_asked_and_unknown_ones_are_dropped()
    {
        using var nexus = new FakeNexusServer(_ => (200, ById(ModJson(53, "Employee Mod"), ModJson(97, "Real VHS"))));
        var mods = await new NexusClient(nexus.Base).ModsByIdAsync(new[] { 97, 404, 53 }, CancellationToken.None);
        Assert.Equal(new[] { 97, 53 }, mods.Select(m => m.ModId));
        var ids = nexus.Requests.Single().Body["variables"]!["ids"]!.AsArray();
        Assert.Equal(3, ids.Count);
        Assert.Equal(NexusLinks.GameDomain, (string?)ids[0]!["gameDomain"]);
    }

    [Fact]
    public async Task Files_and_the_md5_lookup_are_read_and_other_games_files_ignored()
    {
        using var nexus = new FakeNexusServer(req => ((string)req["query"]!).Contains("fileHash")
            ? (200, """{"data":{"fileHash":[{"gameId":1704,"modFile":{"modId":5,"fileId":1,"uri":"skyrim.zip","name":"x","version":"1","category":"MAIN"}},{"gameId":8977,"modFile":{"modId":97,"fileId":44,"uri":"Real VHS-97-1-2-0-1777640822.zip","name":"Real VHS","version":"1.2.0","category":"MAIN"}}]}}""")
            : (200, """{"data":{"modFiles":[{"fileId":44,"uri":"Real VHS-97-1-2-0-1777640822.zip","name":"Real VHS","version":"1.2.0","category":"MAIN"}]}}"""));
        var client = new NexusClient(nexus.Base);
        var files = await client.FilesAsync(97, CancellationToken.None);
        Assert.Equal("Real VHS-97-1-2-0-1777640822.zip", files.Single().FileName);
        Assert.Equal("8977", (string?)nexus.Requests[0].Body["variables"]!["gameId"]);

        var hit = await client.FileByMd5Async("ABCDEF0123456789ABCDEF0123456789", CancellationToken.None);
        Assert.Equal(97, hit!.ModId);
        Assert.Equal("1.2.0", hit.Version);
        Assert.Equal("abcdef0123456789abcdef0123456789", (string?)nexus.Requests[1].Body["variables"]!["md5"]);

        nexus.Handler = _ => (200, """{"data":{"fileHash":[]}}""");
        Assert.Null(await client.FileByMd5Async("00", CancellationToken.None));
    }

    [Fact]
    public async Task Refusals_and_errors_become_plain_messages()
    {
        using var nexus = new FakeNexusServer(_ => (200, """{"errors":[{"message":"Game not found"}],"data":null}"""));
        var client = new NexusClient(nexus.Base);
        var ex = await Assert.ThrowsAsync<NexusException>(() => client.SearchAsync(null, NexusSort.Downloads, false, 0, 20, CancellationToken.None));
        Assert.Contains("Game not found", ex.Message);

        nexus.Handler = _ => (429, "slow down");
        ex = await Assert.ThrowsAsync<NexusException>(() => client.SearchAsync(null, NexusSort.Downloads, false, 0, 20, CancellationToken.None));
        Assert.Contains("busy", ex.Message);

        Assert.Throws<ArgumentException>(() => new NexusClient("http://example.com"));   // https only, except this PC
    }

    [Fact]
    public void Download_goes_straight_to_the_one_main_file_and_otherwise_to_the_files_tab()
    {
        NexusFile F(int id, string cat) => new(53, id, $"EmployeeMod-53-{id}.zip", "EmployeeMod", "1", cat);
        Assert.Equal("https://www.nexusmods.com/retrorewindvideostoresimulator/mods/53?tab=files&file_id=312",
            NexusLinks.DownloadPage(53, new[] { F(94, "OLD_VERSION"), F(312, "MAIN"), F(313, "OPTIONAL") }));
        Assert.Equal("https://www.nexusmods.com/retrorewindvideostoresimulator/mods/53?tab=files",
            NexusLinks.DownloadPage(53, new[] { F(1, "MAIN"), F(2, "MAIN") }));          // variants: the player picks
        Assert.Equal("https://www.nexusmods.com/retrorewindvideostoresimulator/mods/53?tab=files",
            NexusLinks.DownloadPage(53, Array.Empty<NexusFile>()));                    // the list could not be read
    }

    // ------------------------------------------------------------------ file names

    [Theory]
    [InlineData("Real VHS-97-1-2-0-1777640822.zip", true)]
    [InlineData("Real VHS-97-1-2-0-1777640822 (1).zip", true)]
    [InlineData("RR Movie Workshop - Source Files-97-1-1-0-1777574357.rar", true)]
    [InlineData("UE4SS_v3.0.1-946-g265115c0-52-3-0-1-946-1774984957.zip", true)]
    [InlineData("coolmod.zip", false)]
    [InlineData("Real VHS-97-1-2-0-1777640822.zip.crdownload", false)]
    [InlineData("Real VHS-97-1-2-0-1777640822.pak", false)]
    public void Recognises_Nexus_download_names(string name, bool expected)
    {
        Assert.Equal(expected, NexusFileName.LooksLikeNexusDownload(name));
    }

    [Fact]
    public void A_mod_id_must_be_its_own_part_of_the_name()
    {
        Assert.True(NexusFileName.MentionsMod("Real VHS-97-1-2-0-1777640822.zip", 97));
        Assert.False(NexusFileName.MentionsMod("Real VHS-97-1-2-0-1777640822.zip", 9));
        Assert.True(NexusFileName.MentionsMod("UE4SS_v3.0.1-946-g265115c0-52-3-0-1-946-1774984957.zip", 52));
    }

    // ------------------------------------------------------------------ the Downloads folder

    private sealed class Clock
    {
        public DateTime Now = DateTime.UtcNow;
    }

    private static (NexusDownloadWatcher Watcher, TempDir Dir, Clock Clock) Watcher()
    {
        var dir = new TempDir();
        var clock = new Clock();
        return (new NexusDownloadWatcher(dir.Path, TimeSpan.FromHours(2), () => clock.Now), dir, clock);
    }

    private static NexusFile File97(string name = "Real VHS-97-1-2-0-1777640822.zip") => new(97, 44, name, "Real VHS", "1.2.0", "MAIN");

    [Fact]
    public void A_wanted_download_is_reported_once_it_has_finished()
    {
        var (w, dir, _) = Watcher();
        using var _d = dir;
        w.Want(Mod(97), new[] { File97() });
        Assert.True(w.IsWaitingFor(97));

        string partial = dir.Combine("Real VHS-97-1-2-0-1777640822.zip.crdownload");
        File.WriteAllText(partial, "half");
        Assert.Empty(w.Poll());                                    // still downloading

        string final = dir.Combine("Real VHS-97-1-2-0-1777640822.zip");
        File.Move(partial, final);
        File.AppendAllText(final, " and the rest");
        Assert.Empty(w.Poll());                                    // first sight: the size has to hold still once
        var found = w.Poll().Single();
        Assert.Equal(final, found.Path);
        Assert.Equal(44, found.File!.FileId);
        Assert.Equal("1.2.0", found.Version);
        Assert.False(w.IsWaitingFor(97));
        Assert.Empty(w.Poll());                                    // reported once
    }

    [Fact]
    public void A_browsers_numbered_copy_counts()
    {
        var (w, dir, _) = Watcher();
        using var _d = dir;
        w.Want(Mod(97), new[] { File97() });
        File.WriteAllText(dir.Combine("Real VHS-97-1-2-0-1777640822 (1).zip"), "zip");
        w.Poll();
        Assert.Equal(97, w.Poll().Single().Mod.ModId);
    }

    [Fact]
    public void A_file_uploaded_after_the_list_was_read_matches_by_its_mod_id()
    {
        var (w, dir, _) = Watcher();
        using var _d = dir;
        w.Want(Mod(97, version: "1.3.0"), new[] { File97() });
        File.WriteAllText(dir.Combine("Real VHS-97-1-3-0-1777999999.zip"), "zip");
        w.Poll();
        var found = w.Poll().Single();
        Assert.Null(found.File);
        Assert.Equal("1.3.0", found.Version);                      // the mod's version stands in
    }

    [Fact]
    public void Old_files_other_mods_and_unwanted_downloads_are_left_alone()
    {
        var (w, dir, clock) = Watcher();
        using var _d = dir;
        string old = dir.Combine("Real VHS-97-1-2-0-1777640822.zip");
        File.WriteAllText(old, "from last week");
        File.SetLastWriteTimeUtc(old, clock.Now.AddDays(-7));
        File.SetCreationTimeUtc(old, clock.Now.AddDays(-7));
        File.WriteAllText(dir.Combine("Other Mod-53-1-4-1777000000.zip"), "zip");
        File.WriteAllText(dir.Combine("holiday photos.zip"), "zip");

        Assert.Empty(w.Poll());                                    // nothing wanted: nothing even looked at
        w.Want(Mod(97), new[] { File97() });
        w.Poll();
        Assert.Empty(w.Poll());
        Assert.True(w.IsWaitingFor(97));
    }

    [Fact]
    public void Empty_files_and_files_still_being_written_are_not_finished()
    {
        var (w, dir, _) = Watcher();
        using var _d = dir;
        w.Want(Mod(97), new[] { File97() });
        string final = dir.Combine("Real VHS-97-1-2-0-1777640822.zip");
        File.WriteAllText(final, "");                              // Firefox's placeholder
        w.Poll();
        Assert.Empty(w.Poll());
        using (var writer = new FileStream(final, FileMode.Open, FileAccess.Write, FileShare.Read))
        {
            writer.Write(new byte[10]);
            writer.Flush();
            w.Poll();
            Assert.Empty(w.Poll());                                // the browser still has it open for writing
        }
        Assert.Single(w.Poll());
    }

    [Fact]
    public void Waiting_stops_after_a_couple_of_hours()
    {
        var (w, dir, clock) = Watcher();
        using var _d = dir;
        w.Want(Mod(97), Array.Empty<NexusFile>());
        clock.Now = clock.Now.AddHours(3);
        w.Poll();
        Assert.False(w.IsWaiting);
    }

    // ------------------------------------------------------------------ installing, and the co-op check

    [Fact]
    public void A_Nexus_install_records_the_mods_Nexus_id_and_version()
    {
        using var t = new TempDir();
        var game = Fixtures.FakeGame(t);
        string src = t.Combine("src", "CoolMod");
        Fixtures.WriteAt(Path.Combine(src, "Scripts", "main.lua"), "-- cool");
        using var pkgSrc = PackageSource.Open(src);
        var pkg = PackageAnalyzer.Analyze(pkgSrc);
        var mgr = new ModManager(game, t.Combine("installed.json"), () => false);

        var who = MainViewModel.MakeIdentity(pkg, null, "nexus", pkgSrc.DisplayName, new NexusSource(97, "Cool Mod", "1.2.0"), mgr.Managed());
        Assert.Equal("nexus-97", who.Id);
        mgr.Install(pkg, who);

        var rec = mgr.Managed().Single();
        Assert.Equal(97, rec.NexusModId);
        Assert.Equal("1.2.0", rec.NexusVersion);
        Assert.Equal(97, mgr.ScanGame().Single(m => m.Name == "CoolMod").NexusModId);
    }

    [Fact]
    public void A_Nexus_download_of_a_mod_installed_earlier_by_hand_updates_that_install()
    {
        using var t = new TempDir();
        var game = Fixtures.FakeGame(t);
        string src = t.Combine("src", "CoolMod");
        Fixtures.WriteAt(Path.Combine(src, "Scripts", "main.lua"), "-- cool");
        var mgr = new ModManager(game, t.Combine("installed.json"), () => false);
        using (var first = PackageSource.Open(src))
        {
            var pkg = PackageAnalyzer.Analyze(first);
            mgr.Install(pkg, MainViewModel.MakeIdentity(pkg, null, "folder", first.DisplayName));
        }
        string handId = mgr.Managed().Single().Id;
        Assert.StartsWith("local-", handId);

        using var again = PackageSource.Open(src);
        var pkg2 = PackageAnalyzer.Analyze(again);
        var who = MainViewModel.MakeIdentity(pkg2, null, "nexus", again.DisplayName, new NexusSource(97, "Cool Mod", "1.3.0"), mgr.Managed());
        Assert.Equal(handId, who.Id);                              // same record: no "belongs to another mod" refusal
        mgr.Install(pkg2, who);
        Assert.Equal(97, mgr.Managed().Single().NexusModId);
    }

    [Fact]
    public void A_record_an_older_launcher_saved_without_the_Nexus_fields_gets_them_back_from_its_id()
    {
        using var t = new TempDir();
        string path = t.Combine("installed.json");
        // As the 1.7.1 launcher writes it after an install of its own: no nexusModId, plus a field from a future launcher.
        File.WriteAllText(path, """
            {"schemaVersion":1,"futureThing":{"a":1},"mods":[
              {"id":"nexus-53","name":"Employee Mod","version":"1.5","type":"ue4ss-lua","source":"nexus","gameRoot":"C:\\G","enabled":true,"luaFolders":["EmployeeMod"],"files":[],"someNewField":"keep me"},
              {"id":"local-x","name":"X","version":"1","type":"pak","source":"file","gameRoot":"C:\\G","enabled":true,"luaFolders":[],"files":[]}]}
            """);
        var m = InstalledManifest.Load(path);
        Assert.Equal(53, m.Mods[0].NexusModId);
        Assert.Equal("1.5", m.Mods[0].NexusVersion);
        Assert.Null(m.Mods[1].NexusModId);

        m.Save(path);
        string saved = File.ReadAllText(path);
        Assert.Contains("someNewField", saved);                    // what this launcher does not know is kept
        Assert.Contains("futureThing", saved);
    }

    private static GameModInfo Info(string name, ModKind kind, int? nexus, bool enabled = true, bool builtIn = false) =>
        new() { Name = name, Kind = kind, Enabled = enabled, BuiltIn = builtIn, NexusModId = nexus, Path = name };

    [Fact]
    public void The_host_shares_its_Nexus_ids_and_a_guest_gets_the_ones_it_lacks()
    {
        var host = ModFingerprint.FromScan("1.7.2", new[]
        {
            Info("RealVHS", ModKind.Pak, 97),
            Info("EmployeeMod", ModKind.Ue4ssLua, 53),
            Info("OffMod", ModKind.Pak, 12, enabled: false),
            Info("HandMade", ModKind.Pak, null),
        });
        Assert.Equal(new[] { 53, 97 }, host.NexusIds);
        var p = host.ToPresence();
        Assert.Equal("53,97", p[ModFingerprint.KeyNexus]);
        var fromSteam = ModFingerprint.FromPresence(k => p.TryGetValue(k, out var v) ? v : null)!;
        Assert.Equal(new[] { 53, 97 }, fromSteam.NexusIds);

        var guest = ModFingerprint.FromScan("1.7.2", new[] { Info("EmployeeMod", ModKind.Ue4ssLua, 53) });
        var diff = ModMismatch.Compare(guest, fromSteam)!;
        Assert.Equal(new[] { 97 }, diff.NexusHostOnly);
        Assert.True(diff.CanGetHostMods);
        Assert.Contains("Get their mods", diff.Explain("Alex"));
    }

    [Fact]
    public void Nothing_to_get_when_the_mods_match_or_the_host_published_no_ids()
    {
        var same = ModFingerprint.FromScan("1.7.2", new[] { Info("RealVHS", ModKind.Pak, 97) });
        var p = same.ToPresence();
        var diff = ModMismatch.Compare(same, ModFingerprint.FromPresence(k => p.TryGetValue(k, out var v) ? v : null))!;
        Assert.False(diff.CanGetHostMods);

        var older = new Dictionary<string, string>(p);
        older.Remove(ModFingerprint.KeyNexus);                   // a 1.7.1 host
        var host = ModFingerprint.FromPresence(k => older.TryGetValue(k, out var v) ? v : null)!;
        Assert.Empty(host.NexusIds);
        Assert.False(ModMismatch.Compare(ModFingerprint.FromScan("1.7.2", Array.Empty<GameModInfo>()), host)!.CanGetHostMods);
    }

    // ------------------------------------------------------------------ .7z and .rar

    [Fact]
    public void A_7z_download_is_unpacked_and_the_temporary_copy_removed_afterwards()
    {
        string archive = Fixtures.PathOf("coolmod-9-1-0-1777000000.7z");
        string unpacked;
        using (var src = PackageSource.Open(archive))
        {
            Assert.Contains(src.Files, f => f.Path == "CoolMod/Scripts/main.lua");
            Assert.Equal("coolmod-9-1-0-1777000000", src.DisplayName);
            var pkg = PackageAnalyzer.Analyze(src);
            Assert.Equal(new[] { "CoolMod" }, pkg.LuaFolders);
            var lua = src.Files.Single(f => f.Path == "CoolMod/Scripts/main.lua");
            string onDisk;
            using (var s = (FileStream)lua.Open())
            {
                Assert.True(s.Length > 0);
                onDisk = s.Name;
            }
            unpacked = onDisk.Substring(0, onDisk.IndexOf(@"\CoolMod\", StringComparison.Ordinal));
            Assert.Contains("RewindTogether-unpack-", unpacked);
        }
        Assert.False(Directory.Exists(unpacked));
    }

    [Fact]
    public void A_damaged_archive_says_how_to_get_it_in_by_hand()
    {
        using var t = new TempDir();
        string bad = t.Combine("broken.7z");
        File.WriteAllText(bad, "this is not a 7z archive");
        var ex = Assert.Throws<ModInstallException>(() => PackageSource.Open(bad));
        Assert.Contains("7-Zip", ex.Message);
    }
}
