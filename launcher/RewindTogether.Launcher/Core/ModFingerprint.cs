using System.Security.Cryptography;
using System.Text;

namespace RewindTogether.Launcher.Core;

/// <summary>One group of mods as the other side sees it: how many, a hash of exactly which, and
/// their names (cut short when they would not fit in Steam's 255-character presence values).</summary>
public sealed record ModSet(int Count, string Hash, IReadOnlyList<string> Names)
{
    public bool NamesComplete => Names.Count >= Count;
    public static readonly ModSet Empty = new(0, Hashes.Of(Array.Empty<string>()), Array.Empty<string>());
}

/// <summary>
/// What a guest has to match, published by the host over Steam rich presence while its store is
/// open:
///   - the Rewind Together version: different versions do not sync properly;
///   - content mods, the .pak and Blueprint (LogicMods) mods: they change what exists in the store,
///     so a guest without the host's copy is missing objects or cannot connect at all;
///   - script mods, the UE4SS Lua/C++ mods: they run on each PC separately, which is usually fine.
/// The mods UE4SS ships with, and Rewind Together itself, are left out.
///
/// Nothing is downloaded. Other people's mods are theirs to share, so the launcher only names
/// what differs and the player gets the same files from wherever the host got them.
/// </summary>
public sealed record ModFingerprint(string RtVersion, ModSet Content, ModSet Scripts)
{
    public const string KeyVersion = "rt_ver";
    public const string KeyContent = "rt_cmods";
    public const string KeyContentNames = "rt_cnames";
    public const string KeyScripts = "rt_smods";
    public const string KeyScriptNames = "rt_snames";
    public static readonly string[] PresenceKeys = { KeyVersion, KeyContent, KeyContentNames, KeyScripts, KeyScriptNames };

    /// <summary>Steam's limit for one rich presence value (k_cchMaxRichPresenceValueLength - 1).</summary>
    public const int MaxValueLength = 255;
    private const char NameSeparator = '|';

    /// <summary>The fingerprint of this PC's game, from <see cref="ModManager.ScanGame"/>.</summary>
    public static ModFingerprint FromScan(string? rtVersion, IEnumerable<GameModInfo> scan)
    {
        var mods = scan.ToList();
        var content = mods
            .Where(m => m.Enabled && m.Kind is ModKind.Pak or ModKind.LogicMod)
            .Select(m => (m.Name, Key: $"{m.Kind}|{m.Name.ToLowerInvariant()}|{SizeOf(m.Path)}"))
            .ToList();
        var scripts = mods
            .Where(m => m.Enabled && m.Kind == ModKind.Ue4ssLua && !m.BuiltIn && m.HasEntryPoint &&
                        !m.Name.Equals(GameInstall.RewindTogetherFolder, StringComparison.OrdinalIgnoreCase))
            .Select(m => (m.Name, Key: m.Name.ToLowerInvariant()))
            .ToList();
        return new ModFingerprint(rtVersion?.Trim() ?? "",
            new ModSet(content.Count, Hashes.Of(content.Select(c => c.Key)), Sorted(content.Select(c => c.Name))),
            new ModSet(scripts.Count, Hashes.Of(scripts.Select(s => s.Key)), Sorted(scripts.Select(s => s.Name))));
    }

    /// <summary>The rich presence values the host sets. Every value fits Steam's limit.</summary>
    public IReadOnlyDictionary<string, string> ToPresence() => new Dictionary<string, string>
    {
        [KeyVersion] = Cut(RtVersion, MaxValueLength),
        [KeyContent] = $"{Content.Count}:{Content.Hash}",
        [KeyContentNames] = JoinNames(Content.Names),
        [KeyScripts] = $"{Scripts.Count}:{Scripts.Hash}",
        [KeyScriptNames] = JoinNames(Scripts.Names),
    };

    /// <summary>
    /// A host's fingerprint, read back from its rich presence. Null when it published none: a
    /// launcher older than this check, so nothing can be compared.
    /// </summary>
    public static ModFingerprint? FromPresence(Func<string, string?> get)
    {
        string version = (get(KeyVersion) ?? "").Trim();
        if (version.Length == 0) return null;
        return new ModFingerprint(version,
            ReadSet(get(KeyContent), get(KeyContentNames)),
            ReadSet(get(KeyScripts), get(KeyScriptNames)));
    }

    private static ModSet ReadSet(string? countAndHash, string? names)
    {
        string[] parts = (countAndHash ?? "").Split(':', 2);
        if (parts.Length != 2 || !int.TryParse(parts[0], out int count) || count < 0) return ModSet.Empty;
        var list = (names ?? "").Split(NameSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return new ModSet(count, parts[1].Trim().ToLowerInvariant(), list);
    }

    /// <summary>As many names as fit, in order; the count says how many there really are.</summary>
    private static string JoinNames(IReadOnlyList<string> names)
    {
        var sb = new StringBuilder();
        foreach (string raw in names)
        {
            string n = raw.Replace(NameSeparator, '/');
            int extra = (sb.Length > 0 ? 1 : 0) + n.Length;
            if (sb.Length + extra > MaxValueLength) break;
            if (sb.Length > 0) sb.Append(NameSeparator);
            sb.Append(n);
        }
        return sb.ToString();
    }

    private static IReadOnlyList<string> Sorted(IEnumerable<string> names) =>
        names.OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();

    private static long SizeOf(string path)
    {
        try { return new FileInfo(path).Length; } catch { return -1; }
    }

    private static string Cut(string s, int max) => s.Length <= max ? s : s.Substring(0, max);
}

internal static class Hashes
{
    /// <summary>First 12 hex characters of the SHA-256 of the sorted keys: order-independent.</summary>
    public static string Of(IEnumerable<string> keys)
    {
        string joined = string.Join("\n", keys.OrderBy(k => k, StringComparer.Ordinal));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(joined))).Substring(0, 12).ToLowerInvariant();
    }
}

