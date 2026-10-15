using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RewindTogether.Launcher.Core;

/// <summary>One file inside a mod download (zip entry, folder file or loose .pak).</summary>
public sealed class PackageFile
{
    public PackageFile(string path, long length, Func<Stream> open)
    {
        Path = path;
        Length = length;
        Open = open;
    }

    /// <summary>Forward-slash relative path inside the package.</summary>
    public string Path { get; }
    public long Length { get; }
    public Func<Stream> Open { get; }
    public string[] Segments => Path.Split('/', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>A zip, a folder, or a loose .pak (plus its .ucas/.utoc siblings), opened for reading.</summary>
public sealed class PackageSource : IDisposable
{
    private readonly IDisposable? _owner;

    private PackageSource(string originalPath, string displayName, List<PackageFile> files, IDisposable? owner)
    {
        OriginalPath = originalPath;
        DisplayName = displayName;
        Files = files;
        _owner = owner;
    }

    public string OriginalPath { get; }
    /// <summary>File/folder name without extension: the fallback mod name.</summary>
    public string DisplayName { get; }
    public IReadOnlyList<PackageFile> Files { get; }

    public static readonly string[] PakExtensions = { ".pak", ".ucas", ".utoc", ".sig" };

    public static PackageSource Open(string path)
    {
        if (Directory.Exists(path))
        {
            string root = System.IO.Path.GetFullPath(path).TrimEnd('\\', '/');
            var files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
                .Select(f => new PackageFile(
                    System.IO.Path.GetRelativePath(root, f).Replace('\\', '/'),
                    new FileInfo(f).Length,
                    () => new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)))
                .ToList();
            return new PackageSource(root, System.IO.Path.GetFileName(root), files, null);
        }

        if (!File.Exists(path))
            throw new ModInstallException($"\"{path}\" does not exist.");

        string ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
        if (ext == ".zip")
        {
            ZipArchive zip;
            try { zip = ZipFile.OpenRead(path); }
            catch (InvalidDataException) { throw new ModInstallException("This file is not a valid .zip archive (it may be damaged, or only partly downloaded). Download it again."); }
            var files = zip.Entries
                .Where(e => !e.FullName.EndsWith('/') && !e.FullName.EndsWith('\\'))
                .Select(e => new PackageFile(e.FullName.Replace('\\', '/').TrimStart('/'), e.Length, e.Open))
                .ToList();
            return new PackageSource(path, System.IO.Path.GetFileNameWithoutExtension(path), files, zip);
        }

        if (PakExtensions.Contains(ext))
        {
            string dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!;
            string stem = System.IO.Path.GetFileNameWithoutExtension(path);
            var files = PakExtensions
                .Select(e => System.IO.Path.Combine(dir, stem + e))
                .Where(File.Exists)
                .Select(f => new PackageFile(System.IO.Path.GetFileName(f), new FileInfo(f).Length,
                    () => new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)))
                .ToList();
            return new PackageSource(path, stem, files, null);
        }

        if (ext is ".7z" or ".rar")
            throw new ModInstallException(
                $"This is a {ext} archive, which Windows cannot open by itself. Extract it with 7-Zip " +
                "(free, 7-zip.org), then use \"Add mod from folder\" and pick the extracted folder.");

        throw new ModInstallException("Choose a .zip file, a .pak file, or a folder.");
    }

    public void Dispose() => _owner?.Dispose();
}

/// <summary>A plain-English install problem. <see cref="GameFilesLockedException"/> is the "close the game" case.</summary>
public class ModInstallException : Exception
{
    public ModInstallException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>A part of a package that installs to one place.</summary>
public sealed class ModComponent
{
    public ModKind Kind { get; init; }
    /// <summary>For UE4SS mods: the folder under ue4ss\Mods.</summary>
    public string? Folder { get; set; }
    /// <summary>(source file, destination relative to the game root).</summary>
    public List<(PackageFile Source, string Target)> Files { get; } = new();
}

public sealed class PackageAnalysis
{
    public List<ModComponent> Components { get; } = new();
    /// <summary>ue4ss\Mods\shared\... libraries: installed, but never removed on uninstall (other mods may use them).</summary>
    public List<(PackageFile Source, string Target)> SharedFiles { get; } = new();
    public List<string> Warnings { get; } = new();
    public string? ModJsonId { get; set; }
    public string? ModJsonName { get; set; }
    public string? ModJsonVersion { get; set; }
    public string? ModJsonGameBuild { get; set; }
    public string SuggestedName { get; set; } = "";
    public bool IsRewindTogether { get; set; }
    public int IgnoredFiles { get; set; }

