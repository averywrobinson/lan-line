using System.IO.Pipes;
using System.Text;

namespace LanLine.Core;

/// <summary>
/// Files and folders handed to Lan-Line from Explorer ("Send to → Lan-Line" or "Send with Lan-Line", beta.8).
/// Explorer starts <c>Lan-Line.exe --stage PATH…</c>; a second copy passes the paths to the running window over a
/// named pipe and exits. The window only stages them: nothing is sent until the user presses Send.
/// </summary>
public static class StageRequest
{
    public const string Flag = "--stage";
    public const int MaxPaths = 200;
    const string Header = "LANLINE-STAGE 1";
    const string LinkHeader = "LANLINE-LINK 1";
    const int MaxMessage = 1 << 20;

    /// <summary>The checked paths after <c>--stage</c>, or null when the flag isn't there.</summary>
    public static List<string>? FromArgs(string[] args, Func<string, bool>? exists = null)
    {
        var i = Array.IndexOf(args, Flag);
        return i < 0 ? null : Clean(args.Skip(i + 1), exists);
    }

    /// <summary>
    /// Keep only full paths without "..", that exist, once each (case-insensitive), at most <see cref="MaxPaths"/>.
    /// </summary>
    public static List<string> Clean(IEnumerable<string> paths, Func<string, bool>? exists = null)
    {
        exists ??= p => File.Exists(p) || Directory.Exists(p);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var list = new List<string>();
        foreach (var raw in paths)
        {
            if (list.Count >= MaxPaths) break;
            if (string.IsNullOrWhiteSpace(raw) || raw.IndexOfAny(['\0', '\r', '\n']) >= 0) continue;
            var p = raw.Trim().Trim('"');
            if (p.Length == 0 || !Path.IsPathFullyQualified(p)) continue;
            if (p.Split('\\', '/').Any(s => s == "..")) continue;
            if (p.Length > 3) p = Path.TrimEndingDirectorySeparator(p);   // keep "C:\" as it is
            if (!exists(p)) continue;
            if (seen.Add(p)) list.Add(p);
        }
        return list;
    }

    public static string Encode(IEnumerable<string> paths) => Header + "\n" + string.Join("\n", paths) + "\n";

    /// <summary>A pipe message back to checked paths; null when it isn't one of ours.</summary>
    public static List<string>? Decode(string message, Func<string, bool>? exists = null) =>
        message.StartsWith(Header + "\n", StringComparison.Ordinal)
            ? Clean(message[(Header.Length + 1)..].Split('\n', StringSplitOptions.RemoveEmptyEntries), exists)
            : null;

    /// <summary>A toast's lanline:// link for the running window (beta.10).</summary>
    public static string EncodeLink(string url) => LinkHeader + "\n" + url.Replace("\n", "").Replace("\r", "") + "\n";

    public static string? DecodeLink(string message) =>
        message.StartsWith(LinkHeader + "\n", StringComparison.Ordinal) ? message[(LinkHeader.Length + 1)..].Trim() : null;

    /// <summary>The pipe for this sign-in session (other users and sessions can't connect: CurrentUserOnly).</summary>
    public static string PipeName(int sessionId) => $"Lan-Line.Stage.{sessionId}";

    /// <summary>Serve stage requests until cancelled. An empty list means "just show the window".</summary>
    public static async Task Listen(string pipeName, Action<List<string>> onRequest, CancellationToken ct, Func<string, bool>? exists = null,
                                    Action<string>? onLink = null)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(ct);
                using var ms = new MemoryStream();
                var buf = new byte[16384];
                int n;
                using (var read = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    read.CancelAfter(TimeSpan.FromSeconds(5));
                    while ((n = await server.ReadAsync(buf, read.Token)) > 0 && ms.Length <= MaxMessage) ms.Write(buf, 0, n);
                }
                if (ms.Length > MaxMessage) continue;
                var msg = Encoding.UTF8.GetString(ms.ToArray());
                if (Decode(msg, exists) is { } paths) onRequest(paths);
                else if (DecodeLink(msg) is { } link) onLink?.Invoke(link);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception) { await Task.Delay(100, CancellationToken.None); }   // a broken client; keep serving
        }
    }

    /// <summary>Hand paths to the running window. Retries while it is still starting (up to <paramref name="wait"/>).</summary>
    public static bool TrySend(string pipeName, IReadOnlyList<string> paths, TimeSpan wait) => TrySendMessage(pipeName, Encode(paths), wait);

    public static bool TrySendLink(string pipeName, string url, TimeSpan wait) => TrySendMessage(pipeName, EncodeLink(url), wait);

    static bool TrySendMessage(string pipeName, string message, TimeSpan wait)
    {
        var deadline = DateTime.UtcNow + wait;
        var data = Encoding.UTF8.GetBytes(message);
        while (true)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
                client.Connect(500);
                client.Write(data);
                client.Flush();
                return true;
            }
            catch (Exception) when (DateTime.UtcNow < deadline) { Thread.Sleep(150); }
            catch (Exception) { return false; }
        }
    }
}
