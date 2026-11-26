using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Keyboard (beta.10): global shortcuts (show/hide, send the clipboard) through RegisterHotKey, which delivers only
/// our own combinations; the feed by keyboard (Ctrl+↑ in, ↑ ↓, Space, Enter, Ctrl+C, Ctrl+Shift+R, Delete, Esc);
/// Ctrl+O / Ctrl+Shift+O send files / a folder; Ctrl+L, Ctrl+, and the shortcut list (Ctrl+/ or F1).
/// </summary>
sealed partial class MainWindow
{
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    const int WM_HOTKEY = 0x0312, HotShow = 1, HotSend = 2;
    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_NOREPEAT = 0x4000;

    /// <summary>Why a global shortcut couldn't be registered ("show"/"send" → message), for Settings.</summary>
    readonly Dictionary<string, string> _hotKeyProblems = [];
    bool _recordingShortcut;
    bool _hotKeyHooked;

    static uint? Vk(string key) => key switch
    {
        "Space" => 0x20,
        [var c] when c is >= 'A' and <= 'Z' or >= '0' and <= '9' => c,
        ['F', .. var n] when int.TryParse(n, out var f) && f is >= 1 and <= 12 => (uint)(0x70 + f - 1),
        _ => null,
    };

    /// <summary>Register the global shortcuts from Settings (again after Save). Problems show in Settings.</summary>
    void ApplyHotKeys()
    {
        if (_demo) return;
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        if (!_hotKeyHooked) { HwndSource.FromHwnd(hwnd)?.AddHook(WatchHotKeys); _hotKeyHooked = true; }
        _hotKeyProblems.Clear();
        Register(HotShow, "show", _recordingShortcut ? null : _storage.ShowShortcut);
        Register(HotSend, "send", _recordingShortcut ? null : _storage.SendShortcut);

        void Register(int id, string slot, Shortcut? s)
        {
            UnregisterHotKey(hwnd, id);
            if (s == null) return;
            if (s.Problem(mac: false) is { } p) { _hotKeyProblems[slot] = p; return; }
            if (Vk(s.Key) is not { } vk) { _hotKeyProblems[slot] = "That key can't be used."; return; }
            var mods = MOD_NOREPEAT | (s.Ctrl ? MOD_CONTROL : 0) | (s.Alt ? MOD_ALT : 0) | (s.Shift ? MOD_SHIFT : 0);
            if (!RegisterHotKey(hwnd, id, mods, vk))
                _hotKeyProblems[slot] = Marshal.GetLastWin32Error() == 1409 ? $"{s.Display(false)} is taken by another app." : $"Windows refused {s.Display(false)}.";
        }
    }

