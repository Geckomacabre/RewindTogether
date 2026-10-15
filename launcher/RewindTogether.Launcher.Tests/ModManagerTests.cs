using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class ModManagerTests
{
    private static ModIdentity Who(string id, string version = "1.0.0") => new(id, id, version, "test");

    [Fact]
    public void Installs_a_Lua_mod_into_ue4ss_Mods_with_a_mods_txt_line_above_keybinds()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        string zip = Fixtures.Zip(t, "CoolMod.zip",
            ("CoolMod/Scripts/main.lua", "print('hi')"),
            ("CoolMod/enabled.txt", ""),
            ("CoolMod/README.txt", "readme"));

        var outcome = Fixtures.InstallZip(mgr, zip, Who("cool"));

        Assert.True(File.Exists(Path.Combine(g.Ue4ssModsDir, "CoolMod", "Scripts", "main.lua")));
        Assert.False(File.Exists(Path.Combine(g.Ue4ssModsDir, "CoolMod", "enabled.txt"))); // mods.txt is the switch
        var lines = File.ReadAllLines(g.ModsTxt).ToList();
        Assert.Equal(lines.IndexOf("; Built-in keybinds, do not move up!") - 1, lines.IndexOf("CoolMod : 1"));
        Assert.Contains("CoolMod", File.ReadAllText(g.ModsJson));
        Assert.Equal(new[] { "CoolMod" }, outcome.Record.LuaFolders);
        Assert.Equal("ue4ss-lua", mgr.Find("cool")!.Type);
    }

    [Fact]
    public void Updating_replaces_old_files_and_keeps_one_mods_txt_line()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "v1.zip", ("M/Scripts/main.lua", "v1"), ("M/Scripts/old.lua", "old")), Who("m", "1.0"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "v2.zip", ("M/Scripts/main.lua", "v2")), Who("m", "2.0"));

        Assert.Equal("v2", File.ReadAllText(Path.Combine(g.Ue4ssModsDir, "M", "Scripts", "main.lua")));
        Assert.False(File.Exists(Path.Combine(g.Ue4ssModsDir, "M", "Scripts", "old.lua")));
        Assert.Single(ModsTxt.Load(g.ModsTxt).Entries, e => e.Name == "M");
        Assert.Equal("2.0", mgr.Find("m")!.Version);
        Assert.Single(mgr.Managed());
    }

    [Fact]
    public void Disable_and_enable_a_Lua_mod_flip_mods_txt_and_park_enabled_txt()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "m.zip", ("M/Scripts/main.lua", "x")), Who("m"));
        string enabledTxt = Path.Combine(g.Ue4ssModsDir, "M", "enabled.txt");
        File.WriteAllText(enabledTxt, ""); // as if another tool had added one

        mgr.SetEnabled("m", false);
        Assert.False(ModsTxt.Load(g.ModsTxt).IsEnabled("M"));
        Assert.False(File.Exists(enabledTxt));
        Assert.False(mgr.Find("m")!.Enabled);

        mgr.SetEnabled("m", true);
        Assert.True(ModsTxt.Load(g.ModsTxt).IsEnabled("M"));
        Assert.True(File.Exists(enabledTxt));
    }

    [Fact]
    public void Pak_mods_go_to_tilde_mods_and_disabling_moves_them_outside_Paks()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "Skins.zip", ("Skins_P.pak", "pak"), ("Skins_P.ucas", "ucas"), ("Skins_P.utoc", "utoc")), Who("skins"));

        string pak = Path.Combine(g.PakModsDir, "Skins_P.pak");
        Assert.True(File.Exists(pak));
        Assert.True(File.Exists(Path.Combine(g.PakModsDir, "Skins_P.utoc")));
        Assert.Equal("pak", mgr.Find("skins")!.Type);

        mgr.SetEnabled("skins", false);
        Assert.False(File.Exists(pak));
        string parked = Path.Combine(g.DisabledPakModsDir, "Skins_P.pak");
        Assert.True(File.Exists(parked));
        Assert.DoesNotContain(g.PaksDir, parked); // must be outside Content\Paks or Unreal still mounts it

        var scanned = mgr.ScanGame().Single(m => m.Name == "Skins_P");
        Assert.False(scanned.Enabled);
        Assert.Equal("skins", scanned.ManagedId);

        mgr.SetEnabled("skins", true);
        Assert.True(File.Exists(pak));

        mgr.Uninstall("skins");
        Assert.False(File.Exists(pak));
        Assert.False(File.Exists(Path.Combine(g.PakModsDir, "Skins_P.ucas")));
        Assert.Empty(mgr.Managed());
    }

    [Fact]
    public void LogicMods_paks_are_recognised_by_path()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "bp.zip", ("RetroRewind/Content/Paks/LogicMods/MyBP.pak", "pak")), Who("bp"));
        Assert.True(File.Exists(Path.Combine(g.LogicModsDir, "MyBP.pak")));
        Assert.Equal("logicmod", mgr.Find("bp")!.Type);
    }

    [Fact]
    public void Loose_paks_containing_a_ModActor_are_treated_as_LogicMods()
    {
        using var t = new TempDir();
        string zip = Fixtures.Zip(t, "bp.zip", ("MyBP.pak", "....../Game/Mods/MyBP/ModActor.uasset...."));
        var a = Fixtures.Analyze(zip);
        Assert.Equal(ModKind.LogicMod, a.PrimaryKind);
        Assert.EndsWith("Paks/LogicMods/MyBP.pak", a.Components.Single().Files.Single().Target);
    }

    [Fact]
    public void Detects_mods_in_every_common_zip_shape()
    {
        using var t = new TempDir();
        // Scripts at the top: folder comes from the zip name, minus the Nexus id/version suffix
        var top = Fixtures.Analyze(Fixtures.Zip(t, "Better Shelves-123-1-2-1700000000.zip", ("Scripts/main.lua", "x")));
        Assert.Equal("Better_Shelves", top.LuaFolders.Single());

        // Full game layout
        var full = Fixtures.Analyze(Fixtures.Zip(t, "full.zip",
            ("RetroRewind/Binaries/Win64/ue4ss/Mods/Deep/Scripts/main.lua", "x"),
            ("RetroRewind/Binaries/Win64/ue4ss/Mods/shared/lib/util.lua", "y")));
        Assert.Equal("Deep", full.LuaFolders.Single());
        Assert.EndsWith("ue4ss/Mods/shared/lib/util.lua", full.SharedFiles.Single().Target);

        // C++ UE4SS mod
        Assert.Equal("Native", Fixtures.Analyze(Fixtures.Zip(t, "n.zip", ("Native/dlls/main.dll", "x"))).LuaFolders.Single());

        // Nothing usable
        Assert.Throws<ModInstallException>(() => Fixtures.Analyze(Fixtures.Zip(t, "junk.zip", ("readme.txt", "x"))));
        // UE4SS itself
        Assert.Throws<ModInstallException>(() => Fixtures.Analyze(Fixtures.Zip(t, "ue.zip", ("dwmapi.dll", "x"), ("ue4ss/UE4SS.dll", "y"))));
    }

    [Fact]
    public void Unsafe_paths_are_refused()
    {
        using var t = new TempDir();
        string zip = Fixtures.Zip(t, "evil.zip", ("Evil/Scripts/main.lua", "x"), ("Evil/Scripts/../../../../dwmapi.dll", "boom"));
        var ex = Assert.Throws<ModInstallException>(() => Fixtures.Analyze(zip));
        Assert.Contains("unsafe", ex.Message);
    }

    [Fact]
    public void Refuses_to_overwrite_an_unmanaged_mod_unless_asked()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        string zip = Fixtures.Zip(t, "k.zip", ("Keybinds/Scripts/main.lua", "mine"));

        var ex = Assert.Throws<ModConflictException>(() => Fixtures.InstallZip(mgr, zip, Who("kb")));
        Assert.Contains(@"ue4ss\Mods\Keybinds", ex.Conflicts);
        Assert.Equal("-- Keybinds", File.ReadAllText(Path.Combine(g.Ue4ssModsDir, "Keybinds", "Scripts", "main.lua")));

        Fixtures.InstallZip(mgr, zip, Who("kb"), new InstallOptions { ReplaceUnmanaged = true });
        Assert.Equal("mine", File.ReadAllText(Path.Combine(g.Ue4ssModsDir, "Keybinds", "Scripts", "main.lua")));
    }

    [Fact]
    public void Uninstall_removes_the_folder_and_the_mods_txt_line()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "m.zip", ("M/Scripts/main.lua", "x")), Who("m"));
        mgr.Uninstall("m");
        Assert.False(Directory.Exists(Path.Combine(g.Ue4ssModsDir, "M")));
        Assert.Null(ModsTxt.Load(g.ModsTxt).IsEnabled("M"));
        Assert.Equal(File.ReadAllText(Fixtures.PathOf("mods_stock.txt")), File.ReadAllText(g.ModsTxt));
        Assert.Throws<ModInstallException>(() => mgr.Uninstall("m"));
    }

    [Fact]
    public void ScanGame_lists_built_in_and_hand_installed_mods()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        Directory.CreateDirectory(Path.Combine(g.Ue4ssModsDir, "shared"));
        Directory.CreateDirectory(Path.Combine(g.Ue4ssModsDir, "Broken"));
        Directory.CreateDirectory(g.PakModsDir);
        File.WriteAllText(Path.Combine(g.PakModsDir, "Hand_P.pak"), "x");
        var scan = new ModManager(g, t.Combine("installed.json")).ScanGame();

        Assert.DoesNotContain(scan, m => m.Name == "shared");
        Assert.True(scan.Single(m => m.Name == "BPModLoaderMod").BuiltIn);
        Assert.True(scan.Single(m => m.Name == "BPModLoaderMod").Enabled);   // from mods.txt
        Assert.False(scan.Single(m => m.Name == "Broken").HasEntryPoint);
        Assert.Null(scan.Single(m => m.Name == "Hand_P").ManagedId);

        var mgr = new ModManager(g, t.Combine("installed.json"));
        mgr.SetEnabled(scan.Single(m => m.Name == "Hand_P"), false);
        Assert.True(File.Exists(Path.Combine(g.DisabledPakModsDir, "Hand_P.pak")));
        mgr.SetEnabled(scan.Single(m => m.Name == "ConsoleEnablerMod"), false);
        Assert.False(ModsTxt.Load(g.ModsTxt).IsEnabled("ConsoleEnablerMod"));
    }

    [Fact]
    public void Each_game_install_has_its_own_records()
    {
        using var a = new TempDir();
        using var b = new TempDir();
        string manifest = a.Combine("installed.json");
        var ga = Fixtures.FakeGame(a);
        var gb = Fixtures.FakeGame(b);
        Fixtures.InstallZip(new ModManager(ga, manifest), Fixtures.Zip(a, "m.zip", ("M/Scripts/main.lua", "x")), Who("m"));
        Assert.Single(new ModManager(ga, manifest).Managed());
        Assert.Empty(new ModManager(gb, manifest).Managed());
    }
}

