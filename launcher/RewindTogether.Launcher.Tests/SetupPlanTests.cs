using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class SetupPlanTests
{
    private static readonly Ue4ssStatus Ue4ssOk = new(Ue4ssState.Installed, Ue4ssSetup.PinnedVersion, true, "UE4SS is installed.");
    private static readonly Ue4ssStatus Ue4ssMissing = new(Ue4ssState.NotInstalled, null, false, "UE4SS is not installed.");

    private static RewindTogetherInfo Rt(string? version, bool? enabled = true, bool mainLua = true)
        => new(true, version, null, enabled, mainLua);

    private static readonly RewindTogetherInfo NoRt = new(false, null, null, null, false);

    [Fact]
    public void A_fresh_game_gets_everything_in_one_go()
    {
        var p = SetupPlan.For(Ue4ssMissing, NoRt, "1.7.0");
        Assert.True(p.InstallUe4ss);
        Assert.True(p.InstallMod);
        Assert.False(p.SwitchOn); // the install switches it on itself
        Assert.Equal("1.7.0", p.ModVersion);
        Assert.Equal("Install UE4SS (the mod loader), then install Rewind Together 1.7.0.", p.Describe(null));
    }

    [Fact]
    public void Unknown_state_counts_as_missing()
    {
        var p = SetupPlan.For(null, null, "1.7.0");
        Assert.True(p.InstallUe4ss);
        Assert.True(p.InstallMod);
    }

    [Fact]
    public void Nothing_to_do_when_the_same_version_is_installed_and_on()
    {
        var p = SetupPlan.For(Ue4ssOk, Rt("1.7.0"), "1.7.0");
        Assert.True(p.NothingToDo);
        Assert.Equal("", p.Describe("1.7.0"));
    }

    [Fact]
    public void A_newer_bundled_version_is_an_update()
    {
        var p = SetupPlan.For(Ue4ssOk, Rt("1.6.1"), "1.7.0");
        Assert.False(p.InstallUe4ss);
        Assert.True(p.InstallMod);
        Assert.Equal("1.7.0", p.ModVersion);
        Assert.Equal("Update Rewind Together to 1.7.0.", p.Describe("1.6.1"));
    }

    [Fact]
    public void An_older_bundled_version_never_replaces_a_newer_install()
    {
        Assert.True(SetupPlan.For(Ue4ssOk, Rt("1.8.0"), "1.7.0").NothingToDo);
        Assert.True(SetupPlan.For(Ue4ssOk, Rt("1.7.0"), null).NothingToDo);
    }

    [Fact]
    public void A_switched_off_mod_is_switched_on_without_reinstalling()
    {
        var p = SetupPlan.For(Ue4ssOk, Rt("1.7.0", enabled: false), "1.7.0");
        Assert.False(p.InstallMod);
        Assert.True(p.SwitchOn);
        Assert.Equal("Switch Rewind Together on.", p.Describe("1.7.0"));
    }

    [Fact]
    public void A_damaged_install_is_reinstalled()
    {
        var p = SetupPlan.For(Ue4ssOk, Rt("1.7.0", mainLua: false), "1.7.0");
        Assert.True(p.InstallMod);
        Assert.False(p.SwitchOn);
    }

    [Fact]
    public void Old_or_broken_UE4SS_is_reinstalled_but_another_working_build_is_kept()
    {
        Assert.True(SetupPlan.For(new Ue4ssStatus(Ue4ssState.OldLayout, null, false, ""), Rt("1.7.0"), "1.7.0").InstallUe4ss);
        Assert.True(SetupPlan.For(new Ue4ssStatus(Ue4ssState.Broken, null, false, ""), Rt("1.7.0"), "1.7.0").InstallUe4ss);
        Assert.True(SetupPlan.For(new Ue4ssStatus(Ue4ssState.Installed, "3.0.0", false, ""), Rt("1.7.0"), "1.7.0").NothingToDo);
    }

    [Fact]
    public void Missing_mod_with_no_source_still_plans_the_install()
    {
        var p = SetupPlan.For(Ue4ssOk, NoRt, null);
        Assert.True(p.InstallMod);
        Assert.Null(p.ModVersion);
        Assert.Equal("Install Rewind Together.", p.Describe(null));
    }
}

public class BundledUe4ssTests
{
    [Fact]
    public void The_bundled_zip_sits_in_Mods_UE4SS_next_to_the_exe()
    {
        Assert.Equal(Path.Combine(@"C:\RT", "Mods", "UE4SS", Ue4ssSetup.PinnedFileName), Ue4ssSetup.BundledZipPath(@"C:\RT"));
    }

    [Fact]
    public void Missing_or_wrong_files_are_ignored()
    {
        using var t = new TempDir();
        Assert.Null(Ue4ssSetup.FindBundledZip(null));
        Assert.Null(Ue4ssSetup.FindBundledZip(t.Path));

        // Right name, wrong bytes (a damaged or swapped download) - never installed.
        string zip = Ue4ssSetup.BundledZipPath(t.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(zip)!);
        File.WriteAllBytes(zip, new byte[1024]);
        Assert.Null(Ue4ssSetup.FindBundledZip(t.Path));
    }
}
