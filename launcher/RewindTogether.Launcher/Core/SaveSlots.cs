using System.Globalization;

namespace RewindTogether.Launcher.Core;

/// <summary>What is in one of the game's five save slots, for the "host which save?" picker.</summary>
public sealed record SaveSlotInfo(int Number, string Slot, bool Exists, DateTime? LastPlayed)
{
    /// <summary>"Save 1 (last played 14 Oct 2026, 2:06 PM)" or "Save 2 (empty - starts a new store)".</summary>
    public string Label(CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        if (!Exists || LastPlayed is not DateTime t) return $"Save {Number} (empty - starts a new store)";
        // Month as a name, so 03/04 can never be misread; the clock follows the player's settings.
        string when = t.ToString("d MMM yyyy, " + culture.DateTimeFormat.ShortTimePattern, culture);
        return $"Save {Number} (last played {when})";
    }
}

public static class SaveSlots
{
    /// <summary>
    /// Reads %LOCALAPPDATA%\RetroRewind\Saved\SaveGames\Player_Save&lt;N&gt;.sav for N = 1..5 (the five rows
    /// of the game's save screen, top to bottom). The game's own rolling copies
    /// (Player_Save1_backup*.sav) are not slots and are ignored.
    /// </summary>
    public static IReadOnlyList<SaveSlotInfo> Read(string saveGamesDir)
    {
        var list = new List<SaveSlotInfo>(SaveSlotNames.Count);
        for (int n = 1; n <= SaveSlotNames.Count; n++)
        {
            string slot = SaveSlotNames.ForNumber(n);
            string file = Path.Combine(saveGamesDir, slot + ".sav");
            DateTime? when = null;
            bool exists = false;
            try
            {
                var fi = new FileInfo(file);
                if (fi.Exists)
                {
                    exists = true;
                    when = fi.LastWriteTime;
                }
            }
            catch
            {
                // unreadable folder: show the slot as empty rather than failing the whole picker
            }
            list.Add(new SaveSlotInfo(n, slot, exists, when));
        }
        return list;
    }
}
