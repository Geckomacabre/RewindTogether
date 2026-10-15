using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

/// <summary>LAUNCHER_CONTRACT.md §1: { "action": "host", "slot": "Player_Save1", "written": ... }</summary>
public class HostSlotTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1760467200);

    [Fact]
    public void Host_with_a_slot_matches_the_contract_exactly()
        => Assert.Equal("{\"action\":\"host\",\"slot\":\"Player_Save1\",\"written\":1760467200}",
            LaunchFiles.BuildLaunchJson(LaunchRequest.Host(Now, "Player_Save1")));

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(5)]
    public void Every_one_of_the_five_slots_is_written(int n)
    {
        string slot = SaveSlotNames.ForNumber(n);
        Assert.Equal($"Player_Save{n}", slot);
        Assert.Equal(n, SaveSlotNames.NumberOf(slot));
        Assert.Contains($"\"slot\":\"Player_Save{n}\"", LaunchFiles.BuildLaunchJson(LaunchRequest.Host(Now, slot)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void Choose_my_save_in_the_game_writes_no_slot_at_all(string? slot)
        => Assert.Equal("{\"action\":\"host\",\"written\":1760467200}", LaunchFiles.BuildLaunchJson(LaunchRequest.Host(Now, slot)));

    [Theory]
    [InlineData("Player_Save0")]
    [InlineData("Player_Save6")]
    [InlineData("Player_Save10")]
    [InlineData("player_save1")]   // the mod's pattern is case-sensitive
    [InlineData("Player_Save1 ")]
    [InlineData(" Player_Save1")]
    [InlineData("Player_Save")]
    [InlineData("Save 1")]
    [InlineData("../Player_Save1")]
    [InlineData("Player_Save1\"")]
    [InlineData("")]
    public void Anything_but_Player_Save1_to_5_is_refused_because_the_mod_would_reject_the_whole_request(string slot)
    {
        Assert.False(SaveSlotNames.IsValid(slot));
        Assert.Throws<ArgumentException>(() => LaunchFiles.BuildLaunchJson(new LaunchRequest("host", null, null, 1, slot)));
    }

    [Fact]
    public void A_join_cannot_carry_a_slot()
        => Assert.Throws<ArgumentException>(() => LaunchFiles.BuildLaunchJson(new LaunchRequest("join", "1.2.3.4", null, 1, "Player_Save1")));

    [Fact]
    public void Slot_numbers_outside_1_to_5_do_not_exist()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => SaveSlotNames.ForNumber(0));
        Assert.Throws<ArgumentOutOfRangeException>(() => SaveSlotNames.ForNumber(6));
        Assert.Throws<ArgumentException>(() => SaveSlotNames.NumberOf("Player_Save9"));
    }

    [Fact]
    public void A_slot_request_is_written_atomically_and_reads_back_as_flat_JSON()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        LaunchFiles.WriteLaunchRequest(g, LaunchRequest.Host(Now, "Player_Save3"));

        byte[] bytes = File.ReadAllBytes(g.LaunchJson);
        Assert.NotEqual(0xEF, bytes[0]); // no BOM
        Assert.False(File.Exists(g.LaunchJson + ".tmp"));
        using var doc = JsonDocument.Parse(bytes);
        Assert.Equal("host", doc.RootElement.GetProperty("action").GetString());
        Assert.Equal("Player_Save3", doc.RootElement.GetProperty("slot").GetString());
        Assert.Equal(1760467200, doc.RootElement.GetProperty("written").GetInt64());
        Assert.All(doc.RootElement.EnumerateObject(), p => Assert.NotEqual(JsonValueKind.Object, p.Value.ValueKind)); // flat
    }
}

