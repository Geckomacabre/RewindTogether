using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class VdfTests
{
    [Fact]
    public void Parses_current_libraryfolders_and_puts_the_library_with_the_game_first()
    {
        var libs = GameLocator.ParseLibraryFolders(Fixtures.Read("libraryfolders.vdf"));
        Assert.Equal(new[] { @"D:\SteamLibrary", @"C:\Program Files (x86)\Steam", @"E:\SteamLibrary" }, libs);
    }

    [Fact]
    public void Parses_legacy_libraryfolders_and_skips_non_numeric_keys()
    {
        var libs = GameLocator.ParseLibraryFolders(Fixtures.Read("libraryfolders_legacy.vdf"));
        Assert.Equal(new[] { @"D:\SteamLibrary", @"F:\Games\Steam Library" }, libs);
    }

    [Fact]
    public void Parses_appmanifest_buildid_and_installdir()
    {
        var m = GameLocator.ParseAppManifest(Fixtures.Read("appmanifest_3552140.acf"));
        Assert.Equal("RetroRewind", m.InstallDir);
        Assert.Equal("23896268", m.BuildId);
        Assert.Equal("Retro Rewind - Video Store Simulator", m.Name);
    }

    [Fact]
    public void Handles_escapes_comments_nesting_and_case_insensitive_keys()
    {
        var root = Vdf.Parse("// header\n\"Root\" { \"Path\" \"C:\\\\a \\\"b\\\"\" // trailing\n \"Child\" { \"k\" \"v\" } }");
        var r = root.GetObject("root")!;
        Assert.Equal("C:\\a \"b\"", r.GetString("path"));
        Assert.Equal("v", r.GetObject("CHILD")!.GetString("K"));
    }

    [Theory]
    [InlineData("\"a\" { \"b\" \"c\" ")]
    [InlineData("\"a\" \"unterminated")]
    [InlineData("}")]
    public void Malformed_text_throws_FormatException(string text)
        => Assert.Throws<FormatException>(() => Vdf.Parse(text));
}

public class GameLocatorTests
{
    private sealed class FakeRegistry : ISteamRegistry
    {
        private readonly string? _path;
        public FakeRegistry(string? path) => _path = path;
        public string? GetSteamPath() => _path;
    }

    private static void MakeLibrary(TempDir t, string lib, bool withGame, string installDir = "RetroRewind", string buildId = "23896268")
    {
        string acf = Fixtures.Read("appmanifest_3552140.acf").Replace("\"RetroRewind\"", $"\"{installDir}\"").Replace("23896268", buildId);
        if (withGame)
        {
            t.Write(Path.Combine(lib, "steamapps", "appmanifest_3552140.acf"), acf);
            t.Write(Path.Combine(lib, "steamapps", "common", installDir, "RetroRewind", "Binaries", "Win64", GameInstall.ExeName), "");
        }
        else
        {
            Directory.CreateDirectory(t.Combine(lib, "steamapps"));
        }
    }

    private static string Vdf(params string[] libs)
    {
        var sb = new System.Text.StringBuilder("\"libraryfolders\"\n{\n");
        for (int i = 0; i < libs.Length; i++)
            sb.Append($"\t\"{i}\"\n\t{{\n\t\t\"path\"\t\t\"{libs[i].Replace("\\", "\\\\")}\"\n\t\t\"apps\" {{ }}\n\t}}\n");
        return sb.Append("}\n").ToString();
    }

    [Fact]
    public void Finds_the_game_in_a_secondary_library_with_its_buildid()
    {
        using var t = new TempDir();
        MakeLibrary(t, "Steam", withGame: false);
        MakeLibrary(t, "LibA", withGame: false);
        MakeLibrary(t, "LibB", withGame: true, buildId: "99999999");
        t.Write(Path.Combine("Steam", "steamapps", "libraryfolders.vdf"), Vdf(t.Combine("Steam"), t.Combine("LibA"), t.Combine("LibB")));

        var r = new GameLocator(new FakeRegistry(t.Combine("Steam").Replace('\\', '/')), () => Array.Empty<string>()).Locate(null);

        Assert.NotNull(r.Game);
        Assert.Equal(Path.GetFullPath(t.Combine("LibB", "steamapps", "common", "RetroRewind")), r.Game!.Root);
        Assert.Equal("99999999", r.Game.BuildId);
        Assert.Equal("Steam library", r.Game.Source);
        Assert.Equal(3, r.Libraries.Count);
    }

    [Fact]
    public void Honours_a_custom_installdir_from_the_manifest()
    {
        using var t = new TempDir();
        MakeLibrary(t, "Steam", withGame: true, installDir: "Retro Rewind Custom");
        var r = new GameLocator(new FakeRegistry(t.Combine("Steam")), () => Array.Empty<string>()).Locate(null);
        Assert.EndsWith("Retro Rewind Custom", r.Game!.Root);
    }

    [Fact]
    public void Manual_override_wins_and_reads_the_neighbouring_manifest()
    {
        using var t = new TempDir();
        MakeLibrary(t, "Manual", withGame: true, buildId: "123");
        string root = t.Combine("Manual", "steamapps", "common", "RetroRewind");
        var r = new GameLocator(new FakeRegistry(null), () => Array.Empty<string>()).Locate(root);
        Assert.Equal("Chosen by you", r.Game!.Source);
        Assert.Equal("123", r.Game.BuildId);
    }

    [Fact]
    public void A_manifest_without_the_exe_is_not_a_game()
    {
        using var t = new TempDir();
        t.Write(Path.Combine("Steam", "steamapps", "appmanifest_3552140.acf"), Fixtures.Read("appmanifest_3552140.acf"));
        var r = new GameLocator(new FakeRegistry(t.Combine("Steam")), () => Array.Empty<string>()).Locate(null);
        Assert.Null(r.Game);
        Assert.Contains(r.Notes, n => n.Contains("does not contain the game executable"));
    }

    [Fact]
    public void NormalizeUserPick_walks_up_from_Binaries_to_the_install_root()
    {
        using var t = new TempDir();
        MakeLibrary(t, "L", withGame: true);
        string root = t.Combine("L", "steamapps", "common", "RetroRewind");
        Assert.Equal(Path.GetFullPath(root), GameInstall.NormalizeUserPick(Path.Combine(root, "RetroRewind", "Binaries", "Win64")));
        Assert.Null(GameInstall.NormalizeUserPick(t.Path));
    }
}
