using System.Text.Json;
using System.Text.Json.Nodes;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// Keeps UE4SS's Mods\mods.json in step with mods.txt.
///
/// The UE4SS build this game uses (3.0.1-944) reads mods.txt and enabled.txt only - its log says
/// so - but it ships a mods.json too, and newer UE4SS builds read that file instead. Mirroring our
/// own entries into it costs nothing and means a future UE4SS update does not silently disable
/// Rewind Together. Only entries for mods the launcher is touching are added or changed; if the
/// file is missing or not the expected shape it is left alone.
/// </summary>
public static class ModsJson
{
    public static bool SetEnabled(string path, string modName, bool enabled)
        => Mutate(path, arr =>
        {
            foreach (var node in arr)
            {
                if (node is JsonObject o && NameOf(o) is string n && n.Equals(modName, StringComparison.OrdinalIgnoreCase))
                {
                    if (o["mod_enabled"]?.GetValueKind() is JsonValueKind.True or JsonValueKind.False
                        && o["mod_enabled"]!.GetValue<bool>() == enabled)
                        return false;
                    o["mod_enabled"] = enabled;
                    return true;
                }
            }
            var entry = new JsonObject { ["mod_name"] = modName, ["mod_enabled"] = enabled };
            int keybinds = -1;
            for (int i = 0; i < arr.Count; i++)
                if (arr[i] is JsonObject o && string.Equals(NameOf(o), "Keybinds", StringComparison.OrdinalIgnoreCase)) { keybinds = i; break; }
            if (keybinds >= 0) arr.Insert(keybinds, entry); else arr.Add(entry);
            return true;
        });

    public static bool Remove(string path, string modName)
        => Mutate(path, arr =>
        {
            bool changed = false;
            for (int i = arr.Count - 1; i >= 0; i--)
            {
                if (arr[i] is JsonObject o && string.Equals(NameOf(o), modName, StringComparison.OrdinalIgnoreCase))
                {
                    arr.RemoveAt(i);
                    changed = true;
                }
            }
            return changed;
        });

    private static string? NameOf(JsonObject o)
        => o["mod_name"] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static bool Mutate(string path, Func<JsonArray, bool> change)
    {
        if (!File.Exists(path)) return false;
        try
        {
            string text = File.ReadAllText(path);
            if (JsonNode.Parse(text, documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip }) is not JsonArray arr)
                return false;
            if (!change(arr)) return false;
            AtomicFile.WriteAllText(path, arr.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"mods.json left unchanged ({ex.Message}).");
            return false;
        }
    }
}
