using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// History and search (beta.10). Finished items are kept in history.jsonl (up to 1,000, this PC only) and come back
/// at launch; Ctrl+F opens a search bar that looks through all of them: every word must match the text, a file name
/// or the other computer's name (case and accents ignored), and the chips narrow it to texts, pictures, files or links.
/// </summary>
sealed partial class MainWindow
{
    string? _historyPath;
    List<HistoryEntry> _history = [];
    readonly HashSet<string> _recorded = [];
    bool _loadingHistory;

    bool _searchOpen;
    HistoryFilter _filter = HistoryFilter.All;
    Border? _searchBar;
    readonly TextBox _searchBox = new() { FontSize = 13, BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalContentAlignment = VerticalAlignment.Center };
    readonly TextBlock _searchHint = new() { Text = "Search texts, files and computers", FontSize = 13, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(3, 0, 0, 0) };
    readonly TextBlock _matchCount = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    readonly WrapPanel _chips = new();
    readonly StackPanel _results = new() { Margin = new Thickness(14, 12, 14, 8) };
    readonly Dictionary<string, ItemRow> _resultRows = [];
    readonly TextBlock _noMatches = new() { FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(20, 40, 20, 0) };
    System.Windows.Threading.DispatcherTimer? _searchDebounce;

    bool Filtering => _searchOpen && (_searchBox.Text.Trim().Length > 0 || _filter != HistoryFilter.All);

    // ---------- keeping it

    string HistoryFile => Path.Combine(Path.GetDirectoryName(ConfigPath)!, History.FileName);

    /// <summary>"Keep history" on: load it into the feed (at start); turned off: forget it, file and all.</summary>
    void ApplyHistory()
    {
        if (_demo) return;
        if (_storage.KeepHistoryValue)
        {
            if (_historyPath != null) return;
            _historyPath = HistoryFile;
            LoadHistory();
        }
        else if (_historyPath != null || File.Exists(HistoryFile))
        {
            _historyPath = HistoryFile;
            ClearHistory();
            _historyPath = null;
        }
    }

    void LoadHistory()
    {
        if (_historyPath == null) return;
        _history = History.Load(_historyPath);
        try { History.Compact(_history, _historyPath); } catch (Exception) { }
        foreach (var e in _history) _recorded.Add(e.Id);
        _loadingHistory = true;
        var start = Math.Max(0, _history.Count - MaxRows);
        var at = 0;
        foreach (var e in _history.Skip(start))
        {
            Upsert(ItemFor(e), Caption(e));
            _feed.Children.Remove(_rows[e.Id].View);
            _feed.Children.Insert(at++, _rows[e.Id].View);   // before anything this session already showed
            if (e.Kind != "text" && e.Path is { } p && !File.Exists(p) && !Directory.Exists(p)) _rows[e.Id].MarkMissing();
        }
        _loadingHistory = false;
        RefreshEmpty();
        _scroll.ScrollToEnd();
    }

    /// <summary>An item reached its end (received, delivered, failed, cancelled): keep it.</summary>
    void Record(Item item, string? who)
    {
        if (_historyPath == null || _recorded.Contains(item.Id)) return;
        if (item.State.Kind is not (ItemStateKind.Received or ItemStateKind.Delivered or ItemStateKind.Failed or ItemStateKind.Cancelled)) return;
        _recorded.Add(item.Id);
        var e = new HistoryEntry
        {
            Id = item.Id, Incoming = item.Incoming, Kind = !item.IsFile ? "text" : item.IsFolder ? "folder" : "file",
            Text = item.Text, Name = item.FileName, Size = item.IsFile ? item.Size : null, Path = item.Path, Count = item.Count,
            At = DateTime.UtcNow, Who = who, Error = item.State.Error,
            State = item.State.Kind switch { ItemStateKind.Delivered => "delivered", ItemStateKind.Failed => "failed", ItemStateKind.Cancelled => "cancelled", _ => "received" },
        };
        _history.Add(e);
        if (_history.Count > History.Cap) _history.RemoveRange(0, _history.Count - History.Cap);
        try { History.Append(e, _historyPath); } catch (Exception) { }
    }

    void ForgetInHistory(string id)
    {
        if (_history.RemoveAll(e => e.Id == id) == 0 || _historyPath == null) return;
        try { History.Compact(_history, _historyPath); } catch (Exception) { }
    }

