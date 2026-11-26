using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LanLine.Core;

/// <summary>One item still owed to some partners, as the outbox file keeps it (beta.11).</summary>
public sealed record OutboxEntry
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    /// <summary>"text", "file" or "folder".</summary>
    [JsonPropertyName("kind")] public string Kind { get; init; } = "text";
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("path")] public string? Path { get; init; }
    /// <summary>Partner ids still waiting for it.</summary>
    [JsonPropertyName("to")] public string[] To { get; init; } = [];
    /// <summary>When it was sent, Unix seconds (the order it goes out in).</summary>
    [JsonPropertyName("at")] public double At { get; init; }

    public bool SameAs(OutboxEntry o) =>
        Id == o.Id && Kind == o.Kind && Text == o.Text && Path == o.Path && At == o.At && To.SequenceEqual(o.To);
}

/// <summary>
/// What is still waiting for a partner, kept on disk so quitting or restarting doesn't drop it (beta.11): it goes out when
/// that partner is next connected. The Hub writes it; the app only says where.
/// </summary>
public static class Outbox
{
    static readonly JsonSerializerOptions Opts = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static List<OutboxEntry> Load(string path)
    {
        try { return JsonSerializer.Deserialize<List<OutboxEntry>>(File.ReadAllText(path), Opts) ?? []; }
        catch (Exception) { return []; }
    }

    /// <summary>Empty = the file goes. False when it couldn't be written (the caller tries again next time).</summary>
    public static bool Save(string path, List<OutboxEntry> list)
    {
        try
        {
            if (list.Count == 0) { File.Delete(path); return true; }
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(list, Opts), new UTF8Encoding(false));
            File.Move(path + ".tmp", path, overwrite: true);
            return true;
        }
        catch (Exception) { return false; }
    }

    public static bool Same(List<OutboxEntry>? a, List<OutboxEntry> b) =>
        a != null && a.Count == b.Count && a.Zip(b).All(p => p.First.SameAs(p.Second));

    /// <summary>The files and folders the saved outbox still needs.</summary>
    public static HashSet<string> Paths(string outbox) =>
        new(Load(outbox).Where(e => e.Path != null).Select(e => System.IO.Path.GetFullPath(e.Path!)), StringComparer.OrdinalIgnoreCase);

    /// <summary>Tidy a folder of copies made for sending (pasted pictures): remove each entry older than age that no saved
    /// outbox item needs. Call before the hub starts. Returns how many went.</summary>
    public static int SweepUnsent(string dir, string outbox, TimeSpan age, DateTime? now = null)
    {
        if (!Directory.Exists(dir)) return 0;
        var keep = Paths(outbox);
        var t = now ?? DateTime.UtcNow;
        int removed = 0;
        foreach (var k in Directory.EnumerateFileSystemEntries(dir))
        {
            var full = System.IO.Path.GetFullPath(k);
            if (keep.Any(p => string.Equals(p, full, StringComparison.OrdinalIgnoreCase) ||
                              p.StartsWith(full + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) continue;
            try
            {
                var dirEntry = Directory.Exists(k);
                var at = dirEntry ? Directory.GetLastWriteTimeUtc(k) : File.GetLastWriteTimeUtc(k);
                if (t - at <= age) continue;
                if (dirEntry) Directory.Delete(k, recursive: true); else File.Delete(k);
                removed++;
            }
            catch (Exception) { }
        }
        return removed;
    }

    /// <summary>Still owed: queued or partly sent. Fully written (waiting for the ack) counts as delivered here, so a restart
    /// never sends a second copy of something the other side may already have.</summary>
    public static bool Owed(ItemState s) => s.Kind is ItemStateKind.Waiting or ItemStateKind.Sending;
}
