using System.Text.RegularExpressions;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// Edits UE4SS's Mods\mods.txt without disturbing anything we do not own.
///
/// The file is a list of "ModName : 1" / "ModName : 0" lines, blank lines and ";" comments. UE4SS
/// ships a block at the end that must stay last:
///
///     ; Built-in keybinds, do not move up!
///     Keybinds : 1
///
/// so new entries are inserted directly ABOVE that comment (or above the Keybinds entry if the
/// comment was deleted), never appended after it. Every operation is idempotent: running an
/// install twice leaves the file byte-for-byte the same as running it once.
/// </summary>
public sealed class ModsTxt
{
    public const string KeybindsMarker = "Built-in keybinds";
    private static readonly Regex EntryRx = new(@"^\s*(?<name>[^:;\r\n]+?)\s*:\s*(?<val>\d+)\s*$", RegexOptions.Compiled);

    private readonly List<string> _lines;
    private readonly string _newline;
    private readonly bool _trailingNewline;

    private ModsTxt(List<string> lines, string newline, bool trailingNewline)
    {
        _lines = lines;
        _newline = newline;
        _trailingNewline = trailingNewline;
    }

    public static ModsTxt Parse(string text)
    {
        if (text.Length > 0 && text[0] == '﻿') text = text.Substring(1); // a BOM breaks UE4SS's first line
        string nl = text.Contains("\r\n") ? "\r\n" : text.Contains('\n') ? "\n" : "\r\n";
        bool trailing = text.EndsWith("\n");
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        if (trailing && lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        if (text.Length == 0) lines.Clear();
        return new ModsTxt(lines, nl, trailing);
    }

    public static ModsTxt Load(string path)
        => File.Exists(path) ? Parse(File.ReadAllText(path)) : Parse("");

    public IReadOnlyList<string> Lines => _lines;

    public override string ToString()
    {
        string body = string.Join(_newline, _lines);
        return _trailingNewline && _lines.Count > 0 ? body + _newline : body;
    }

    public IReadOnlyList<(string Name, bool Enabled)> Entries
    {
        get
        {
            var list = new List<(string, bool)>();
            foreach (string l in _lines)
            {
                var m = EntryRx.Match(l);
                if (m.Success) list.Add((m.Groups["name"].Value.Trim(), m.Groups["val"].Value != "0"));
            }
            return list;
        }
    }

    /// <summary>true / false if listed, null if the mod has no line.</summary>
    public bool? IsEnabled(string modName)
    {
        int i = IndexOf(modName);
        if (i < 0) return null;
        return EntryRx.Match(_lines[i]).Groups["val"].Value != "0";
    }

    /// <summary>
    /// Ensures "<paramref name="modName"/> : 1|0". An existing line is rewritten in place - unless it
    /// sits below the keybinds marker, where UE4SS's own comment says nothing belongs, in which case
    /// it is moved up. Returns true if the text changed.
    /// </summary>
    public bool SetEnabled(string modName, bool enabled)
    {
        ValidateName(modName);
        string wanted = $"{modName} : {(enabled ? 1 : 0)}";
        string before = ToString();

        int existing = IndexOf(modName);
        int marker = MarkerIndex();
        bool isKeybinds = string.Equals(modName, "Keybinds", StringComparison.OrdinalIgnoreCase);

        if (existing >= 0 && (isKeybinds || marker < 0 || existing < marker))
        {
            // Keep the spelling already in the file (UE4SS matches folder names, which may differ in case).
            string name = EntryRx.Match(_lines[existing]).Groups["name"].Value.Trim();
            _lines[existing] = $"{name} : {(enabled ? 1 : 0)}";
            // Drop any duplicate lines for the same mod further down; UE4SS would read both.
            for (int i = _lines.Count - 1; i > existing; i--)
                if (IsLineFor(_lines[i], modName)) _lines.RemoveAt(i);
        }
        else
        {
            RemoveAll(modName);
            marker = MarkerIndex();
            if (marker >= 0)
            {
                _lines.Insert(marker, wanted);
            }
            else
            {
                // No marker at all: append, but keep any trailing blank lines at the very end.
                int at = _lines.Count;
                while (at > 0 && string.IsNullOrWhiteSpace(_lines[at - 1])) at--;
                _lines.Insert(at, wanted);
            }
        }
        return ToString() != before;
    }

    /// <summary>Removes every line for this mod. Returns true if anything was removed.</summary>
    public bool Remove(string modName) => RemoveAll(modName) > 0;

    private int RemoveAll(string modName)
    {
        int n = 0;
        for (int i = _lines.Count - 1; i >= 0; i--)
        {
            if (IsLineFor(_lines[i], modName))
            {
                _lines.RemoveAt(i);
                n++;
            }
        }
        return n;
    }

    private int IndexOf(string modName)
    {
        for (int i = 0; i < _lines.Count; i++)
            if (IsLineFor(_lines[i], modName)) return i;
        return -1;
    }

    /// <summary>The line new entries go above: the "Built-in keybinds" comment, else the Keybinds entry.</summary>
    private int MarkerIndex()
    {
        for (int i = 0; i < _lines.Count; i++)
        {
            string t = _lines[i].TrimStart();
            if (t.StartsWith(';') && t.Contains(KeybindsMarker, StringComparison.OrdinalIgnoreCase)) return i;
        }
        return IndexOf("Keybinds");
    }

    private static bool IsLineFor(string line, string modName)
    {
        var m = EntryRx.Match(line);
        return m.Success && string.Equals(m.Groups["name"].Value.Trim(), modName, StringComparison.OrdinalIgnoreCase);
    }

    private static void ValidateName(string modName)
    {
        if (string.IsNullOrWhiteSpace(modName) || modName.IndexOfAny(new[] { ':', ';', '\r', '\n' }) >= 0)
            throw new ArgumentException($"\"{modName}\" is not a valid UE4SS mod name.", nameof(modName));
    }

    /// <summary>
    /// Load, apply, and write back atomically - only if something changed. A one-time backup
    /// (mods.txt.launcher-backup) is kept the first time the launcher ever edits the file.
    /// </summary>
    public static bool Update(string path, Func<ModsTxt, bool> change)
    {
        var doc = Load(path);
        if (!change(doc)) return false;
        string backup = path + ".launcher-backup";
        try
        {
            if (File.Exists(path) && !File.Exists(backup)) File.Copy(path, backup);
        }
        catch (Exception ex)
        {
            Log.Warn("Could not back up mods.txt: " + ex.Message);
        }
        AtomicFile.WriteAllText(path, doc.ToString());
        return true;
    }
}
