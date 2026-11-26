namespace LanLine.Core;

/// <summary>
/// Speed and time left for a transfer (beta.10), from the progress events the cards already get. Smoothed so the
/// numbers don't jump with every chunk; the same rules and wording as the Mac (TransferRate in LanLineCore).
/// </summary>
public sealed class TransferRate
{
    /// <summary>Bytes per second, smoothed; null until there are two samples far enough apart.</summary>
    public double? BytesPerSecond { get; private set; }
    (long Bytes, DateTime At)? _last;

    public const double Weight = 0.3;
    public static readonly TimeSpan MinGap = TimeSpan.FromSeconds(0.2);

    public void Update(long done, DateTime at)
    {
        if (_last is not { } l) { _last = (done, at); return; }
        if (done < l.Bytes) { BytesPerSecond = null; _last = (done, at); return; }   // started again (a resend)
        var dt = (at - l.At).TotalSeconds;
        if (dt < MinGap.TotalSeconds) return;
        var now = (done - l.Bytes) / dt;
        BytesPerSecond = BytesPerSecond is { } r ? r * (1 - Weight) + now * Weight : now;
        _last = (done, at);
    }

    /// <summary>Seconds left at the current speed; null when unknown or stalled.</summary>
    public double? Remaining(long done, long total) =>
        BytesPerSecond is { } r && r > 1 ? Math.Max(total - done, 0) / r : null;

    /// <summary>"42% · 85 MB/s · 12 s left" (each part only when known).</summary>
    public string Describe(long done, long total)
    {
        var parts = new List<string> { $"{(total > 0 ? (int)((double)done * 100 / total) : 0)}%" };
        if (BytesPerSecond is { } r && r > 1) parts.Add($"{Cleanup.FormatBytes((long)r)}/s");
        if (Remaining(done, total) is { } s) parts.Add(TimeLeft(s));
        return string.Join(" · ", parts);
    }

    /// <summary>"a few seconds left", "12 s left", "3 min left", "1 h 5 min left".</summary>
    public static string TimeLeft(double s)
    {
        if (s < 5) return "a few seconds left";
        if (s < 60) return $"{(int)Math.Round(s, MidpointRounding.AwayFromZero)} s left";
        if (s < 3600) return $"{(int)Math.Round(s / 60, MidpointRounding.AwayFromZero)} min left";
        var m = (int)Math.Round(s / 60, MidpointRounding.AwayFromZero);
        return m % 60 == 0 ? $"{m / 60} h left" : $"{m / 60} h {m % 60} min left";
    }
}
