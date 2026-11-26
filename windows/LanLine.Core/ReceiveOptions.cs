namespace LanLine.Core;

/// <summary>What happens when a file arrives (beta.10): nothing (the default), show it in Explorer, or open it. Opening
/// is only for kinds that can't run anything: pictures, PDFs, plain text and media.</summary>
public enum AfterReceive { Nothing, Reveal, Open }

/// <summary>Where received files go and what to do after (beta.10). The same rules as ReceiveOptions on the Mac.</summary>
public static class ReceiveOptions
{
    public static readonly HashSet<string> Openable = new(StringComparer.OrdinalIgnoreCase)
    {
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
        "pdf", "txt", "md", "csv", "rtf",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "flac",
    };
    public const int MaxOpensPerBurst = 3;

    public static string Key(AfterReceive a) => a switch { AfterReceive.Reveal => "reveal", AfterReceive.Open => "open", _ => "nothing" };

    /// <summary>The folder a partner's files go to: the chosen folder, or a folder per computer inside it.</summary>
    public static string Folder(string baseDir, bool perComputer, string partner) =>
        perComputer ? Path.Combine(baseDir, Names.Sanitize(partner)) : baseDir;

    /// <summary>What to really do for one arrived item: Open falls back to Reveal for folders, kinds that could run code,
    /// and after MaxOpensPerBurst opens.</summary>
    public static AfterReceive Action(AfterReceive setting, string name, bool isFolder, int opensSoFar)
    {
        if (setting != AfterReceive.Open) return setting;
        if (isFolder || opensSoFar >= MaxOpensPerBurst) return AfterReceive.Reveal;
        return Openable.Contains(Path.GetExtension(name).TrimStart('.')) ? AfterReceive.Open : AfterReceive.Reveal;
    }
}

/// <summary>One burst of arrivals (beta.10): how many files were opened and shown. A burst ends after Quiet without an
/// *arrival* (not without an open), so a long stream of files never opens more than the cap, and the folder is shown
/// once, not once per file. The same rule as ArrivalBurst on the Mac.</summary>
public sealed class ArrivalBurst
{
    public static readonly TimeSpan Quiet = TimeSpan.FromSeconds(5);
    /// <summary>Explorer comes forward once per burst; the other files are in that same window.</summary>
    public const int MaxRevealsPerBurst = 1;
    DateTime _lastArrival = DateTime.MinValue;
    public int Opens { get; private set; }
    public int Reveals { get; private set; }

    /// <summary>What to do for this arrival, counting it.</summary>
    public AfterReceive Next(AfterReceive setting, string name, bool isFolder, DateTime? at = null)
    {
        if (setting == AfterReceive.Nothing) return AfterReceive.Nothing;
        var now = at ?? DateTime.UtcNow;
        if (now - _lastArrival > Quiet) { Opens = 0; Reveals = 0; }
        _lastArrival = now;
        switch (ReceiveOptions.Action(setting, name, isFolder, Opens))
        {
            case AfterReceive.Open: Opens++; return AfterReceive.Open;
            case AfterReceive.Reveal:
                if (Reveals >= MaxRevealsPerBurst) return AfterReceive.Nothing;
                Reveals++;
                return AfterReceive.Reveal;
            default: return AfterReceive.Nothing;
        }
    }
}