public class RewindTogetherInstallTests
{
    private static (string, string)[] RtFiles(string folder, int configVersion, string marker = "new")
        => new (string, string)[]
        {
            ($"{folder}Scripts/main.lua", "-- main " + marker),
            ($"{folder}Scripts/net.lua", "Net.VERSION = \"1.7.0\""),
            ($"{folder}Scripts/rpcchan.lua", "-- rpc"),
            ($"{folder}Scripts/config.lua", $"Config.ConfigVersion = {configVersion}\nConfig.JoinTarget = \"{marker}\""),
            ($"{folder}mod.json", "{ \"id\": \"rewind-together\", \"name\": \"Rewind Together\", \"version\": \"1.7.0\", \"game_build\": \"23896268\", \"ue4ss\": \"3.0.1\" }"),
        };

    [Fact]
    public void Is_recognised_whatever_the_download_is_called_and_lands_in_RewindTogether()
    {
        using var t = new TempDir();
        var a = Fixtures.Analyze(Fixtures.Zip(t, "rewind-together-v1.7.0.zip", RtFiles("", 9)));
        Assert.True(a.IsRewindTogether);
        Assert.Equal("RewindTogether", a.LuaFolders.Single());
        Assert.Equal("1.7.0", a.ModJsonVersion);
        Assert.Equal("23896268", a.ModJsonGameBuild);

        // Without mod.json, its own modules identify it.
        var b = Fixtures.Analyze(Fixtures.Zip(t, "src.zip",
            ("Scripts/main.lua", "x"), ("Scripts/net.lua", "x"), ("Scripts/rpcchan.lua", "x")), fallback: "Scripts-copy");
        Assert.Equal("RewindTogether", b.LuaFolders.Single());
    }

