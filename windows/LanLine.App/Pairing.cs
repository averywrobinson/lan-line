using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LanLine.Core;

namespace LanLine.App;

/// <summary>First run and "Pair with another computer": show a code here, or type the other computer's code.</summary>
sealed partial class MainWindow
{
    string[] _args = [];
    bool _pairing, _showMode, _pairBusy, _searching;
    PairingBook _book = new(new DeviceConfig());   // saved partners plus the pairing in progress; every Hub event goes through it
    DeviceConfig _device => _book.Config;
    Hub? _hub;
    internal readonly List<PartnerInfo> _partners = [];
    internal string? _sendTarget;   // null = everyone
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

    int Port => int.TryParse(Arg(_args, "--port"), out var p) ? p : _device.Port;
    string ConfigPath => Arg(_args, "--config") ?? LanLineConfig.DefaultPath;
    /// <summary>Items still waiting for a partner (beta.11), kept so a restart doesn't drop them.</summary>
    string OutboxFile => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(ConfigPath)!, "outbox.json");
    /// <summary>Pasted pictures wait here to be sent, beside the outbox rather than in %TEMP% (which Storage Sense may empty);
    /// what nothing waits for is tidied after 7 days (the feed shows them).</summary>
    string PastedDir => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(ConfigPath)!, "Pasted");
    static string MyName => Environment.MachineName;

    void Boot()
    {
        DeviceConfig loaded;
        try { loaded = DeviceConfig.Load(ConfigPath, "connect"); } catch (Exception) { loaded = new DeviceConfig(); }
        _book = new PairingBook(loaded);
        if (Arg(_args, "--connect") is { } host && _device.Peers.Count == 0)   // flags win (tests)
            try { var legacy = LanLineConfig.Load(ConfigPath); _device.Peers.Add(new Partner { Id = "legacy", Name = legacy.Peer ?? host, Secret = legacy.Token, Role = "connect", Hosts = [host] }); } catch (Exception) { }
        Save();
        StartHub();
        if (_device.Peers.Count == 0) BeginPairing(show: false);   // a PC types the code by default; it can switch
        SetUpStorage();
        ApplyHistory();
        ApplyDownloads();
        ApplyEdgeDrop();
    }

    /// <summary>One Hub for all partners: it listens for those that dial us, dials those we dial, answers discovery.</summary>
    void StartHub()
    {
        var hc = new HubConfig
        {
            Name = MyName, DeviceId = _device.DeviceId, DownloadDir = Arg(_args, "--downloads") ?? LanLineConfig.DownloadsDir, Port = Port,
            AppVersion = MyVersion, LatestKnown = SavedLatest(), Advertise = [.. Discovery.LocalAddresses()],
            OutboxPath = OutboxFile,
        };
        Outbox.SweepUnsent(PastedDir, OutboxFile, TimeSpan.FromDays(7));   // the feed's thumbnails use these too
        // The one UI-thread hop: the Hub calls this on its own queue thread.
        _hub = new Hub(hc, _device.Peers, e => Dispatcher.BeginInvoke(() => Handle(e)));
        _partners.Clear();
        _partners.AddRange(_device.Peers.Select(p => new PartnerInfo(p.Id, p.Name)));
        _statusText = _device.Peers.Count == 0 ? "Not paired yet" : "Starting…";
        _hub.Start();
        _hub.StartResponder();
        // Partners we dial that moved (DHCP) are found again by pair id or device id.
        _rediscover = new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
        _rediscover.Tick += async (_, _) => { if (_hub != null) await _hub.FindMoved(); };
        _rediscover.Start();
        RefreshStatus();
    }

    /// <summary>Carry out what the PairingBook decided, in order.</summary>
    void Apply(PairingBook.Effect f)
    {
        switch (f)
        {
            case PairingBook.Effect.Save: Save(); break;
            case PairingBook.Effect.HubRemove rm:
                _hub?.Remove(rm.Id); _partners.RemoveAll(x => x.Id == rm.Id);
                if (_sendTarget == rm.Id) _sendTarget = null;
                break;
            case PairingBook.Effect.HubRename rn: _hub?.Rename(rn.Old, rn.New); break;
            case PairingBook.Effect.RenamedLocally rl:
                var i = _partners.FindIndex(x => x.Id == rl.Old);
                if (i >= 0) _partners[i] = _partners[i] with { Id = rl.New };
                if (_sendTarget == rl.Old) _sendTarget = rl.New;
                break;
            case PairingBook.Effect.Finished fin: FinishPairing(fin.Partner); break;
        }
    }

    void Save()
    {
        try { _device.Save(ConfigPath); } catch (Exception e) { Note($"Couldn't save the pairing: {e.Message}"); }
    }

    void StopAll()
    {
        _hub?.Dispose(); _hub = null;
        _pairTimeout?.Stop(); _pairTimeout = null;
        _rediscover?.Stop(); _rediscover = null;
        _connected = false;
    }

    // ---------- pairing adds a partner; the others stay connected

    void BeginPairing(bool show)
    {
        if (_book.Cancel() is { } old) { _hub?.Remove(old); _partners.RemoveAll(x => x.Id == old); }
        _pairTimeout?.Stop();
        _showMode = show;
        _pairBusy = false;
        HidePairError();
        SetPairing(true);
        if (Height < 440)   // the pairing screen needs a little more room than the feed
        {
            var grow = 440 - Height;
            Height = 440;
            Top = Math.Max(SystemParameters.WorkArea.Top + 8, Top - grow);
        }
        if (_device.Peers.Count >= DeviceConfig.MaxPartners)
        {
            ShowPairError($"Lan-Line pairs with up to {DeviceConfig.MaxPartners} computers. Forget one in Settings first.");
            RefreshPairPanel();
            return;
        }
        if (show)
        {
            _code = PairCode.Generate();
            var pending = new Partner { Id = "pairing-" + Guid.NewGuid().ToString("N")[..8], Name = "New computer", Secret = _code, Role = "listen" };
            _book.Begin(pending);
            _hub?.Add(pending, pairing: true);   // the hub's responder now also answers for this code
        }
        else _ = Search();
        RefreshPairPanel();
    }

    void CancelPairing()
    {
        if (_book.Cancel() is { } id) _hub?.Remove(id);
        _pairTimeout?.Stop();
        _pairBusy = false;
        SetPairing(false);
    }

    /// <summary>The PairingBook saved the new partner: show it and leave the pairing screen.</summary>
    void FinishPairing(Partner p)
    {
        _pairTimeout?.Stop();
        var i = _partners.FindIndex(x => x.Id == p.Id);
        if (i >= 0) _partners[i] = _partners[i] with { Name = p.Name, Up = true }; else _partners.Add(new PartnerInfo(p.Id, p.Name, true));
        _pairBusy = false;
        SetPairing(false);
        MaybeShowTour();
        if (Multi) Note($"Paired with {p.Name}. Send goes to everyone; pick one computer above the message box.", 10);
    }

    internal void RenamePartner(string id, string name)
    {
        name = name.Trim();
        if (name.Length == 0) return;
        foreach (var f in _book.Rename(id, name)) Apply(f);
        _hub?.SetName(id, name);   // a folder per computer follows the new name
        var i = _partners.FindIndex(x => x.Id == id);
        if (i >= 0) _partners[i] = _partners[i] with { Name = name.Length > 64 ? name[..64] : name };
        RefreshStatus();
    }

    internal void ForgetPartner(string id)
    {
        foreach (var f in _book.Forget(id)) Apply(f);
        _connected = _partners.Any(x => x.Up);
        if (_device.Peers.Count == 0) _statusText = "Not paired yet";
        RefreshStatus();
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
        HidePairError();
        _pairBusy = true;
        var p = new Partner { Id = "pairing-" + Guid.NewGuid().ToString("N")[..8], Name = host, Secret = code, Role = "connect", Hosts = [host] };
        _book.Begin(p);
        _hub?.Add(p, pairing: false);
        _pairTimeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        _pairTimeout.Tick += (_, _) =>
        {
            _pairTimeout?.Stop();
            if (_book.Pending is not { } q || (q.Id != p.Id && q.Id != _book.Resolve(p.Id))) return;
            _book.Cancel();
            _hub?.Remove(q.Id);
            _pairBusy = false;
            ShowPairError($"Couldn't pair. Check the code, and that Lan-Line is open on {host}.");
            RefreshPairPanel();
        };
        _pairTimeout.Start();
        RefreshPairPanel();
    }

    void SetPairing(bool on)
    {
        _pairing = on;
        ApplyScreen();
        _cancelLink.Visibility = on && _device.Peers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        RefreshStatus();
        if (!on) _input.Focus();
    }

    void ShowPairError(string s) { _pairErr.Text = s; _pairErr.Visibility = Visibility.Visible; }
    void HidePairError() => _pairErr.Visibility = Visibility.Collapsed;

    void OnWindowKey(object sender, KeyEventArgs e)
    {
        if (FeedKey(e)) { e.Handled = true; return; }   // shortcuts and the feed by keyboard (beta.10)
        if (e.Key == Key.P && Keyboard.Modifiers == ModifierKeys.Control) { _pinned = !_pinned; ApplyPin(); e.Handled = true; }
    }

    /// <summary>The status line's menu (right-click, or click while not connected).</summary>
    ContextMenu StatusMenu()
    {
        var m = new ContextMenu();
        var keys = new MenuItem { Header = "Keyboard shortcuts", InputGestureText = "Ctrl+/" };
        keys.Click += (_, _) => ShowShortcuts();
        var settings = new MenuItem { Header = "Settings…", InputGestureText = "Ctrl+," };
        settings.Click += (_, _) => ShowSettings();
        m.Items.Add(settings);
        var pair = new MenuItem { Header = "Pair with another computer…" };
        pair.Click += (_, _) => BeginPairing(show: false);
        var pin = new MenuItem { Header = "Keep on top", InputGestureText = "Ctrl+P", IsCheckable = true };
        m.Opened += (_, _) => pin.IsChecked = _pinned;
        pin.Click += (_, _) => { _pinned = !_pinned; ApplyPin(); };
        var check = new MenuItem { Header = "Check for updates…" };
        check.Click += (_, _) => _ = CheckForUpdates(manual: true);
        m.Items.Add(pair);
        m.Items.Add(pin);
        m.Items.Add(new Separator());
        var tour = new MenuItem { Header = "Welcome tour" };
        tour.Click += (_, _) => { if (_showingSettings) CloseSettings(); ShowTour(0); };
        m.Items.Add(check);
        m.Items.Add(keys);
        m.Items.Add(tour);
        return m;
    }

    // ---------- panel

    FrameworkElement BuildPairPanel()
    {
        // Design refresh (beta.10): the code, name and address sit on one card, readable over any backdrop; the
        // alternatives are quiet links beneath it.
        var page = new StackPanel { Margin = new Thickness(12, 6, 12, 14) };
        var col = new StackPanel();
        var pairCard = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(16, 18, 16, 16), Child = col };
        pairCard.SetResourceReference(Border.BackgroundProperty, "GroupFill");
        pairCard.SetResourceReference(Border.BorderBrushProperty, "GroupStroke");
        page.Children.Add(pairCard);
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
        // the QR code for the iPhone companion (beta.10), behind a link so the window stays small
        _qrBox.Child = _qrImage;
        RenderOptions.SetBitmapScalingMode(_qrImage, BitmapScalingMode.NearestNeighbor);   // crisp modules
        _qrBox.Visibility = Visibility.Collapsed;
        _qrCaption.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        _qrCaption.Visibility = Visibility.Collapsed;
        _qrLink.SetResourceReference(StyleProperty, "LinkButton");
        _qrLink.Click += (_, _) => { _showQR = !_showQR; RefreshPairPanel(); if (_showQR) Height = Math.Max(Height, 600); };
        _showPart.Children.Add(_qrBox);
        _showPart.Children.Add(_qrCaption);
        _showPart.Children.Add(codeBox);
        _showPart.Children.Add(_myName);
        _showPart.Children.Add(_myAddr);
        _showPart.Children.Add(waiting);
        _showPart.Children.Add(_qrLink);

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
        _cancelLink.Click += (_, _) => CancelPairing();
        _switchLink.Click += (_, _) => BeginPairing(!_showMode);
        var linksBack = Scrimmed(links, 9, HorizontalAlignment.Center);
        linksBack.Padding = new Thickness(6, 2, 6, 3);
        page.Children.Add(linksBack);

        var sv = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = page };
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
        var name = _demoName ?? MyName;
        _myName.Text = name;
        var addrs = _demoAddrs ?? Discovery.LocalAddresses();
        _myAddr.Text = addrs.FirstOrDefault() ?? "";
        _qrLink.Content = _showQR ? "Hide the QR code" : "Pairing an iPhone? Show a QR code";
        var link = _code.Length > 0 && addrs.Count > 0 ? new PairLink(_code, name, Port, [.. addrs]).Url : null;
        if (_showQR && link != null && link != _qrFor) { _qrImage.Source = QrBitmap(QrCode.Encode(link)); _qrFor = link; }
        _qrBox.Visibility = _qrCaption.Visibility = _showQR && link != null ? Visibility.Visible : Visibility.Collapsed;
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
    readonly Border _qrBox = new() { Background = Brushes.White, CornerRadius = new CornerRadius(10), Padding = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) };
    readonly Image _qrImage = new() { Width = 150, Height = 150, Stretch = Stretch.Fill };
    readonly TextBlock _qrCaption = new() { Text = "Scan with Lan-Line on your iPhone", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 10) };
    readonly Button _qrLink = new() { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
    bool _showQR;
    string? _qrFor;

    /// <summary>A QR matrix as a sharp bitmap (one pixel per module, scaled without smoothing), with the quiet zone.</summary>
    static System.Windows.Media.Imaging.BitmapSource QrBitmap(bool[,] q)
    {
        var n = q.GetLength(0); var side = n + 8;
        var px = new byte[side * side];
        for (var y = 0; y < side; y++) for (var x = 0; x < side; x++)
        {
            int r = y - 4, c = x - 4;
            px[y * side + x] = r >= 0 && c >= 0 && r < n && c < n && q[r, c] ? (byte)0 : (byte)255;
        }
        var bmp = System.Windows.Media.Imaging.BitmapSource.Create(side, side, 96, 96, PixelFormats.Gray8, null, px, side);
        bmp.Freeze();
        return bmp;
    }

    /// <summary>Screenshots show sample values, never this PC's real name and address.</summary>
    string? _demoName;
    List<string>? _demoAddrs;

    internal void DemoPair(string mode)
    {
        _demoName = "Studio PC";
        _demoAddrs = ["192.168.1.42"];
        _showMode = mode != "enter";
        _showQR = mode == "qr";
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
