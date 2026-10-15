using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Text;
using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

/// <summary>A minimal HTTP/1.1 server on 127.0.0.1 standing in for GitHub (no admin rights needed).</summary>
internal sealed class FakeReleaseServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly Dictionary<string, (int Status, byte[] Body)> _routes = new(StringComparer.Ordinal);

    public FakeReleaseServer()
    {
        _listener.Start();
        _ = Task.Run(AcceptLoop);
    }

    public string Base => $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";

    public void Serve(string path, byte[] body, int status = 200) { lock (_routes) _routes[path] = (status, body); }
    public void Serve(string path, string body, int status = 200) => Serve(path, Encoding.UTF8.GetBytes(body), status);

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
            var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
            string? requestLine = reader.ReadLine();
            while (!string.IsNullOrEmpty(reader.ReadLine())) { }   // headers
            string path = requestLine?.Split(' ') is { Length: >= 2 } parts ? parts[1] : "/";
            (int status, byte[] body) = (404, Encoding.UTF8.GetBytes("not found"));
            lock (_routes) if (_routes.TryGetValue(path, out var r)) (status, body) = r;
            string head = $"HTTP/1.1 {status} {(status == 200 ? "OK" : "Error")}\r\nContent-Length: {body.Length}\r\n" +
                          "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n";
            stream.Write(Encoding.ASCII.GetBytes(head));
            stream.Write(body);
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
    }
}

public class SelfUpdateTests
{
    private const string Sha = "d9b5c1334678fd0865adaa8e7f328c1ac972ae04db690bd42c9bc29c09dd335e";

    private static string ReleaseJson(string tag, string zipUrl, long size, string? digest, bool prerelease = false,
        string? shaUrl = null, string zipName = null!)
    {
        zipName ??= $"RewindTogether-{tag.TrimStart('v')}.zip";
        string asset = $$"""{"name":"{{zipName}}","size":{{size}},"browser_download_url":"{{zipUrl}}"{{(digest != null ? $",\"digest\":\"sha256:{digest}\"" : "")}}}""";
        string shaAsset = shaUrl != null ? $$""",{"name":"{{zipName}}.sha256","size":90,"browser_download_url":"{{shaUrl}}"}""" : "";
        return $$"""{"tag_name":"{{tag}}","draft":false,"prerelease":{{(prerelease ? "true" : "false")}},"html_url":"https://github.com/o/r/releases/tag/{{tag}}","assets":[{{asset}}{{shaAsset}}]}""";
    }

    /// <summary>A release zip shaped like dev/package.py's: one top folder with the release inside.</summary>
    private static byte[] MakeReleaseZip(string version, string exeContent = "new launcher", string? modVersion = null)
    {
        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            void Add(string rel, string content)
            {
                using var w = new StreamWriter(zip.CreateEntry($"RewindTogether-{version}/{rel}").Open());
                w.Write(content);
            }
            Add("RewindTogetherLauncher.exe", exeContent);
            Add("Mods/RewindTogether/mod.json", $$"""{ "id": "rewind-together", "version": "{{modVersion ?? version}}" }""");
            Add("Mods/RewindTogether/Scripts/main.lua", "-- new");
            Add("README.md", "new readme");
        }
        return ms.ToArray();
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant();

    /// <summary>A launcher folder holding release <paramref name="version"/>, plus a file of the player's.</summary>
    private static void MakeAppFolder(TempDir t, string version)
    {
        t.Write("RewindTogetherLauncher.exe", "old launcher");
        t.Write("Mods/RewindTogether/mod.json", $$"""{ "id": "rewind-together", "version": "{{version}}" }""");
        t.Write("Mods/RewindTogether/Scripts/main.lua", "-- old");
        t.Write("README.md", "old readme");
        t.Write("my notes.txt", "the player's own file");
    }

    // ------------------------------------------------------------------ the feed

    [Fact]
    public void Parse_reads_the_release_zip_and_GitHubs_digest()
    {
        var r = ReleaseFeed.Parse(ReleaseJson("v1.7.1", "https://example.test/RewindTogether-1.7.1.zip", 1234, Sha));
        Assert.NotNull(r);
        Assert.Equal("1.7.1", r!.Version);
        Assert.Equal("RewindTogether-1.7.1.zip", r.ZipName);
        Assert.Equal(1234, r.ZipSize);
        Assert.Equal(Sha, r.Sha256);
        Assert.Equal("https://github.com/o/r/releases/tag/v1.7.1", r.PageUrl);
    }

    [Fact]
    public void Parse_skips_prereleases_and_releases_without_a_zip()
    {
        Assert.Null(ReleaseFeed.Parse(ReleaseJson("v2.0.0", "https://x.test/a.zip", 1, Sha, prerelease: true)));
        Assert.Null(ReleaseFeed.Parse(ReleaseJson("v2.0.0", "https://x.test/notes.txt", 1, Sha, zipName: "notes.txt")));
        Assert.Null(ReleaseFeed.Parse("""{"tag_name":"","assets":[]}"""));
    }