    [Fact]
    public void Keeps_the_players_config_lua_when_the_ConfigVersion_matches()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "a.zip", RtFiles("RewindTogether/", 9, "old")), new ModIdentity("rewind-together", "Rewind Together", "1.6.0", "test"));
        string cfg = Path.Combine(g.RewindTogetherDir, "Scripts", "config.lua");
        File.WriteAllText(cfg, "Config.ConfigVersion = 9\nConfig.JoinTarget = \"my edit\"");

        var outcome = Fixtures.InstallZip(mgr, Fixtures.Zip(t, "b.zip", RtFiles("RewindTogether/", 9, "new")), new ModIdentity("rewind-together", "Rewind Together", "1.7.0", "test"));

        Assert.Contains("my edit", File.ReadAllText(cfg));
        Assert.Contains("-- main new", File.ReadAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua")));
        Assert.Contains(outcome.Notes, n => n.Contains("Kept your existing config.lua"));
    }

    [Fact]
    public void Replaces_config_lua_and_keeps_a_backup_when_the_ConfigVersion_changed()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "a.zip", RtFiles("RewindTogether/", 8, "old")), new ModIdentity("rewind-together", "Rewind Together", "1.6.0", "test"));

        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "b.zip", RtFiles("RewindTogether/", 9, "new")), new ModIdentity("rewind-together", "Rewind Together", "1.7.0", "test"));

        Assert.Contains("\"new\"", File.ReadAllText(Path.Combine(g.RewindTogetherDir, "Scripts", "config.lua")));
        Assert.Contains("\"old\"", File.ReadAllText(Path.Combine(g.Ue4ssModsDir, "RewindTogether-config.lua.v8-backup")));
    }

    [Fact]
    public void Replaces_a_hand_installed_copy_and_reports_version_and_build()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        // what Install-RewindTogether.ps1 leaves behind: folder + enabled.txt + mods.txt line
        Fixtures.WriteAt(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua"), "-- old");
        Fixtures.WriteAt(Path.Combine(g.RewindTogetherDir, "enabled.txt"), "");
        ModsTxt.Update(g.ModsTxt, d => d.SetEnabled("RewindTogether", true));

        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "rt.zip", RtFiles("RewindTogether/", 9)), new ModIdentity("rewind-together", "Rewind Together", "1.7.0", "test"),
            new InstallOptions { ReplaceUnmanaged = true });

        var info = RewindTogetherInfo.Read(g);
        Assert.True(info.Installed);
        Assert.Equal("1.7.0", info.Version);
        Assert.Equal("23896268", info.GameBuild);
        Assert.True(info.EnabledInModsTxt);
        Assert.Null(info.BuildWarning("23896268"));
        Assert.NotNull(info.BuildWarning("24000000"));
        Assert.False(File.Exists(Path.Combine(g.RewindTogetherDir, "enabled.txt")));
        Assert.Single(ModsTxt.Load(g.ModsTxt).Entries, e => e.Name == "RewindTogether");
    }

    [Fact]
    public void Uninstall_keeps_a_copy_of_config_lua()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        var mgr = new ModManager(g, t.Combine("installed.json"));
        Fixtures.InstallZip(mgr, Fixtures.Zip(t, "rt.zip", RtFiles("RewindTogether/", 9, "mine")), new ModIdentity("rewind-together", "Rewind Together", "1.7.0", "test"));
        mgr.Uninstall("rewind-together");
        Assert.False(Directory.Exists(g.RewindTogetherDir));
        Assert.Contains("mine", File.ReadAllText(Path.Combine(g.Ue4ssModsDir, "RewindTogether-config.lua.uninstalled-backup")));
        Assert.False(RewindTogetherInfo.Read(g).Installed);
    }

    [Fact]
    public void Version_falls_back_to_net_lua_when_there_is_no_mod_json()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t);
        Fixtures.WriteAt(Path.Combine(g.RewindTogetherDir, "Scripts", "main.lua"), "");
        Fixtures.WriteAt(Path.Combine(g.RewindTogetherDir, "Scripts", "net.lua"), "Net.VERSION = \"1.6.1\"");
        Assert.Equal("1.6.1", RewindTogetherInfo.Read(g).Version);
    }
}

