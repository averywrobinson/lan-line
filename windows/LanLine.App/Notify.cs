using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Windows toast notifications without the Windows SDK projection or any package (beta.10): the WinRT classes are
/// activated through combase and called through their vtables. Unpackaged apps need an AppUserModelID that Windows
/// knows; it is registered per user under HKCU\Software\Classes\AppUserModelId (name and icon), the same way the
/// Windows App SDK does it. Buttons and clicks are lanline:// links (protocol activation, registered alongside).
/// </summary>
static unsafe class WinToast
{
    public const string Aumid = "LanLine.Desktop";

    [DllImport("combase.dll")] static extern int WindowsCreateString([MarshalAs(UnmanagedType.LPWStr)] string s, int len, out IntPtr h);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr h);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);
    [DllImport("combase.dll")] static extern int RoActivateInstance(IntPtr classId, out IntPtr instance);

    static Guid IID_IXmlDocument = new("F7F3A506-1E87-42D6-BCFB-B8C809FA5494");
    static Guid IID_IXmlDocumentIO = new("6CD0E74E-EE65-4489-9EBF-CA43E87BA637");
    static Guid IID_IToastNotificationFactory = new("04124B20-82C6-4229-B109-FD9ED4662B53");
    static Guid IID_IToastNotificationManagerStatics = new("50AC103F-D235-4598-BBEF-98FE4D1A3AD4");

    // vtable slots: 0-2 IUnknown, 3-5 IInspectable, then the interface's own methods in declaration order
    static int Call(IntPtr o, int slot, IntPtr a) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)(*(*(void***)o + slot)))(o, a);
    static int Call(IntPtr o, int slot, IntPtr a, IntPtr* outp) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr*, int>)(*(*(void***)o + slot)))(o, a, outp);
    static int CallOutInt(IntPtr o, int slot, int* outv) => ((delegate* unmanaged[Stdcall]<IntPtr, int*, int>)(*(*(void***)o + slot)))(o, outv);

    sealed class HString : IDisposable
    {
        public readonly IntPtr H;
        public HString(string s) => Check(WindowsCreateString(s, s.Length, out H), "string");
        public void Dispose() => WindowsDeleteString(H);
    }

    static void Check(int hr, string what) { if (hr < 0) throw new COMException($"toast: {what} failed (0x{hr:X8})", hr); }
    static void Release(IntPtr p) { if (p != IntPtr.Zero) Marshal.Release(p); }

    static IntPtr Factory(string cls, ref Guid iid)
    {
        using var h = new HString(cls);
        Check(RoGetActivationFactory(h.H, ref iid, out var f), cls);
        return f;
    }

    static IntPtr Notifier()
    {
        var statics = Factory("Windows.UI.Notifications.ToastNotificationManager", ref IID_IToastNotificationManagerStatics);
        try
        {
            using var id = new HString(Aumid);
            IntPtr notifier;
            Check(Call(statics, 7, id.H, &notifier), "CreateToastNotifierWithId");   // slot 7
            return notifier;
        }
        finally { Release(statics); }
    }

    /// <summary>Show a toast. Throws (COMException) when Windows refuses; the caller falls back to the tray balloon.</summary>
    public static void Show(string xml)
    {
        IntPtr inst = 0, docIO = 0, doc = 0, factory = 0, toast = 0, notifier = 0;
        try
        {
            using (var cls = new HString("Windows.Data.Xml.Dom.XmlDocument")) Check(RoActivateInstance(cls.H, out inst), "XmlDocument");
            Check(Marshal.QueryInterface(inst, in IID_IXmlDocumentIO, out docIO), "IXmlDocumentIO");
            using (var x = new HString(xml)) Check(Call(docIO, 6, x.H), "LoadXml");                       // IXmlDocumentIO.LoadXml
            Check(Marshal.QueryInterface(inst, in IID_IXmlDocument, out doc), "IXmlDocument");
            factory = Factory("Windows.UI.Notifications.ToastNotification", ref IID_IToastNotificationFactory);
            Check(Call(factory, 6, doc, &toast), "CreateToastNotification");                              // slot 6
            notifier = Notifier();
            Check(Call(notifier, 6, toast), "Show");                                                        // IToastNotifier.Show
        }
        finally { foreach (var p in new[] { notifier, toast, factory, doc, docIO, inst }) Release(p); }
    }

    /// <summary>Whether Windows lets Lan-Line show toasts: true = on, false = turned off in Settings (or by policy),
    /// null = couldn't tell.</summary>
    public static bool? Enabled()
    {
        try
        {
            var n = Notifier();
            try { int v; Check(CallOutInt(n, 8, &v), "get_Setting"); return v == 0; }   // NotificationSetting.Enabled
            finally { Release(n); }
        }
        catch (Exception) { return null; }
    }

    /// <summary>Per-user registration (no admin): the AUMID's name and icon, and the lanline: link handler that
    /// points at this exe. Rewritten only when something differs; the installer writes the same keys and removes
    /// them on uninstall.</summary>
    public static void Register(string exe)
    {
        try
        {
            var icon = IconPng();
            using (var k = Registry.CurrentUser.CreateSubKey($@"Software\Classes\AppUserModelId\{Aumid}"))
            {
                Set(k, "DisplayName", "Lan-Line");
                if (icon != null) Set(k, "IconUri", icon);
            }
            using (var k = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ArrivalNotices.Scheme}"))
            {
                Set(k, "", "URL:Lan-Line");
                Set(k, "URL Protocol", "");
            }
            using (var k = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ArrivalNotices.Scheme}\DefaultIcon")) Set(k, "", $"\"{exe}\",0");
            using (var k = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ArrivalNotices.Scheme}\shell\open\command")) Set(k, "", $"\"{exe}\" --url \"%1\"");
        }
        catch (Exception) { /* no toasts then; the tray balloon still works */ }

        static void Set(RegistryKey k, string name, string v) { if (k.GetValue(name) as string != v) k.SetValue(name, v); }
    }

    /// <summary>The app icon as a PNG next to the settings (toasts show it in their header).</summary>
    static string? IconPng()
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lan-Line");
            var path = Path.Combine(dir, "notify-icon.png");
            if (File.Exists(path)) return path;
            Directory.CreateDirectory(dir);
            var dec = BitmapDecoder.Create(new Uri("pack://application:,,,/Lan-Line;component/LanLine.ico"), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            var big = dec.Frames.OrderByDescending(f => f.PixelWidth).First();
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(big));
            using (var fs = File.Create(path)) enc.Save(fs);
            return path;
        }
        catch (Exception) { return null; }
    }
}

