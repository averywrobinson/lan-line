using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Shell;
using LanLine.Core;

namespace LanLine.App;

/// <summary>The Lan-Line window: a thin view over one Session. Everything here runs on the UI thread.</summary>
sealed partial class MainWindow : Window
{
    internal const string Glyph_Copy = "", Glyph_Check = "", Glyph_Clock = "", Glyph_Error = "",
        Glyph_Pin = "", Glyph_Unpin = "", Glyph_Min = "", Glyph_Max = "", Glyph_Restore = "",
        Glyph_Close = "", Glyph_Up = "", Glyph_Doc = "", Glyph_Upload = "", Glyph_More = "", Glyph_Folder = "\uE8B7";

    readonly Button _target = new() { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 18, 0), Visibility = Visibility.Collapsed };
    internal bool Multi => _partners.Count >= 2;
    string NameOf(string id) => _partners.FirstOrDefault(p => p.Id == id)?.Name ?? "partner";
    string TargetLabel => _sendTarget is { } t ? NameOf(t) : "Everyone";
    readonly Ellipse _dot = new() { Width = 7, Height = 7, Margin = new Thickness(0, 1, 6, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _status = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _pin = new() { Content = Glyph_Unpin };
    readonly Button _max = new() { Content = Glyph_Max };
    readonly StackPanel _feed = new() { Margin = new Thickness(14, 12, 14, 8) };
    readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    // Fixed 18 px lines and a 5-line cap, so a long message scrolls by whole lines (no half-clipped top line).
    readonly TextBox _input = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 90, MinHeight = 18, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _placeholder = new() { FontSize = 13, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _send = new() { Content = Glyph_Up, IsEnabled = false, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Bottom };
    readonly FrameworkElement _empty;
    readonly Grid _dropOverlay;
    readonly Grid _body = new();
    readonly Border _composer;
    readonly FrameworkElement _pairPanel;
    readonly Dictionary<string, ItemRow> _rows = [];
    const int MaxRows = 200;
    bool _connected, _pinned = true, _draggingOwnChip;
    string _peer = "", _statusText = "Starting…";

    internal string PeerLabel => _peer.Length > 0 ? _peer : "your other computer";
    string Away => _peer.Length > 0 ? _peer : "partner";

    /// <summary>Session diagnostics → the short line under the title. Version and pairing problems say what to do.</summary>
    static string StatusLine(string s, string away) =>
        s.StartsWith("dialing") ? $"Connecting to {away}…"
        : s.StartsWith("Refused") ? $"{away} doesn't know this pairing: pair again"
        : s.Contains("update Lan-Line on the other") || s.StartsWith("The other computer runs an older") ? $"Update Lan-Line on {away}"
        : s.Contains("newer Lan-Line") ? "Update Lan-Line on this PC"
        : $"Can't reach {away}";

    public MainWindow(string[] args, bool demo = false)
    {
        Title = "Lan-Line";
        Width = 380; Height = 320; MinWidth = 300; MinHeight = 230;
        Topmost = true;
        AllowDrop = true;
        UseLayoutRounding = true;
        FontFamily = (FontFamily)Application.Current.Resources["UiFont"];
        SetResourceReference(BackgroundProperty, "Bg");
        Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Lan-Line;component/LanLine.ico"));
        var wa = SystemParameters.WorkArea;
        Left = wa.Right - Width - 24; Top = wa.Bottom - Height - 24;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 52, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = Theme.Glass ? new Thickness(-1) : new Thickness(0, 0, 0, 1),
            CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        SourceInitialized += (_, _) => Theme.ApplyFrame(this);
        StateChanged += (_, _) =>
        {
            _max.Content = WindowState == WindowState.Maximized ? Glyph_Restore : Glyph_Max;
            _max.ToolTip = WindowState == WindowState.Maximized ? "Restore" : "Maximize";
            Automation(_max, WindowState == WindowState.Maximized ? "Restore" : "Maximize");
            Padding = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);   // keep content on screen
        };

        // ---- title bar: title + status on the left, caption buttons on the right
        var titleBlock = new TextBlock { Text = "Lan-Line", FontSize = 14, FontWeight = FontWeights.SemiBold };
        titleBlock.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _status.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
        statusRow.Children.Add(_dot);
        statusRow.Children.Add(_status);
        statusRow.Background = Brushes.Transparent;   // hit-testable: right-click for the menu
        statusRow.ContextMenu = StatusMenu();
        statusRow.ToolTip = "Right-click for pairing and Keep on top";
        statusRow.MouseLeftButtonUp += (_, _) => { if (!_connected && !_pairing) { statusRow.ContextMenu.PlacementTarget = statusRow; statusRow.ContextMenu.IsOpen = true; } };
        WindowChrome.SetIsHitTestVisibleInChrome(statusRow, true);
        var titleStack = new StackPanel { Margin = new Thickness(16, 9, 0, 0) };
        titleStack.Children.Add(titleBlock);
        titleStack.Children.Add(statusRow);

        var min = new Button { Content = Glyph_Min, ToolTip = "Minimize" };
        var close = new Button { Content = Glyph_Close, ToolTip = "Close" };
        foreach (var b in new[] { _pin, min, _max }) b.SetResourceReference(StyleProperty, "CaptionButton");
        close.SetResourceReference(StyleProperty, "CloseButton");
        _pin.Click += (_, _) => { _pinned = !_pinned; ApplyPin(); };
        min.Click += (_, _) => WindowState = WindowState.Minimized;
        _max.Click += (_, _) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        close.Click += (_, _) => Close();
        _max.ToolTip = "Maximize";
        Automation(_pin, "Pin on top"); Automation(min, "Minimize"); Automation(_max, "Maximize"); Automation(close, "Close");
        var caption = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 6, 0) };
        foreach (var b in new[] { _pin, min, _max, close }) { WindowChrome.SetIsHitTestVisibleInChrome(b, true); caption.Children.Add(b); }

        var header = new Grid { Height = 52 };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(titleStack);
        Grid.SetColumn(caption, 1);
        header.Children.Add(caption);
        var hairline = new Border { Height = 1 };
        hairline.SetResourceReference(Border.BackgroundProperty, "Hairline");

        // ---- feed
        _scroll.Content = _feed;
        _empty = BuildEmptyState();

        // ---- composer: rounded box, placeholder, round send button (shown when there is text)
        _input.SetResourceReference(StyleProperty, "InputBox");
        TextBlock.SetLineHeight(_input, 18);
        TextBlock.SetLineStackingStrategy(_input, LineStackingStrategy.BlockLineHeight);
        _placeholder.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        Automation(_input, "Message");
        _send.SetResourceReference(StyleProperty, "SendButton");
        _send.ToolTip = "Send (Enter). Shift+Enter adds a line.";
        Automation(_send, "Send");
        _send.Click += (_, _) => SendInput();
        var field = new Grid { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 8, 0, 8) };
        field.Children.Add(_placeholder);
        field.Children.Add(_input);
        var composerRow = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(_send, Dock.Right);
        composerRow.Children.Add(_send);
        composerRow.Children.Add(field);
        var composer = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Padding = new Thickness(12, 0, 6, 0), Margin = new Thickness(12, 6, 12, 12), MinHeight = 40, Child = composerRow };
        composer.SetResourceReference(Border.BackgroundProperty, "InputFill");
        composer.SetResourceReference(Border.BorderBrushProperty, "InputStroke");
        composer.MouseLeftButtonDown += (_, _) => _input.Focus();
        _input.TextChanged += (_, _) =>
        {
            var has = !string.IsNullOrWhiteSpace(_input.Text);
            _placeholder.Visibility = _input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _send.IsEnabled = has;
            _send.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        };
        _send.Visibility = Visibility.Collapsed;

        _dropOverlay = BuildDropOverlay();

        var body = _body;
        body.Children.Add(_scroll);
        body.Children.Add(_empty);
        _composer = composer;
        _pairPanel = BuildPairPanel();
        _pairPanel.Visibility = Visibility.Collapsed;
        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(hairline, Dock.Top);
        DockPanel.SetDock(composer, Dock.Bottom);
        DockPanel.SetDock(_target, Dock.Bottom);
        _target.SetResourceReference(StyleProperty, "LinkButton");
        _target.FontSize = 11;
        _target.ToolTip = "Where Send goes: everyone, or one computer";
        _target.Click += (_, _) => { _target.ContextMenu = TargetMenu(); _target.ContextMenu.PlacementTarget = _target; _target.ContextMenu.IsOpen = true; };
        root.Children.Add(header);
        root.Children.Add(hairline);
        root.Children.Add(composer);
        root.Children.Add(_target);
        // The DockPanel's last child fills the rest of the window: the feed and the pairing panel share it
        // (only one is visible). Adding them as two children would dock the feed left at its content width.
        var center = new Grid();
        center.Children.Add(body);
        center.Children.Add(_pairPanel);   // shown instead of the feed and composer while pairing
        _settingsPanel = BuildSettingsPanel();
        _settingsPanel.Visibility = Visibility.Collapsed;
        center.Children.Add(_settingsPanel);   // shown over both until storage settings are saved once
        root.Children.Add(center);
        var layers = new Grid();
        layers.Children.Add(root);
        layers.Children.Add(_dropOverlay);
        Content = layers;

        _input.PreviewKeyDown += OnInputKey;
        CommandManager.AddPreviewCanExecuteHandler(_input, OnCanPaste);
        CommandManager.AddPreviewExecutedHandler(_input, OnPaste);
        _input.PreviewDragOver += OnDragOver;
        _input.PreviewDrop += OnDrop;
        DragEnter += OnDragEnter;
        DragLeave += (_, _) => _dropOverlay.Visibility = Visibility.Collapsed;
        DragOver += OnDragOver;
        Drop += OnDrop;
        Loaded += (_, _) => _input.Focus();

        ApplyPin();
        RefreshStatus();
        RefreshEmpty();
        if (demo) return;

        _args = args;
        PreviewKeyDown += OnWindowKey;
        Closed += (_, _) => StopAll();
        Boot();
    }

    static string? Arg(string[] a, string f) { var i = Array.IndexOf(a, f); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }
    internal static void Automation(DependencyObject o, string name) => System.Windows.Automation.AutomationProperties.SetName(o, name);

    /// <summary>Called when the Windows theme changes.</summary>
    public void ThemeChanged() => Theme.ApplyFrame(this);

    // ---------- status, pin, empty state

    /// <summary>--demo-multi: three paired computers, captions and a "✓ 1/2" row (no network).</summary>
    internal void SetDemoMulti(IEnumerable<(Item Item, string Caption)> rows)
    {
        _partners.Clear();
        _partners.AddRange([new PartnerInfo("mac", "MacBook Pro", true), new PartnerInfo("intel", "Intel Mac", false)]);
        _connected = true;
        foreach (var (i, c) in rows) Upsert(i, c);
        RefreshStatus();
    }

    internal void SetDemo(string peer, IEnumerable<Item> items)
    {
        _connected = true; _peer = peer;
        foreach (var i in items) Upsert(i);
        RefreshStatus();
    }

    void RefreshStatus()
    {
        _dot.SetResourceReference(Shape.FillProperty, _connected ? "Green" : "IdleDot");
        _status.Text = _pairing ? (_connected ? $"Paired with {_peer}" : "Not paired yet")
            : _connected && Multi ? $"Connected · {_partners.Count(p => p.Up)} of {_partners.Count}"
            : _connected ? $"Connected · {(_peer.Length > 0 ? _peer : "partner")}" : _statusText;
        _status.ToolTip = Multi ? string.Join("\n", _partners.Select(p => $"{p.Name}: {(p.Up ? "connected" : "not connected")}")) : null;
        _placeholder.Text = Multi ? $"Message {(_sendTarget == null ? "everyone" : TargetLabel)}" : $"Message {PeerLabel}";
        // The chevron is an icon-font glyph (private use area): the UI font has no such character and draws a box.
        var to = new TextBlock();
        to.Inlines.Add(new System.Windows.Documents.Run($"To: {TargetLabel} "));
        to.Inlines.Add(new System.Windows.Documents.Run("\uE70D") { FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 9 });
        _target.Content = to;
        _target.Visibility = Multi && !_pairing && _composer.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        System.Windows.Automation.AutomationProperties.SetName(_target, $"Send to {TargetLabel}");
        System.Windows.Automation.AutomationProperties.SetName(_status, $"Status: {_status.Text}");
    }

    /// <summary>"To: Everyone ⌄": Everyone (the default) or one paired computer.</summary>
    ContextMenu TargetMenu()
    {
        var m = new ContextMenu();
        var all = new MenuItem { Header = "Everyone", IsCheckable = true, IsChecked = _sendTarget == null };
        all.Click += (_, _) => { _sendTarget = null; RefreshStatus(); };
        m.Items.Add(all);
        m.Items.Add(new Separator());
        foreach (var p in _partners)
        {
            var id = p.Id;
            var mi = new MenuItem { Header = p.Up ? p.Name : $"{p.Name} (not connected)", IsCheckable = true, IsChecked = _sendTarget == id };
            mi.Click += (_, _) => { _sendTarget = id; RefreshStatus(); };
            m.Items.Add(mi);
        }
        return m;
    }

    void ApplyPin()
    {
        Topmost = _pinned;
        _pin.Content = _pinned ? Glyph_Pin : Glyph_Unpin;
        _pin.SetResourceReference(ForegroundProperty, _pinned ? "PinOn" : "Icon");
        _pin.ToolTip = _pinned ? "Pinned on top. Click to unpin." : "Keep Lan-Line on top";
        Automation(_pin, _pinned ? "Unpin" : "Pin on top");
    }

    void RefreshEmpty() => _empty.Visibility = _feed.Children.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    FrameworkElement BuildEmptyState()
    {
        var panel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false, Margin = new Thickness(24) };
        panel.Children.Add(Mark(15));
        var t1 = new TextBlock { Text = "Drop here. Grab there.", FontSize = 14, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
        t1.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        var t2 = new TextBlock { FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        t2.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        t2.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(TextBlock.Text)) { Source = _placeholder, Converter = new HintConverter() });
        panel.Children.Add(t1);
        panel.Children.Add(t2);
        return panel;
    }

    sealed class HintConverter : System.Windows.Data.IValueConverter
    {
        public object Convert(object v, Type t, object p, System.Globalization.CultureInfo c) =>
            $"Type, paste or drop files to send them to {((string)v).Replace("Message ", "")}.";
        public object ConvertBack(object v, Type t, object p, System.Globalization.CultureInfo c) => throw new NotSupportedException();
    }

    /// <summary>The Lan-Line mark: two rounded squares joined by a short line.</summary>
    internal static FrameworkElement Mark(double size)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        Rectangle Box(double opacity)
        {
            var r = new Rectangle { Width = size, Height = size, RadiusX = size * 0.28, RadiusY = size * 0.28, StrokeThickness = Math.Max(1.5, size * 0.11), Opacity = opacity };
            r.SetResourceReference(Shape.StrokeProperty, "Text2");
            return r;
        }
        var line = new Rectangle { Width = size * 0.45, Height = Math.Max(1.5, size * 0.11), VerticalAlignment = VerticalAlignment.Center };
        line.SetResourceReference(Shape.FillProperty, "Text2");
        sp.Children.Add(Box(1)); sp.Children.Add(line); sp.Children.Add(Box(0.55));
        return sp;
    }

    Grid BuildDropOverlay()
    {
        var g = new Grid { Visibility = Visibility.Collapsed, IsHitTestVisible = false };
        var r = new Rectangle { RadiusX = 14, RadiusY = 14, StrokeThickness = 2, StrokeDashArray = [4, 3], Margin = new Thickness(8) };
        r.SetResourceReference(Shape.StrokeProperty, "Accent");
        r.SetResourceReference(Shape.FillProperty, "DropFill");
        var icon = new TextBlock { Text = Glyph_Upload, FontSize = 22, HorizontalAlignment = HorizontalAlignment.Center, FontFamily = (FontFamily)Application.Current.Resources["IconFont"] };
        var text = new TextBlock { Text = "Drop to send", FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
        icon.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        text.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        label.Children.Add(icon);
        label.Children.Add(text);
        g.Children.Add(r);
        g.Children.Add(label);
        return g;
    }

    // ---------- session events

    void Handle(HubEvent e)
    {
        PartnerEvent(e);
        switch (e)
        {
            case HubEvent.Listening: if (!_connected) _statusText = _partners.Count == 0 ? "Not paired yet" : $"Waiting for {Away}…"; break;
            case HubEvent.UpdateAvailable ua: RememberLatest(ua.Version, ua.Url); ShowUpdate(ua.Version, ua.Url); break;
            case HubEvent.Connected c:
                SetUp(c.Partner, true, c.Name);
                if (_partners.Count == 1) _peer = c.Name;
                break;
            case HubEvent.Disconnected d:
                SetUp(d.Partner, false, null);
                if (!_connected) _statusText = "Reconnecting…";
                break;
            case HubEvent.Status s: if (!_connected) _statusText = StatusLine(s.Text, s.Partner.Length == 0 ? Away : NameOf(s.Partner)); break;
            case HubEvent.Received r:
                Upsert(r.Item, Multi ? $"from {NameOf(r.Partner)}" : null);
                if (r.Item.IsFile && r.Item.Path is { } rp) LogReceived(rp, r.Item.Size);
                PopUp();
                break;
            case HubEvent.Outgoing o: UpsertOutgoing(o.Item); break;
            case HubEvent.ReceiveFailed f: Note($"Couldn't receive {f.Name}{(Multi ? $" from {NameOf(f.Partner)}" : "")}: {f.Reason}"); PopUp(); break;
            case HubEvent.Error err: if (!_pairing) Note(err.Message); break;
        }
        RefreshStatus();
    }

    void SetUp(string id, bool up, string? name)
    {
        var i = _partners.FindIndex(p => p.Id == id);
        if (i >= 0) _partners[i] = _partners[i] with { Up = up, Name = name ?? _partners[i].Name };
        _connected = _partners.Any(p => p.Up);
    }

    /// <summary>The row for an outgoing item: one row for everyone, "to everyone · ✓ 2/3" until all have it.</summary>
    void UpsertOutgoing(HubItem h)
    {
        var item = h.Item with { State = h.Summary };
        var label = Multi ? (h.Total > 1 ? "to everyone" : h.To.Length == 1 ? $"to {NameOf(h.To[0])}" : null) : null;
        var caption = label == null ? null : h.Total > 1 && h.Summary.Kind != ItemStateKind.Delivered ? $"{label} · ✓ {h.Delivered}/{h.Total}" : label;
        Upsert(item, caption);
    }

    /// <summary>Something arrived: bring the window back even if it was minimized or behind others.</summary>
    void PopUp()
    {
        // WindowState = Normal restores with SW_RESTORE, which also activates the window and takes the
        // keyboard from whatever the user is typing in. SW_SHOWNOACTIVATE restores it without activating;
        // WPF picks the new state up from WM_SIZE. (Windows session fix, test 14.)
        if (WindowState == WindowState.Minimized)
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            if (hwnd != IntPtr.Zero) ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            else WindowState = WindowState.Normal;
        }
        if (!IsVisible) { ShowActivated = false; Show(); }
        if (!Topmost) { Topmost = true; Topmost = false; }   // raise without stealing the keyboard
    }

    const int SW_SHOWNOACTIVATE = 4;
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);

    // ---------- feed

    void Upsert(Item item, string? caption = null)
    {
        if (_rows.TryGetValue(item.Id, out var row)) { row.Update(item); if (caption != null) row.SetCaption(caption); return; }
        row = new ItemRow(item, this);
        row.SetCaption(caption);
        _rows[item.Id] = row;
        Append(row.View);
    }

    /// <summary>A passing remark that removes itself after a few seconds.</summary>
    void Note(string s, double fadeAfter)
    {
        Note(s);
        var row = _feed.Children[^1];
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(fadeAfter) };
        t.Tick += (_, _) => { t.Stop(); _feed.Children.Remove(row); RefreshEmpty(); };
        t.Start();
    }

    FrameworkElement? _updateRow;

    /// <summary>One quiet, dismissible "Lan-Line X is available · Download ×" row. It opens the release page in the
    /// browser; Lan-Line never downloads anything itself. A newer notice replaces an older one.</summary>
    void ShowUpdate(string version, string url)
    {
        if (!Updates.IsAllowedUrl(url)) return;
        if (_updateRow != null) _feed.Children.Remove(_updateRow);
        var text = new TextBlock { Text = $"Lan-Line {version} is available", FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var dl = new Button { Content = "Download", FontSize = 11, Margin = new Thickness(8, 0, 0, 0), ToolTip = url };
        dl.SetResourceReference(StyleProperty, "LinkButton");
        dl.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
        var x = new Button { Content = Glyph_Close, FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 9, Margin = new Thickness(8, 0, 0, 0), ToolTip = "Dismiss" };
        x.SetResourceReference(StyleProperty, "LinkButton");
        System.Windows.Automation.AutomationProperties.SetName(x, "Dismiss update notice");
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 6) };
        row.Children.Add(text); row.Children.Add(dl); row.Children.Add(x);
        x.Click += (_, _) => { _feed.Children.Remove(row); _updateRow = null; RefreshEmpty(); };
        _updateRow = row;
        Append(row);
    }

    void Note(string s)
    {
        var t = new TextBlock { Text = s, FontSize = 11, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 2, 0, 6) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        Append(t);
    }

    void Append(FrameworkElement v)
    {
        _feed.Children.Add(v);
        while (_feed.Children.Count > MaxRows)
        {
            if (_feed.Children[0] is FrameworkElement { Tag: string id }) _rows.Remove(id);
            _feed.Children.RemoveAt(0);
        }
        RefreshEmpty();
        _scroll.ScrollToEnd();
    }

    internal bool IsOwn(string path) =>
        _rows.Values.Any(r => r.Path is { } p && string.Equals(System.IO.Path.GetFullPath(p), System.IO.Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase));

    // ---------- sending

    void SendInput()
    {
        var t = _input.Text;
        if (string.IsNullOrWhiteSpace(t) || _hub == null || _partners.Count == 0) return;
        UpsertOutgoing(_hub.SendText(t, _sendTarget));
        _input.Clear();
    }

    void SendFiles(IEnumerable<string> paths)
    {
        if (_hub == null || _pairing) return;
        if (_partners.Count == 0) { Note("Not paired yet: nothing was sent"); return; }
        foreach (var p in paths)
        {
            if (IsOwn(p)) continue;
            if (Directory.Exists(p))
            {
                var skipped = Session.ScanFolder(p).Skipped;
                UpsertOutgoing(_hub.SendFolder(p, _sendTarget));
                if (skipped > 0) Note($"{System.IO.Path.GetFileName(System.IO.Path.TrimEndingDirectorySeparator(p))}: {skipped} shortcut{(skipped == 1 ? "" : "s")} (links) left out");
                continue;
            }
            if (File.Exists(p)) UpsertOutgoing(_hub.SendFile(p, _sendTarget));
        }
    }

    void OnInputKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0) { e.Handled = true; SendInput(); }
    }

    static bool ClipboardHasSendable() => Clipboard.ContainsFileDropList() || (Clipboard.ContainsImage() && !Clipboard.ContainsText());

    void OnCanPaste(object sender, CanExecuteRoutedEventArgs e)
    {
        if (e.Command == ApplicationCommands.Paste && ClipboardHasSendable()) { e.CanExecute = true; e.Handled = true; }
    }

    void OnPaste(object sender, ExecutedRoutedEventArgs e)
    {
        if (e.Command != ApplicationCommands.Paste) return;
        if (Clipboard.ContainsFileDropList())
        {
            e.Handled = true;
            SendFiles(Clipboard.GetFileDropList().Cast<string>());
        }
        else if (Clipboard.ContainsImage() && !Clipboard.ContainsText() && Clipboard.GetImage() is { } img)
        {
            e.Handled = true;
            var dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Lan-Line-pasted");
            Directory.CreateDirectory(dir);
            var path = Names.Unique($"pasted-{DateTime.Now:yyyyMMdd-HHmmss}.png", dir);
            using (var fs = File.Create(path))
            {
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(img));
                enc.Save(fs);
            }
            SendFiles([path]);
        }
    }

    void OnDragEnter(object sender, DragEventArgs e)
    {
        if (!_draggingOwnChip && !_pairing && e.Data.GetDataPresent(DataFormats.FileDrop)) _dropOverlay.Visibility = Visibility.Visible;
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (!_draggingOwnChip && e.Data.GetDataPresent(DataFormats.FileDrop)) { e.Effects = DragDropEffects.Copy; e.Handled = true; }
        else e.Effects = DragDropEffects.None;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        _dropOverlay.Visibility = Visibility.Collapsed;
        if (_draggingOwnChip || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Handled = true;
        SendFiles((string[])e.Data.GetData(DataFormats.FileDrop));
    }

    internal void DragOut(DependencyObject source, string path)
    {
        _draggingOwnChip = true;
        try { DragDrop.DoDragDrop(source, new DataObject(DataFormats.FileDrop, new[] { path }), DragDropEffects.Copy); }
        finally { _draggingOwnChip = false; }
    }
}
