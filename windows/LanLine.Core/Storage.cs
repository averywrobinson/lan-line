using System.Text.Json;
using System.Text.Json.Serialization;

namespace LanLine.Core;

/// <summary>
/// How long received files are kept and how much room they may use. Saved as settings.json next to the pairing
/// config, so re-pairing never resets it. Defaults: nothing is ever deleted; warn as 10 GB fills up. Same rules as the Mac.
/// </summary>
public sealed class StorageSettings
{
    /// <summary>Days to keep a received file; 0 = keep forever.</summary>
    [JsonPropertyName("retentionDays")] public int RetentionDays { get; set; }
    /// <summary>Storage limit for received files in GB; 0 = no limit.</summary>
    [JsonPropertyName("limitGB")] public double LimitGB { get; set; } = 10;
    /// <summary>Over the limit: "warn" (just say so) or "trash" (move the oldest received files to the Recycle Bin).</summary>
    [JsonPropertyName("overLimit")] public string OverLimit { get; set; } = "warn";
    [JsonPropertyName("trashReminder")] public bool TrashReminder { get; set; } = true;
    /// <summary>The user has looked at these settings and pressed Save at least once.</summary>
    [JsonPropertyName("confirmed")] public bool Confirmed { get; set; }
    [JsonPropertyName("lastTrashReminder")] public DateTime? LastTrashReminder { get; set; }
    [JsonPropertyName("lastLimitWarning")] public DateTime? LastLimitWarning { get; set; }

    public static readonly int[] RetentionChoices = [0, 1, 10, 30, 60, 90];
    public static readonly double[] LimitChoices = [0, 5, 10, 25, 50, 100];

    [JsonIgnore] public long LimitBytes => LimitGB > 0 ? (long)(LimitGB * 1_000_000_000) : 0;

    public static string DefaultPath => Path.Combine(Path.GetDirectoryName(LanLineConfig.DefaultPath)!, "settings.json");
    static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    public static StorageSettings Load(string? path = null)
    {
        try { return JsonSerializer.Deserialize<StorageSettings>(File.ReadAllText(path ?? DefaultPath)) ?? new(); }
        catch (Exception) { return new(); }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(this, Opts));
        File.Move(path + ".tmp", path, overwrite: true);
    }

    public StorageSettings Copy() => (StorageSettings)MemberwiseClone();
}

/// <summary>One file Lan-Line received and saved. Only files in this log are ever cleaned up.</summary>
public sealed record ReceivedFile(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("receivedAt")] DateTime ReceivedAt);

public static class ReceivedLog
{
    public static string DefaultPath => Path.Combine(Path.GetDirectoryName(LanLineConfig.DefaultPath)!, "received.json");

    public static List<ReceivedFile> Load(string? path = null)
    {
        try { return JsonSerializer.Deserialize<List<ReceivedFile>>(File.ReadAllText(path ?? DefaultPath)) ?? []; }
        catch (Exception) { return []; }
    }

    public static void Save(List<ReceivedFile> files, string? path = null)
    {
        path ??= DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(files, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(path + ".tmp", path, overwrite: true);
    }
}

/// <summary>What a cleanup pass should do. Pure: the app moves the files and shows the notes.</summary>
public sealed class CleanupPlan
{
    public List<ReceivedFile> Expired { get; } = [];
    public List<ReceivedFile> OverLimit { get; } = [];
    public long UsageBytes { get; set; }
    public long LimitBytes { get; set; }
    /// <summary>0 = fine, 1 = at least 80 % of the limit, 2 = over the limit.</summary>
    public int Level { get; set; }
    public IEnumerable<ReceivedFile> ToTrash => Expired.Concat(OverLimit);
}

public static class Cleanup
{
    /// <summary>existing = log entries whose files are still there (the caller drops the rest from the log).</summary>
    public static CleanupPlan Plan(IEnumerable<ReceivedFile> existing, StorageSettings s, DateTime now)
    {
        var p = new CleanupPlan { LimitBytes = s.LimitBytes };
        var keep = existing.OrderBy(f => f.ReceivedAt).ToList();   // oldest first
        if (s.RetentionDays > 0)
        {
            var cutoff = now.AddDays(-s.RetentionDays);
            p.Expired.AddRange(keep.Where(f => f.ReceivedAt <= cutoff));
            keep.RemoveAll(f => f.ReceivedAt <= cutoff);
        }
        var usage = keep.Sum(f => f.Size);
        if (p.LimitBytes > 0 && s.OverLimit == "trash")
        {
            // Never move the newest file: one file bigger than the limit is the user's to decide about.
            while (usage > p.LimitBytes && keep.Count > 1)
            {
                p.OverLimit.Add(keep[0]);
                usage -= keep[0].Size;
                keep.RemoveAt(0);
            }
        }
        p.UsageBytes = usage;
        if (p.LimitBytes > 0) p.Level = usage > p.LimitBytes ? 2 : usage >= 0.8 * p.LimitBytes ? 1 : 0;
        return p;
    }

    /// <summary>Quiet warnings: at most one limit warning a day, one Recycle Bin reminder every 14 days.</summary>
    public static bool ShouldWarnLimit(StorageSettings s, int level, DateTime now) =>
        level > 0 && (s.LastLimitWarning is not { } t || now - t >= TimeSpan.FromDays(1));

    public static bool ShouldRemindTrash(StorageSettings s, bool movedSomething, DateTime now) =>
        movedSomething && s.TrashReminder && (s.LastTrashReminder is not { } t || now - t >= TimeSpan.FromDays(14));

    public static string FormatBytes(long b)
    {
        var gb = b / 1e9;
        if (gb >= 1) return gb >= 10 ? $"{gb:0} GB" : $"{gb:0.0} GB";
        var mb = b / 1e6;
        return mb >= 1 ? $"{mb:0} MB" : $"{Math.Max(b / 1000, b > 0 ? 1 : 0)} KB";
    }
}
