using System.Security.Cryptography;
using System.Text;
using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class CatalogTests
{
    private const string GoodSha = "4b47d4bcedd2f561a4e395bfa00924ccfc945af576a2d0c613e6537846c57ec0";

    [Fact]
    public void The_built_in_catalog_parses_and_lists_Rewind_Together()
    {
        var c = CatalogParser.LoadEmbedded();
        Assert.Empty(c.Warnings);
        var rt = c.Find("rewind-together");
        Assert.NotNull(rt);
        Assert.Equal("RewindTogether", rt!.FolderName);
        Assert.Equal(ModKind.Ue4ssLua, rt.Kind);
        Assert.True(rt.IsRewindTogether);
        Assert.False(rt.IsDownloadable); // nothing is published yet
    }

    [Fact]
    public void Parses_all_fields_from_an_object_or_a_bare_array()
    {
        string entry = $$"""
            { "id": "big-shelves", "name": "Big Shelves", "author": "Someone", "description": "More room.",
              "version": "2.1.0", "type": "pak", "url": "https://example.com/big.zip",
              "sha256": "SHA256:{{GoodSha.ToUpperInvariant()}}", "size": 12345, "homepage": "https://example.com" }
            """;
        foreach (string json in new[] { $"{{ \"mods\": [ {entry} ] }}", $"[ {entry} ]" })
        {
            var c = CatalogParser.Parse(json, "test");
            var e = Assert.Single(c.Mods);
            Assert.Equal("big-shelves", e.Id);
            Assert.Equal(ModKind.Pak, e.Kind);
            Assert.Equal(GoodSha, e.Sha256); // normalised: no prefix, lower case
            Assert.Equal(12345, e.Size);
            Assert.True(e.IsDownloadable);
            Assert.Equal("big-shelves", e.FolderName);
        }
    }

    [Fact]
    public void Bad_entries_are_skipped_with_a_reason_and_the_rest_survive()
    {
        string json = $$"""
            { "mods": [
              { "id": "ok", "version": "1", "type": "logicmod" },
              { "id": "bad type", "version": "1", "type": "ue4ss-lua" },
              { "id": "weird", "version": "1", "type": "exe" },
              { "id": "nohash", "version": "1", "type": "pak", "url": "https://x/y.zip" },
              { "id": "plainhttp", "version": "1", "type": "pak", "url": "http://x/y.zip", "sha256": "{{GoodSha}}" },
              { "id": "noversion", "type": "pak" },
              { "id": "ok", "version": "2", "type": "pak" },
              { "id": "../escape", "version": "1", "type": "pak" },
              { "id": "badfolder", "version": "1", "type": "ue4ss-lua", "folder": "..\\..\\x" }
            ] }
            """;
        var c = CatalogParser.Parse(json, "test");
        Assert.Equal(new[] { "ok" }, c.Mods.Select(m => m.Id));
        Assert.Equal(8, c.Warnings.Count);
        Assert.Contains(c.Warnings, w => w.Contains("unknown type"));
        Assert.Contains(c.Warnings, w => w.Contains("sha256"));
        Assert.Contains(c.Warnings, w => w.Contains("https"));
        Assert.Contains(c.Warnings, w => w.Contains("duplicate"));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{ \"nomods\": [] }")]
    [InlineData("42")]
    public void Unusable_documents_throw(string json)
        => Assert.ThrowsAny<Exception>(() => CatalogParser.Parse(json, "test"));

    [Theory]
    [InlineData("1.7.0", "1.6.9", 1)]
    [InlineData("1.7", "1.7.0", 0)]
    [InlineData("v2.0.0", "1.99.99", 1)]
    [InlineData("1.10.0", "1.9.0", 1)]
    [InlineData("1.7.0-beta", "1.7.0", -1)]
    [InlineData("1.7.0+build5", "1.7.0", 0)]
    [InlineData("", "1.0", -1)]
    public void Versions_compare_numerically(string a, string b, int sign)
        => Assert.Equal(sign, Math.Sign(VersionCompare.Compare(a, b)));
}

public class DownloadAndChecksumTests
{
    private static string Sha(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    [Fact]
    public async Task A_matching_sha256_is_accepted()
    {
        using var t = new TempDir();
        byte[] data = Encoding.UTF8.GetBytes("pretend this is a mod zip");
        string src = t.Combine("src.zip");
        File.WriteAllBytes(src, data);
        string dest = t.Combine("dl", "mod.zip");

        await new HttpDownloader().DownloadAsync(new Uri(src).AbsoluteUri, dest, "sha256:" + Sha(data).ToUpperInvariant(), data.Length, null, CancellationToken.None);

        Assert.Equal(data, File.ReadAllBytes(dest));
        Assert.False(File.Exists(dest + ".part"));
    }

    [Fact]
    public async Task A_wrong_sha256_is_rejected_and_nothing_is_left_behind()
    {
        using var t = new TempDir();
        string src = t.Write("src.zip", "tampered");
        string dest = t.Combine("dl", "mod.zip");
        var ex = await Assert.ThrowsAsync<DownloadException>(() =>
            new HttpDownloader().DownloadAsync(new Uri(src).AbsoluteUri, dest, new string('a', 64), null, null, CancellationToken.None));
        Assert.Contains("checksum", ex.Message);
        Assert.False(File.Exists(dest));
        Assert.False(File.Exists(dest + ".part"));
    }

    [Fact]
    public async Task A_short_download_is_rejected()
    {
        using var t = new TempDir();
        string src = t.Write("src.zip", "short");
        await Assert.ThrowsAsync<DownloadException>(() =>
            new HttpDownloader().DownloadAsync(new Uri(src).AbsoluteUri, t.Combine("x.zip"), null, 999, null, CancellationToken.None));
    }

    [Fact]
    public async Task Only_https_is_allowed()
    {
        using var t = new TempDir();
        await Assert.ThrowsAsync<DownloadException>(() =>
            new HttpDownloader().DownloadAsync("http://example.com/x.zip", t.Combine("x.zip"), null, null, null, CancellationToken.None));
    }

    [Fact]
    public void Sha256_helpers_normalise_case_and_prefix()
    {
        Assert.True(Hashing.Matches("ABCDEF" + new string('0', 58), "sha256:abcdef" + new string('0', 58)));
        Assert.False(Hashing.IsSha256Hex("xyz"));
        using var t = new TempDir();
        string f = t.Write("a.txt", "abc");
        Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", Hashing.Sha256OfFile(f));
    }
}