public class SaveSlotLabelTests
{
    [Fact]
    public void Labels_say_when_each_save_was_last_played_or_that_it_is_empty()
    {
        using var t = new TempDir();
        string dir = t.Combine("SaveGames");
        var played = new DateTime(2026, 10, 14, 14, 6, 0, DateTimeKind.Local);
        File.SetLastWriteTime(t.Write(Path.Combine("SaveGames", "Player_Save1.sav"), "s1"), played);
        File.SetLastWriteTime(t.Write(Path.Combine("SaveGames", "Player_Save3.sav"), "s3"), played.AddDays(-30));
        t.Write(Path.Combine("SaveGames", "Player_Save2_backup.sav"), "not a slot");
        t.Write(Path.Combine("SaveGames", "DefaultSaveSlot.sav"), "not a slot either");

        var slots = SaveSlots.Read(dir);

        Assert.Equal(5, slots.Count);
        Assert.Equal(new[] { true, false, true, false, false }, slots.Select(s => s.Exists));
        Assert.Equal("Player_Save1", slots[0].Slot);
        Assert.Equal("Save 1 (last played 14 Oct 2026, 14:06)", slots[0].Label(CultureInfo.InvariantCulture));
        Assert.Equal("Save 2 (empty - starts a new store)", slots[1].Label(CultureInfo.InvariantCulture));
        Assert.Equal("Save 3 (last played 14 Sep 2026, 14:06)", slots[2].Label(CultureInfo.InvariantCulture));
        Assert.Equal("Save 5 (empty - starts a new store)", slots[4].Label(CultureInfo.InvariantCulture));
    }

    [Fact]
    public void A_missing_save_folder_means_five_empty_slots()
    {
        using var t = new TempDir();
        var slots = SaveSlots.Read(t.Combine("nope"));
        Assert.All(slots, s => Assert.False(s.Exists));
        Assert.Equal(new[] { "Player_Save1", "Player_Save2", "Player_Save3", "Player_Save4", "Player_Save5" }, slots.Select(s => s.Slot));
    }
}

/// <summary>The release zip: RewindTogetherLauncher.exe next to Mods\RewindTogether\.</summary>
public class BundledModTests
{
    internal static string MakeRelease(TempDir t, string version = "1.7.0", string dllText = "native v1", int configVersion = 9, string marker = "v1")
    {
        string release = t.Combine("release-" + Guid.NewGuid().ToString("N")[..6]);
        string mod = BundledMod.FolderFor(release);
        Fixtures.WriteAt(Path.Combine(mod, "mod.json"),
            $"{{ \"id\": \"rewind-together\", \"name\": \"Rewind Together\", \"version\": \"{version}\", \"game_build\": \"23896268\", \"ue4ss\": \"3.0.1\" }}");
        Fixtures.WriteAt(Path.Combine(mod, "Scripts", "main.lua"), "-- main " + marker);
        Fixtures.WriteAt(Path.Combine(mod, "Scripts", "net.lua"), $"Net.VERSION = \"{version}\"");
        Fixtures.WriteAt(Path.Combine(mod, "Scripts", "rpcchan.lua"), "-- rpc");
        Fixtures.WriteAt(Path.Combine(mod, "Scripts", "config.lua"), $"Config.ConfigVersion = {configVersion}\nConfig.Marker = \"{marker}\"");
        Fixtures.WriteAt(Path.Combine(mod, "native", "RewindNative.dll"), dllText);
        File.WriteAllText(Path.Combine(release, "RewindTogetherLauncher.exe"), "");
        return release;
    }

    [Fact]
    public void Finds_the_copy_next_to_the_exe()
    {
        using var t = new TempDir();
        string release = MakeRelease(t, "1.7.1");
        var b = BundledMod.Find(release)!;
        Assert.Equal("1.7.1", b.Version);
        Assert.Equal("23896268", b.GameBuild);
        Assert.Equal(Path.Combine(release, "Mods", "RewindTogether"), b.Folder);
    }

