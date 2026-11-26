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
    /// <summary>"Check for updates automatically once a day". Off unless the user turns it on (null = never set = off).</summary>
    [JsonPropertyName("autoUpdateCheck")] public bool? AutoUpdateCheck { get; set; }
    [JsonPropertyName("lastUpdateCheck")] public DateTime? LastUpdateCheck { get; set; }
    /// <summary>The newest version this computer heard of (update check or the other computer), and its page.</summary>
    [JsonPropertyName("latestVersion")] public string? LatestVersion { get; set; }
    [JsonPropertyName("latestURL")] public string? LatestUrl { get; set; }
    /// <summary>How opaque the smoked-glass backdrop is, 0.40–1.00 (beta.8); null = the default look. Only the
    /// backdrop changes; text, bubbles and chips keep their own colors. Same key and rules as the Mac.</summary>
    [JsonPropertyName("glassOpacity")] public double? GlassOpacity { get; set; }
    /// <summary>The welcome tour was shown, or isn't owed (beta.10): null = a new install that hasn't seen it yet.</summary>
    [JsonPropertyName("tourSeen")] public bool? TourSeen { get; set; }
    /// <summary>Text size (accessibility pass, beta.10): one of TextScaleChoices; null = 100 %. On Windows it multiplies
    /// the system's own Text size setting; on the Mac it is the whole setting.</summary>
    [JsonPropertyName("textScale")] public double? TextScale { get; set; }

    /// <summary>Closing the window keeps Lan-Line running in the notification area (tray) and takes it off the
    /// taskbar until the window is shown again (beta.9); null = never set = on. Same key as the Mac.</summary>
    [JsonPropertyName("keepRunningWhenClosed")] public bool? KeepRunningWhenClosed { get; set; }
    [JsonIgnore] public bool KeepRunningWhenClosedValue => KeepRunningWhenClosed ?? true;
    /// <summary>A system notification when something arrives while Lan-Line isn't the window in use (beta.10);
    /// null = on. Same key as the Mac.</summary>
    [JsonPropertyName("notifyOnArrival")] public bool? NotifyOnArrival { get; set; }
    [JsonIgnore] public bool NotifyOnArrivalValue => NotifyOnArrival ?? true;
    /// <summary>Bring the window forward when something arrives (the behaviour before beta.10); null = on.</summary>
    [JsonPropertyName("popUpOnArrival")] public bool? PopUpOnArrival { get; set; }
    [JsonIgnore] public bool PopUpOnArrivalValue => PopUpOnArrival ?? true;
    /// <summary>Global shortcuts (beta.10), as Shortcut text. Show/hide: null = the default (Ctrl+Alt+L), "" = off.
    /// Send the clipboard: null or "" = off. Same keys as the Mac.</summary>
    [JsonPropertyName("shortcutShow")] public string? ShortcutShow { get; set; }
    /// <summary>The arrival chime and the send tick (beta.10); null = on. Same key as the Mac.</summary>
    [JsonPropertyName("sounds")] public bool? Sounds { get; set; }
    [JsonIgnore] public bool SoundsValue => Sounds ?? true;
    /// <summary>Keep a history of finished items on this computer (history.jsonl) (beta.10); null = on.</summary>
    [JsonPropertyName("keepHistory")] public bool? KeepHistory { get; set; }
    [JsonIgnore] public bool KeepHistoryValue => KeepHistory ?? true;
    /// <summary>Clipboard sharing (beta.10): off unless turned on (null = off); pictures too while on (null = on).</summary>
    [JsonPropertyName("shareClipboard")] public bool? ShareClipboard { get; set; }
    [JsonPropertyName("shareClipboardPictures")] public bool? ShareClipboardPictures { get; set; }
    [JsonIgnore] public bool ShareClipboardValue => ShareClipboard ?? false;
    [JsonIgnore] public bool ShareClipboardPicturesValue => ShareClipboardPictures ?? true;
    /// <summary>Where received files go (beta.10): null = Downloads\Lan-Line; a folder per computer inside it (null = no);
    /// what to do when one arrives ("nothing" / "reveal" / "open"; null = nothing). Same keys as the Mac.</summary>
    [JsonPropertyName("downloadFolder")] public string? DownloadFolder { get; set; }
    [JsonPropertyName("folderPerComputer")] public bool? FolderPerComputer { get; set; }
    [JsonPropertyName("afterReceive")] public string? AfterReceive { get; set; }
    [JsonIgnore] public bool FolderPerComputerValue => FolderPerComputer ?? false;
    /// <summary>Link previews (beta.10): fetch a shared link's title and picture. Off unless turned on (null = off).</summary>
    [JsonPropertyName("linkPreviews")] public bool? LinkPreviews { get; set; }
    [JsonIgnore] public bool LinkPreviewsValue => LinkPreviews ?? false;
    /// <summary>Windows only (beta.10): a slim drop zone at the right edge of the screen; null = off. The Mac takes drops
    /// on its menu bar icon instead.</summary>
    [JsonPropertyName("edgeDropZone")] public bool? EdgeDropZone { get; set; }
    [JsonIgnore] public bool EdgeDropZoneValue => EdgeDropZone ?? false;
    [JsonIgnore] public AfterReceive AfterReceiveValue => AfterReceive switch { "reveal" => LanLine.Core.AfterReceive.Reveal, "open" => LanLine.Core.AfterReceive.Open, _ => LanLine.Core.AfterReceive.Nothing };
    [JsonIgnore] public string? DownloadFolderValue => string.IsNullOrEmpty(DownloadFolder) ? null : DownloadFolder;
    [JsonPropertyName("shortcutSend")] public string? ShortcutSend { get; set; }
    [JsonIgnore] public Shortcut? ShowShortcut => ShortcutShow == null ? Shortcut.DefaultShow : Shortcut.Parse(ShortcutShow);
    [JsonIgnore] public Shortcut? SendShortcut => Shortcut.Parse(ShortcutSend);
    /// <summary>The one-time "Lan-Line is still running" note was shown (Windows only).</summary>
    [JsonPropertyName("trayHintShown")] public bool TrayHintShown { get; set; }

    public static readonly double[] TextScaleChoices = [0.9, 1.0, 1.15, 1.3, 1.5];
    /// <summary>The saved text size snapped to the nearest choice (a damaged value can't make text unusable).</summary>
    [JsonIgnore] public double TextScaleValue => SnapTextScale(TextScale ?? 1);
    public static double SnapTextScale(double v) => double.IsFinite(v) ? TextScaleChoices.MinBy(c => Math.Abs(c - v)) : 1;
    /// <summary>What the window is scaled by: Windows' Text size (100–225 %) times the Lan-Line setting, kept within
    /// 90–225 % so the window stays usable.</summary>
    public static double EffectiveTextScale(double systemPercent, double setting)
    {
        var sys = double.IsFinite(systemPercent) ? Math.Clamp(systemPercent, 100, 225) / 100 : 1;
        return Math.Clamp(sys * SnapTextScale(setting), 0.9, 2.25);
    }

    public const double GlassOpacityMin = 0.40, GlassOpacityMax = 1.00;
    /// <summary>The look before the setting existed (the dark backdrop's alpha, #BD).</summary>
    public const double DefaultGlassOpacity = 0.74;
    [JsonIgnore] public double GlassOpacityValue => ClampOpacity(GlassOpacity ?? DefaultGlassOpacity);
    public static double ClampOpacity(double v) => double.IsFinite(v) ? Math.Clamp(v, GlassOpacityMin, GlassOpacityMax) : DefaultGlassOpacity;
    /// <summary>The backdrop tint's alpha: the value itself in dark mode; light stays a little more opaque (0.80 at the default).</summary>
    public static double TintAlpha(double v, bool dark) { var o = ClampOpacity(v); return dark ? o : Math.Min(1, o + 0.06); }

    /// <summary>How strong the scrim under text that sits directly on the window body is (design refresh, beta.10):
    /// nothing at the default opacity and above, rising evenly to full strength at the minimum.</summary>
    public static double ScrimStrength(double v)
    {
        var o = ClampOpacity(v);
        return o >= DefaultGlassOpacity ? 0 : (DefaultGlassOpacity - o) / (DefaultGlassOpacity - GlassOpacityMin);
    }
    /// <summary>The scrim's opacity at full strength.</summary>
    public const double ScrimMax = 0.62;

    public static readonly int[] RetentionChoices = [0, 1, 10, 30, 60, 90];
    public static readonly double[] LimitChoices = [0, 5, 10, 25, 50, 100];

    [JsonIgnore] public long LimitBytes => LimitGB > 0 ? (long)(LimitGB * 1_000_000_000) : 0;

    public static string DefaultPath => Path.Combine(Path.GetDirectoryName(LanLineConfig.DefaultPath)!, "settings.json");
    // Readable text in the file ("ctrl+alt+L", not "ctrl\u002Balt\u002BL"); it is a local file, never put in HTML.
    static readonly JsonSerializerOptions Opts = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

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
