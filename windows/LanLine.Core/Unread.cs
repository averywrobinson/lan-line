namespace LanLine.Core;

/// <summary>Items that arrived while Lan-Line wasn't the window in use (beta.10): the taskbar overlay and a dot on
/// the tray icon (Mac: the Dock badge and the menu bar dot); cleared when the window is used again.</summary>
public sealed class Unread
{
    public int Count { get; private set; }

    /// <summary>Something arrived; inUse = the user has Lan-Line in front, so it was seen straight away.</summary>
    public void Arrived(bool inUse) { if (!inUse) Count++; }
    public void Seen() => Count = 0;

    /// <summary>The badge text: null for none, "1"…"99", then "99+".</summary>
    public string? Badge => Count == 0 ? null : Count > 99 ? "99+" : Count.ToString();
    /// <summary>"3 new" for tooltips and the menu, null for none.</summary>
    public string? Phrase => Badge is { } b ? $"{b} new" : null;
}

/// <summary>Open Lan-Line at sign-in (beta.10): the per-user Run value, started with --background so it waits in the
/// tray instead of opening the window. The Settings switch and the installer's option write the same value.</summary>
public static class SignIn
{
    public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string ValueName = "Lan-Line";
    public const string BackgroundFlag = "--background";

    public static string Command(string exe) => $"\"{exe}\" {BackgroundFlag}";

    /// <summary>Whether a Run value starts this Lan-Line (older installers wrote it without --background).</summary>
    public static bool IsOn(string? value, string exe) =>
        value != null && value.Trim().TrimStart('"').StartsWith(exe, StringComparison.OrdinalIgnoreCase);
}
