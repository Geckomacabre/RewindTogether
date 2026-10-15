using System.Text.Json;

namespace RewindTogether.Launcher.Core;

/// <summary>A mod the launcher installed, as recorded in %APPDATA%\RewindTogether\installed.json.</summary>
public sealed class InstalledMod
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
    /// <summary>"ue4ss-lua" | "pak" | "logicmod" (the main part, for display).</summary>
    public string Type { get; set; } = "ue4ss-lua";
    /// <summary>"catalog", "file" or "folder".</summary>
    public string Source { get; set; } = "";
    public string? Sha256 { get; set; }
    /// <summary>The game install this record belongs to (the launcher can be pointed at more than one).</summary>
    public string GameRoot { get; set; } = "";
    public DateTime InstalledAt { get; set; }
    public bool Enabled { get; set; } = true;
    /// <summary>Folders under ue4ss\Mods that belong to this mod.</summary>
    public List<string> LuaFolders { get; set; } = new();
    /// <summary>Pak files, relative to the game root, at their ENABLED location.</summary>
    public List<string> Files { get; set; } = new();
}

public sealed class InstalledManifest
{
    public int SchemaVersion { get; set; } = 1;
    public List<InstalledMod> Mods { get; set; } = new();

    public static InstalledManifest Load(string path)
    {
        string? text = AtomicFile.TryReadShared(path);
        if (string.IsNullOrWhiteSpace(text)) return new InstalledManifest();
        try
        {
            return JsonSerializer.Deserialize<InstalledManifest>(text, JsonDefaults.Pretty) ?? new InstalledManifest();
        }
        catch (JsonException ex)
        {
            // Keep the damaged file for a human; start clean rather than refusing to work.
            try { File.Copy(path, path + ".damaged", overwrite: true); } catch { }
            Log.Warn("installed.json was damaged and has been set aside: " + ex.Message);
            return new InstalledManifest();
        }
    }

    public void Save(string path) => AtomicFile.WriteAllText(path, JsonSerializer.Serialize(this, JsonDefaults.Pretty));

    public IEnumerable<InstalledMod> For(GameInstall game)
        => Mods.Where(m => SameRoot(m.GameRoot, game.Root));

    public InstalledMod? Find(GameInstall game, string id)
        => For(game).FirstOrDefault(m => m.Id.Equals(id, StringComparison.OrdinalIgnoreCase));

    public static bool SameRoot(string a, string b)
    {
        if (string.IsNullOrWhiteSpace(a) || string.IsNullOrWhiteSpace(b)) return false;
        try
        {
            return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}