/// <summary>Arrival notifications in the window (beta.10): collects a burst, posts one toast, answers its buttons.</summary>
sealed partial class MainWindow
{
    readonly List<(string From, Item Item)> _pendingNotices = [];
    System.Windows.Threading.DispatcherTimer? _noticeTimer;
    DateTime? _burstStarted;
    /// <summary>Toasts refused in a row. One refusal can be about one notice; three in a row means toasts don't work
    /// here, and the tray balloon takes over for this run.</summary>
    int _toastRefusals;
    bool ToastBroken => _toastRefusals >= 3;

    /// <summary>Notify only while Lan-Line isn't the window in use.</summary>
    bool ShouldNotify => _storage.NotifyOnArrivalValue && !InUse;

    void NotifyArrived(string from, Item item)
    {
        _pendingNotices.Add((from, item));
        var now = DateTime.UtcNow;
        _burstStarted ??= now;
        var wait = TimeSpan.FromSeconds(Math.Min(ArrivalNotices.Coalesce.TotalSeconds, Math.Max(0, 3 - (now - _burstStarted.Value).TotalSeconds)));
        _noticeTimer?.Stop();
        _noticeTimer = new System.Windows.Threading.DispatcherTimer { Interval = wait };
        _noticeTimer.Tick += (_, _) =>
        {
            _noticeTimer?.Stop();
            var batch = _pendingNotices.ToList();
            _pendingNotices.Clear(); _burstStarted = null;
            if (ArrivalNotices.Make(batch) is { } n) PostNotice(n);
        };
        _noticeTimer.Start();
    }