public class Ue4ssSetupTests
{
    private static string Ue4ssZip(TempDir t, bool flat = false)
        => flat
            ? Fixtures.Zip(t, "UE4SS_v3.0.1.zip", ("dwmapi.dll", "p"), ("UE4SS.dll", "d"), ("Mods/mods.txt", "x"))
            : Fixtures.Zip(t, "UE4SS_v3.0.1-944-g0196ef29.zip",
                ("dwmapi.dll", "proxy"),
                ("ue4ss/UE4SS.dll", "dll"),
                ("ue4ss/UE4SS-settings.ini", "[Stock]"),
                ("ue4ss/Mods/mods.txt", "STOCK"),
                ("ue4ss/Mods/mods.json", "[]"),
                ("ue4ss/Mods/Keybinds/Scripts/main.lua", "-- kb"));

    [Fact]
    public void Validates_the_layout_before_writing_anything()
    {
        using var t = new TempDir();
        Assert.Null(Ue4ssSetup.ValidateZip(Ue4ssZip(t)));
        Assert.Contains("older UE4SS", Ue4ssSetup.ValidateZip(Ue4ssZip(t, flat: true)));
        Assert.Contains("not a UE4SS release", Ue4ssSetup.ValidateZip(Fixtures.Zip(t, "x.zip", ("a.txt", "a"))));
    }

