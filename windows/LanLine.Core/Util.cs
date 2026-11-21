using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LanLine.Core;

public static class Names
{
    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>Reduce a peer-supplied file name to a safe base name (PROTOCOL.md "Rules").</summary>
    public static string Sanitize(string raw)
    {
        var parts = raw.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        var s = parts.Length > 0 ? parts[^1] : "";
        var sb = new StringBuilder();
        foreach (var ch in s)
            if (!char.IsControl(ch) && "<>:\"|?*".IndexOf(ch) < 0) sb.Append(ch);
        s = sb.ToString();
        while (s.Contains("..")) s = s.Replace("..", ".");
        s = s.Trim().TrimStart('.', ' ').TrimEnd('.', ' ');
        if (s.Length > 200)
        {
            var ext = Path.GetExtension(s);
            var keep = ext.Length == 0 || ext.Length > 21 ? "" : ext;
            s = s[..(200 - keep.Length)] + keep;
        }
        if (s.Length == 0) return "file";
        var stem = s.Split('.')[0];
        return Reserved.Contains(stem) ? "_" + s : s;   // Windows device names (CON, NUL, ...)
    }

    /// <summary>dir\name, or dir\name (2).ext, dir\name (3).ext, ... if it already exists.</summary>
    public static string Unique(string name, string dir)
    {
        var path = Path.Combine(dir, name);
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        var ext = Path.GetExtension(name);
        var stem = ext.Length == 0 ? name : name[..^ext.Length];
        for (var n = 2; ; n++)
        {
            path = Path.Combine(dir, $"{stem} ({n}){ext}");
            if (!File.Exists(path) && !Directory.Exists(path)) return path;
        }
    }
}

public static class Secrets
{
    /// <summary>Constant-time comparison (time depends only on the lengths).</summary>
    public static bool Equal(string a, string b)
    {
        var x = Encoding.UTF8.GetBytes(a);
        var y = Encoding.UTF8.GetBytes(b);
        if (x.Length != y.Length) { CryptographicOperations.FixedTimeEquals(x, x); return false; }
        return CryptographicOperations.FixedTimeEquals(x, y);
    }

    public static string NewToken() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
}

public static class Hashing
{
    public static string Sha256File(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
        return Convert.ToHexStringLower(SHA256.HashData(fs));
    }
}

public sealed class LanLineConfig
{
    [System.Text.Json.Serialization.JsonPropertyName("port")] public int Port { get; set; } = 47830;
    [System.Text.Json.Serialization.JsonPropertyName("token")] public string Token { get; set; } = "";
    [System.Text.Json.Serialization.JsonPropertyName("hosts")] public string[] Hosts { get; set; } = [];
    /// <summary>"listen" (wait for the other computer) or "connect" (dial it). Missing = this platform's default (connect on Windows).</summary>
    [System.Text.Json.Serialization.JsonPropertyName("role")] public string? Role { get; set; }
    /// <summary>The partner's name from the last connection, for "Waiting for …" while it is away.</summary>
    [System.Text.Json.Serialization.JsonPropertyName("peer")] public string? Peer { get; set; }

    [System.Text.Json.Serialization.JsonIgnore] public bool Listens => Role == "listen";

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lan-Line", "config.json");

    public static LanLineConfig Load(string? path = null) =>
        JsonSerializer.Deserialize<LanLineConfig>(File.ReadAllText(path ?? DefaultPath))
        ?? throw new InvalidDataException("empty config");

    /// <summary>Write atomically next to the target, then replace it. %APPDATA% is already private to the user.</summary>
    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, path, overwrite: true);
    }

    public static string DownloadsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Lan-Line");
}

/// <summary>One thread that runs posted actions in order: the Session's only home.</summary>
public sealed class SerialQueue : IDisposable
{
    readonly System.Collections.Concurrent.BlockingCollection<Action> _q = new();
    readonly Thread _t;

    public SerialQueue(string name)
    {
        _t = new Thread(Run) { IsBackground = true, Name = name };
        _t.Start();
    }

    public bool IsCurrent => Thread.CurrentThread == _t;

    void Run()
    {
        foreach (var a in _q.GetConsumingEnumerable())
        {
            try { a(); }
            catch (Exception e) { Console.Error.WriteLine($"lan-line: queue action failed: {e}"); }
        }
    }

    public void Post(Action a)
    {
        try { _q.Add(a); } catch (InvalidOperationException) { /* stopped */ }
    }

    public void PostAfter(TimeSpan delay, Action a) => Task.Delay(delay).ContinueWith(_ => Post(a));

    public T Sync<T>(Func<T> f)
    {
        if (IsCurrent) return f();
        T result = default!;
        using var done = new ManualResetEventSlim();
        Post(() => { try { result = f(); } finally { done.Set(); } });
        if (!done.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("session queue busy");
        return result;
    }

    public void Dispose() => _q.CompleteAdding();
}
