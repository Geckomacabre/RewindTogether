using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// One launcher per user. The mod starts the launcher with --join when a friend uses Steam's
/// "Join Game"; if a launcher is already open that request must reach IT (two launchers would
/// fight over the tunnel port and the Steam session), so a second instance forwards its
/// arguments over a named pipe and exits.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private readonly Mutex _mutex;
    private readonly string _pipeName;
    private readonly CancellationTokenSource _cts = new();
    private bool _owned;

    public SingleInstance(string scope)
    {
        string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserName + "|" + scope.ToLowerInvariant())))[..16];
        _mutex = new Mutex(false, $"Local\\RewindTogetherLauncher-{key}");
        _pipeName = $"RewindTogetherLauncher-{key}";
    }

    /// <summary>True if this process is now the one-and-only launcher.</summary>
    public bool TryAcquire()
    {
        try
        {
            _owned = _mutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            _owned = true; // previous launcher crashed; we take over
        }
        return _owned;
    }

    /// <summary>First instance: receive forwarded argument lists.</summary>
    public void Listen(Action<string[]> onArgs)
    {
        var token = _cts.Token;
        Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(_pipeName, PipeDirection.In, 1,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await server.WaitForConnectionAsync(token);
                    using var reader = new StreamReader(server, Encoding.UTF8);
                    string? line = await reader.ReadLineAsync(token);
                    if (line == null) continue;
                    string[] args = JsonSerializer.Deserialize<string[]>(line) ?? Array.Empty<string>();
                    onArgs(args);
                }
                catch (OperationCanceledException) { return; }
                catch (Exception ex)
                {
                    Log.Warn("Single-instance pipe: " + ex.Message);
                    await Task.Delay(500, CancellationToken.None);
                }
            }
        }, token);
    }

    /// <summary>Second instance: hand our arguments to the first one.</summary>
    public bool Forward(string[] args, TimeSpan timeout)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", _pipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            client.Connect((int)timeout.TotalMilliseconds);
            using var writer = new StreamWriter(client, new UTF8Encoding(false)) { AutoFlush = true };
            writer.WriteLine(JsonSerializer.Serialize(args));
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn("Could not reach the running launcher: " + ex.Message);
            return false;
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        if (_owned)
        {
            try { _mutex.ReleaseMutex(); } catch { }
        }
        _mutex.Dispose();
    }
}
