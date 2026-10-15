using RewindTogether.Launcher.Core;
using Xunit;

namespace RewindTogether.Launcher.Tests;

public class ModsTxtTests
{
    private static string Stock => Fixtures.Read("mods_stock.txt");

    [Fact]
    public void Inserts_directly_above_the_keybinds_comment()
    {
        var doc = ModsTxt.Parse(Stock);
        Assert.True(doc.SetEnabled("RewindTogether", true));

        var lines = doc.Lines.ToList();
        int marker = lines.FindIndex(l => l.Contains("Built-in keybinds"));
        Assert.Equal("RewindTogether : 1", lines[marker - 1]);
        Assert.Equal("Keybinds : 1", lines[marker + 1]);
        Assert.Equal(lines.Count - 1, marker + 1); // Keybinds is still the last line
    }

    [Fact]
    public void Matches_the_real_file_shape_after_an_install()
    {
        var doc = ModsTxt.Parse(Stock);
        doc.SetEnabled("RewindTogether", true);
        string expected = "CheatManagerEnablerMod : 1\r\nConsoleCommandsMod : 1\r\nConsoleEnablerMod : 1\r\nSplitScreenMod : 0\r\nLineTraceMod : 0\r\n" +
                          "BPML_GenericFunctions : 1\r\nBPModLoaderMod : 1\r\n\r\n\r\n\r\n\r\nRewindTogether : 1\r\n; Built-in keybinds, do not move up!\r\nKeybinds : 1\r\n";
        Assert.Equal(expected, doc.ToString());
    }

    [Fact]
    public void Is_idempotent()
    {
        var once = ModsTxt.Parse(Stock);
        once.SetEnabled("RewindTogether", true);
        string a = once.ToString();

        var twice = ModsTxt.Parse(a);
        Assert.False(twice.SetEnabled("RewindTogether", true));
        Assert.Equal(a, twice.ToString());
        Assert.Single(twice.Entries, e => e.Name == "RewindTogether");
    }

    [Fact]
    public void Toggles_in_place_without_moving_the_line()
    {
        var doc = ModsTxt.Parse(Stock);
        doc.SetEnabled("RewindTogether", true);
        int before = doc.Lines.ToList().IndexOf("RewindTogether : 1");

        Assert.True(doc.SetEnabled("RewindTogether", false));
        Assert.Equal("RewindTogether : 0", doc.Lines[before]);
        Assert.False(doc.IsEnabled("RewindTogether"));

        Assert.True(doc.SetEnabled("rewindtogether", true)); // case-insensitive like Windows folder names
        Assert.Equal("RewindTogether : 1", doc.Lines[before]);  // and keeps the file's own spelling
        Assert.True(doc.IsEnabled("RewindTogether"));
    }

    [Fact]
    public void Toggles_built_in_mods_too()
    {
        var doc = ModsTxt.Parse(Stock);
        Assert.True(doc.SetEnabled("LineTraceMod", true));
        Assert.True(doc.IsEnabled("LineTraceMod"));
        Assert.True(doc.SetEnabled("Keybinds", false));
        Assert.Equal("Keybinds : 0", doc.Lines[^1]); // Keybinds itself never moves
    }

    [Fact]
    public void A_line_below_the_marker_is_moved_up()
    {
        string text = "A : 1\r\n; Built-in keybinds, do not move up!\r\nKeybinds : 1\r\nRewindTogether : 1\r\n";
        var doc = ModsTxt.Parse(text);
        Assert.True(doc.SetEnabled("RewindTogether", true));
        Assert.Equal(new[] { "A : 1", "RewindTogether : 1", "; Built-in keybinds, do not move up!", "Keybinds : 1" }, doc.Lines);
    }

    [Fact]
    public void Duplicate_lines_are_collapsed()
    {
        var doc = ModsTxt.Parse("RewindTogether : 0\nRewindTogether : 1\nKeybinds : 1\n");
        doc.SetEnabled("RewindTogether", true);
        Assert.Single(doc.Entries, e => e.Name == "RewindTogether");
    }

