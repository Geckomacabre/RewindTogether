using System.Text;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// Atomic text writes, as LAUNCHER_CONTRACT.md requires: UTF-8 without BOM, written to
/// "&lt;name&gt;.tmp" and renamed over the target, so a reader (the Lua mod polling every tick)
/// never sees half a file.
/// </summary>
public static class AtomicFile
{
    public static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    public static void WriteAllText(string path, string content)
        => WriteAllBytes(path, Utf8NoBom.GetBytes(content));

    public static void WriteAllBytes(string path, byte[] bytes)
    {
        string full = Path.GetFullPath(path);
        string dir = Path.GetDirectoryName(full)!;
        Directory.CreateDirectory(dir);
        string tmp = full + ".tmp";

        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            fs.Write(bytes, 0, bytes.Length);
            fs.Flush(flushToDisk: true);
        }

        // The mod may have the target open for a moment (it reads, then deletes). On Windows a
        // rename over an open file fails with a sharing violation, so retry briefly rather than
        // reporting a failure the user can do nothing about.
        Exception? last = null;
        for (int attempt = 0; attempt < 40; attempt++)
        {
            try
            {
                File.Move(tmp, full, overwrite: true);
                return;
            }
            catch (IOException ex) { last = ex; }
            catch (UnauthorizedAccessException ex) { last = ex; }
            Thread.Sleep(25);
        }

        try { File.Delete(tmp); } catch { }
        throw new IOException($"Could not replace {full}: {last?.Message}", last);
    }

    /// <summary>Reads a text file that another process may be writing (shared read/write/delete).</summary>
    public static string? TryReadShared(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs, Utf8NoBom, detectEncodingFromByteOrderMarks: true);
            return sr.ReadToEnd();
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>The last <paramref name="maxLines"/> lines of a (possibly huge, possibly open) log file.</summary>
    public static IReadOnlyList<string> TailLines(string path, int maxLines, int maxBytes = 512 * 1024)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            long start = Math.Max(0, fs.Length - maxBytes);
            fs.Seek(start, SeekOrigin.Begin);
            using var sr = new StreamReader(fs, Utf8NoBom, detectEncodingFromByteOrderMarks: true);
            string text = sr.ReadToEnd();
            var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
            if (start > 0 && lines.Count > 0) lines.RemoveAt(0); // probably a partial line
            while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
            return lines.Count <= maxLines ? lines : lines.GetRange(lines.Count - maxLines, maxLines);
        }
        catch
        {
            return Array.Empty<string>();
        }
    }
}