    /// <summary>Forget everything kept; items still moving stay in the window.</summary>
    void ClearHistory()
    {
        if (_historyPath != null) History.Clear(_historyPath);
        _history = []; _recorded.Clear();
        foreach (var (id, row) in _rows.ToList())
        {
            if (row.Item.State.Kind is not (ItemStateKind.Received or ItemStateKind.Delivered or ItemStateKind.Failed or ItemStateKind.Cancelled)) continue;
            _feed.Children.Remove(row.View);
            _rows.Remove(id);
        }
        RefreshEmpty();
        if (Filtering) RefreshResults();
    }

    static Item ItemFor(HistoryEntry e)
    {
        var st = e.State switch
        {
            "delivered" => ItemState.Delivered,
            "failed" => new ItemState(ItemStateKind.Failed, Error: e.Error ?? "failed"),
            "cancelled" => ItemState.CancelledState,
            _ => ItemState.ReceivedState,
        };
        return e.Kind == "text"
            ? new Item(e.Id, e.Incoming, e.Text ?? "", null, (e.Text ?? "").Length, null, st)
            : new Item(e.Id, e.Incoming, null, e.Name ?? "file", e.Size ?? 0, e.Path, st, e.Kind == "folder" ? e.Count ?? 0 : null);
    }

    string? Caption(HistoryEntry e) => Multi && e.Who is { } w ? (e.Incoming ? $"from {w}" : $"to {w}") : null;

    // ---------- searching it

    internal void OpenSearch()
    {
        if (_showingSettings || _pairing) return;
        ShowFromTray();
        Deselect();
        EnsureSearchBar();
        _searchOpen = true;
        _searchBar!.Visibility = Visibility.Visible;
        _searchBox.Focus();
        _searchBox.SelectAll();
        RefreshResults();
    }

    void CloseSearch()
    {
        if (!_searchOpen) return;
        _searchOpen = false;
        _searchBox.Text = "";
        _filter = HistoryFilter.All;
        if (_searchBar != null) _searchBar.Visibility = Visibility.Collapsed;
        RefreshResults();
        _input.Focus();
    }