/// <summary>How a guest's mods differ from a host's, in words a player can act on.</summary>
public sealed record ModMismatch(
    string GuestVersion, string HostVersion,
    IReadOnlyList<string> ContentHostOnly, IReadOnlyList<string> ContentGuestOnly, bool ContentDiffers, bool HostContentListCut,
    IReadOnlyList<string> ScriptsHostOnly, IReadOnlyList<string> ScriptsGuestOnly, bool ScriptsDiffer, bool HostScriptListCut)
{
    public bool VersionDiffers => VersionCompare.Compare(GuestVersion, HostVersion) != 0;
    public bool Any => VersionDiffers || ContentDiffers || ScriptsDiffer;

    /// <summary>bad: the session will not work properly. warn: things may be missing. info: usually fine.</summary>
    public string Tone => VersionDiffers ? "bad" : ContentDiffers ? "warn" : ScriptsDiffer ? "info" : "ok";

    /// <summary>One line for the friend's row in the list.</summary>
    public string ShortText =>
        VersionDiffers ? $"Has Rewind Together {HostVersion} - you have {(GuestVersion.Length > 0 ? GuestVersion : "none")}"
        : ContentDiffers ? "Has different content mods than you"
        : ScriptsDiffer ? "Has different script mods (usually fine)"
        : "";

    public static ModMismatch? Compare(ModFingerprint guest, ModFingerprint? host)
    {
        if (host == null) return null;
        var hostContent = new HashSet<string>(host.Content.Names, StringComparer.OrdinalIgnoreCase);
        var hostScripts = new HashSet<string>(host.Scripts.Names, StringComparer.OrdinalIgnoreCase);
        var guestContent = new HashSet<string>(guest.Content.Names, StringComparer.OrdinalIgnoreCase);
        var guestScripts = new HashSet<string>(guest.Scripts.Names, StringComparer.OrdinalIgnoreCase);
        return new ModMismatch(
            guest.RtVersion, host.RtVersion,
            host.Content.Names.Where(n => !guestContent.Contains(n)).ToList(),
            guest.Content.Names.Where(n => !hostContent.Contains(n)).ToList(),
            guest.Content.Count != host.Content.Count || guest.Content.Hash != host.Content.Hash,
            !host.Content.NamesComplete,
            host.Scripts.Names.Where(n => !guestScripts.Contains(n)).ToList(),
            guest.Scripts.Names.Where(n => !hostScripts.Contains(n)).ToList(),
            guest.Scripts.Count != host.Scripts.Count || guest.Scripts.Hash != host.Scripts.Hash,
            !host.Scripts.NamesComplete);
    }

    /// <summary>The full explanation for the "Join anyway?" dialog.</summary>
    public string Explain(string hostName)
    {
        var sb = new StringBuilder();
        if (VersionDiffers)
        {
            sb.AppendLine($"{hostName} has Rewind Together {HostVersion}; you have {(GuestVersion.Length > 0 ? GuestVersion : "no Rewind Together installed")}. " +
                          "You both need the same version, or the store will not stay in sync. Whoever is behind should update first " +
                          "(the launcher shows an Update banner when a new version is out).");
            sb.AppendLine();
        }
        if (ContentDiffers)
        {
            sb.AppendLine("Content mods (.pak and Blueprint mods) change what is in the store, so they must match:");
            AppendDiff(sb, hostName, ContentHostOnly, ContentGuestOnly, HostContentListCut);
            if (ContentHostOnly.Count == 0 && ContentGuestOnly.Count == 0 && !HostContentListCut)
                sb.AppendLine("  - You both have the same ones, but some are different versions or files.");
            sb.AppendLine("Without the same content mods you may not see some things in the store, or may not be able to connect. " +
                          $"Get the same files from wherever {hostName} got them.");
            sb.AppendLine();
        }
        if (ScriptsDiffer)
        {
            sb.AppendLine("Script mods (UE4SS) run on each PC separately, so this is usually fine:");
            AppendDiff(sb, hostName, ScriptsHostOnly, ScriptsGuestOnly, HostScriptListCut);
        }
        return sb.ToString().TrimEnd();
    }

    private static void AppendDiff(StringBuilder sb, string hostName, IReadOnlyList<string> hostOnly, IReadOnlyList<string> guestOnly, bool hostListCut)
    {
        if (hostOnly.Count > 0) sb.AppendLine($"  - {hostName} has, you don't: {string.Join(", ", hostOnly)}");
        if (guestOnly.Count > 0)
            sb.AppendLine($"  - You have, {hostName} {(hostListCut ? "may not" : "doesn't")}: {string.Join(", ", guestOnly)}");
        if (hostListCut) sb.AppendLine($"  - (and more: {hostName} has too many to list)");
    }
}
