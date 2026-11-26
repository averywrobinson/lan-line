using System.Windows.Shell;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Live transfer feedback (beta.10): speed and time left on moving cards, a cancel button for queued and moving
/// items (either direction), and the taskbar button's progress bar while anything is moving.
/// </summary>
sealed partial class MainWindow
{
    readonly Dictionary<string, TransferRate> _rates = [];
    /// <summary>Names whose failure an incoming card already shows (so no second note).</summary>
    readonly HashSet<string> _cardedFailures = [];
    readonly Dictionary<string, (double Done, long Total)> _moving = [];

    /// <summary>--demo-smart: a code, a colour, code, a single link and a message with links (screenshots).</summary>
    internal void DemoSmart()
    {
        var texts = new (string Text, bool In)[]
        {
            ("Your Lan-Line test verification code is 482913. It expires in 10 minutes.", true),
            ("#3A7BD5", false),
            ("```csharp\nvar port = 47830;\nConsole.WriteLine($\"listening on {port}\");\n```", true),
            ("https://github.com/averywrobinson/lan-line/releases", false),
            ("Notes are in https://example.com/q4-plan and the deck on www.example.org/deck", true),
        };
        for (var i = 0; i < texts.Length; i++)
            Upsert(new Item($"s{i}", texts[i].In, texts[i].Text, null, texts[i].Text.Length, null, texts[i].In ? ItemState.ReceivedState : ItemState.Delivered));
    }

    /// <summary>"Show link previews" (beta.10); never in demos and screenshots.</summary>
    internal bool LinkPreviewsOn => !_demo && _storage.LinkPreviewsValue;

    static bool IsMoving(ItemState s) => s.Kind is ItemStateKind.Sending or ItemStateKind.Receiving;

    void Track(Item item)
    {
        if (IsMoving(item.State))
        {
            if (!_rates.TryGetValue(item.Id, out var r)) _rates[item.Id] = r = new TransferRate();
            r.Update((long)(item.State.Progress * item.Size), DateTime.UtcNow);
            _moving[item.Id] = (item.State.Progress * Math.Max(item.Size, 0), Math.Max(item.Size, 0));
        }
        else if (item.State.Kind != ItemStateKind.Waiting)
        {
            _rates.Remove(item.Id);
            _moving.Remove(item.Id);
        }
        RefreshTaskbarProgress();
    }

    /// <summary>--demo-transfers: a file arriving, one sending, one queued and one cancelled (screenshots).</summary>
    internal void DemoTransfers(string dir)
    {
        var t = DateTime.UtcNow;
        void Rate(string id, long done, double bps) { var r = new TransferRate(); r.Update(done - (long)bps, t.AddSeconds(-1)); r.Update(done, t); _rates[id] = r; }
        var items = new[]
        {
            new Item("t1", true, "Sending the renders now", null, 0, null, ItemState.ReceivedState),
            new Item("t2", true, null, "render-final.mov", 1_820_000_000, System.IO.Path.Combine(dir, "render-final.mov"), new ItemState(ItemStateKind.Receiving, 0.38)),
            new Item("t3", false, null, "Q4 plan.pdf", 412_000_000, System.IO.Path.Combine(dir, "Q4 plan.pdf"), new ItemState(ItemStateKind.Sending, 0.42)),
            new Item("t4", false, null, "Shoot 11-24", 6_400_000_000, System.IO.Path.Combine(dir, "Shoot"), ItemState.Waiting, 214),
            new Item("t5", true, null, "old-cut.mov", 900_000_000, System.IO.Path.Combine(dir, "old-cut.mov"), ItemState.CancelledState),
        };
        Rate("t2", 691_600_000, 85_000_000);
        Rate("t3", 173_040_000, 31_000_000);
        foreach (var i in items) { Track(i); Upsert(i); }
    }

    /// <summary>"42% · 85 MB/s · 12 s left" for a moving card; null otherwise.</summary>
    internal string? ProgressText(Item item) =>
        IsMoving(item.State) ? (_rates.TryGetValue(item.Id, out var r) ? r : new TransferRate()).Describe((long)(item.State.Progress * item.Size), item.Size) : null;

    /// <summary>Queued or moving, either direction.</summary>
    internal bool CanCancel(Item item) => item.State.Kind switch
    {
        ItemStateKind.Waiting or ItemStateKind.Sending => !item.Incoming && item.IsFile,
        ItemStateKind.Receiving => item.Incoming,
        _ => false,
    };

    internal void CancelTransfer(ItemRow row)
    {
        var item = row.Item;
        if (_hub == null || !CanCancel(item)) return;
        // A search result is a copy of the feed's row and may not know who is sending: ask the feed's row.
        var from = row.Partner ?? (_rows.TryGetValue(item.Id, out var live) ? live.Partner : null);
        if (item.Incoming) { if (from is { } p) _hub.CancelIncoming(p, item.Id); }
        else _hub.Cancel(item.Id);
    }

    void RefreshTaskbarProgress()
    {
        TaskbarItemInfo ??= new TaskbarItemInfo();
        double done = 0, total = 0;
        foreach (var (d, t) in _moving.Values) { done += d; total += t; }
        if (total <= 0) { TaskbarItemInfo.ProgressState = TaskbarItemProgressState.None; return; }
        TaskbarItemInfo.ProgressState = TaskbarItemProgressState.Normal;
        TaskbarItemInfo.ProgressValue = done / total;
    }
}
