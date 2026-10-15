using System.IO.Compression;
using System.Text;
using RewindTogether.Launcher.Core;

namespace RewindTogether.Launcher.Tests;

/// <summary>A throw-away folder under %TEMP%, deleted on dispose.</summary>
public sealed class TempDir : IDisposable
{
    public TempDir()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rt-launcher-tests", Guid.NewGuid().ToString("N")[..12]);
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string Combine(params string[] parts) => System.IO.Path.Combine(new[] { Path }.Concat(parts).ToArray());

    public string Write(string relative, string content)
    {
        string full = Combine(relative);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
        File.WriteAllText(full, content, new UTF8Encoding(false));
        return full;
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch { }
    }
}

public static class Fixtures
{
    public static string Read(string name) => File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    /// <summary>Writes a file at an absolute path (inside a fake game), creating folders.</summary>
    public static void WriteAt(string fullPath, string content)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(fullPath)!);
        File.WriteAllText(fullPath, content, new UTF8Encoding(false));
    }
    public static string PathOf(string name) => System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", name);

    /// <summary>
    /// A fake Retro Rewind install: the exe (empty), UE4SS 3.x layout with the stock mods.txt and
    /// the built-in mods, and empty pak folders. Never the real game.
    /// </summary>
    public static GameInstall FakeGame(TempDir dir, bool withUe4ss = true)
    {
        string root = dir.Combine("steamapps", "common", "RetroRewind");
        var g = new GameInstall(root, null, "23896268", "test");
        Directory.CreateDirectory(g.Win64);
        File.WriteAllBytes(g.Exe, Array.Empty<byte>());
        Directory.CreateDirectory(g.PaksDir);
        if (withUe4ss)
        {
            File.WriteAllBytes(g.Ue4ssProxyDll, new byte[] { 1 });
            Directory.CreateDirectory(g.Ue4ssModsDir);
            File.WriteAllBytes(g.Ue4ssDll, new byte[] { 2 });
            File.Copy(PathOf("mods_stock.txt"), g.ModsTxt);
            File.Copy(PathOf("mods_stock.json"), g.ModsJson);
            foreach (string m in new[] { "BPModLoaderMod", "Keybinds", "ConsoleEnablerMod" })
                WriteAt(System.IO.Path.Combine(g.Ue4ssModsDir, m, "Scripts", "main.lua"), "-- " + m);
        }
        return g;
    }

    /// <summary>Builds a zip from (path, content) pairs.</summary>
    public static string Zip(TempDir dir, string name, params (string Path, string Content)[] entries)
    {
        string zipPath = dir.Combine(name);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(zipPath)!);
        using var fs = File.Create(zipPath);
        using var zip = new ZipArchive(fs, ZipArchiveMode.Create);
        foreach (var (p, c) in entries)
        {
            var e = zip.CreateEntry(p);
            using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
            w.Write(c);
        }
        return zipPath;
    }

    public static PackageAnalysis Analyze(string path, string? fallback = null, string? forcedFolder = null, ModKind? hint = null)
    {
        using var src = PackageSource.Open(path);
        // Materialise the analysis while the zip is open; tests that install use InstallZip instead.
        return PackageAnalyzer.Analyze(src, fallback, forcedFolder, hint);
    }

    public static InstallOutcome InstallZip(ModManager mgr, string zip, ModIdentity who, InstallOptions? opts = null, string? forcedFolder = null, ModKind? hint = null)
    {
        using var src = PackageSource.Open(zip);
        var pkg = PackageAnalyzer.Analyze(src, null, forcedFolder, hint);
        return mgr.Install(pkg, who, opts);
    }
}