    [Fact]
    public void Parse_finds_a_sha256_file_when_GitHub_gives_no_digest()
    {
        var r = ReleaseFeed.Parse(ReleaseJson("v1.8.0", "https://x.test/z.zip", 1, digest: null, shaUrl: "https://x.test/z.zip.sha256"));
        Assert.Null(r!.Sha256);
        Assert.Equal("https://x.test/z.zip.sha256", r.Sha256Url);
        Assert.Equal(Sha, ReleaseFeed.ParseSha256File(Sha.ToUpperInvariant() + "  RewindTogether-1.8.0.zip\n"));
        Assert.Null(ReleaseFeed.ParseSha256File("not a hash"));
    }

    [Fact]
    public void Only_https_or_this_PC_is_allowed()
    {
        Assert.True(ReleaseFeed.IsAllowedUrl("https://api.github.com/x"));
        Assert.True(ReleaseFeed.IsAllowedUrl("http://127.0.0.1:5000/x"));
        Assert.False(ReleaseFeed.IsAllowedUrl("http://example.com/x"));
        Assert.False(ReleaseFeed.IsAllowedUrl("file:///C:/x.zip"));
    }

    [Fact]
    public async Task Checker_reads_the_latest_release_and_its_sha256_file()
    {
        using var server = new FakeReleaseServer();
        server.Serve("/repos/o/r/releases/latest",
            ReleaseJson("v1.8.0", server.Base + "/z.zip", 10, digest: null, shaUrl: server.Base + "/z.zip.sha256"));
        server.Serve("/z.zip.sha256", Sha + "  RewindTogether-1.8.0.zip");
        var r = await new UpdateChecker().LatestAsync(server.Base, "o/r", CancellationToken.None);
        Assert.Equal("1.8.0", r!.Version);
        Assert.Equal(Sha, r.Sha256);
    }

