using System.Text.Json;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// The copy of Rewind Together that ships in the release zip next to the launcher:
///
///     RewindTogetherLauncher.exe
///     Mods\RewindTogether\mod.json
///     Mods\RewindTogether\Scripts\*.lua
///     Mods\RewindTogether\native\RewindNative.dll
///
/// When it is there it is THE install source for Rewind Together: the Setup row installs and
/// updates from it with no download and no file prompt, and "update available" compares its
/// mod.json version with the installed one. Without it, the catalog entry is used as before.
/// </summary>
public sealed record BundledMod(string Folder, string Version, string? GameBuild)
{
    public static string FolderFor(string exeDir) => Path.Combine(exeDir, "Mods", GameInstall.RewindTogetherFolder);

    /// <summary>The bundled copy next to <paramref name="exeDir"/>, or null if there is none (or it is unusable).</summary>
    public static BundledMod? Find(string? exeDir)
    {
        if (string.IsNullOrWhiteSpace(exeDir)) return null;
        string folder = FolderFor(exeDir);
        string modJson = Path.Combine(folder, "mod.json");
        if (!File.Exists(modJson)) return null;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(modJson),
                new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            var r = doc.RootElement;
            string? Get(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

            string? id = Get("id");
            if (id != null && !id.Equals(GameInstall.RewindTogetherId, StringComparison.OrdinalIgnoreCase))
            {
                Log.Warn($"Ignoring {modJson}: its id is \"{id}\", not \"{GameInstall.RewindTogetherId}\".");
                return null;
            }
            if (!File.Exists(Path.Combine(folder, "Scripts", "main.lua")))
            {
                Log.Warn($"Ignoring the bundled Rewind Together at {folder}: Scripts\\main.lua is missing (incomplete download?).");
                return null;
            }
            string version = Get("version") is { Length: > 0 } v ? v : "unknown";
            return new BundledMod(folder, version, Get("game_build"));
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            Log.Warn($"Ignoring {modJson}: {ex.Message}");
            return null;
        }
    }
}