    public ModKind PrimaryKind => Components.Any(c => c.Kind == ModKind.Ue4ssLua) ? ModKind.Ue4ssLua
        : Components.Any(c => c.Kind == ModKind.LogicMod) ? ModKind.LogicMod : ModKind.Pak;

    public IEnumerable<string> LuaFolders => Components.Where(c => c.Kind == ModKind.Ue4ssLua).Select(c => c.Folder!);
}

/// <summary>
/// Works out what a mod download is and where each file goes, from its contents alone - Nexus
/// zips come in every shape: "MyMod\Scripts\main.lua", "Scripts\main.lua" at the top,
/// "RetroRewind\Binaries\Win64\ue4ss\Mods\MyMod\...", loose .pak files, "~mods\x.pak",
/// "LogicMods\x.pak" ...
/// </summary>
public static class PackageAnalyzer
{
    public const string Win64Rel = "RetroRewind/Binaries/Win64";
    public const string Ue4ssModsRel = "RetroRewind/Binaries/Win64/ue4ss/Mods";
    public const string PakModsRel = "RetroRewind/Content/Paks/~mods";
    public const string LogicModsRel = "RetroRewind/Content/Paks/LogicMods";

    private static readonly string[] Junk = { "__MACOSX", ".DS_Store", "Thumbs.db", "desktop.ini" };

