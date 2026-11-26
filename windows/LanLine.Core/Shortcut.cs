namespace LanLine.Core;

/// <summary>
/// A keyboard shortcut Lan-Line listens for everywhere (beta.10): "show/hide Lan-Line" and "send the clipboard".
/// Saved as text, "ctrl+alt+L" (modifiers in a fixed order, then the key), the same on Windows and the Mac, so one rule
/// set (here and Shortcut in LanLineCore) decides what is valid and how it reads.
/// </summary>
public sealed record Shortcut(bool Ctrl, bool Alt, bool Shift, bool Cmd, string Key)
{
    public static readonly Shortcut DefaultShow = new(true, true, false, false, "L");
    /// <summary>Offered in Settings for "send the clipboard"; that one is off until the user picks a key.</summary>
    public static readonly Shortcut SuggestedSend = new(true, true, false, false, "V");

    static readonly HashSet<string> Keys =
        [.. Enumerable.Range('A', 26).Select(c => ((char)c).ToString()), .. Enumerable.Range(0, 10).Select(d => d.ToString()), "Space", .. Enumerable.Range(1, 12).Select(n => $"F{n}")];

    /// <summary>"ctrl+alt+L"; null for anything else.</summary>
    public static Shortcut? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        bool c = false, a = false, s = false, m = false;
        string? key = null;
        foreach (var raw in text.Split('+').Select(p => p.Trim()))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl" or "control": c = true; break;
                case "alt" or "option": a = true; break;
                case "shift": s = true; break;
                case "cmd" or "command": m = true; break;
                default:
                    if (key != null || raw.Length == 0) return null;
                    var k = raw.Length == 1 ? raw.ToUpperInvariant() : char.ToUpperInvariant(raw[0]) + raw[1..].ToLowerInvariant();
                    if (!Keys.Contains(k)) return null;
                    key = k;
                    break;
            }
        }
        return key == null ? null : new Shortcut(c, a, s, m, key);
    }

    public string Text => string.Join("+", new[] { Ctrl ? "ctrl" : null, Alt ? "alt" : null, Shift ? "shift" : null, Cmd ? "cmd" : null, Key }.Where(x => x != null));

    /// <summary>"Ctrl+Alt+L" on Windows, "⌃⌥L" on the Mac.</summary>
    public string Display(bool mac) => mac
        ? (Ctrl ? "⌃" : "") + (Alt ? "⌥" : "") + (Shift ? "⇧" : "") + (Cmd ? "⌘" : "") + Key
        : string.Join("+", new[] { Ctrl ? "Ctrl" : null, Alt ? "Alt" : null, Shift ? "Shift" : null, Key }.Where(x => x != null));

    /// <summary>Why this can't be a global shortcut on this platform; null = fine.</summary>
    public string? Problem(bool mac)
    {
        if (!mac && Cmd) return "Windows has no ⌘ key.";
        if (!(Ctrl || Alt || Cmd)) return $"Use Ctrl{(mac ? ", ⌥ or ⌘" : " or Alt")} with the key, so normal typing isn't caught.";
        var only = (Ctrl, Alt, Shift, Cmd);
        if (mac)
        {
            if (only == (false, false, false, true) && new[] { "Q", "W", "H", "M", "C", "V", "X", "Z", "A", "S", "F", "P", "N", "O", "T", "Space" }.Contains(Key)) return $"⌘{Key} is used by every app.";
            if (only == (true, false, false, false) && Key == "Space") return "⌃Space switches the keyboard language.";
            if (only == (false, true, false, true) && Key == "Space") return "⌥⌘Space opens Finder search.";
        }
        else
        {
            if (only == (true, false, false, false) && new[] { "A", "C", "V", "X", "Z", "Y", "S", "F", "P", "N", "O", "W", "T" }.Contains(Key)) return $"Ctrl+{Key} is used by every app.";
            if (only == (false, true, false, false) && Key is "F4" or "Space") return $"Alt+{Key} is used by Windows.";
        }
        return null;
    }
}

/// <summary>The in-window shortcuts, for the "Keyboard shortcuts" list (Ctrl+/ or ⌘/) (beta.10); the same rows on both.</summary>
public static class KeyboardHelp
{
    public sealed record Row(string Keys, string Action);

    public static List<(string Section, List<Row> Rows)> Rows(bool mac, Shortcut? show, Shortcut? send)
    {
        string K(string m, string w) => mac ? m : w;
        return
        [
            ("Anywhere", [
                new(show?.Display(mac) ?? "Off (Settings)", "Show or hide Lan-Line, from any app"),
                new(send?.Display(mac) ?? "Off (Settings)", "Send what's on the clipboard"),
            ]),
            ("Sending", [
                new(K("Return", "Enter"), "Send"),
                new(K("⇧Return", "Shift+Enter"), "New line"),
                new(K("⌘V", "Ctrl+V"), "Paste text, a picture or files (sends them)"),
                new(K("⌘O", "Ctrl+O"), "Send files…"),
                new(K("⌘L", "Ctrl+L"), "Go to the message box"),
            ]),
            ("Items", [
                new(K("⌘F", "Ctrl+F"), "Search the history"),
                new(K("⌘↑", "Ctrl+↑"), "From the message box: select the newest item"),
                new("↑ ↓", "Select the item above or below"),
                new("Space", "Preview the selected file"),
                new(K("Return", "Enter"), "Open the selected file"),
                new(K("⌘C", "Ctrl+C"), "Copy the selected item"),
                new(K("⌘⇧R", "Ctrl+Shift+R"), K("Show the file in Finder", "Show the file in its folder")),
                new(K("⌫", "Delete"), "Cancel a transfer, or remove the item from the list"),
                new("Esc", "Back to the message box"),
            ]),
            ("Window", [
                new(K("⌘P", "Ctrl+P"), "Keep on top"),
                new(K("⌘,", "Ctrl+,"), "Settings"),
                new(K("⌘/", "Ctrl+/"), "This list"),
            ]),
        ];
    }
}
