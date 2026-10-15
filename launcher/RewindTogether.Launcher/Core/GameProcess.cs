using System.ComponentModel;
using System.Diagnostics;

namespace RewindTogether.Launcher.Core;

/// <summary>Is the game running, and how to start it (always through Steam).</summary>
public static class GameProcess
{
    /// <summary>
    /// True if RetroRewind-Win64-Shipping.exe is running from <paramref name="game"/>. A copy
    /// running from a different install does not count (when its path can be read).
    /// </summary>
    public static bool IsRunning(GameInstall? game) => FindProcessId(game) != null;

    public static int? FindProcessId(GameInstall? game)
    {
        Process[] procs;
        try { procs = Process.GetProcessesByName(GameInstall.ProcessName); }
        catch { return null; }
        try
        {
            foreach (var p in procs)
            {
                if (game == null) return p.Id;
                string? path = ImagePath(p.Id); // null = cannot tell: assume it is ours
                if (path == null || string.Equals(Path.GetFullPath(path), Path.GetFullPath(game.Exe), StringComparison.OrdinalIgnoreCase))
                    return p.Id;
            }
            return null;
        }
        finally
        {
            foreach (var p in procs) p.Dispose();
        }
    }

    private const uint ProcessQueryLimitedInformation = 0x1000;

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, int flags, System.Text.StringBuilder name, ref int size);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    /// <summary>Full exe path of a process without needing to read its memory (works across elevation).</summary>
    private static string? ImagePath(int pid)
    {
        IntPtr h = OpenProcess(ProcessQueryLimitedInformation, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new System.Text.StringBuilder(1024);
            int size = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
        }
        finally
        {
            CloseHandle(h);
        }
    }

    /// <summary>
    /// Starts the game the way Steam does (steam://rungameid/3552140), so Steam overlay, cloud
    /// saves and the Steam API all work exactly as they do from the library page.
    /// </summary>
    public static void LaunchViaSteam()
    {
        try
        {
            Process.Start(new ProcessStartInfo($"steam://rungameid/{GameInstall.AppId}") { UseShellExecute = true });
            Log.Info($"Asked Steam to start the game (steam://rungameid/{GameInstall.AppId}).");
        }
        catch (Win32Exception ex)
        {
            throw new InvalidOperationException(
                "Windows could not hand the game over to Steam. Make sure Steam is installed, then start Retro Rewind " +
                "from your Steam library - the launcher will notice it is running. (" + ex.Message + ")", ex);
        }
    }

    public static async Task<bool> WaitForStartAsync(GameInstall game, TimeSpan timeout, CancellationToken ct)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until)
        {
            if (IsRunning(game)) return true;
            await Task.Delay(1000, ct);
        }
        return IsRunning(game);
    }

    public static void OpenInShell(string pathOrUrl)
    {
        try
        {
            Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not open {pathOrUrl}: {ex.Message}");
            throw new InvalidOperationException($"Windows could not open {pathOrUrl}.", ex);
        }
    }

    /// <summary>Opens Explorer with the file selected (or the folder, if the file does not exist yet).</summary>
    public static void RevealInExplorer(string path)
    {
        if (File.Exists(path))
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        else if (Directory.Exists(path))
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        else if (Path.GetDirectoryName(path) is { } dir && Directory.Exists(dir))
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dir}\"") { UseShellExecute = true });
        else
            throw new InvalidOperationException($"{path} does not exist yet.");
    }
}