    [Fact]
    public void No_copy_wrong_id_incomplete_or_broken_means_no_bundled_mod()
    {
        using var t = new TempDir();
        Assert.Null(BundledMod.Find(null));
        Assert.Null(BundledMod.Find(t.Path));

        string wrongId = MakeRelease(t);
        File.WriteAllText(Path.Combine(BundledMod.FolderFor(wrongId), "mod.json"), "{ \"id\": \"something-else\", \"version\": \"1\" }");
        Assert.Null(BundledMod.Find(wrongId));

        string noMain = MakeRelease(t);
        File.Delete(Path.Combine(BundledMod.FolderFor(noMain), "Scripts", "main.lua"));
        Assert.Null(BundledMod.Find(noMain));

        string broken = MakeRelease(t);
        File.WriteAllText(Path.Combine(BundledMod.FolderFor(broken), "mod.json"), "{ not json");
        Assert.Null(BundledMod.Find(broken));
    }

    [Fact]
    public void The_bundled_copy_becomes_the_catalog_install_source()
    {
        using var t = new TempDir();
        var bundled = BundledMod.Find(MakeRelease(t, "1.8.0"))!;

        var catalog = CatalogParser.LoadEmbedded();
        Assert.False(catalog.Find("rewind-together")!.IsInstallable); // no download link without it
        catalog.ApplyBundled(bundled);
        var rt = catalog.Find("rewind-together")!;
        Assert.Equal("1.8.0", rt.Version);
        Assert.Equal(bundled.Folder, rt.LocalPath);
        Assert.True(rt.IsInstallable);
        Assert.True(rt.IsBundled);
        Assert.True(VersionCompare.IsNewer(rt.Version, "1.7.0")); // what "update available" compares

        var empty = CatalogParser.Parse("{ \"mods\": [] }", "test");
        empty.ApplyBundled(bundled);
        Assert.Equal("RewindTogether", empty.Find("rewind-together")!.FolderName);
        empty.ApplyBundled(null); // no bundled copy: nothing changes
        Assert.Single(empty.Mods);
    }
}

/// <summary>
/// native\RewindNative.dll, and what happens when a running game has it (or anything else) locked:
/// "Close Retro Rewind first, then press Install again" and the previous install untouched.
/// </summary>
public class NativeDllAndLockTests
{
    private static readonly ModIdentity Rt = new(GameInstall.RewindTogetherId, "Rewind Together", "1.7.0", "bundled");

    private static InstallOutcome InstallFolder(ModManager mgr, string folder, ModIdentity? who = null)
    {
        using var src = PackageSource.Open(folder);
        var pkg = PackageAnalyzer.Analyze(src, fallbackName: "RewindTogether");
        Assert.True(pkg.IsRewindTogether);
        return mgr.Install(pkg, who ?? Rt);
    }

    private static string Dll(GameInstall g) => Path.Combine(g.RewindTogetherDir, "native", "RewindNative.dll");
    private static string StagingRoot(GameInstall g) => Path.Combine(g.ProjectDir, FileTransaction.StagingFolderName);