    [Fact]
    public void Installs_into_Win64_and_never_overwrites_the_players_settings_or_mod_list()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t, withUe4ss: false);
        Assert.Equal(Ue4ssState.NotInstalled, Ue4ssSetup.Detect(g).State);

        Fixtures.WriteAt(Path.Combine(g.Ue4ssDir, "UE4SS-settings.ini"), "[Mine]");
        Fixtures.WriteAt(Path.Combine(g.Ue4ssModsDir, "mods.txt"), "Mine : 1");
        Assert.Equal(Ue4ssState.Broken, Ue4ssSetup.Detect(g).State);

        var notes = Ue4ssSetup.InstallFromZip(g, Ue4ssZip(t));

        Assert.Equal("proxy", File.ReadAllText(g.Ue4ssProxyDll));
        Assert.Equal("dll", File.ReadAllText(g.Ue4ssDll));
        Assert.Equal("[Mine]", File.ReadAllText(g.Ue4ssSettings));
        Assert.Equal("Mine : 1", File.ReadAllText(g.ModsTxt));
        Assert.Equal("[]", File.ReadAllText(g.ModsJson)); // there was none, so the stock one is used
        Assert.Contains(notes, n => n.Contains("UE4SS-settings.ini"));
        var status = Ue4ssSetup.Detect(g);
        Assert.Equal(Ue4ssState.Installed, status.State);
        Assert.False(status.IsPinnedBuild); // our fake DLL is not the real pinned one
    }

    [Fact]
    public void Old_flat_layout_is_reported()
    {
        using var t = new TempDir();
        var g = Fixtures.FakeGame(t, withUe4ss: false);
        File.WriteAllText(Path.Combine(g.Win64, "UE4SS.dll"), "old");
        File.WriteAllText(g.Ue4ssProxyDll, "old");
        Assert.Equal(Ue4ssState.OldLayout, Ue4ssSetup.Detect(g).State);
        Assert.Throws<ModInstallException>(() => Ue4ssSetup.InstallFromZip(g, Ue4ssZip(t, flat: true)));
    }

    [Fact]
    public void Pinned_constants_are_consistent()
    {
        Assert.True(Hashing.IsSha256Hex(Ue4ssSetup.PinnedSha256));
        Assert.True(Hashing.IsSha256Hex(Ue4ssSetup.PinnedDllSha256));
        Assert.StartsWith("https://github.com/UE4SS-RE/RE-UE4SS/releases/download/", Ue4ssSetup.PinnedUrl);
        Assert.EndsWith(Ue4ssSetup.PinnedFileName, Ue4ssSetup.PinnedUrl);
    }
}