    /// <param name="fallbackName">Folder name to use when Scripts\main.lua sits at the top of the archive.</param>
    /// <param name="forcedFolder">Force the UE4SS folder name (used for catalog entries with a "folder").</param>
    /// <param name="pakKindHint">Catalog type for loose paks whose kind cannot be told from their path.</param>
    public static PackageAnalysis Analyze(PackageSource src, string? fallbackName = null, string? forcedFolder = null, ModKind? pakKindHint = null)
    {
        var a = new PackageAnalysis();
        var files = src.Files.Where(f => !f.Segments.Any(s => Junk.Contains(s, StringComparer.OrdinalIgnoreCase))).ToList();

        // "Zip slip": an entry like Mod/Scripts/../../../dwmapi.dll would land outside its mod folder.
        var unsafePath = files.FirstOrDefault(f => f.Segments.Any(s => s == ".." || s.Contains(':')) || f.Path.StartsWith('/'));
        if (unsafePath != null)
            throw new ModInstallException($"This archive contains an unsafe file path ({unsafePath.Path}), so it was not installed.");

        // UE4SS itself is installed from the Play tab, never as a "mod".
        bool hasUe4ssDll = files.Any(f => f.Segments.Length > 0 && f.Segments[^1].Equals("UE4SS.dll", StringComparison.OrdinalIgnoreCase));
        bool hasProxy = files.Any(f => f.Segments.Length > 0 && f.Segments[^1] is var n &&
            (n.Equals("dwmapi.dll", StringComparison.OrdinalIgnoreCase) || n.Equals("xinput1_3.dll", StringComparison.OrdinalIgnoreCase)));
        if (hasUe4ssDll && hasProxy)
            throw new ModInstallException("This is UE4SS itself, not a mod. Install it from the Play tab (\"Install UE4SS\").");

        // ---- UE4SS mods: every folder that holds Scripts\main.lua or dlls\main.dll
        var roots = new List<string>();
        foreach (var f in files)
        {
            var s = f.Segments;
            if (s.Length < 2) continue;
            bool lua = s[^2].Equals("Scripts", StringComparison.OrdinalIgnoreCase) && s[^1].Equals("main.lua", StringComparison.OrdinalIgnoreCase);
            bool dll = s[^2].Equals("dlls", StringComparison.OrdinalIgnoreCase) && s[^1].Equals("main.dll", StringComparison.OrdinalIgnoreCase);
            if (!lua && !dll) continue;
            string root = string.Join('/', s.Take(s.Length - 2));
            if (!roots.Contains(root, StringComparer.OrdinalIgnoreCase)) roots.Add(root);
        }
        // A root nested inside another root is part of that mod, not a mod of its own.
        roots = roots.Where(r => !roots.Any(o => o != r && IsUnder(r, o))).ToList();

        var claimed = new HashSet<PackageFile>();
        foreach (string root in roots)
        {
            string prefix = root.Length == 0 ? "" : root + "/";
            var modJson = files.FirstOrDefault(f => f.Path.Equals(prefix + "mod.json", StringComparison.OrdinalIgnoreCase));
            string? jsonIdBefore = a.ModJsonId;
            if (modJson != null) ReadModJson(modJson, a);

            // Rewind Together must always land in ue4ss\Mods\RewindTogether, whatever the zip or
            // folder it came in is called: recognise it by its mod.json id, or by two of its own modules.
            bool isRt = (modJson != null && jsonIdBefore == null &&
                         string.Equals(a.ModJsonId, GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase))
                        || (files.Any(f => f.Path.Equals(prefix + "Scripts/rpcchan.lua", StringComparison.OrdinalIgnoreCase))
                            && files.Any(f => f.Path.Equals(prefix + "Scripts/launchfile.lua", StringComparison.OrdinalIgnoreCase) ||
                                              f.Path.Equals(prefix + "Scripts/net.lua", StringComparison.OrdinalIgnoreCase)));

            string folderSource = root.Length == 0
                ? (fallbackName ?? src.DisplayName)
                : root.Split('/')[^1];
            string folder = SanitizeFolderName(roots.Count == 1 && forcedFolder != null ? forcedFolder : folderSource);
            if (folder.Equals("Mods", StringComparison.OrdinalIgnoreCase) || folder.Equals("ue4ss", StringComparison.OrdinalIgnoreCase))
                folder = SanitizeFolderName(fallbackName ?? src.DisplayName);
            if (isRt) folder = GameInstall.RewindTogetherFolder;

            var comp = new ModComponent { Kind = ModKind.Ue4ssLua, Folder = folder };
            foreach (var f in files)
            {
                if (!IsUnder(f.Path, root) && root.Length > 0) continue;
                if (root.Length == 0 && roots.Count > 1) continue; // ambiguous top-level files
                string rest = root.Length == 0 ? f.Path : f.Path.Substring(root.Length + 1);
                if (root.Length == 0 && IsPak(f)) continue; // loose paks next to a top-level Scripts folder are handled below
                claimed.Add(f);
                // enabled.txt would make UE4SS start the mod even when mods.txt says 0, which
                // would break "disable". mods.txt is how the launcher enables mods.
                if (rest.Equals("enabled.txt", StringComparison.OrdinalIgnoreCase)) continue;
                comp.Files.Add((f, $"{Ue4ssModsRel}/{folder}/{rest}"));
            }
            a.Components.Add(comp);
        }

        // ---- shared Lua libraries (…/Mods/shared/…)
        foreach (var f in files)
        {
            if (claimed.Contains(f)) continue;
            var s = f.Segments;
            int k = Array.FindIndex(s, x => x.Equals("shared", StringComparison.OrdinalIgnoreCase));
            if (k > 0 && s[k - 1].Equals("Mods", StringComparison.OrdinalIgnoreCase) && k < s.Length - 1)
            {
                claimed.Add(f);
                a.SharedFiles.Add((f, $"{Ue4ssModsRel}/shared/{string.Join('/', s.Skip(k + 1))}"));
            }
        }

        // ---- pak mods
        var pakFiles = files.Where(f => !claimed.Contains(f) && IsPak(f)).ToList();
        if (pakFiles.Count > 0)
        {
            var pak = new ModComponent { Kind = ModKind.Pak };
            var logic = new ModComponent { Kind = ModKind.LogicMod };
            bool? looseIsLogic = null;
            foreach (var f in pakFiles)
            {
                var s = f.Segments;
                int li = Array.FindIndex(s, x => x.Equals("LogicMods", StringComparison.OrdinalIgnoreCase));
                int mi = Array.FindIndex(s, x => x.Equals("~mods", StringComparison.OrdinalIgnoreCase));
                if (li >= 0 && li < s.Length - 1)
                {
                    logic.Files.Add((f, $"{LogicModsRel}/{string.Join('/', s.Skip(li + 1))}"));
                }
                else if (mi >= 0 && mi < s.Length - 1)
                {
                    pak.Files.Add((f, $"{PakModsRel}/{string.Join('/', s.Skip(mi + 1))}"));
                }
                else
                {
                    looseIsLogic ??= pakKindHint.HasValue
                        ? pakKindHint == ModKind.LogicMod
                        : pakFiles.Any(LooksLikeLogicMod);
                    (looseIsLogic.Value ? logic : pak).Files.Add((f, $"{(looseIsLogic.Value ? LogicModsRel : PakModsRel)}/{s[^1]}"));
                }
                claimed.Add(f);
            }
            if (pak.Files.Count > 0) a.Components.Add(pak);
            if (logic.Files.Count > 0) a.Components.Add(logic);
            if (pakFiles.Any(f => f.Path.EndsWith(".pak", StringComparison.OrdinalIgnoreCase)) == false)
                a.Warnings.Add("There are .ucas/.utoc files but no .pak file; the game needs all three to load an IoStore mod.");
        }

        a.IgnoredFiles = files.Count(f => !claimed.Contains(f));

        if (a.Components.Count == 0)
            throw new ModInstallException(
                "No mod was found inside. The launcher looks for a UE4SS mod (a folder with Scripts\\main.lua) " +
                "or .pak files. If this mod came with its own install instructions, follow those instead.");

        a.IsRewindTogether =
            string.Equals(a.ModJsonId, GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase) ||
            a.LuaFolders.Any(f => f.Equals(GameInstall.RewindTogetherFolder, StringComparison.OrdinalIgnoreCase));

        a.SuggestedName = a.ModJsonName
            ?? (a.LuaFolders.FirstOrDefault()
                ?? System.IO.Path.GetFileNameWithoutExtension(a.Components[0].Files[0].Target.Split('/')[^1]));
        return a;
    }

