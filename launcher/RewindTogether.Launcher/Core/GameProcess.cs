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

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder name, int size);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    private const uint WmClose = 0x0010;

    /// <summary>
    /// The game's own window (Unreal's "UnrealWindow" class). Process.MainWindowHandle is just the
    /// front-most visible window, which can be UE4SS's GUI console (1.6's installer switched it on).
    /// </summary>
    private static IntPtr FindGameWindow(int pid)
    {
        IntPtr found = IntPtr.Zero;
        var cls = new System.Text.StringBuilder(64);
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out uint owner);
            if (owner != (uint)pid || !IsWindowVisible(h)) return true;
            cls.Clear();
            GetClassName(h, cls, cls.Capacity);
            if (cls.ToString() != "UnrealWindow") return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>
    /// Asks the game to quit the way its window's close button does (never kills it), then waits.
    /// True once it has exited; false if it is still running after <paramref name="timeout"/>.
    /// Checked on the real game (October 2026): it quits in about 1.5 s from the main menu or a
    /// store, and its DLLs are free at once.
    /// </summary>
    public static async Task<bool> CloseAsync(GameInstall game, TimeSpan timeout)
    {
        if (FindProcessId(game) is not int pid) return true;
        try
        {
            using var p = Process.GetProcessById(pid);
            Log.Info($"Asking Retro Rewind (pid {pid}) to close.");
            IntPtr window = FindGameWindow(pid);
            bool asked = window != IntPtr.Zero ? PostMessage(window, WmClose, IntPtr.Zero, IntPtr.Zero) : p.CloseMainWindow();
            if (!asked) Log.Warn("Retro Rewind has no window to close yet.");
            using var cts = new CancellationTokenSource(timeout);
            await p.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception)
        {
            // ArgumentException: it exited between the two calls.
            Log.Warn("Closing the game: " + ex.Message);
        }
        // Its files stay locked for a moment after the process is gone.
        for (int i = 0; i < 10 && IsRunning(game); i++) await Task.Delay(500);
        bool closed = !IsRunning(game);
        if (closed) await Task.Delay(1000);
        return closed;
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
