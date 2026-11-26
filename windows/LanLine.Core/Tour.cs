namespace LanLine.Core;

/// <summary>The welcome tour and the empty window's hints (beta.10), the same rules and wording as the Mac's
/// Tour.swift: three cards, shown once on a new install after pairing and the first-run settings; never automatically
/// for someone who was already paired before the tour existed.</summary>
public sealed record TourCard(string Id, string Title, string Body);
public sealed record TourHint(string Id, string Text);

public static class Tour
{
    public enum Platform { Mac, Windows, IPhone }

    public static IReadOnlyList<TourCard> Cards(Platform p) => p switch
    {
        Platform.Mac =>
        [
            new("send", "Send anything", "Type and press Return, paste, or drop files and folders on the window. They arrive on your other computer a moment later, encrypted end to end."),
            new("anywhere", "From anywhere", "Share from Finder, or drop files on Lan-Line's Dock or menu bar icon. In Settings you can set a shortcut that sends the clipboard from any app."),
            new("close", "Always close by", "Pin the window on top, or close it: Lan-Line stays in the menu bar and tells you when something arrives."),
        ],
        Platform.Windows =>
        [
            new("send", "Send anything", "Type and press Enter, paste, or drop files and folders on the window. They arrive on your other computer a moment later, encrypted end to end."),
            new("anywhere", "From anywhere", "Right-click a file and choose Send to › Lan-Line. In Settings you can set a shortcut that sends the clipboard from any app."),
            new("close", "Always close by", "Pin the window on top, or close it: Lan-Line stays in the notification area and tells you when something arrives."),
        ],
        _ =>
        [
            new("send", "Send anything", "Type a message, or tap + for photos, videos and files. They arrive on your computer a moment later, encrypted end to end."),
            new("anywhere", "Everything in one place", "What your computers send appears here. Tap to preview; touch and hold to copy, share or save to Photos."),
            new("close", "Open while you use it", "iPhone lets Lan-Line receive while it's open. What your computers send meanwhile waits on them and arrives when you open it. Leave it open for big transfers."),
        ],
    };

    public static IReadOnlyList<TourHint> Hints(Platform p) => p switch
    {
        Platform.Mac => [new("type", "Type or paste, then press Return"), new("drop", "Drop files or folders anywhere in this window"), new("share", "Or share from Finder to Lan-Line")],
        Platform.Windows => [new("type", "Type or paste, then press Enter"), new("drop", "Drop files or folders anywhere in this window"), new("share", "Or right-click a file: Send to › Lan-Line")],
        _ => [new("type", "Type a message"), new("drop", "Tap + for photos, videos and files"), new("share", "What your computers send appears here")],
    };

    public static bool ShouldShow(bool? seen, bool paired, bool settingsConfirmed) => seen == null && paired && settingsConfirmed;

    public static bool? SeenAtLaunch(bool? saved, bool alreadyPaired) => saved ?? (alreadyPaired ? true : null);
}