    [Fact]
    public async Task Checker_treats_no_releases_as_none_and_a_rate_limit_as_a_plain_error()
    {
        using var server = new FakeReleaseServer();
        Assert.Null(await new UpdateChecker().LatestAsync(server.Base, "o/r", CancellationToken.None));   // 404
        server.Serve("/repos/o/r/releases/latest", "{}", status: 403);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => new UpdateChecker().LatestAsync(server.Base, "o/r", CancellationToken.None));
        Assert.Contains("limiting", ex.Message);
    }

    // ------------------------------------------------------------------ the install

    [Fact]
    public async Task An_update_replaces_the_release_files_and_keeps_the_players_own()
    {
        using var t = new TempDir();
        using var server = new FakeReleaseServer();
        MakeAppFolder(t, "1.7.0");
        byte[] zip = MakeReleaseZip("9.9.9");
        server.Serve("/RewindTogether-9.9.9.zip", zip);
        var release = new ReleaseInfo("9.9.9", "v9.9.9", "RewindTogether-9.9.9.zip", server.Base + "/RewindTogether-9.9.9.zip",
            zip.Length, Sha256(zip), null, "");

        var installer = new UpdateInstaller(t.Path, new HttpDownloader());
        string root = await installer.PrepareAsync(release, null, CancellationToken.None);
        installer.Install(root);

        Assert.Equal("new launcher", File.ReadAllText(t.Combine("RewindTogetherLauncher.exe")));
        Assert.Equal("9.9.9", BundledMod.Find(t.Path)!.Version);
        Assert.Equal("new readme", File.ReadAllText(t.Combine("README.md")));
        Assert.Equal("the player's own file", File.ReadAllText(t.Combine("my notes.txt")));
        Assert.Equal("old launcher", File.ReadAllText(Path.Combine(installer.WorkDir, "old", "RewindTogetherLauncher.exe")));

        UpdateInstaller.CleanUp(t.Path);
        Assert.False(Directory.Exists(installer.WorkDir));
    }

    [Fact]
    public async Task A_download_that_does_not_match_its_checksum_changes_nothing()
    {
        using var t = new TempDir();
        using var server = new FakeReleaseServer();
        MakeAppFolder(t, "1.7.0");
        byte[] zip = MakeReleaseZip("9.9.9");
        server.Serve("/z.zip", zip);
        var release = new ReleaseInfo("9.9.9", "v9.9.9", "z.zip", server.Base + "/z.zip", zip.Length, Sha, null, "");

        await Assert.ThrowsAsync<DownloadException>(() =>
            new UpdateInstaller(t.Path, new HttpDownloader()).PrepareAsync(release, null, CancellationToken.None));
        Assert.Equal("old launcher", File.ReadAllText(t.Combine("RewindTogetherLauncher.exe")));
        Assert.Equal("1.7.0", BundledMod.Find(t.Path)!.Version);
    }

    [Fact]
    public async Task A_release_that_is_not_the_version_it_claims_is_refused()
    {
        using var t = new TempDir();
        using var server = new FakeReleaseServer();
        MakeAppFolder(t, "1.7.0");
        byte[] zip = MakeReleaseZip("9.9.9", modVersion: "1.0.0");
        server.Serve("/z.zip", zip);
        var release = new ReleaseInfo("9.9.9", "v9.9.9", "z.zip", server.Base + "/z.zip", zip.Length, Sha256(zip), null, "");

        var ex = await Assert.ThrowsAsync<UpdateException>(() =>
            new UpdateInstaller(t.Path, new HttpDownloader()).PrepareAsync(release, null, CancellationToken.None));
        Assert.Contains("1.0.0", ex.Message);
    }

    [Fact]
    public async Task A_release_without_a_checksum_is_not_installed_automatically()
    {
        using var t = new TempDir();
        var release = new ReleaseInfo("9.9.9", "v9.9.9", "z.zip", "https://example.test/z.zip", 1, null, null, "");
        await Assert.ThrowsAsync<UpdateException>(() =>
            new UpdateInstaller(t.Path, new HttpDownloader()).PrepareAsync(release, null, CancellationToken.None));
    }

    [Fact]
    public async Task A_file_that_cannot_be_moved_puts_everything_back()
    {
        using var t = new TempDir();
        using var server = new FakeReleaseServer();
        MakeAppFolder(t, "1.7.0");
        byte[] zip = MakeReleaseZip("9.9.9");
        server.Serve("/z.zip", zip);
        var release = new ReleaseInfo("9.9.9", "v9.9.9", "z.zip", server.Base + "/z.zip", zip.Length, Sha256(zip), null, "");
        var installer = new UpdateInstaller(t.Path, new HttpDownloader());
        string root = await installer.PrepareAsync(release, null, CancellationToken.None);

        // Something holds README.md open without letting it be renamed.
        using (new FileStream(t.Combine("README.md"), FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<UpdateException>(() => installer.Install(root));

        Assert.Equal("old launcher", File.ReadAllText(t.Combine("RewindTogetherLauncher.exe")));
        Assert.Equal("1.7.0", BundledMod.Find(t.Path)!.Version);
        Assert.Equal("old readme", File.ReadAllText(t.Combine("README.md")));
        Assert.Equal("the player's own file", File.ReadAllText(t.Combine("my notes.txt")));
    }

    [Fact]
    public async Task The_running_launcher_exe_is_replaced_while_it_runs()
    {
        using var t = new TempDir();
        using var server = new FakeReleaseServer();
        MakeAppFolder(t, "1.7.0");
        // A real program, running from the launcher's own name, the way the launcher is during an update.
        string exe = t.Combine("RewindTogetherLauncher.exe");
        File.Copy(Path.Combine(Environment.SystemDirectory, "PING.EXE"), exe, overwrite: true);
        using var running = Process.Start(new ProcessStartInfo(exe, "-n 30 127.0.0.1")
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
        })!;
        try
        {
            byte[] zip = MakeReleaseZip("9.9.9");
            server.Serve("/z.zip", zip);
            var release = new ReleaseInfo("9.9.9", "v9.9.9", "z.zip", server.Base + "/z.zip", zip.Length, Sha256(zip), null, "");
            var installer = new UpdateInstaller(t.Path, new HttpDownloader());
            installer.Install(await installer.PrepareAsync(release, null, CancellationToken.None));

            Assert.False(running.HasExited);
            Assert.Equal("new launcher", File.ReadAllText(exe));
            Assert.True(File.Exists(Path.Combine(installer.WorkDir, "old", "RewindTogetherLauncher.exe")));
        }
        finally
        {
            try { running.Kill(); running.WaitForExit(5000); } catch { }
        }
        UpdateInstaller.CleanUp(t.Path);
        Assert.False(Directory.Exists(Path.Combine(t.Path, UpdateInstaller.WorkFolderName)));
    }

    [Fact]
    public void The_restarted_launcher_reads_its_update_arguments()
    {
        var a = LaunchArgs.Parse(new[] { "--after-update", "4242", "--updated-from", "1.7.0" });
        Assert.Equal(4242, a.AfterUpdatePid);
        Assert.Equal("1.7.0", a.UpdatedFrom);
        Assert.Null(LaunchArgs.Parse(new[] { "--after-update", "nope" }).AfterUpdatePid);
    }

    [Fact]
    public void The_restarted_launcher_keeps_its_data_and_game_folders()
    {
        var a = LaunchArgs.Parse(new[] { "--data-dir", @"D:\Rewind data", "--game-dir", @"E:\Games\Retro Rewind", "--host" });
        Assert.Equal(new[] { "--data-dir", @"D:\Rewind data", "--game-dir", @"E:\Games\Retro Rewind" }, a.PersistentArgs());
        Assert.Empty(LaunchArgs.Parse(Array.Empty<string>()).PersistentArgs());
    }

    [Fact]
    public void Newer_releases_are_offered_and_older_or_equal_ones_are_not()
    {
        Assert.True(VersionCompare.IsNewer("1.7.1", "1.7.0"));
        Assert.True(VersionCompare.IsNewer("v1.10.0", "1.9.9"));
        Assert.False(VersionCompare.IsNewer("1.7.0", "1.7.0"));
        Assert.False(VersionCompare.IsNewer("1.6.9", "1.7.0"));
    }
}