    void NotifyFailed(string from, string name, string reason) => PostNotice(ArrivalNotices.Failed(from, name, reason));

    void PostNotice(ArrivalNotice n)
    {
        if (!ToastBroken)
        {
            try { WinToast.Show(ToastXml.Build(n)); _toastRefusals = 0; DebugLog($"toast shown: {n.Title} / {n.Body} (enabled: {WinToast.Enabled()?.ToString() ?? "unknown"})"); return; }
            catch (Exception e) { _toastRefusals++; DebugLog($"toast refused ({_toastRefusals}), using the tray balloon for this one: {e.Message}"); }
        }
        if (_tray == null) return;
        _balloonItem = n.ItemId;
        _tray.ShowBalloonTip(6000, n.Title, n.Body, System.Windows.Forms.ToolTipIcon.None);
    }

    string? _balloonItem;

    /// <summary>--debug-log PATH: append diagnostic lines (support and tests; off by default).</summary>
    internal static string? DebugLogPath;
    static void DebugLog(string line)
    {
        if (DebugLogPath is not { } p) return;
        try { File.AppendAllText(p, $"{DateTime.Now:O} {line}{Environment.NewLine}"); } catch (Exception) { }
    }

    /// <summary>A lanline://notify link from a toast (via the pipe, or the command line when Lan-Line wasn't running).</summary>
    internal void HandleLink(string url)
    {
        DebugLog($"link: {url}");
        if (ArrivalNotices.ParseLink(url) is not { } l) return;
        ItemRow? row = l.Id != null && _rows.TryGetValue(l.Id, out var r) ? r : null;
        switch (l.Action)
        {
            case NoticeAction.Copy when row != null:   // a one-time code: just the code (beta.10)
                if (SmartText.Analyze(row.Item.Text ?? "").Otp is { } otp) { try { Clipboard.SetText(otp); } catch (Exception) { } }
                else row.Copy();
                return;
            case NoticeAction.Open when row is { Exists: true }: row.Open(); return;
            case NoticeAction.Reveal when row is { Exists: true }: row.Reveal(); return;
        }
        ShowFromTray();
        if (row != null) Dispatcher.BeginInvoke(row.Highlight, System.Windows.Threading.DispatcherPriority.Loaded);
        if (l.Action != NoticeAction.Show) Note(row == null ? "That item is from an earlier session." : "That item is no longer in the Lan-Line folder.", 6);
    }

    /// <summary>--test-notify text|file|picture|burst|failed: post a sample toast after 2 s (checks and screenshots).</summary>
    internal void TestNotify(string kind)
    {
        var dir = Path.Combine(Path.GetTempPath(), "lan-line-demo");
        var png = Path.Combine(dir, "hero-export.png");
        var pdf = Path.Combine(dir, "Q4 plan.pdf");
        var text = new Item("test-text", true, "Meeting moved to 3:30. Bring the Q4 deck and the new icons, please.", null, 0, null, ItemState.ReceivedState);
        var file = new Item("test-file", true, null, "Q4 plan.pdf", 412_000, pdf, ItemState.ReceivedState);
        var pic = new Item("test-pic", true, null, "hero-export.png", File.Exists(png) ? new FileInfo(png).Length : 0, png, ItemState.ReceivedState);
        foreach (var i in new[] { text, file, pic }) Upsert(i);
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            switch (kind)
            {
                case "text": NotifyArrived("MacBook Pro", text); break;
                case "file": NotifyArrived("MacBook Pro", file); break;
                case "picture": NotifyArrived("MacBook Pro", pic); break;
                case "failed": NotifyFailed("MacBook Pro", "big.zip", "not enough disk space"); break;
                default: foreach (var i in new[] { file, pic, text }) NotifyArrived("MacBook Pro", i); break;
            }
        };
        t.Start();
    }
}
