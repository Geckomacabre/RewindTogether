using System.Text;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// A tiny append-only file logger. Every action the launcher takes on the user's game folder is
/// written here, so "Copy diagnostics" can say what actually happened rather than what we think
/// happened.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private static string? _path;
    private static readonly Queue<string> Recent = new();
    private const int RecentMax = 400;
    private const long RotateAt = 2 * 1024 * 1024;

    public static event Action<string>? LineWritten;

    public static void Init(string path)
    {
        lock (Gate)
        {
            _path = path;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var fi = new FileInfo(path);
                if (fi.Exists && fi.Length > RotateAt)
                    File.Move(path, path + ".old", overwrite: true);
            }
            catch
            {
                // Logging must never be the reason the launcher fails to start.
            }
        }
    }

    public static void Info(string message) => Write("INFO ", message);
    public static void Warn(string message) => Write("WARN ", message);
    public static void Error(string message) => Write("ERROR", message);
    public static void Error(string message, Exception ex) => Write("ERROR", message + " :: " + ex.GetType().Name + ": " + ex.Message);

    public static IReadOnlyList<string> RecentLines()
    {
        lock (Gate) return Recent.ToArray();
    }

    private static void Write(string level, string message)
    {
        string line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {level} {message}";
        lock (Gate)
        {
            Recent.Enqueue(line);
            while (Recent.Count > RecentMax) Recent.Dequeue();
            if (_path != null)
            {
                try { File.AppendAllText(_path, line + Environment.NewLine, new UTF8Encoding(false)); }
                catch { /* disk full / locked: keep going */ }
            }
        }
        try { LineWritten?.Invoke(line); } catch { }
    }
}