    void EnsureSearchBar()
    {
        if (_searchBar != null) return;
        var icon = new TextBlock { Text = "", FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        icon.SetResourceReference(TextBlock.ForegroundProperty, "Icon");
        _searchBox.SetResourceReference(Control.ForegroundProperty, "Text");
        _searchBox.SetResourceReference(TextBoxBase.CaretBrushProperty, "Text");
        _searchHint.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        Automation(_searchBox, "Search");
        _searchBox.TextChanged += (_, _) =>
        {
            _searchHint.Visibility = _searchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _searchDebounce ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            _searchDebounce.Stop();
            _searchDebounce.Tick -= DebouncedRefresh; _searchDebounce.Tick += DebouncedRefresh;
            _searchDebounce.Start();
        };
        _searchBox.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; CloseSearch(); }
            else if (e.Key == Key.Down && FeedRows() is { Count: > 0 } r) { e.Handled = true; Select(r[^1]); r[^1].View.BringIntoView(); }
        };
        var done = new Button { Content = "Done", FontSize = 12, Margin = new Thickness(8, 0, 0, 0), ToolTip = "Close search (Esc)" };
        done.SetResourceReference(StyleProperty, "LinkButton");
        done.Click += (_, _) => CloseSearch();
        var field = new Grid();
        field.Children.Add(_searchHint);
        field.Children.Add(_searchBox);
        var line = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left); DockPanel.SetDock(done, Dock.Right);
        line.Children.Add(icon); line.Children.Add(done); line.Children.Add(field);
        var box = new Border { Child = line, CornerRadius = new CornerRadius(9), Padding = new Thickness(9, 5, 9, 5) };
        box.SetResourceReference(Border.BackgroundProperty, "CardStroke");
        foreach (var f in Enum.GetValues<HistoryFilter>())
        {
            var chip = new RadioButton { Content = History.Title(f), GroupName = "searchfilter", Tag = f, IsChecked = f == HistoryFilter.All, FontSize = 12 };
            chip.SetResourceReference(StyleProperty, "Pill");
            chip.Checked += (_, _) => { _filter = f; RefreshResults(); };
            _chips.Children.Add(chip);
        }
        _matchCount.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var chipsLine = new DockPanel { Margin = new Thickness(0, 7, 0, 0) };
        DockPanel.SetDock(_matchCount, Dock.Right);
        chipsLine.Children.Add(_matchCount); chipsLine.Children.Add(_chips);
        var stack = new StackPanel();
        stack.Children.Add(box); stack.Children.Add(chipsLine);
        _searchBar = new Border { Child = stack, Padding = new Thickness(12, 8, 12, 4), Visibility = Visibility.Collapsed };
        DockPanel.SetDock(_searchBar, Dock.Top);
        var root = (DockPanel)((Grid)Content).Children[0];
        root.Children.Insert(root.Children.Count - 1, _searchBar);   // above the feed, under the header
        _noMatches.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
    }

    void DebouncedRefresh(object? s, EventArgs e) { _searchDebounce?.Stop(); RefreshResults(); }

    /// <summary>The feed, or the matches (history plus items still moving, newest last).</summary>
    void RefreshResults()
    {
        foreach (var c in _chips.Children.OfType<RadioButton>()) c.IsChecked = (HistoryFilter)c.Tag == _filter;
        if (!Filtering)
        {
            if (_scroll.Content != _feed) { _scroll.Content = _feed; _resultRows.Clear(); _results.Children.Clear(); _scroll.ScrollToEnd(); }
            _matchCount.Text = "";
            RefreshEmpty();
            return;
        }
        var q = _searchBox.Text;
        var seen = new HashSet<string>();
        var items = new List<(Item Item, string? Caption)>();
        foreach (var e in _history.Where(e => History.Matches(e, q, _filter)))
        {
            seen.Add(e.Id);
            items.Add(_rows.TryGetValue(e.Id, out var live) ? (live.Item, Caption(e)) : (ItemFor(e), Caption(e)));
        }
        foreach (var r in FeedRowsOf(_feed, _rows).Where(r => !seen.Contains(r.Item.Id)))   // still moving: not in the history yet
        {
            var it = r.Item;
            var probe = new HistoryEntry { Id = it.Id, Kind = !it.IsFile ? "text" : it.IsFolder ? "folder" : "file", Text = it.Text, Name = it.FileName };
            if (History.Matches(probe, q, _filter)) items.Add((it, null));
        }
        Deselect();
        _results.Children.Clear();
        _resultRows.Clear();
        foreach (var (it, cap) in items)
        {
            var row = new ItemRow(it, this);
            if (_rows.TryGetValue(it.Id, out var feedRow)) row.Partner = feedRow.Partner;   // so cancel works from the results too
            row.SetCaption(cap);
            if (it.IsFile && it.Path is { } p && !File.Exists(p) && !Directory.Exists(p) && it.State.Kind is ItemStateKind.Received or ItemStateKind.Delivered) row.MarkMissing();
            _resultRows[it.Id] = row;
            _results.Children.Add(row.View);
        }
        _noMatches.Text = _historyPath == null ? "No matches.\nHistory is off, so only this session's items are searched." : $"No matches.\nSearch covers the last {History.Cap:N0} items on this PC.";
        if (items.Count == 0) _results.Children.Add(_noMatches);
        _matchCount.Text = $"{items.Count} {(items.Count == 1 ? "match" : "matches")}";
        _empty.Visibility = Visibility.Collapsed;
        _scroll.Content = _results;
        _scroll.ScrollToEnd();
    }

    static List<ItemRow> FeedRowsOf(Panel panel, Dictionary<string, ItemRow> map) =>
        panel.Children.OfType<FrameworkElement>().Select(v => v.Tag is string id && map.TryGetValue(id, out var r) ? r : null).OfType<ItemRow>().ToList();

    /// <summary>--demo-search "QUERY" or "QUERY|filter": the search bar open (screenshots).</summary>
    internal void DemoSearch(string spec)
    {
        var parts = spec.Split('|', 2);
        EnsureSearchBar();
        _searchOpen = true;
        _searchBar!.Visibility = Visibility.Visible;
        _searchBox.Text = parts[0];
        if (parts.Length > 1 && Enum.TryParse<HistoryFilter>(parts[1], true, out var f)) _filter = f;
        RefreshResults();
    }
}