    [Fact]
    public void The_bundled_layout_installs_with_its_native_folder_and_leaves_no_staging_behind()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);

        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t)));

        Assert.Equal("native v1", File.ReadAllText(Dll(g)));
        Assert.True(File.Exists(Path.Combine(g.RewindTogetherDir, "mod.json")));
        Assert.True(ModsTxt.Load(g.ModsTxt).IsEnabled("RewindTogether"));
        Assert.Equal("1.7.0", RewindTogetherInfo.Read(g).Version);
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [Fact]
    public void Updating_replaces_the_native_dll_and_keeps_config_lua()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);
        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.0", "native v1", 9, "v1")));
        File.WriteAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "config.lua"), "Config.ConfigVersion = 9\nConfig.Marker = \"player edit\"");

        var outcome = InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.1", "native v2", 9, "v2")),
            Rt with { Version = "1.7.1" });

        Assert.Equal("native v2", File.ReadAllText(Dll(g)));
        Assert.Contains("-- main v2", File.ReadAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua")));
        Assert.Contains("player edit", File.ReadAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "config.lua")));
        Assert.Contains(outcome.Notes, n => n.Contains("Kept your existing config.lua"));
        Assert.Equal("1.7.1", mgr.Find(GameInstall.RewindTogetherId)!.Version);
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [Fact]
    public void An_open_native_dll_blocks_the_update_and_the_previous_install_stays_exactly_as_it_was()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);
        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.0", "native v1", 9, "v1")));
        string modsTxtBefore = File.ReadAllText(g.ModsTxt);
        string manifestBefore = File.ReadAllText(t.Combine("installed.json"));

        GameFilesLockedException ex;
        using (new FileStream(Dll(g), FileMode.Open, FileAccess.Read, FileShare.Read)) // the game holding it
        {
            ex = Assert.Throws<GameFilesLockedException>(() =>
                InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.1", "native v2", 9, "v2")), Rt with { Version = "1.7.1" }));
        }

        Assert.StartsWith("Close Retro Rewind first, then press Install again.", ex.Message);
        Assert.Contains("RewindNative.dll", ex.Message);
        Assert.Equal("native v1", File.ReadAllText(Dll(g)));
        Assert.Contains("-- main v1", File.ReadAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua")));
        Assert.Equal(modsTxtBefore, File.ReadAllText(g.ModsTxt));
        Assert.Equal(manifestBefore, File.ReadAllText(t.Combine("installed.json")));
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryW(string path);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);

    [Fact]
    public void A_really_loaded_native_dll_is_detected_too_and_nothing_is_changed()
    {
        // As close to the game as a test can get: a real DLL mapped into this process. Measured:
        // its FOLDER could still be renamed, so without the up-front check the swap would "succeed"
        // against a running game. The check must stop it.
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);
        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t)));
        File.Copy(Path.Combine(Environment.SystemDirectory, "dbghelp.dll"), Dll(g), overwrite: true);
        byte[] before = File.ReadAllBytes(Dll(g));

        IntPtr h = LoadLibraryW(Dll(g));
        Assert.NotEqual(IntPtr.Zero, h);
        try
        {
            var ex = Assert.Throws<GameFilesLockedException>(() =>
                InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.1", "native v2")), Rt with { Version = "1.7.1" }));
            Assert.StartsWith("Close Retro Rewind first, then press Install again.", ex.Message);
            var un = Assert.Throws<GameFilesLockedException>(() => mgr.Uninstall(GameInstall.RewindTogetherId));
            Assert.StartsWith("Close Retro Rewind first, then press Uninstall again.", un.Message);
        }
        finally
        {
            FreeLibrary(h);
        }

        Assert.Equal(before, File.ReadAllBytes(Dll(g)));
        Assert.True(Directory.Exists(g.RewindTogetherDir));
        Assert.Equal("1.7.0", mgr.Find(GameInstall.RewindTogetherId)!.Version);
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [Fact]
    public void An_open_file_blocks_uninstall_and_then_uninstall_works_once_it_is_closed()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);
        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t)));

        using (new FileStream(Dll(g), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var ex = Assert.Throws<GameFilesLockedException>(() => mgr.Uninstall(GameInstall.RewindTogetherId));
            Assert.StartsWith("Close Retro Rewind first, then press Uninstall again.", ex.Message);
        }
        Assert.True(File.Exists(Dll(g)));
        Assert.True(ModsTxt.Load(g.ModsTxt).IsEnabled("RewindTogether"));
        Assert.NotNull(mgr.Find(GameInstall.RewindTogetherId));

        mgr.Uninstall(GameInstall.RewindTogetherId);
        Assert.False(Directory.Exists(g.RewindTogetherDir));
        Assert.Null(ModsTxt.Load(g.ModsTxt).IsEnabled("RewindTogether"));
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void A_failure_in_the_middle_of_the_swap_is_rolled_back(bool gameRunning)
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => gameRunning);
        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.0", "native v1", 9, "v1")));

        // Fail exactly when the new folder moves in - after the old one has been moved aside.
        mgr.BeforeMove = (from, to) =>
        {
            if (string.Equals(Path.GetFullPath(to), Path.GetFullPath(g.RewindTogetherDir), StringComparison.OrdinalIgnoreCase))
                throw new IOException("simulated failure");
        };
        var ex = Assert.ThrowsAny<ModInstallException>(() =>
            InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t, "1.7.1", "native v2", 9, "v2")), Rt with { Version = "1.7.1" }));

        Assert.Equal(gameRunning, ex is GameFilesLockedException);
        if (!gameRunning) Assert.Contains("Nothing was changed", ex.Message);
        Assert.Equal("native v1", File.ReadAllText(Dll(g)));
        Assert.Contains("-- main v1", File.ReadAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua")));
        Assert.Equal("1.7.0", mgr.Find(GameInstall.RewindTogetherId)!.Version);
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [Fact]
    public void An_install_interrupted_between_the_two_renames_is_put_back_on_the_next_run()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);
        InstallFolder(mgr, BundledMod.FolderFor(BundledModTests.MakeRelease(t)));

        // Simulate the launcher being killed right after moving the old copy aside (no Dispose).
        var txn = new FileTransaction(g);
        txn.RemoveDirectory(g.RewindTogetherDir);
        Assert.False(Directory.Exists(g.RewindTogetherDir));

        FileTransaction.CleanupStale(g, minAge: TimeSpan.Zero);

        Assert.Equal("native v1", File.ReadAllText(Dll(g)));
        Assert.False(Directory.Exists(StagingRoot(g)));
    }

    [Fact]
    public void A_hand_installed_copy_with_a_native_folder_is_removed_safely()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        Fixtures.WriteAt(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua"), "-- old");
        Fixtures.WriteAt(Path.Combine(g.RewindTogetherDir, "Scripts", "config.lua"), "Config.ConfigVersion = 9 -- mine");
        Fixtures.WriteAt(Dll(g), "old native");
        ModsTxt.Update(g.ModsTxt, d => d.SetEnabled("RewindTogether", true));
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);

        using (new FileStream(Dll(g), FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.Throws<GameFilesLockedException>(() => mgr.UninstallUnmanagedFolder("RewindTogether"));
        Assert.Equal("old native", File.ReadAllText(Dll(g)));

        mgr.UninstallUnmanagedFolder("RewindTogether");
        Assert.False(Directory.Exists(g.RewindTogetherDir));
        Assert.Null(ModsTxt.Load(g.ModsTxt).IsEnabled("RewindTogether"));
        Assert.Contains("mine", File.ReadAllText(Path.Combine(g.Ue4ssModsDir, "RewindTogether-config.lua.uninstalled-backup")));
        Assert.Throws<ArgumentException>(() => mgr.UninstallUnmanagedFolder(".."));
    }

    [Fact]
    public void Switching_off_a_pak_the_game_has_open_says_close_the_game_and_moves_nothing()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"), () => false);
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "Skins.zip", ("Skins_P.pak", "pak")), new ModIdentity("skins", "Skins", "1", "test"));
        string pak = Path.Combine(g.PakModsDir, "Skins_P.pak");

        using (new FileStream(pak, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var ex = Assert.Throws<GameFilesLockedException>(() => mgr.SetEnabled("skins", false));
            Assert.StartsWith("Close Retro Rewind first, then switch Skins_P off again.", ex.Message);
        }
        Assert.True(File.Exists(pak));
        Assert.True(mgr.Find("skins")!.Enabled);
    }

    [Fact]
    public void UE4SS_is_not_touched_while_its_dll_is_in_use()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t); // has a fake dwmapi.dll and ue4ss\UE4SS.dll
        string zip = Fixtures.Zip(t, "UE4SS_v3.0.1-944-g0196ef29.zip", ("dwmapi.dll", "new proxy"), ("ue4ss/UE4SS.dll", "new dll"));
        byte[] proxyBefore = File.ReadAllBytes(g.Ue4ssProxyDll);

        using (new FileStream(g.Ue4ssDll, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var ex = Assert.Throws<GameFilesLockedException>(() => Ue4ssSetup.InstallFromZip(g, zip));
            Assert.StartsWith("Close Retro Rewind first, then press Install UE4SS again.", ex.Message);
        }
        Assert.Equal(proxyBefore, File.ReadAllBytes(g.Ue4ssProxyDll)); // not even the unlocked file was overwritten
    }
}
