using System.Security.Cryptography;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// Loose semantic-version comparison for mod versions ("1.7.0", "1.7", "v2.0.1-beta").
/// Numeric parts compare as numbers, missing parts count as 0, and a pre-release
/// ("-beta") sorts before the same version without one.
/// </summary>
public static class VersionCompare
{
    public static int Compare(string? a, string? b)
    {
        a = Clean(a);
        b = Clean(b);
        if (a.Length == 0 || b.Length == 0) return a.Length.CompareTo(b.Length);

        Split(a, out var aCore, out string? aPre);
        Split(b, out var bCore, out string? bPre);

        int n = Math.Max(aCore.Length, bCore.Length);
        for (int i = 0; i < n; i++)
        {
            string x = i < aCore.Length ? aCore[i] : "0";
            string y = i < bCore.Length ? bCore[i] : "0";
            int c = ComparePart(x, y);
            if (c != 0) return c;
        }

        if (aPre == null && bPre == null) return 0;
        if (aPre == null) return 1;
        if (bPre == null) return -1;
        return string.Compare(aPre, bPre, StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsNewer(string? candidate, string? installed) => Compare(candidate, installed) > 0;

    private static string Clean(string? v)
    {
        v = (v ?? "").Trim();
        if (v.StartsWith("v", StringComparison.OrdinalIgnoreCase)) v = v.Substring(1);
        int plus = v.IndexOf('+');
        return plus >= 0 ? v.Substring(0, plus) : v;
    }

    private static void Split(string v, out string[] core, out string? pre)
    {
        int dash = v.IndexOf('-');
        pre = dash >= 0 ? v.Substring(dash + 1) : null;
        core = (dash >= 0 ? v.Substring(0, dash) : v).Split('.', StringSplitOptions.RemoveEmptyEntries);
    }

    private static int ComparePart(string x, string y)
    {
        bool xn = long.TryParse(x, out long xi);
        bool yn = long.TryParse(y, out long yi);
        if (xn && yn) return xi.CompareTo(yi);
        if (xn) return 1;
        if (yn) return -1;
        return string.Compare(x, y, StringComparison.OrdinalIgnoreCase);
    }
}

public static class Hashing
{
    public static string Sha256OfFile(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
        return Convert.ToHexString(SHA256.HashData(fs)).ToLowerInvariant();
    }

    /// <summary>Accepts "abc..." or "sha256:abc..." in any case.</summary>
    public static string NormalizeSha256(string? s)
    {
        s = (s ?? "").Trim();
        if (s.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) s = s.Substring(7);
        return s.ToLowerInvariant();
    }

    public static bool IsSha256Hex(string? s)
    {
        s = NormalizeSha256(s);
        return s.Length == 64 && s.All(Uri.IsHexDigit);
    }

    public static bool Matches(string actualHex, string? expected)
        => string.Equals(NormalizeSha256(actualHex), NormalizeSha256(expected), StringComparison.Ordinal);
}