    [Fact]
    public void Without_the_comment_it_inserts_above_the_Keybinds_entry()
    {
        var doc = ModsTxt.Parse("A : 1\nKeybinds : 1\n");
        doc.SetEnabled("B", true);
        Assert.Equal("A : 1\nB : 1\nKeybinds : 1\n", doc.ToString());
    }

    [Fact]
    public void Without_any_marker_it_appends_before_trailing_blank_lines()
    {
        var doc = ModsTxt.Parse("A : 1\n\n");
        doc.SetEnabled("B", false);
        Assert.Equal("A : 1\nB : 0\n\n", doc.ToString());
    }

    [Fact]
    public void Empty_or_missing_file_gets_just_our_line_and_no_BOM()
    {
        using var t = new TempDir();
        string path = t.Combine("Mods", "mods.txt");
        Assert.True(ModsTxt.Update(path, d => d.SetEnabled("RewindTogether", true)));
        byte[] bytes = File.ReadAllBytes(path);
        Assert.False(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF);
        Assert.Equal("RewindTogether : 1", File.ReadAllText(path));
    }

    [Fact]
    public void A_BOM_in_the_input_is_dropped()
    {
        var doc = ModsTxt.Parse("﻿A : 1\r\nKeybinds : 1");
        Assert.Equal("A", doc.Entries[0].Name);
        Assert.DoesNotContain('﻿', doc.ToString());
    }

    [Fact]
    public void Remove_deletes_every_line_for_the_mod()
    {
        var doc = ModsTxt.Parse("A : 1\r\nRewindTogether : 1\r\n; Built-in keybinds, do not move up!\r\nKeybinds : 1\r\n");
        Assert.True(doc.Remove("RewindTogether"));
        Assert.False(doc.Remove("RewindTogether"));
        Assert.Equal("A : 1\r\n; Built-in keybinds, do not move up!\r\nKeybinds : 1\r\n", doc.ToString());
    }

    [Fact]
    public void Update_writes_once_backs_up_once_and_leaves_no_tmp_file()
    {
        using var t = new TempDir();
        string path = t.Write("mods.txt", Stock);
        Assert.True(ModsTxt.Update(path, d => d.SetEnabled("X", true)));
        Assert.False(ModsTxt.Update(path, d => d.SetEnabled("X", true)));
        Assert.Equal(Stock, File.ReadAllText(path + ".launcher-backup"));
        Assert.False(File.Exists(path + ".tmp"));
        Assert.True(ModsTxt.Load(path).IsEnabled("X"));
    }

    [Theory]
    [InlineData("Bad:Name")]
    [InlineData("Semi;colon")]
    [InlineData("")]
    public void Refuses_names_that_would_corrupt_the_file(string name)
        => Assert.Throws<ArgumentException>(() => ModsTxt.Parse(Stock).SetEnabled(name, true));
}

public class ModsJsonTests
{
    [Fact]
    public void Adds_before_Keybinds_toggles_and_removes()
    {
        using var t = new TempDir();
        string path = t.Write("mods.json", Fixtures.Read("mods_stock.json"));

        Assert.True(ModsJson.SetEnabled(path, "RewindTogether", true));
        var arr = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(path))!.AsArray();
        Assert.Equal("RewindTogether", (string?)arr[^2]!["mod_name"]);
        Assert.Equal("Keybinds", (string?)arr[^1]!["mod_name"]);

        Assert.False(ModsJson.SetEnabled(path, "RewindTogether", true));
        Assert.True(ModsJson.SetEnabled(path, "RewindTogether", false));
        Assert.True(ModsJson.Remove(path, "RewindTogether"));
        Assert.DoesNotContain("RewindTogether", File.ReadAllText(path));
    }

    [Fact]
    public void A_missing_or_odd_file_is_left_alone()
    {
        using var t = new TempDir();
        Assert.False(ModsJson.SetEnabled(t.Combine("nope.json"), "X", true));
        string odd = t.Write("odd.json", "{ \"not\": \"an array\" }");
        Assert.False(ModsJson.SetEnabled(odd, "X", true));
        Assert.Equal("{ \"not\": \"an array\" }", File.ReadAllText(odd));
    }
}
