using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Controls;
using System.Windows.Threading;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Storage settings for received files (keep for N days, storage limit, warn or move oldest to the Recycle Bin,
/// Recycle Bin reminder), the cleanup that applies them, and the first-run gate: until the user presses Save once,
/// every launch opens on this panel. Same rules as the Mac (LanLine.Core.Cleanup).
/// </summary>
sealed partial class MainWindow
{
    StorageSettings _storage = new();
    bool _showingSettings, _settingsFirstRun;
    DispatcherTimer? _cleanupTimer;
    FrameworkElement? _settingsPanel;
    long _usageBytes;
    double? _heightBeforeSettings, _topBeforeSettings;

    // panel parts
    readonly TextBlock _setFirstRun = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
    readonly WrapPanel _retPills = new(), _limPills = new(), _overPills = new(), _remindPills = new(), _updatePills = new(), _keepPills = new(),
        _notifyPills = new(), _popPills = new(), _signInPills = new(), _soundPills = new(), _historyPills = new(), _clipPills = new(), _clipPicPills = new(), _previewPills = new(), _edgePills = new();
    // Global shortcuts (beta.10): recorders, what they hold until Save, and why one can't be used
    Shortcut? _showKey, _sendKey;
    readonly Button _showRec = new(), _sendRec = new(), _showOff = new(), _sendOff = new();
    readonly TextBlock _showProblem = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed },
                       _sendProblem = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed },
                       _keysNote = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
    readonly StackPanel _notifyOff = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
    readonly TextBox _customDays = new(), _customGB = new();
    Border _customDaysBox = null!, _customGBBox = null!;   // built in BuildSettingsPanel
    readonly StackPanel _overRow = new();
    readonly TextBlock _usageText = new() { FontSize = 12, Margin = new Thickness(0, 14, 0, 5) };
    readonly ProgressBar _usageBar = new() { Height = 5, Maximum = 1 };
    readonly TextBlock _unmanagedText = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
    readonly TextBlock _setError = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
    readonly Button _setCancel = new() { Content = "Cancel" };
    readonly Slider _opacity = new() { Minimum = StorageSettings.GlassOpacityMin, Maximum = StorageSettings.GlassOpacityMax, SmallChange = 0.01, LargeChange = 0.05, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _opacityText = new() { FontSize = 12, Width = 40, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _opacityDefault = new() { Content = "Default", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
    bool _loadingOpacity;

    string SettingsPath => Path.Combine(Path.GetDirectoryName(ConfigPath)!, "settings.json");
    string LogPath => Path.Combine(Path.GetDirectoryName(ConfigPath)!, "received.json");
    /// <summary>Where received files go: --downloads (tests), the folder chosen in Settings, or Downloads\Lan-Line.</summary>
    string DownloadsPath => Arg(_args, "--downloads") ?? _storage.DownloadFolderValue ?? LanLineConfig.DownloadsDir;

    /// <summary>The folder settings (beta.10): one folder, or one per computer inside it; applied to every partner.</summary>
    void ApplyDownloads() => _hub?.SetDownloads(DownloadsPath, _storage.FolderPerComputerValue);

    readonly ArrivalBurst _burst = new();

    /// <summary>"When a file arrives" (beta.10): show it, or open it if it's a kind that can't run anything.</summary>
    void AfterReceive(Item item)
    {
        var setting = _storage.AfterReceiveValue;
        if (setting == LanLine.Core.AfterReceive.Nothing || !item.IsFile || item.Path is not { } p) return;
        try
        {
            switch (_burst.Next(setting, item.FileName ?? p, item.IsFolder))   // at most 3 opened and Explorer shown once per burst of arrivals
            {
                case LanLine.Core.AfterReceive.Open:
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(p) { UseShellExecute = true });
                    break;
                case LanLine.Core.AfterReceive.Reveal:
                    System.Diagnostics.Process.Start("explorer.exe", item.IsFolder ? $"\"{p}\"" : $"/select,\"{p}\"");
                    break;
            }
        }
        catch (Exception) { /* no app for it: the item is in the window anyway */ }
    }

    void SetUpStorage()
    {
        _storage = StorageSettings.Load(SettingsPath);
        // Welcome tour (beta.10): someone already paired before it existed isn't owed one.
        if (Tour.SeenAtLaunch(_storage.TourSeen, _device.Peers.Count > 0) is var seen && seen != _storage.TourSeen)
        {
            _storage.TourSeen = seen;
            try { _storage.Save(SettingsPath); } catch (Exception) { }
        }
        ApplyKeepRunning();
        Theme.GlassOpacity = _storage.GlassOpacityValue;
        Theme.ApplyBackdrop(Application.Current.Resources);
        ApplyTextScale();
        WatchTextScale();
        RunCleanup(manual: false);
        _cleanupTimer = new DispatcherTimer { Interval = TimeSpan.FromHours(1) };
        _cleanupTimer.Tick += (_, _) => { RunCleanup(manual: false); _ = CheckForUpdates(manual: false); };
        _cleanupTimer.Start();
        if (SavedLatest() is { } a) ShowUpdate(a.Version.ToString(), a.Url);
        _ = CheckForUpdates(manual: false);
        if (!_storage.Confirmed) ShowSettings(firstRun: true);   // every launch until saved once
    }

    // ---------- updates (the only network call; manual, or daily if the user turned it on)

    string MyVersion => Arg(_args, "--app-version") ?? AppInfo.Version;

    /// <summary>The saved "newest version heard of", if it is still newer than this app.</summary>
    Updates.Available? SavedLatest() =>
        LanLineVersion.Parse(_storage.LatestVersion) is { } v && Updates.IsAllowedUrl(_storage.LatestUrl)
        && LanLineVersion.Parse(MyVersion) is { } own && v > own ? new Updates.Available(v, _storage.LatestUrl!) : null;

    void RememberLatest(string version, string url)
    {
        if (_storage.LatestVersion == version) return;
        _storage.LatestVersion = version; _storage.LatestUrl = url;
        try { _storage.Save(SettingsPath); } catch (Exception) { }
    }

    async Task CheckForUpdates(bool manual)
    {
        if (!manual && !Updates.DueForAutoCheck(_storage, DateTime.UtcNow)) return;
        if (LanLineVersion.Parse(MyVersion) == null) { if (manual) Note("This build has no version number to compare.", 6); return; }
        _storage.LastUpdateCheck = DateTime.UtcNow;
        try { _storage.Save(SettingsPath); } catch (Exception) { }
        var r = await Updates.FetchLatest(MyVersion);   // resumes on the UI thread
        if (r is { Kind: Updates.Outcome.Available, Found: { } a })
        {
            _hub?.NoteLatest(a);   // tells every partner
            ShowUpdate(a.Version.ToString(), a.Url);
            if (manual) ShowUpdate(a.Version.ToString(), a.Url);
        }
        else if (Updates.Message(r, manual) is { } m) Note(m, 6);
    }

    void ShowSettings(bool firstRun = false)
    {
        _settingsFirstRun = firstRun;
        RefreshUsage();
        LoadSettingsIntoPanel();
        _showingSettings = true;
        if (Height < 600)
        {
            _heightBeforeSettings = Height; _topBeforeSettings = Top;
            var grow = 600 - Height;
            Height = 600;
            Top = Math.Max(SystemParameters.WorkArea.Top + 8, Top - grow);
        }
        ApplyScreen();
    }

    void CloseSettings()
    {
        if (Math.Abs(Theme.GlassOpacity - _storage.GlassOpacityValue) > 0.0001)   // undo a slider preview
        {
            Theme.GlassOpacity = _storage.GlassOpacityValue;
            Theme.ApplyBackdrop(Application.Current.Resources);
        }
        _showingSettings = false;
        ApplyScreen();
        if (_heightBeforeSettings is { } h && WindowState == WindowState.Normal && !_pairing)   // back to the size it had
        {
            Height = h;
            if (_topBeforeSettings is { } t) Top = t;
        }
        _heightBeforeSettings = _topBeforeSettings = null;
    }

    /// <summary>Which middle area shows: settings over everything, else pairing, else the feed and composer.</summary>
    void ApplyScreen()
    {
        if (_settingsPanel != null) _settingsPanel.Visibility = _showingSettings ? Visibility.Visible : Visibility.Collapsed;
        _pairPanel.Visibility = !_showingSettings && _pairing ? Visibility.Visible : Visibility.Collapsed;
        _body.Visibility = _composer.Visibility = !_showingSettings && !_pairing ? Visibility.Visible : Visibility.Collapsed;
        _stagedStrip.Visibility = _staged.Count > 0 && _composer.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        RefreshStatus();   // "To: …" follows the composer; without this it stayed under the Settings footer
    }

    void LogReceived(string path, long size)
    {
        var log = ReceivedLog.Load(LogPath);
        log.RemoveAll(f => string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase));
        log.Add(new ReceivedFile(path, size, DateTime.UtcNow));
        try { ReceivedLog.Save(log, LogPath); } catch (Exception) { }
        RunCleanup(manual: false);
    }

    void RefreshUsage()
    {
        var existing = ReceivedLog.Load(LogPath).Where(f => Path.Exists(f.Path)).ToList();
        _usageBytes = existing.Sum(f => f.Size);
        // Files in the folder that Lan-Line doesn't manage (received before 0.9.0-beta.3, or put there by hand).
        var managed = existing.Select(f => f.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        // Only a folder Lan-Line owns is counted: a chosen folder like the Desktop holds plenty of other files.
        var owned = Arg(_args, "--downloads") != null || _storage.DownloadFolderValue == null;
        var others = owned && Directory.Exists(DownloadsPath)
            ? new DirectoryInfo(DownloadsPath).GetFiles().Where(f => !f.Name.StartsWith('.') && (f.Attributes & FileAttributes.Hidden) == 0 && !managed.Contains(f.FullName)).ToList()
            : [];
        _unmanagedText.Text = $"Also in the folder: {others.Count} file{(others.Count == 1 ? "" : "s")} ({Cleanup.FormatBytes(others.Sum(f => f.Length))}) from before this version or added by you. Lan-Line leaves these alone.";
        _unmanagedText.Visibility = others.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Move expired / over-limit received files to the Recycle Bin, then say so quietly. Never touches anything else.</summary>
    void RunCleanup(bool manual)
    {
        var log = ReceivedLog.Load(LogPath);
        var existing = log.Where(f => Path.Exists(f.Path)).ToList();
        var now = DateTime.UtcNow;
        var plan = Cleanup.Plan(existing, _storage, now);
        var moved = plan.ToTrash.Where(f => RecycleBin.Send(f.Path)).ToList();
        var movedPaths = moved.Select(f => f.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var kept = existing.Where(f => !movedPaths.Contains(f.Path)).ToList();
        if (kept.Count != log.Count) { try { ReceivedLog.Save(kept, LogPath); } catch (Exception) { } }
        foreach (var r in _rows.Values) if (r.Path is { } p && movedPaths.Contains(p)) r.MarkRemoved();
        _usageBytes = kept.Sum(f => f.Size);
        var changed = false;
        if (moved.Count > 0)
        {
            var why = plan.Expired.Count > 0 ? $"older than {_storage.RetentionDays} day{(_storage.RetentionDays == 1 ? "" : "s")}"
                                             : $"to stay under your {Cleanup.FormatBytes(plan.LimitBytes)} limit";
            Note($"Moved {moved.Count} received file{(moved.Count == 1 ? "" : "s")} ({Cleanup.FormatBytes(moved.Sum(f => f.Size))}) to the Recycle Bin, {why}.");
            if (Cleanup.ShouldRemindTrash(_storage, true, now))
            {
                Note("Old received files go to the Recycle Bin. Empty it once you've had a look. (Turn this reminder off in Settings.)");
                _storage.LastTrashReminder = now; changed = true;
            }
        }
        else if (manual) Note($"Nothing to clean up. Received files use {Cleanup.FormatBytes(plan.UsageBytes)}.", fadeAfter: 6);
        if (Cleanup.ShouldWarnLimit(_storage, plan.Level, now) || (manual && plan.Level > 0))
        {
            var used = Cleanup.FormatBytes(plan.UsageBytes); var lim = Cleanup.FormatBytes(plan.LimitBytes);
            Note(plan.Level == 2 ? $"Received files use {used}, over your {lim} limit. Raise it or turn on cleanup in Settings."
                                 : $"Received files use {used} of your {lim} limit.");
            _storage.LastLimitWarning = now; changed = true;
        }
        if (changed) { try { _storage.Save(SettingsPath); } catch (Exception) { } }
        if (_showingSettings) RefreshUsageBar();
    }

    // ---------- panel

    FrameworkElement BuildSettingsPanel()
    {
        _customDaysBox = NumberBox(_customDays, "days", "Days to keep files");
        _customGBBox = NumberBox(_customGB, "GB", "Storage limit in GB");
        _customGB.TextChanged += (_, _) => RefreshUsageBar();
        // Design refresh (beta.10): titled groups on solid surfaces (readable at any window opacity), in the same order
        // as the Mac: paired computers, received files, arrivals, shortcuts, clipboard and links, running, updates, look.
        var outer = new StackPanel { Margin = new Thickness(12, 4, 12, 12) };
        StackPanel col;
        StackPanel Group(string title, out FrameworkElement box)
        {
            var head = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(10, 12, 8, 5) };
            head.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            System.Windows.Automation.AutomationProperties.SetHeadingLevel(head, System.Windows.Automation.AutomationHeadingLevel.Level2);
            var inner = new StackPanel();
            var card = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Padding = new Thickness(12, 0, 12, 12), Child = inner };
            card.SetResourceReference(Border.BackgroundProperty, "GroupFill");
            card.SetResourceReference(Border.BorderBrushProperty, "GroupStroke");
            var wrap = new StackPanel();
            var headBack = Scrimmed(head);
            head.Margin = new Thickness(0); headBack.Margin = new Thickness(4, 12, 8, 5); headBack.Padding = new Thickness(6, 1, 6, 2);
            wrap.Children.Add(headBack); wrap.Children.Add(card);
            outer.Children.Add(wrap);
            box = wrap;
            return inner;
        }
        col = Group("Paired computers", out _pairedGroup);
        col.Children.Add(_pairedBox);   // filled when the panel opens
        col = Group("Received files", out _);
        _setFirstRun.Text = "Choose how Lan-Line keeps received files before you start. You can change this any time from the status line's menu.";
        _setFirstRun.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        _setFirstRun.Margin = new Thickness(0, 10, 0, 0);
        col.Children.Add(_setFirstRun);
        BuildReceiveRows(col);

        col.Children.Add(Label("Delete received files after"));
        foreach (var d in StorageSettings.RetentionChoices) _retPills.Children.Add(Pill("ret", d == 0 ? "Never" : d == 1 ? "1 day" : $"{d} days", d));
        _retPills.Children.Add(Pill("ret", "Custom", -1));
        col.Children.Add(_retPills);
        col.Children.Add(_customDaysBox);

        col.Children.Add(Label("Storage limit"));
        foreach (var g in StorageSettings.LimitChoices) _limPills.Children.Add(Pill("lim", g == 0 ? "No limit" : $"{g:0} GB", g));
        _limPills.Children.Add(Pill("lim", "Custom", -1.0));
        col.Children.Add(_limPills);
        col.Children.Add(_customGBBox);

        _overRow.Children.Add(Label("When over the limit"));
        _overPills.Children.Add(Pill("over", "Warn me", "warn"));
        _overPills.Children.Add(Pill("over", "Move oldest to Recycle Bin", "trash"));
        _overRow.Children.Add(_overPills);
        col.Children.Add(_overRow);

        col.Children.Add(Label("Remind me now and then to empty the Recycle Bin"));
        _remindPills.Children.Add(Pill("remind", "On", true));
        _remindPills.Children.Add(Pill("remind", "Off", false));
        col.Children.Add(_remindPills);

        _usageText.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _usageBar.SetResourceReference(StyleProperty, "ThinProgress");
        col.Children.Add(_usageText);
        col.Children.Add(_usageBar);
        var note = new TextBlock { Text = "Only files Lan-Line received are ever moved, and only to the Recycle Bin, so you can still get them back.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0) };
        note.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(note);
        _unmanagedText.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(_unmanagedText);

        col = Group("When something arrives", out _);
        // When something arrives (beta.10): a toast, and/or the window coming forward
        col.Children.Add(Label("Notify me when something arrives"));
        _notifyPills.Children.Add(Pill("notify", "On", true));
        _notifyPills.Children.Add(Pill("notify", "Off", false));
        col.Children.Add(_notifyPills);
        var offText = new TextBlock { Text = "Notifications are off for Lan-Line in Windows Settings.", FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        offText.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        var openNs = new Button { Content = "Open Settings", FontSize = 12, Margin = new Thickness(8, 0, 0, 0) };
        openNs.SetResourceReference(StyleProperty, "LinkButton");
        openNs.Click += (_, _) => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:notifications") { UseShellExecute = true }); } catch (Exception) { } };
        _notifyOff.Children.Add(offText); _notifyOff.Children.Add(openNs);
        col.Children.Add(_notifyOff);
        col.Children.Add(Label("Bring the window forward when something arrives"));
        _popPills.Children.Add(Pill("popup", "Yes", true));
        _popPills.Children.Add(Pill("popup", "No", false));
        col.Children.Add(_popPills);
        col.Children.Add(Label("Play sounds"));
        _soundPills.Children.Add(Pill("sounds", "On", true));
        _soundPills.Children.Add(Pill("sounds", "Off", false));
        _soundPills.ToolTip = "A soft chime when something arrives while you're in Lan-Line, and a quiet tick when you send";
        col.Children.Add(_soundPills);
        var notifyNote = new TextBlock { Text = "Notifications appear only while you're using another window, with Copy for texts and Open or Show in folder for files. Do not disturb and Focus follow Windows Settings.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        notifyNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(notifyNote);
        col = Group("Keyboard shortcuts, from any app", out _);
        BuildShortcutRows(col);

        col = Group("Clipboard and links", out _);
        // Clipboard sharing (beta.10): off until turned on
        col.Children.Add(Label("Share the clipboard"));
        _clipPills.Children.Add(Pill("clip", "Off", false));
        _clipPills.Children.Add(Pill("clip", "On", true));
        col.Children.Add(_clipPills);
        var picLabel = Label("Include pictures (up to 10 MB)");
        col.Children.Add(picLabel);
        _clipPicPills.Children.Add(Pill("clippic", "On", true));
        _clipPicPills.Children.Add(Pill("clippic", "Off", false));
        col.Children.Add(_clipPicPills);
        var clipNote = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        clipNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(clipNote);
        void ClipRefresh()
        {
            var on = Selected(_clipPills) is true;
            picLabel.Visibility = _clipPicPills.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            clipNote.Text = on ? "Copy on one computer, paste on the other, while they're connected. Copies from password managers are never shared, and nothing is kept. Pause it any time from the tray icon."
                               : "Off: copying stays on this PC. Turn it on here and on the other computer.";
        }
        foreach (var r in _clipPills.Children.OfType<System.Windows.Controls.RadioButton>()) r.Checked += (_, _) => ClipRefresh();
        _clipRefresh = ClipRefresh;

        // Link previews (beta.10): off unless turned on (fetching a page tells that website)
        col.Children.Add(Label("Show link previews"));
        _previewPills.Children.Add(Pill("previews", "Off", false));
        _previewPills.Children.Add(Pill("previews", "On", true));
        col.Children.Add(_previewPills);
        var prevNote = new TextBlock { Text = "On: a shared link shows its page's title and picture, fetched from that website (which can see the visit). Off: links show their site and path, and nothing is fetched until you open one.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        prevNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(prevNote);

        col = Group("Running", out _);
        // Open at sign-in (beta.10): the Run value, read from the registry each time the panel opens
        col.Children.Add(Label("Open Lan-Line when I sign in"));
        _signInPills.Children.Add(Pill("signin", "On", true));
        _signInPills.Children.Add(Pill("signin", "Off", false));
        col.Children.Add(_signInPills);
        var signNote = new TextBlock { Text = "At sign-in it waits in the tray, still receiving, and opens when something arrives.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        signNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(signNote);

        // Keep running in the tray (beta.9)
        col.Children.Add(Label("When I close the window"));
        _keepPills.Children.Add(Pill("keep", "Keep running in the tray", true));
        _keepPills.Children.Add(Pill("keep", "Quit Lan-Line", false));
        col.Children.Add(_keepPills);
        var keepNote = new TextBlock { Text = "In the tray, Lan-Line keeps receiving, off the taskbar. If Windows tucks the icon under ^ by the clock, drag it onto the taskbar to keep it in view.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        keepNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(keepNote);

        // Edge drop zone (beta.10): the tray takes no drops, so an optional strip at the screen edge does
        col.Children.Add(Label("Drop zone at the screen edge"));
        _edgePills.Children.Add(Pill("edge", "Off", false));
        _edgePills.Children.Add(Pill("edge", "On", true));
        col.Children.Add(_edgePills);
        var edgeNote = new TextBlock { Text = "A slim strip at the right edge of the screen. Drag files, a folder or text onto it to send them without opening Lan-Line (the notification area by the clock can't take drops).", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        edgeNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(edgeNote);

        col = Group("Updates and history", out _);
        col.Children.Add(Label("Check for updates automatically"));
        _updatePills.Children.Add(Pill("updates", "Off", false));
        _updatePills.Children.Add(Pill("updates", "Once a day", true));
        col.Children.Add(_updatePills);
        var upNote = new TextBlock { Text = "Off unless you turn it on. Lan-Line then reads one small file from averywrobinson.com once a day. It sends no ID and nothing about your files.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        upNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(upNote);

        // History (beta.10): kept on this PC only, searchable with Ctrl+F
        col.Children.Add(Label("Keep history on this PC"));
        _historyPills.Children.Add(Pill("history", "On", true));
        _historyPills.Children.Add(Pill("history", "Off", false));
        var clearHist = new Button { Content = "Clear history…", FontSize = 12, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        clearHist.SetResourceReference(StyleProperty, "LinkButton");
        clearHist.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "Clear the history on this PC? Texts and file names are removed from Lan-Line. Received files stay in your Lan-Line folder.",
                                "Lan-Line", MessageBoxButton.OKCancel, MessageBoxImage.None, MessageBoxResult.Cancel) == MessageBoxResult.OK) ClearHistory();
        };
        _historyPills.Children.Add(clearHist);
        col.Children.Add(_historyPills);
        var histNote = new TextBlock { Text = $"The last {History.Cap:N0} texts and file names stay in the window and in search (Ctrl+F), on this PC only. Turning it off deletes it.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        histNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(histNote);

        col = Group("Appearance", out _);
        // Text size (accessibility pass, beta.10): Lan-Line's own, on top of Windows' Text size setting
        col.Children.Add(Label("Text size"));
        foreach (var c in StorageSettings.TextScaleChoices) _textPills.Children.Add(Pill("textsize", $"{c * 100:0}%", c));
        col.Children.Add(_textPills);
        var textNote = new TextBlock { Text = "Changes when you save. Lan-Line also follows Windows' own Text size (Settings › Accessibility › Text size).", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        textNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(textNote);
        // Window opacity (beta.8): moves the glass backdrop live while dragging; Save keeps it, Cancel puts it back.
        col.Children.Add(Label("Window opacity"));
        _opacity.SetResourceReference(StyleProperty, "GlassSlider");
        System.Windows.Automation.AutomationProperties.SetName(_opacity, "Window opacity");
        _opacityText.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _opacityDefault.SetResourceReference(StyleProperty, "LinkButton");
        _opacity.ValueChanged += (_, e) =>
        {
            _opacityText.Text = $"{Math.Round(e.NewValue * 100):0}%";
            _opacityDefault.Visibility = Math.Abs(e.NewValue - StorageSettings.DefaultGlassOpacity) > 0.005 ? Visibility.Visible : Visibility.Hidden;
            if (_loadingOpacity) return;
            Theme.GlassOpacity = Math.Round(e.NewValue, 2);
            Theme.ApplyBackdrop(Application.Current.Resources);
        };
        _opacityDefault.Click += (_, _) => _opacity.Value = StorageSettings.DefaultGlassOpacity;
        var opRow = new DockPanel();
        DockPanel.SetDock(_opacityDefault, Dock.Right); DockPanel.SetDock(_opacityText, Dock.Right);
        opRow.Children.Add(_opacityDefault); opRow.Children.Add(_opacityText); opRow.Children.Add(_opacity);
        col.Children.Add(opRow);
        var opNote = new TextBlock { Text = Theme.GlassSupported ? "Changes only the smoked-glass background; text stays fully readable."
                                                        : "Needs Windows 11 (22H2 or later), where the background is see-through.", FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        opNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(opNote);
        _setError.SetResourceReference(TextBlock.ForegroundProperty, "Danger");

        var open = new Button { Content = "Open folder" };
        var clean = new Button { Content = "Clean up now", ToolTip = "Saves these settings and applies them now" };
        foreach (var b in new[] { open, clean }) b.SetResourceReference(StyleProperty, "SecondaryButton");
        open.Click += (_, _) => { Directory.CreateDirectory(DownloadsPath); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(DownloadsPath) { UseShellExecute = true }); };
        clean.Click += (_, _) => { if (BuildSettings() is { } s) { SaveSettings(s); RunCleanup(manual: true); } };
        var save = new Button { Content = "Save", Width = 88, IsDefault = true };
        save.SetResourceReference(StyleProperty, "PrimaryButton");
        save.Click += (_, _) => { if (BuildSettings() is { } s) SaveSettings(s); };
        _setCancel.SetResourceReference(StyleProperty, "LinkButton");
        _setCancel.VerticalAlignment = VerticalAlignment.Center;
        _setCancel.Click += (_, _) => CloseSettings();
        var buttons = new DockPanel { Margin = new Thickness(0, 8, 0, 0), LastChildFill = false };
        DockPanel.SetDock(save, Dock.Right); DockPanel.SetDock(_setCancel, Dock.Right);
        buttons.Children.Add(open); buttons.Children.Add(clean); buttons.Children.Add(save); buttons.Children.Add(_setCancel);
        foreach (var w in new[] { _retPills, _limPills }) foreach (var r in w.Children.OfType<RadioButton>()) r.Checked += (_, _) => RefreshCustomBoxes();
        // Pinned bar: the error line and Save never scroll out of view.
        var bar = new StackPanel { Margin = new Thickness(14, 2, 14, 12) };
        _setError.Margin = new Thickness(0, 6, 0, 0);
        bar.Children.Add(_setError);
        bar.Children.Add(buttons);
        var barBorder = new Border { BorderThickness = new Thickness(0, 1, 0, 0), Child = bar };   // a solid layer: Save is always readable
        barBorder.SetResourceReference(Border.BorderBrushProperty, "GroupStroke");
        barBorder.SetResourceReference(Border.BackgroundProperty, "GroupFill");
        var dock = new DockPanel();
        DockPanel.SetDock(barBorder, Dock.Bottom);
        dock.Children.Add(barBorder);
        dock.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = outer });
        NamePillGroups(outer);   // Narrator: "Play sounds: Off", not just "Off"
        return dock;
    }

    static TextBlock Label(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 6) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        return t;
    }

    static RadioButton Pill(string group, string text, object value)
    {
        var r = new RadioButton { Content = text, GroupName = group, Tag = value };
        r.SetResourceReference(StyleProperty, "Pill");
        Automation(r, text);
        return r;
    }

    static Border NumberBox(TextBox box, string unit, string label)
    {
        box.SetResourceReference(StyleProperty, "InputBox");
        box.Width = 70; box.FontSize = 13; box.VerticalAlignment = VerticalAlignment.Center;
        Automation(box, label);
        var u = new TextBlock { Text = unit, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        u.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(box); sp.Children.Add(u);
        var b = new Border { CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1), Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left, Child = sp, Margin = new Thickness(0, 2, 0, 0) };
        b.SetResourceReference(Border.BackgroundProperty, "InputFill");
        b.SetResourceReference(Border.BorderBrushProperty, "InputStroke");
        return b;
    }

    static void Select(WrapPanel w, Func<object?, bool> match)
    {
        foreach (var r in w.Children.OfType<RadioButton>()) r.IsChecked = match(r.Tag);   // a row may also hold a button (Clear history)
    }

    static bool IsWritable(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var probe = Path.Combine(dir, $".lan-line-{Guid.NewGuid():N}.tmp");
            File.WriteAllText(probe, ""); File.Delete(probe);
            return true;
        }
        catch (Exception) { return false; }
    }

    static object? Selected(WrapPanel w) => w.Children.OfType<RadioButton>().FirstOrDefault(r => r.IsChecked == true)?.Tag;

    readonly StackPanel _pairedBox = new() { Margin = new Thickness(0, 10, 0, 0) };
    FrameworkElement _pairedGroup = new Border();
    readonly WrapPanel _textPills = new();

    /// <summary>Settings → Paired computers: rename, forget (with a warning), pair another.</summary>
    void RefreshPairedList()
    {
        _pairedBox.Children.Clear();
        _pairedGroup.Visibility = _settingsFirstRun ? Visibility.Collapsed : Visibility.Visible;
        if (_partners.Count == 0)
        {
            var none = new TextBlock { Text = "None yet.", FontSize = 12 };
            none.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            _pairedBox.Children.Add(none);
        }
        foreach (var p in _partners.ToList())
        {
            var id = p.Id;
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var dot = new System.Windows.Shapes.Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, p.Up ? "Green" : "IdleDot");
            Automation(dot, p.Up ? "connected" : "not connected");
            var name = new TextBox { Text = p.Name, FontSize = 12, MinWidth = 140, IsReadOnly = true, BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent, VerticalAlignment = VerticalAlignment.Center };
            name.SetResourceReference(ForegroundProperty, "Text");
            Automation(name, $"Name of {p.Name}");
            var rename = new Button { Content = "Rename", FontSize = 11, Margin = new Thickness(8, 0, 0, 0) };
            var forget = new Button { Content = "Forget", FontSize = 11, Margin = new Thickness(8, 0, 0, 0) };
            foreach (var b in new[] { rename, forget }) b.SetResourceReference(StyleProperty, "LinkButton");
            forget.SetResourceReference(ForegroundProperty, "Danger");
            rename.Click += (_, _) =>
            {
                if (name.IsReadOnly) { name.IsReadOnly = false; name.BorderThickness = new Thickness(1); name.Focus(); name.SelectAll(); rename.Content = "Done"; }
                else { RenamePartner(id, name.Text); RefreshPairedList(); }
            };
            name.KeyDown += (_, k) => { if (k.Key == System.Windows.Input.Key.Enter && !name.IsReadOnly) { RenamePartner(id, name.Text); RefreshPairedList(); } };
            forget.Click += (_, _) =>
            {
                var ok = MessageBox.Show(this, $"Forget {p.Name}? Lan-Line stops connecting to it and deletes its pairing secret. Files you already received stay.",
                                         "Forget computer", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
                if (ok == MessageBoxResult.OK) { ForgetPartner(id); RefreshPairedList(); }
            };
            DockPanel.SetDock(dot, Dock.Left);
            DockPanel.SetDock(forget, Dock.Right);
            DockPanel.SetDock(rename, Dock.Right);
            row.Children.Add(dot); row.Children.Add(forget); row.Children.Add(rename); row.Children.Add(name);
            _pairedBox.Children.Add(row);
        }
        var another = new Button { Content = _partners.Count == 0 ? "Pair a computer…" : "Pair another computer…", FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0),
                                   IsEnabled = _partners.Count < DeviceConfig.MaxPartners };
        another.SetResourceReference(StyleProperty, "LinkButton");
        another.Click += (_, _) => { CloseSettings(); BeginPairing(show: false); };
        _pairedBox.Children.Add(another);
    }

    void LoadSettingsIntoPanel()
    {
        RefreshPairedList();
        var s = _storage;
        var retKnown = StorageSettings.RetentionChoices.Contains(s.RetentionDays);
        Select(_retPills, t => retKnown ? (t is int i && i == s.RetentionDays) : (t is int j && j == -1));
        _customDays.Text = retKnown ? "" : s.RetentionDays.ToString();
        var limKnown = StorageSettings.LimitChoices.Contains(s.LimitGB);
        Select(_limPills, t => limKnown ? (t is double d && d == s.LimitGB) : (t is double e && e == -1));
        _customGB.Text = limKnown ? "" : s.LimitGB.ToString("0.##");
        Select(_overPills, t => (string?)t == s.OverLimit);
        Select(_remindPills, t => t is bool b && b == s.TrashReminder);
        Select(_updatePills, t => t is bool u && u == (s.AutoUpdateCheck == true));
        Select(_keepPills, t => t is bool k && k == s.KeepRunningWhenClosedValue);
        Select(_notifyPills, t => t is bool n && n == s.NotifyOnArrivalValue);
        Select(_popPills, t => t is bool p && p == s.PopUpOnArrivalValue);
        Select(_soundPills, t => t is bool so && so == s.SoundsValue);
        Select(_historyPills, t => t is bool hi && hi == s.KeepHistoryValue);
        Select(_clipPills, t => t is bool cl && cl == s.ShareClipboardValue);
        _folderDraft = s.DownloadFolderValue;
        Select(_perComputerPills, t => t is bool pc && pc == s.FolderPerComputerValue);
        Select(_afterPills, t => t is LanLine.Core.AfterReceive ar && ar == s.AfterReceiveValue);
        RefreshReceiveRows();
        Select(_clipPicPills, t => t is bool cp && cp == s.ShareClipboardPicturesValue);
        Select(_previewPills, t => t is bool lp && lp == s.LinkPreviewsValue);
        Select(_edgePills, t => t is bool ed && ed == s.EdgeDropZoneValue);
        _clipRefresh?.Invoke();
        Select(_signInPills, t => t is bool si && si == (!_demo && OpensAtSignIn()));
        _notifyOff.Visibility = !_demo && s.NotifyOnArrivalValue && WinToast.Enabled() == false ? Visibility.Visible : Visibility.Collapsed;
        _showKey = s.ShowShortcut; _sendKey = s.SendShortcut;
        RefreshShortcutRows();
        Select(_textPills, t => t is double ts && Math.Abs(ts - s.TextScaleValue) < 0.001);
        _loadingOpacity = true;
        _opacity.Value = s.GlassOpacityValue;
        _loadingOpacity = false;
        _setFirstRun.Visibility = _settingsFirstRun ? Visibility.Visible : Visibility.Collapsed;
        _setCancel.Visibility = _settingsFirstRun ? Visibility.Collapsed : Visibility.Visible;
        _setError.Visibility = Visibility.Collapsed;
        RefreshCustomBoxes();
    }

    void RefreshCustomBoxes()
    {
        _customDaysBox.Visibility = Selected(_retPills) is int i && i == -1 ? Visibility.Visible : Visibility.Collapsed;
        _customGBBox.Visibility = Selected(_limPills) is double d && d == -1 ? Visibility.Visible : Visibility.Collapsed;
        _overRow.Visibility = Selected(_limPills) is double z && z == 0 ? Visibility.Collapsed : Visibility.Visible;
        RefreshUsageBar();
    }

    void RefreshUsageBar()
    {
        var gb = Selected(_limPills) is double d ? (d == -1 ? (double.TryParse(_customGB.Text, out var c) ? c : 0) : d) : _storage.LimitGB;
        var limit = gb > 0 ? (long)(gb * 1e9) : 0;
        _usageText.Text = limit > 0 ? $"Received files use {Cleanup.FormatBytes(_usageBytes)} of {Cleanup.FormatBytes(limit)}"
                                    : $"Received files use {Cleanup.FormatBytes(_usageBytes)}";
        _usageBar.Visibility = limit > 0 ? Visibility.Visible : Visibility.Collapsed;
        var frac = limit > 0 ? Math.Min(1, (double)_usageBytes / limit) : 0;
        _usageBar.Value = frac;
        if (frac >= 1) _usageBar.SetResourceReference(ForegroundProperty, "Danger");
        else if (frac >= 0.8) _usageBar.Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0xF5, 0xB0, 0x33));
        else _usageBar.SetResourceReference(ForegroundProperty, "Accent");
    }

    /// <summary>The settings as chosen, or null (with an error shown) when a custom number isn't valid.</summary>
    StorageSettings? BuildSettings()
    {
        var s = _storage.Copy();
        if (Selected(_retPills) is int r)
        {
            if (r == -1)
            {
                if (!int.TryParse(_customDays.Text.Trim(), out var d) || d < 1 || d > 3650) return Fail("Days to keep files must be a whole number from 1 to 3650.");
                s.RetentionDays = d;
            }
            else s.RetentionDays = r;
        }
        if (Selected(_limPills) is double g)
        {
            if (g == -1)
            {
                if (!double.TryParse(_customGB.Text.Trim(), out var c) || c < 0.1 || c > 100_000) return Fail("The storage limit must be a number of GB from 0.1 to 100000.");
                s.LimitGB = c;
            }
            else s.LimitGB = g;
        }
        if (Selected(_overPills) is string o) s.OverLimit = o;
        if (Selected(_remindPills) is bool b) s.TrashReminder = b;
        if (Selected(_updatePills) is bool u) s.AutoUpdateCheck = u;
        if (Selected(_keepPills) is bool k) s.KeepRunningWhenClosed = k ? null : false;
        if (Selected(_notifyPills) is bool nt) s.NotifyOnArrival = nt ? null : false;
        if (Selected(_popPills) is bool pu) s.PopUpOnArrival = pu ? null : false;
        if (Selected(_soundPills) is bool snd) s.Sounds = snd ? null : false;
        if (Selected(_historyPills) is bool hk) s.KeepHistory = hk ? null : false;
        if (Selected(_clipPills) is bool cs) s.ShareClipboard = cs ? true : null;
        if (_folderDraft != null && !IsWritable(_folderDraft)) return Fail("Lan-Line can't save files in that folder. Choose another one.");
        s.DownloadFolder = _folderDraft;
        if (Selected(_perComputerPills) is bool pcs) s.FolderPerComputer = pcs ? true : null;
        if (Selected(_afterPills) is LanLine.Core.AfterReceive arv) s.AfterReceive = arv == LanLine.Core.AfterReceive.Nothing ? null : ReceiveOptions.Key(arv);
        if (Selected(_clipPicPills) is bool cpp) s.ShareClipboardPictures = cpp ? null : false;
        if (Selected(_previewPills) is bool lpv) s.LinkPreviews = lpv ? true : null;
        if (Selected(_edgePills) is bool edv) s.EdgeDropZone = edv ? true : null;
        if (_showKey != null && _showKey == _sendKey) return Fail("Pick two different keyboard shortcuts.");
        if ((_showKey?.Problem(mac: false) ?? _sendKey?.Problem(mac: false)) is { } kp) return Fail(kp);
        s.ShortcutShow = _showKey == Shortcut.DefaultShow ? null : _showKey?.Text ?? "";
        s.ShortcutSend = _sendKey?.Text;
        var op = Math.Round(_opacity.Value, 2);
        s.GlassOpacity = Math.Abs(op - StorageSettings.DefaultGlassOpacity) < 0.005 ? null : op;
        s.TextScale = Selected(_textPills) is double ts && Math.Abs(ts - 1) > 0.001 ? ts : null;
        s.Confirmed = true;
        _setError.Visibility = Visibility.Collapsed;
        return s;

        StorageSettings? Fail(string msg) { _setError.Text = msg; _setError.Visibility = Visibility.Visible; return null; }
    }

    /// <summary>"Keyboard shortcuts, from any app": a recorder per shortcut (click, press the keys; Esc cancels,
    /// Delete turns it off) and a × to turn it off.</summary>
    void BuildShortcutRows(StackPanel col)
    {
        foreach (var (rec, off, problem, label, isShow) in new[] { (_showRec, _showOff, _showProblem, "Show or hide Lan-Line", true), (_sendRec, _sendOff, _sendProblem, "Send the clipboard", false) })
        {
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
            var text = new TextBlock { Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
            text.SetResourceReference(TextBlock.ForegroundProperty, "Text");
            off.Content = Glyph_Close; off.FontFamily = (System.Windows.Media.FontFamily)Application.Current.Resources["IconFont"];
            off.FontSize = 9; off.ToolTip = "Turn off"; off.Margin = new Thickness(6, 0, 0, 0);
            off.SetResourceReference(StyleProperty, "IconButton");
            Automation(off, $"Turn off: {label}");
            off.Click += (_, _) => { if (isShow) _showKey = null; else _sendKey = null; RefreshShortcutRows(); };
            rec.MinWidth = 130;
            rec.SetResourceReference(StyleProperty, "SecondaryButton");
            Automation(rec, $"Shortcut: {label}");
            rec.Click += (_, _) => StartRecording(rec);
            rec.PreviewKeyDown += (_, e) => RecordKey(e, isShow);
            rec.LostKeyboardFocus += (_, _) => { if (_recordingShortcut) StopRecording(); };
            DockPanel.SetDock(off, Dock.Right); DockPanel.SetDock(rec, Dock.Right);
            row.Children.Add(off); row.Children.Add(rec); row.Children.Add(text);
            col.Children.Add(row);
            problem.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
            col.Children.Add(problem);
        }
        _keysNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(_keysNote);
    }

    Button? _recording;
    Action? _clipRefresh;

    void StartRecording(Button rec)
    {
        _recording = rec;
        _recordingShortcut = true;
        ApplyHotKeys();   // the current global shortcuts would fire instead of being recorded
        rec.Content = "Type a shortcut…";
        rec.Focus();
    }

    void StopRecording()
    {
        _recording = null;
        _recordingShortcut = false;
        ApplyHotKeys();
        RefreshShortcutRows();
    }

    void RecordKey(KeyEventArgs e, bool isShow)
    {
        if (!_recordingShortcut) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        if (key == Key.Escape) { StopRecording(); return; }
        if (key is Key.Delete or Key.Back) { if (isShow) _showKey = null; else _sendKey = null; StopRecording(); return; }
        string? name = key switch
        {
            >= Key.A and <= Key.Z => key.ToString(),
            >= Key.D0 and <= Key.D9 => ((char)('0' + (key - Key.D0))).ToString(),
            Key.Space => "Space",
            >= Key.F1 and <= Key.F12 => key.ToString(),
            _ => null,
        };
        if (name == null) return;
        var m = Keyboard.Modifiers;
        var s = new Shortcut(m.HasFlag(ModifierKeys.Control), m.HasFlag(ModifierKeys.Alt), m.HasFlag(ModifierKeys.Shift), false, name);
        if (isShow) _showKey = s; else _sendKey = s;
        StopRecording();
    }

    void RefreshShortcutRows()
    {
        if (_recording == null)
        {
            _showRec.Content = _showKey?.Display(false) ?? "Off";
            _sendRec.Content = _sendKey?.Display(false) ?? "Off";
        }
        // the space stays, so both fields line up
        _showOff.Visibility = _showKey == null ? Visibility.Hidden : Visibility.Visible;
        _sendOff.Visibility = _sendKey == null ? Visibility.Hidden : Visibility.Visible;
        Show(_showProblem, _showKey?.Problem(false) ?? (_showKey == _storage.ShowShortcut && _hotKeyProblems.TryGetValue("show", out var a) ? a : null));
        Show(_sendProblem, _sendKey?.Problem(false) ?? (_sendKey == _storage.SendShortcut && _hotKeyProblems.TryGetValue("send", out var b) ? b : null)
                           ?? (_sendKey != null && _sendKey == _showKey ? "Pick two different shortcuts." : null));
        var to = _sendTarget is { } t ? NameOf(t) : Multi ? "everyone" : PeerLabel;
        _keysNote.Text = _sendKey == null
            ? $"Send the clipboard is off. Try {Shortcut.SuggestedSend.Display(false)} (or Ctrl+Alt+Shift+V if you use Paste Special in Office): it sends copied text, a picture or files to {to} without opening the window."
            : "Sends copied text, a picture or files without opening the window. All shortcuts: Ctrl+/.";

        static void Show(TextBlock tb, string? why) { tb.Text = why ?? ""; tb.Visibility = why == null ? Visibility.Collapsed : Visibility.Visible; }
    }

    // ---------- where received files go, and what happens when one arrives (beta.10)

    readonly WrapPanel _folderPills = new(), _perComputerPills = new(), _afterPills = new();
    readonly TextBlock _folderPath = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) },
                       _afterNote = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
    string? _folderDraft;   // null = Downloads\Lan-Line
    static string DesktopPath => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

    void BuildReceiveRows(StackPanel col)
    {
        col.Children.Add(Label("Save received files in"));
        _folderPills.Children.Add(Pill("folder", "Downloads\\Lan-Line", "default"));
        _folderPills.Children.Add(Pill("folder", "Desktop", "desktop"));
        _folderPills.Children.Add(Pill("folder", "Choose a folder…", "custom"));
        foreach (var r in _folderPills.Children.OfType<RadioButton>())
            r.Click += (_, _) =>
            {
                switch (r.Tag as string)
                {
                    case "default": _folderDraft = null; break;
                    case "desktop": _folderDraft = DesktopPath; break;
                    default:
                        var d = new Microsoft.Win32.OpenFolderDialog { Title = "Received files will be saved here", InitialDirectory = _folderDraft ?? LanLineConfig.DownloadsDir };
                        if (d.ShowDialog(this) == true) _folderDraft = d.FolderName;
                        break;
                }
                RefreshReceiveRows();
            };
        col.Children.Add(_folderPills);
        _folderPath.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(_folderPath);
        col.Children.Add(Label("A folder for each computer"));
        _perComputerPills.Children.Add(Pill("percomputer", "Off", false));
        _perComputerPills.Children.Add(Pill("percomputer", "On", true));
        col.Children.Add(_perComputerPills);
        col.Children.Add(Label("When a file arrives"));
        _afterPills.Children.Add(Pill("after", "Do nothing", LanLine.Core.AfterReceive.Nothing));
        _afterPills.Children.Add(Pill("after", "Show in folder", LanLine.Core.AfterReceive.Reveal));
        _afterPills.Children.Add(Pill("after", "Open it", LanLine.Core.AfterReceive.Open));
        foreach (var r in _afterPills.Children.OfType<RadioButton>()) r.Checked += (_, _) => RefreshReceiveRows();
        col.Children.Add(_afterPills);
        _afterNote.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        col.Children.Add(_afterNote);
    }

    void RefreshReceiveRows()
    {
        var tag = _folderDraft == null ? "default" : string.Equals(_folderDraft, DesktopPath, StringComparison.OrdinalIgnoreCase) ? "desktop" : "custom";
        Select(_folderPills, t => (string?)t == tag);
        _folderPath.Text = _folderDraft ?? (_demoSettings ? @"C:\Users\you\Downloads\Lan-Line" : LanLineConfig.DownloadsDir);   // screenshots never show the real user name
        _afterNote.Text = Selected(_afterPills) is LanLine.Core.AfterReceive.Open
            ? "Opens pictures, PDFs, text and media (up to 3 at a time). Apps, scripts, installers and archives are shown in their folder instead."
            : "Files save as soon as they arrive: pairing is what makes a computer trusted.";
    }

    void SaveSettings(StorageSettings s)
    {
        if (!_demo && Selected(_signInPills) is bool signIn && signIn != OpensAtSignIn()) SetOpenAtSignIn(signIn);
        s.LastUpdateCheck = _storage.LastUpdateCheck; s.LatestVersion = _storage.LatestVersion; s.LatestUrl = _storage.LatestUrl;
        s.TrayHintShown = _storage.TrayHintShown;
        s.TourSeen = _storage.TourSeen;
        _storage = s;
        ApplyTextScale();
        try { s.Save(SettingsPath); } catch (Exception e) { Note($"Couldn't save settings: {e.Message}"); }
        _settingsFirstRun = false;
        CloseSettings();
        MaybeShowTour();   // a new install: pairing and these settings are done, so say hello
        RunCleanup(manual: false);
        ApplyKeepRunning();
        ApplyHotKeys();
        ApplyHistory();
        ApplyClipboardShare();
        ApplyDownloads();
        ApplyEdgeDrop();
    }

    /// <summary>--demo-settings first|normal: the settings panel with sample usage (screenshots).</summary>
    bool _demoSettings;

    internal void DemoSettings(bool firstRun)
    {
        _demoSettings = true;
        _storage = new StorageSettings();
        if (!firstRun) { _storage.RetentionDays = 30; _storage.OverLimit = "trash"; _storage.Confirmed = true; }
        _settingsFirstRun = firstRun;
        LoadSettingsIntoPanel();
        _usageBytes = 8_400_000_000;
        RefreshUsageBar();
        _showingSettings = true;
        Height = 600;
        ApplyScreen();
    }
}

/// <summary>Moves a file to the Recycle Bin (recoverable), without any dialog.</summary>
static class RecycleBin
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd; public uint wFunc; public string pFrom; public string? pTo; public ushort fFlags;
        public int fAnyOperationsAborted; public IntPtr hNameMappings; public string? lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    public static bool Send(string path)
    {
        const uint FO_DELETE = 3;
        const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;
        var op = new SHFILEOPSTRUCT { wFunc = FO_DELETE, pFrom = path + "\0", fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI };
        return SHFileOperation(ref op) == 0 && op.fAnyOperationsAborted == 0 && !Path.Exists(path);
    }
}
