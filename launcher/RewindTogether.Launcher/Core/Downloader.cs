using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace RewindTogether.Launcher.Core;

public readonly record struct DownloadProgress(long BytesReceived, long? TotalBytes)
{
    public double? Fraction => TotalBytes is > 0 ? (double)BytesReceived / TotalBytes.Value : null;
}

public sealed class DownloadException : Exception
{
    public DownloadException(string message, Exception? inner = null) : base(message, inner) { }
}

public interface IDownloader
{
    /// <summary>
    /// Downloads <paramref name="url"/> to <paramref name="destination"/>, verifying size and sha256
    /// when given. A file that fails verification is deleted and a <see cref="DownloadException"/>
    /// explains what went wrong in plain English.
    /// </summary>
    Task DownloadAsync(string url, string destination, string? expectedSha256, long? expectedSize,
        IProgress<DownloadProgress>? progress, CancellationToken ct);
}

public sealed class HttpDownloader : IDownloader
{
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var c = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 10,
            ConnectTimeout = TimeSpan.FromSeconds(20),
        })
        {
            Timeout = Timeout.InfiniteTimeSpan, // large files; we time out reads ourselves
        };
        c.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RewindTogetherLauncher", AppInfo.Version));
        return c;
    }

    public async Task DownloadAsync(string url, string destination, string? expectedSha256, long? expectedSize,
        IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
            throw new DownloadException($"\"{url}\" is not a valid web address.");

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        string part = destination + ".part";
        try
        {
            if (uri.IsFile)
            {
                await CopyWithProgress(File.OpenRead(uri.LocalPath), part, new FileInfo(uri.LocalPath).Length, progress, ct);
            }
            else if (uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback))
            {
                using var resp = await Http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
                if (!resp.IsSuccessStatusCode)
                    throw new DownloadException(
                        $"The download server answered \"{(int)resp.StatusCode} {resp.ReasonPhrase}\" for {uri.Host}. " +
                        "The file may have moved - try again later, or download it by hand and use \"Add mod from file\".");
                long? total = resp.Content.Headers.ContentLength ?? expectedSize;
                await CopyWithProgress(await resp.Content.ReadAsStreamAsync(ct), part, total, progress, ct);
            }
            else
            {
                throw new DownloadException("Only https:// downloads are allowed (plain http only to this PC, for tests).");
            }

            var fi = new FileInfo(part);
            if (expectedSize is > 0 && fi.Length != expectedSize)
                throw new DownloadException(
                    $"The download is {fi.Length:N0} bytes but should be {expectedSize:N0}. " +
                    "It was probably cut off - check your connection and try again.");

            if (!string.IsNullOrWhiteSpace(expectedSha256))
            {
                string actual = Hashing.Sha256OfFile(part);
                if (!Hashing.Matches(actual, expectedSha256))
                    throw new DownloadException(
                        "The downloaded file does not match its published checksum, so it was thrown away " +
                        "rather than installed. It may be corrupted or may have been replaced on the server. " +
                        $"(expected {Hashing.NormalizeSha256(expectedSha256)}, got {actual})");
            }

            File.Move(part, destination, overwrite: true);
        }
        catch (OperationCanceledException)
        {
            TryDelete(part);
            throw;
        }
        catch (DownloadException)
        {
            TryDelete(part);
            throw;
        }
        catch (HttpRequestException ex)
        {
            TryDelete(part);
            throw new DownloadException(
                $"Could not reach {uri.Host}. Check that you are online and that a firewall is not blocking the launcher. ({ex.Message})", ex);
        }
        catch (IOException ex)
        {
            TryDelete(part);
            throw new DownloadException($"The download could not be saved: {ex.Message}", ex);
        }
    }

    private static async Task CopyWithProgress(Stream source, string destination, long? total,
        IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        await using (source)
        await using (var dest = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
        {
            var buf = new byte[1 << 16];
            long got = 0;
            var lastReport = DateTime.MinValue;
            while (true)
            {
                using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                readTimeout.CancelAfter(TimeSpan.FromSeconds(60));
                int n;
                try
                {
                    n = await source.ReadAsync(buf, readTimeout.Token);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    throw new DownloadException("The download stalled for a minute and was stopped. Check your connection and try again.");
                }
                if (n == 0) break;
                await dest.WriteAsync(buf.AsMemory(0, n), ct);
                got += n;
                if ((DateTime.UtcNow - lastReport).TotalMilliseconds > 100)
                {
                    lastReport = DateTime.UtcNow;
                    progress?.Report(new DownloadProgress(got, total));
                }
            }
            progress?.Report(new DownloadProgress(got, total));
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}

public static class AppInfo
{
    public static string Version =>
        typeof(AppInfo).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0.0";
}