    private static bool IsUnder(string path, string root)
        => root.Length == 0 || path.StartsWith(root + "/", StringComparison.OrdinalIgnoreCase);

    private static bool IsPak(PackageFile f)
        => PackageSource.PakExtensions.Any(e => f.Path.EndsWith(e, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Blueprint mods for BPModLoaderMod contain a "ModActor" asset. Pak indexes usually store
    /// file names in plain text at the end of the file (and in the .utoc for IoStore), so a
    /// byte search there is a decent heuristic. An encrypted index simply looks like a normal pak.
    /// </summary>
    public static bool LooksLikeLogicMod(PackageFile f)
    {
        bool utoc = f.Path.EndsWith(".utoc", StringComparison.OrdinalIgnoreCase);
        bool pak = f.Path.EndsWith(".pak", StringComparison.OrdinalIgnoreCase);
        if (!utoc && !pak) return false;
        if (f.Length > 256L * 1024 * 1024) return false;
        try
        {
            using var s = f.Open();
            byte[] needle = Encoding.ASCII.GetBytes("ModActor");
            const int tailWindow = 8 * 1024 * 1024;
            byte[] data;
            if (s.CanSeek && s.Length > tailWindow)
            {
                s.Seek(-tailWindow, SeekOrigin.End);
                data = new byte[tailWindow];
                s.ReadExactly(data);
            }
            else
            {
                using var ms = new MemoryStream();
                s.CopyTo(ms);
                data = ms.ToArray();
            }
            return data.AsSpan().IndexOf(needle) >= 0;
        }
        catch
        {
            return false;
        }
    }

    private static void ReadModJson(PackageFile f, PackageAnalysis a)
    {
        try
        {
            using var s = f.Open();
            using var doc = JsonDocument.Parse(s, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            var r = doc.RootElement;
            string? Get(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            a.ModJsonId ??= Get("id");
            a.ModJsonName ??= Get("name");
            a.ModJsonVersion ??= Get("version");
            a.ModJsonGameBuild ??= Get("game_build");
        }
        catch (Exception ex)
        {
            a.Warnings.Add("mod.json could not be read: " + ex.Message);
        }
    }

    private static readonly Regex NexusSuffix = new(@"-\d{2,}(?:-\d+)*$", RegexOptions.Compiled);

    /// <summary>"Cool Mod-123-1-0-1700000000" → "Cool_Mod". Never empty, never a path.</summary>
    public static string SanitizeFolderName(string? name)
    {
        string n = (name ?? "").Trim();
        n = NexusSuffix.Replace(n, "");
        var sb = new StringBuilder();
        foreach (char c in n)
            sb.Append(char.IsLetterOrDigit(c) || c is '_' or '-' or '.' ? c : '_');
        string r = sb.ToString().Trim('.', '_', ' ');
        return r.Length == 0 ? "Mod" : r.Length > 64 ? r.Substring(0, 64) : r;
    }
}
