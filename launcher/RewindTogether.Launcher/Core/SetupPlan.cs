namespace RewindTogether.Launcher.Core;

/// <summary>
/// What "set up Rewind Together" still has to do on this PC, worked out from what is installed in
/// the game and which version came with the launcher. The launcher runs it by itself when it
/// starts and again before HOST or JOIN, so a player never has to know the steps (UE4SS first,
/// then the mod, then switching it on) - or notice that an update arrived with a new download.
/// </summary>
public sealed record SetupPlan(bool InstallUe4ss, bool InstallMod, bool SwitchOn, string? ModVersion)
{
    public bool NothingToDo => !InstallUe4ss && !InstallMod && !SwitchOn;

    /// <param name="ue4ss">What is in the game now (null: unknown, treated as missing).</param>
    /// <param name="rt">The installed Rewind Together (null: unknown, treated as missing).</param>
    /// <param name="available">The version that came with the launcher (or the catalog's), if any.</param>
    public static SetupPlan For(Ue4ssStatus? ue4ss, RewindTogetherInfo? rt, string? available)
    {
        bool ue = ue4ss?.State != Ue4ssState.Installed;
        bool missing = rt is not { Installed: true, HasMainLua: true };
        // Everyone in a session needs the same version: a newer one that came with the launcher is
        // installed without asking. An older one never replaces a newer install.
        bool outdated = !missing && available != null && VersionCompare.IsNewer(available, rt!.Version);
        bool mod = missing || outdated;
        // An install writes "RewindTogether : 1" itself; only an unchanged install needs switching on.
        bool on = !mod && rt?.EnabledInModsTxt == false;
        return new SetupPlan(ue, mod, on, mod ? available : null);
    }

    /// <summary>One line for the setup strip: what pressing "Set up" (or HOST) will do.</summary>
    public string Describe(string? installedVersion)
    {
        var parts = new List<string>();
        if (InstallUe4ss) parts.Add("install UE4SS (the mod loader)");
        if (InstallMod)
            parts.Add(installedVersion == null
                ? $"install Rewind Together{(ModVersion != null ? " " + ModVersion : "")}"
                : $"update Rewind Together to {ModVersion ?? "the latest version"}");
        if (SwitchOn) parts.Add("switch Rewind Together on");
        return parts.Count == 0 ? "" : char.ToUpperInvariant(parts[0][0]) + string.Join(", then ", parts)[1..] + ".";
    }
}
