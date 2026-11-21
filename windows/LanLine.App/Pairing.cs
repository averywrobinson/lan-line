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
    DeviceConfig _device = new();   // this computer's id and its paired computers
    Hub? _hub;
    Partner? _pendingPartner;       // a pairing being tried; added to the list once it connects
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
    static string MyName => Environment.MachineName;

    void Boot()
    {
        try { _device = DeviceConfig.Load(ConfigPath, "connect"); } catch (Exception) { _device = new DeviceConfig(); }
        if (Arg(_args, "--connect") is { } host && _device.Peers.Count == 0)   // flags win (tests)
            try { var legacy = LanLineConfig.Load(ConfigPath); _device.Peers.Add(new Partner { Id = "legacy", Name = legacy.Peer ?? host, Secret = legacy.Token, Role = "connect", Hosts = [host] }); } catch (Exception) { }
        Save();
        StartHub();
        if (_device.Peers.Count == 0) BeginPairing(show: false);   // a PC types the code by default; it can switch
        SetUpStorage();
    }

    /// <summary>One Hub for all partners: it listens for those that dial us, dials those we dial, answers discovery.</summary>
    void StartHub()
    {
        var hc = new HubConfig
        {
            Name = MyName, DeviceId = _device.DeviceId, DownloadDir = Arg(_args, "--downloads") ?? LanLineConfig.DownloadsDir, Port = Port,
            AppVersion = MyVersion, LatestKnown = SavedLatest(), Advertise = [.. Discovery.LocalAddresses()],
        };
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

    /// <summary>Hub events that change the saved pairings; the feed handles the rest.</summary>
    void PartnerEvent(HubEvent e)
    {
        switch (e)
        {
            case HubEvent.Rekeyed rk:   // the pairing code was swapped for a long-term secret
                if (_device.Partner(rk.Partner) is { } p) { _device.Add(p with { Secret = rk.Token }); Save(); }
                else if (_pendingPartner?.Id == rk.Partner) _pendingPartner = _pendingPartner with { Secret = rk.Token };
                break;
            case HubEvent.PeerAddresses pa when _device.Partner(pa.Partner) is { Connects: true } q:   // fallbacks; a moved partner's new address first
                var hosts = pa.Addrs.Length > 0 && (q.Hosts.Length == 0 || q.Hosts[0] != pa.Addrs[0])
                    ? pa.Addrs.Concat(q.Hosts) : q.Hosts.Concat(pa.Addrs);
                _device.Add(q with { Hosts = [.. hosts.Distinct(StringComparer.OrdinalIgnoreCase).Take(6)] }); Save();
                break;
            case HubEvent.PeerDevice pd when pd.Partner != pd.Device: AdoptDeviceId(pd.Partner, pd.Device); break;
            case HubEvent.Connected c:
                if (_pendingPartner?.Id == c.Partner) FinishPairing(c.Name);
                else if (_device.Partner(c.Partner) is { } k && k.Name != c.Name) { _device.Add(k with { Name = c.Name }); Save(); }
                break;
        }
    }

    /// <summary>A partner told us its device id: use it as the partner's id. If we already had a partner with that id (paired again), the new pairing replaces it.</summary>
    void AdoptDeviceId(string old, string dev)
    {
        if (_pendingPartner?.Id == old) _pendingPartner = _pendingPartner with { Id = dev };
        if (_device.Partner(dev) is { } dup && _device.Partner(old) != null)
        {
            _device.Forget(dup.Id); _hub?.Remove(dup.Id); _partners.RemoveAll(x => x.Id == dup.Id);
        }
        if (_device.Partner(old) is { } p) { _device.Forget(old); _device.Add(p with { Id = dev }); Save(); }
        var i = _partners.FindIndex(x => x.Id == old);
        if (i >= 0) _partners[i] = _partners[i] with { Id = dev };
        if (_sendTarget == old) _sendTarget = dev;
        _hub?.Rename(old, dev);
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
        if (_pendingPartner is { } old) _hub?.Remove(old.Id);
        _pendingPartner = null;
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
            _pendingPartner = new Partner { Id = "pairing-" + Guid.NewGuid().ToString("N")[..8], Name = "New computer", Secret = _code, Role = "listen" };
            _hub?.Add(_pendingPartner, pairing: true);   // the hub's responder now also answers for this code
        }
        else _ = Search();
        RefreshPairPanel();
    }

    void CancelPairing()
    {
        if (_pendingPartner is { } p) _hub?.Remove(p.Id);
        _pendingPartner = null;
        _pairTimeout?.Stop();
        _pairBusy = false;
        SetPairing(false);
    }

    void FinishPairing(string name)
    {
        if (_pendingPartner is not { } p) return;
        _pendingPartner = null;
        _pairTimeout?.Stop();
        try { _device.Add(p with { Name = name }); } catch (TooManyPartnersException) { Note($"Lan-Line pairs with up to {DeviceConfig.MaxPartners} computers."); }
        Save();
        if (!_partners.Any(x => x.Id == p.Id)) _partners.Add(new PartnerInfo(p.Id, name, true));
        _pairBusy = false;
        SetPairing(false);
        if (Multi) Note($"Paired with {name}. Send goes to everyone; pick one computer above the message box.", 10);
    }

    internal void RenamePartner(string id, string name)
    {
        name = name.Trim();
        if (name.Length == 0) return;
        _device.Rename(id, name); Save();
        var i = _partners.FindIndex(x => x.Id == id);
        if (i >= 0) _partners[i] = _partners[i] with { Name = name.Length > 64 ? name[..64] : name };
        RefreshStatus();
    }

    internal void ForgetPartner(string id)
    {
        _device.Forget(id); Save();
        _hub?.Remove(id);
        _partners.RemoveAll(x => x.Id == id);
        if (_sendTarget == id) _sendTarget = null;
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
        _pendingPartner = p;
        _hub?.Add(p, pairing: false);
        _pairTimeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        _pairTimeout.Tick += (_, _) =>
        {
            _pairTimeout?.Stop();
            if (_pendingPartner?.Id != p.Id) return;
            _hub?.Remove(p.Id);
            _pendingPartner = null;
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
        if (e.Key == Key.P && Keyboard.Modifiers == ModifierKeys.Control) { _pinned = !_pinned; ApplyPin(); e.Handled = true; }
    }

    /// <summary>The status line's menu (right-click, or click while not connected).</summary>
    ContextMenu StatusMenu()
    {
        var m = new ContextMenu();
        var settings = new MenuItem { Header = "Settings…" };
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
        m.Items.Add(check);
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
        _cancelLink.Click += (_, _) => CancelPairing();
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