    IntPtr WatchHotKeys(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_HOTKEY) return IntPtr.Zero;
        handled = true;
        if ((int)wParam == HotShow) ToggleWindow();
        else if ((int)wParam == HotSend) SendClipboard();
        return IntPtr.Zero;
    }

    /// <summary>The show/hide shortcut: in front → hide (to the tray while "Keep running" is on, else minimize).</summary>
    void ToggleWindow()
    {
        if (IsVisible && IsActive && WindowState != WindowState.Minimized)
        {
            if (_tray != null) Hide(); else WindowState = WindowState.Minimized;
            return;
        }
        ShowFromTray();
    }

    /// <summary>The send-the-clipboard shortcut: files, a picture or text to the current target, without opening
    /// the window; a notification says what went where. An empty clipboard just beeps.</summary>
    void SendClipboard()
    {
        if (_hub == null || _partners.Count == 0) { System.Media.SystemSounds.Beep.Play(); Note("Not paired yet: nothing was sent"); return; }
        if (_pairing) { System.Media.SystemSounds.Beep.Play(); ShowFromTray(); return; }   // mid-pairing: nothing goes out behind the pairing screen
        var to = _sendTarget is { } t ? NameOf(t) : Multi ? "everyone" : PeerLabel;
        string? body = null;
        try
        {
            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList().Cast<string>().ToList();
                var n = SendFiles(files);   // "Sent" only for what went out
                if (n > 0) body = n == 1 && files.Count == 1 ? Path.GetFileName(files[0]) : $"{n} item{(n == 1 ? "" : "s")}";
            }
            else if (Clipboard.ContainsImage() && !Clipboard.ContainsText() && Clipboard.GetImage() is { } img)
            {
                if (SendFiles([SavePasted(img)]) > 0) body = "A picture from the clipboard";
            }
            else if (Clipboard.ContainsText() && Clipboard.GetText() is { } s && s.Trim().Length > 0)
            {
                UpsertOutgoing(_hub.SendText(s, _sendTarget));
                TickSent();
                body = ArrivalNotices.Preview(s);
            }
        }
        catch (Exception) { /* clipboard busy */ }
        if (body == null) { System.Media.SystemSounds.Beep.Play(); return; }
        PostNotice(new ArrivalNotice($"Sent to {to}", body, []));
    }

    static string SavePasted(System.Windows.Media.Imaging.BitmapSource img)
    {
        var dir = Path.Combine(Path.GetTempPath(), "Lan-Line-pasted");
        Directory.CreateDirectory(dir);
        var path = Names.Unique($"pasted-{DateTime.Now:yyyyMMdd-HHmmss}.png", dir);
        using var fs = File.Create(path);
        var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
        enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(img));
        enc.Save(fs);
        return path;
    }

    void SendFilesDialog(bool folder)
    {
        if (_hub == null || _pairing) return;
        ShowFromTray();
        string[] picked;
        if (folder)
        {
            var d = new Microsoft.Win32.OpenFolderDialog { Title = "Choose folders to send", Multiselect = true };
            if (d.ShowDialog(this) != true) return;
            picked = d.FolderNames;
        }
        else
        {
            var d = new Microsoft.Win32.OpenFileDialog { Title = "Choose files to send", Multiselect = true };
            if (d.ShowDialog(this) != true) return;
            picked = d.FileNames;
        }
        SendFiles(picked);
    }

    void FocusInput() { Deselect(); _input.Focus(); }

    // ---------- the feed by keyboard

    /// <summary>The rows on screen: the feed, or the search results.</summary>
    List<ItemRow> FeedRows() => Filtering ? FeedRowsOf(_results, _resultRows) : FeedRowsOf(_feed, _rows);

    bool SelectNewest()
    {
        var rows = FeedRows();
        if (rows.Count == 0) { System.Media.SystemSounds.Beep.Play(); return false; }
        Select(rows[^1]);
        rows[^1].View.BringIntoView();
        return true;
    }

    /// <summary>↑ / ↓. False when ↓ passes the newest (back to the message box).</summary>
    bool SelectRelative(int d)
    {
        var rows = FeedRows();
        var i = _selected == null ? rows.Count : rows.IndexOf(_selected);
        var j = i + d;
        if (j < 0) return true;
        if (j >= rows.Count) return false;
        Select(rows[j]);
        rows[j].View.BringIntoView();
        return true;
    }

    void RemoveRow(ItemRow row)
    {
        var rows = FeedRows();
        var i = rows.IndexOf(row);
        var next = i + 1 < rows.Count ? rows[i + 1] : i > 0 ? rows[i - 1] : null;
        // `row` may be a search result: a copy of the feed's row. Take the item out of both lists by id, each
        // with its own view, or the feed keeps a card nothing tracks any more.
        if (_rows.Remove(row.Item.Id, out var live)) _feed.Children.Remove(live.View);
        if (_resultRows.Remove(row.Item.Id, out var found)) _results.Children.Remove(found.View);
        ForgetInHistory(row.Item.Id);   // or it would come back at the next start
        RefreshEmpty();
        _selected = null;
        if (next != null) Select(next); else FocusInput();
    }

    /// <summary>All window keys (from OnWindowKey). True = handled.</summary>
    bool FeedKey(KeyEventArgs e)
    {
        if (_recordingShortcut) return false;   // the Settings recorder takes every key
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;
        if (ShortcutsOpen)
        {
            if (key is Key.Escape or Key.F1 || (key == Key.OemQuestion && mods == ModifierKeys.Control)) { HideShortcuts(); return true; }
            return false;
        }
        if ((key == Key.OemQuestion && mods == ModifierKeys.Control) || (key == Key.F1 && mods == ModifierKeys.None)) { ShowShortcuts(); return true; }
        if (key == Key.OemComma && mods == ModifierKeys.Control) { ShowSettings(); return true; }
        if (_showingSettings || _pairing) return false;
        if (key == Key.O && mods == ModifierKeys.Control) { SendFilesDialog(folder: false); return true; }
        if (key == Key.O && mods == (ModifierKeys.Control | ModifierKeys.Shift)) { SendFilesDialog(folder: true); return true; }
        if (key == Key.L && mods == ModifierKeys.Control) { FocusInput(); return true; }
        if (key == Key.F && mods == ModifierKeys.Control) { OpenSearch(); return true; }
        if (key == Key.Up && mods == ModifierKeys.Control && _input.IsKeyboardFocusWithin) { if (SelectNewest()) FocusFeed(); return true; }
        if (_selected is not { } sel) return false;
        // Typing somewhere (the message box, the search box, a text bubble or a code block): the keys belong to
        // that text, not to a card selected earlier.
        if (!PreviewOpen && Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase) { Deselect(); return false; }
        var plain = mods == ModifierKeys.None;
        switch (key)
        {
            case Key.Space when plain:
                if (PreviewOpen) ClosePreview(); else if (sel.Item.IsFile && !sel.Unavailable) OpenPreview(); else System.Media.SystemSounds.Beep.Play();
                return true;
            case Key.Escape:
                if (PreviewOpen) ClosePreview(); else FocusInput();
                return true;
            case Key.Left or Key.Up when PreviewOpen: Page(-1); return true;
            case Key.Right or Key.Down when PreviewOpen: Page(1); return true;
            case Key.Up when plain: SelectRelative(-1); return true;
            case Key.Down when plain: if (!SelectRelative(1)) FocusInput(); return true;
            case Key.Enter when plain: if (sel.Item.IsFile && !sel.Unavailable) sel.Open(); return true;
            case Key.C when mods == ModifierKeys.Control: if (!sel.Unavailable) sel.Copy(); return true;
            case Key.R when mods == (ModifierKeys.Control | ModifierKeys.Shift): if (sel.Item.IsFile && !sel.Unavailable) sel.Reveal(); return true;
            case Key.Delete or Key.Back when plain && !PreviewOpen:
                if (CanCancel(sel.Item)) CancelTransfer(sel); else RemoveRow(sel);
                return true;
        }
        if (PreviewOpen || !(plain || mods == ModifierKeys.Shift)) return false;
        FocusInput();   // typing goes back to the message box, and lands there
        return false;
    }

    // ---------- the shortcut list (Ctrl+/ or F1)

    Grid? _shortcutsLayer;
    bool ShortcutsOpen => _shortcutsLayer is { Visibility: Visibility.Visible };

    void HideShortcuts() { if (_shortcutsLayer != null) _shortcutsLayer.Visibility = Visibility.Collapsed; }

    internal void ShowShortcuts(bool bringForward = true)
    {
        if (bringForward) ShowFromTray();
        if (_shortcutsLayer != null) ((Grid)Content).Children.Remove(_shortcutsLayer);
        var layer = new Grid { Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)) };
        layer.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource == layer) HideShortcuts(); };
        var card = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 12, 16, 12), Margin = new Thickness(14, 40, 14, 14), BorderThickness = new Thickness(1) };
        card.SetResourceReference(Border.BackgroundProperty, "Bg");
        card.SetResourceReference(Border.BorderBrushProperty, "CardStroke");
        card.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Direction = 270, Opacity = 0.35, Color = Colors.Black };
        var dock = new DockPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var title = new TextBlock { Text = "Keyboard shortcuts", FontSize = 14, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        var close = new Button { Content = Glyph_Close, FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 10, ToolTip = "Close (Esc)" };
        close.SetResourceReference(StyleProperty, "IconButton");
        Automation(close, "Close");
        close.Click += (_, _) => HideShortcuts();
        DockPanel.SetDock(close, Dock.Right);
        head.Children.Add(close); head.Children.Add(title);
        DockPanel.SetDock(head, Dock.Top);
        var list = new StackPanel();
        foreach (var (section, rows) in KeyboardHelp.Rows(mac: false, _storage.ShowShortcut, _storage.SendShortcut))
        {
            var h = new TextBlock { Text = section.ToUpperInvariant(), FontSize = 10, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 4) };
            h.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            list.Children.Add(h);
            foreach (var r in rows)
            {
                var g = new Grid { Margin = new Thickness(0, 2, 0, 2) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(118) });
                g.ColumnDefinitions.Add(new ColumnDefinition());
                var k = new TextBlock { Text = r.Keys, FontSize = 11.5, FontWeight = FontWeights.Medium, Padding = new Thickness(6, 1, 6, 1) };
                k.SetResourceReference(TextBlock.ForegroundProperty, r.Keys.StartsWith("Off") ? "Text2" : "Text");
                var chip = new Border { Child = k, CornerRadius = new CornerRadius(5), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
                chip.SetResourceReference(Border.BackgroundProperty, "CardStroke");
                var a = new TextBlock { Text = r.Action, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8, 1, 0, 0) };
                a.SetResourceReference(TextBlock.ForegroundProperty, "Text");
                Grid.SetColumn(a, 1);
                g.Children.Add(chip); g.Children.Add(a);
                System.Windows.Automation.AutomationProperties.SetName(g, $"{r.Keys}: {r.Action}");
                list.Children.Add(g);
            }
        }
        dock.Children.Add(head);
        dock.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        card.Child = dock;
        layer.Children.Add(card);
        _shortcutsLayer = layer;
        ((Grid)Content).Children.Add(layer);
    }
}
