using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Ferry.Core;

namespace Ferry.App;

/// <summary>First run and "Pair with another computer": show a code here, or type the other computer's code.</summary>
sealed partial class MainWindow
{
    string[] _args = [];
    bool _pairing, _showMode, _pairBusy, _searching;
    FerryConfig? _config;    // the saved pairing, if any
    FerryConfig? _pending;   // a pairing being tried, saved once it connects
    DiscoveryResponder? _responder;
    DispatcherTimer? _pairTimeout, _rediscover;
    string _code = "";
    List<DiscoveredPeer> _found = [];

    // pairing panel parts
    readonly TextBlock _pairSub = new() { FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 12) };
    readonly StackPanel _showPart = new(), _enterPart = new(), _peerList = new();
    readonly TextBlock _codeText = new() { FontSize = 24, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _myName = new() { FontSize = 12, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
    readonly TextBlock _myAddr = new() { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _noneFound = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Text = "None found. Type the address the other computer shows.", Margin = new Thickness(0, 0, 0, 6) };
    readonly TextBox _addrBox = new(), _codeBox = new();
    readonly Button _pairBtn = new() { Content = "Pair", Margin = new Thickness(0, 4, 0, 0) };
    readonly Button _searchBtn = new() { Content = "\uE72C", ToolTip = "Search again" };
    readonly TextBlock _pairErr = new() { FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0), Visibility = Visibility.Collapsed };
    readonly Button _cancelLink = new() { Content = "Cancel" }, _switchLink = new();

    int Port => int.TryParse(Arg(_args, "--port"), out var p) ? p : _config?.Port ?? 47830;
    string ConfigPath => Arg(_args, "--config") ?? FerryConfig.DefaultPath;
    static string MyName => Environment.MachineName;

    void Boot()
    {
        FerryConfig? cfg = null;
        try { cfg = FerryConfig.Load(ConfigPath); } catch (Exception) { }
        if (cfg != null || Arg(_args, "--connect") != null || _args.Contains("--listen"))
            Run(cfg ?? new FerryConfig());
        else
            BeginPairing(show: false);   // a PC types the code by default; it can switch
    }

    /// <summary>Normal operation with a saved pairing.</summary>
    void Run(FerryConfig cfg)
    {
        StopAll();
        _config = cfg;
        SetPairing(false);
        _peer = cfg.Peer ?? "";
        _statusText = "Starting…";
        StartSession(cfg);
        if (Listens(cfg)) TryRespond(cfg.Token);
        else
        {
            // If the partner's address changes (DHCP), find it again by its pair id.
            _rediscover = new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
            _rediscover.Tick += async (_, _) => await FindMovedPartner();
            _rediscover.Start();
        }
        RefreshStatus();
    }

    bool Listens(FerryConfig cfg) => _args.Contains("--listen") || (Arg(_args, "--connect") == null && cfg.Listens);

    void StartSession(FerryConfig cfg)
    {
        Role role = Listens(cfg) ? new Role.Listen(Port) : new Role.Dial(Arg(_args, "--connect")?.Split(',') ?? cfg.Hosts, Port);
        var config = new SessionConfig { Token = cfg.Token, Name = MyName, DownloadDir = Arg(_args, "--downloads") ?? FerryConfig.DownloadsDir };
        // The one UI-thread hop: the Session calls this on its own queue thread.
        _session = new Session(role, config, e => Dispatcher.BeginInvoke(() => Handle(e)));
        _session.Start();
    }

    void TryRespond(string token)
    {
        try { _responder = new DiscoveryResponder(Port, MyName, PairCode.PairId(token)); }
        catch (Exception) { if (_pairing) ShowPairError("Other computers can't find this one automatically; type its address there."); }
    }

    /// <summary>Called on every connect: keeps a new pairing, and remembers the partner's name.</summary>
    void Paired(string name)
    {
        if (_pending is { } p)
        {
            _pending = null;
            _pairTimeout?.Stop();
            p.Peer = name;
            Save(p);
            _config = p;
            _pairBusy = false;
            SetPairing(false);
            if (p.Listens && _responder == null) TryRespond(p.Token);
        }
        else if (_config is { } c && c.Peer != name)
        {
            c.Peer = name;
            Save(c);
        }
    }

    void Save(FerryConfig c)
    {
        try { c.Save(ConfigPath); } catch (Exception e) { Note($"Couldn't save the pairing: {e.Message}"); }
    }

    void StopAll()
    {
        _session?.Dispose(); _session = null;
        _responder?.Dispose(); _responder = null;
        _pairTimeout?.Stop(); _pairTimeout = null;
        _rediscover?.Stop(); _rediscover = null;
        _connected = false;
    }

    void BeginPairing(bool show)
    {
        StopAll();
        _pending = null;
        _showMode = show;
        _pairBusy = false;
        _peer = "";
        HidePairError();
        SetPairing(true);
        if (Height < 440)   // the pairing screen needs a little more room than the feed
        {
            var grow = 440 - Height;
            Height = 440;
            Top = Math.Max(SystemParameters.WorkArea.Top + 8, Top - grow);
        }
        if (show)
        {
            _code = PairCode.Generate();
            var cfg = new FerryConfig { Port = Port, Token = _code, Role = "listen" };
            _pending = cfg;
            StartSession(cfg);
            TryRespond(_code);
        }
        else _ = Search();
        RefreshPairPanel();
    }

    async Task Search()
    {
        _searching = true; RefreshPairPanel();
        _found = await Discovery.SearchAsync(Port);
        _searching = false;
        if (_addrBox.Text.Length == 0 && _found.Count == 1) _addrBox.Text = _found[0].Host;
        RefreshPairPanel();
    }

    void TryConnect()
    {
        var host = _addrBox.Text.Trim();
        if (host.Length == 0) { ShowPairError("Pick a computer above or type its address."); return; }
        if (PairCode.Normalize(_codeBox.Text) is not { } code) { ShowPairError("The code is 10 letters and numbers, like 7QK4M-2XH9C."); return; }
        StopAll();
        HidePairError();
        _pairBusy = true;
        var cfg = new FerryConfig { Port = Port, Token = code, Hosts = [host], Role = "connect" };
        _pending = cfg;
        StartSession(cfg);
        _pairTimeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        _pairTimeout.Tick += (_, _) =>
        {
            _pairTimeout?.Stop();
            if (_pending == null) return;
            StopAll();
            _pending = null;
            _pairBusy = false;
            ShowPairError($"Couldn't pair. Check the code, and that Lan-Line is open on {host}.");
            RefreshPairPanel();
        };
        _pairTimeout.Start();
        RefreshPairPanel();
    }

    async Task FindMovedPartner()
    {
        if (_config is not { } c || Listens(c) || _connected || _pairing) return;
        var want = PairCode.PairId(c.Token);
        var peers = await Discovery.SearchAsync(c.Port);
        if (peers.FirstOrDefault(x => x.PairId == want) is not { } p || c.Hosts.Contains(p.Host) || _config != c || _connected) return;
        c.Hosts = [p.Host, .. c.Hosts.Take(3)];
        Save(c);
        Run(c);
    }

    void SetPairing(bool on)
    {
        _pairing = on;
        _pairPanel.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _body.Visibility = _composer.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        _cancelLink.Visibility = on && _config != null ? Visibility.Visible : Visibility.Collapsed;
        RefreshStatus();
        if (!on) _input.Focus();
    }

    void ShowPairError(string s) { _pairErr.Text = s; _pairErr.Visibility = Visibility.Visible; }
    void HidePairError() => _pairErr.Visibility = Visibility.Collapsed;

    void OnWindowKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.P && Keyboard.Modifiers == ModifierKeys.Control) { _pinned = !_pinned; ApplyPin(); e.Handled = true; }
    }

    /// <summary>The status line's menu (right-click, or click while not connected).</summary>
    ContextMenu StatusMenu()
    {
        var m = new ContextMenu();
        var pair = new MenuItem { Header = "Pair with another computer…" };
        pair.Click += (_, _) => BeginPairing(show: false);
        var pin = new MenuItem { Header = "Keep on top", InputGestureText = "Ctrl+P", IsCheckable = true };
        m.Opened += (_, _) => pin.IsChecked = _pinned;
        pin.Click += (_, _) => { _pinned = !_pinned; ApplyPin(); };
        m.Items.Add(pair);
        m.Items.Add(pin);
        return m;
    }

    // ---------- panel

    FrameworkElement BuildPairPanel()
    {
        var col = new StackPanel { Margin = new Thickness(22, 16, 22, 16) };
        col.Children.Add(Mark(15));
        var title = new TextBlock { Text = "Pair with your other computer", FontSize = 15, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _pairSub.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(title);
        col.Children.Add(_pairSub);

        // show a code
        var mono = new FontFamily("Cascadia Mono, Consolas");
        _codeText.FontFamily = mono;
        _codeText.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        var copy = new Button { Content = MainWindow.Glyph_Copy, ToolTip = "Copy the code", Margin = new Thickness(10, 0, 0, 0) };
        copy.SetResourceReference(StyleProperty, "IconButton");
        copy.Click += (_, _) => { try { Clipboard.SetText(PairCode.Display(_code)); copy.Content = MainWindow.Glyph_Check; } catch (Exception) { } };
        Automation(copy, "Copy code");
        var codeRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        codeRow.Children.Add(_codeText);
        codeRow.Children.Add(copy);
        var codeBox = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(16, 9, 12, 9), HorizontalAlignment = HorizontalAlignment.Center, Child = codeRow };
        codeBox.SetResourceReference(Border.BackgroundProperty, "CardFill");
        codeBox.SetResourceReference(Border.BorderBrushProperty, "CardStroke");
        _myName.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _myAddr.FontFamily = mono;
        _myAddr.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var waiting = new TextBlock { Text = "Waiting for the other computer…", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
        waiting.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        _showPart.Children.Add(codeBox);
        _showPart.Children.Add(_myName);
        _showPart.Children.Add(_myAddr);
        _showPart.Children.Add(waiting);

        // enter a code
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var onNet = new TextBlock { Text = "On your network", FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        onNet.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        _searchBtn.SetResourceReference(StyleProperty, "IconButton");
        _searchBtn.Click += async (_, _) => await Search();
        Automation(_searchBtn, "Search again");
        DockPanel.SetDock(_searchBtn, Dock.Right);
        head.Children.Add(_searchBtn);
        head.Children.Add(onNet);
        _noneFound.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        _enterPart.Children.Add(head);
        _enterPart.Children.Add(_noneFound);
        _enterPart.Children.Add(_peerList);
        _enterPart.Children.Add(Field("Address", _addrBox, mono, "192.168.1.20"));
        _enterPart.Children.Add(Field("Code", _codeBox, mono, "XXXXX-XXXXX"));
        _codeBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; TryConnect(); } };
        _addrBox.TextChanged += (_, _) => RefreshPeerList();
        _pairBtn.SetResourceReference(StyleProperty, "PrimaryButton");
        _pairBtn.Click += (_, _) => TryConnect();
        _enterPart.Children.Add(_pairBtn);

        col.Children.Add(_showPart);
        col.Children.Add(_enterPart);
        _pairErr.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
        col.Children.Add(_pairErr);

        var links = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) };
        foreach (var l in new[] { _cancelLink, _switchLink }) { l.SetResourceReference(StyleProperty, "LinkButton"); links.Children.Add(l); }
        _cancelLink.Click += (_, _) => { if (_config is { } c) Run(c); };
        _switchLink.Click += (_, _) => BeginPairing(!_showMode);
        col.Children.Add(links);

        var sv = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = col };
        return sv;
    }

    static Border Field(string label, TextBox box, FontFamily mono, string hint)
    {
        var l = new TextBlock { Text = label, FontSize = 12, Width = 56, VerticalAlignment = VerticalAlignment.Center };
        l.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        box.SetResourceReference(StyleProperty, "InputBox");
        box.FontFamily = mono;
        box.FontSize = 13;
        box.VerticalAlignment = VerticalAlignment.Center;
        box.ToolTip = hint;
        Automation(box, label);
        var g = new DockPanel();
        DockPanel.SetDock(l, Dock.Left);
        g.Children.Add(l);
        g.Children.Add(box);
        var b = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Padding = new Thickness(12, 0, 10, 0), Height = 36, Margin = new Thickness(0, 0, 0, 8), Child = g };
        b.SetResourceReference(Border.BackgroundProperty, "InputFill");
        b.SetResourceReference(Border.BorderBrushProperty, "InputStroke");
        b.MouseLeftButtonDown += (_, _) => box.Focus();
        return b;
    }

    void RefreshPairPanel()
    {
        _pairSub.Text = _showMode
            ? "Open Lan-Line on the other computer, pick this one, and type this code."
            : "Pick the computer that shows a code, then type it here.";
        _showPart.Visibility = _showMode ? Visibility.Visible : Visibility.Collapsed;
        _enterPart.Visibility = _showMode ? Visibility.Collapsed : Visibility.Visible;
        _switchLink.Content = _showMode ? "Enter a code instead" : "Show a code instead";
        _codeText.Text = PairCode.Display(_code);
        Automation(_codeText, "Pairing code " + string.Join(" ", _code.ToCharArray()));
        _myName.Text = MyName;
        var addrs = Discovery.LocalAddresses();
        _myAddr.Text = addrs.FirstOrDefault() ?? "";
        _searchBtn.IsEnabled = !_searching;
        _noneFound.Visibility = _found.Count == 0 && !_searching ? Visibility.Visible : Visibility.Collapsed;
        _pairBtn.IsEnabled = !_pairBusy;
        _pairBtn.Content = _pairBusy ? "Pairing…" : "Pair";
        RefreshPeerList();
    }

    void RefreshPeerList()
    {
        _peerList.Children.Clear();
        foreach (var peer in _found)
        {
            var chosen = _addrBox.Text.Trim() == peer.Host;
            var icon = new TextBlock { Text = chosen ? "\uE73E" : "\uE7F4", FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 12, Width = 20, VerticalAlignment = VerticalAlignment.Center };
            icon.SetResourceReference(TextBlock.ForegroundProperty, chosen ? "Accent" : "Icon");
            var name = new TextBlock { Text = peer.Name, FontSize = 12.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            name.SetResourceReference(TextBlock.ForegroundProperty, "Text");
            var addr = new TextBlock { Text = peer.Host, FontSize = 12, FontFamily = new FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
            addr.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            var row = new DockPanel();
            DockPanel.SetDock(icon, Dock.Left);
            DockPanel.SetDock(addr, Dock.Right);
            row.Children.Add(icon); row.Children.Add(addr); row.Children.Add(name);
            var b = new Button { Content = row };
            b.SetResourceReference(StyleProperty, "PeerButton");
            b.SetResourceReference(BackgroundProperty, chosen ? "DropFill" : "CardFill");
            b.SetResourceReference(BorderBrushProperty, chosen ? "Accent" : "CardStroke");
            b.Click += (_, _) => { _addrBox.Text = peer.Host; _codeBox.Focus(); };
            Automation(b, $"{peer.Name}, {peer.Host}");
            _peerList.Children.Add(b);
        }
    }

    /// <summary>--demo-pair show|enter: the pairing screen with sample values (screenshots).</summary>
    internal void DemoPair(string mode)
    {
        _showMode = mode != "enter";
        _code = "7QK4M2XH9C";
        if (!_showMode)
        {
            _found = [new DiscoveredPeer("MacBook Pro", "192.168.1.20", 47830, "0")];
            _addrBox.Text = "192.168.1.20";
            _codeBox.Text = "7QK4M-2XH9C";
        }
        Height = 440;
        SetPairing(true);
        RefreshPairPanel();
    }
}
