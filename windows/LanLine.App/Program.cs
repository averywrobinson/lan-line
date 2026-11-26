using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LanLine.Core;

namespace LanLine.App;

static class Program
{
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);

    [STAThread]
    static int Main(string[] args)
    {
        args = LaunchArgs.LinkOnly(args);   // a lanline: link launch is only that link, before any flag is read
        if (Headless.Wants(args))
        {
            if (!Console.IsOutputRedirected) AttachConsole(-1);   // WinExe: borrow the parent console when there is one
            return Headless.Run(args);
        }
        var snapshot = Arg(args, "--snapshot");
        Theme.Forced = Arg(args, "--theme") switch { "dark" => true, "light" => false, _ => null };
        Theme.ForcedHighContrast = Arg(args, "--theme") == "hc";   // a stand-in contrast theme, for checks
        if (double.TryParse(Arg(args, "--text-scale"), System.Globalization.CultureInfo.InvariantCulture, out var forcedScale)) MainWindow.ForcedTextScale = Math.Clamp(forcedScale, 0.9, 2.25);
        Theme.Glass = snapshot == null && !args.Contains("--no-glass") && Theme.GlassSupported;

        // Explorer's "Send to → Lan-Line" / "Send with Lan-Line" start Lan-Line.exe --stage PATH… (beta.8).
        var stage = StageRequest.FromArgs(args);
        // A toast's button or click opens lanline://notify?… (beta.10): Windows starts Lan-Line.exe --url LINK.
        var link = Arg(args, "--url");
        MainWindow.DebugLogPath = Arg(args, "--debug-log");
        var pipe = StageRequest.PipeName(System.Diagnostics.Process.GetCurrentProcess().SessionId);
        if (Arg(args, "--test-notify") != null && Arg(args, "--test-pipe") is { } tp) pipe = tp;   // a test copy's own pipe

        // One window per user: two PC instances would keep replacing each other at the Mac.
        var testRun = snapshot != null || Arg(args, "--test-notify") != null || Arg(args, "--render-badges") != null || Arg(args, "--render-edge") != null;   // checks never collide with the user's Lan-Line
        using var single = new Mutex(true, !testRun ? @"Local\Lan-Line.SingleInstance" : @"Local\Lan-Line.Snapshot." + Environment.ProcessId, out var first);
        if (!first)
        {
            // Hand the paths (or just "show yourself") to the running window, which may still be starting.
            AllowSetForegroundWindow(-1);   // ASFW_ANY: let it come to the front
            if (link != null) return StageRequest.TrySendLink(pipe, link, TimeSpan.FromSeconds(10)) ? 0 : 1;
            if (StageRequest.TrySend(pipe, stage ?? [], TimeSpan.FromSeconds(10))) return 0;
            MessageBox.Show("Lan-Line is already running.", "Lan-Line");
            return 0;
        }
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Lan-Line;component/Styles.xaml") });
        Theme.Apply(app.Resources);
        var demoPair = Arg(args, "--demo-pair");
        var demoSettings = Arg(args, "--demo-settings");
        var demo = args.Contains("--demo") || args.Contains("--demo-multi") || demoPair != null || demoSettings != null;
        var w = new MainWindow(args, demo);
        w.ApplyTextScale();
        if (Arg(args, "--render-badges") is { } rb) { w.RenderBadges(rb); return 0; }
        if (Arg(args, "--render-edge") is { } re) { new EdgeDropZone(w).RenderTo(re); return 0; }
        if (demoSettings != null) { Demo.Fill(w, empty: false); w.DemoSettings(demoSettings == "first"); }
        else if (demoPair != null) w.DemoPair(demoPair);
        else if (args.Contains("--demo-multi")) Demo.Multi(w);
        else if (demo) Demo.Fill(w, empty: args.Contains("--empty"));
        if (stage is { Count: > 0 } && snapshot != null) w.Stage(stage, show: false);   // screenshots of the chips
        if (Arg(args, "--demo-preview") is { } dp) w.DemoPreview(dp);
        if (args.Contains("--demo-shortcuts")) w.ShowShortcuts(bringForward: false);
        if (int.TryParse(Arg(args, "--demo-tour"), out var tourPage)) w.ShowTour(tourPage);   // screenshots of a tour card
        if (args.Contains("--demo-smart")) w.DemoSmart();
        if (Arg(args, "--demo-search") is { } ds) w.DemoSearch(ds);
        if (args.Contains("--demo-transfers")) w.DemoTransfers(Path.Combine(Path.GetTempPath(), "lan-line-demo"));
        if (snapshot != null)
        {
            if (Arg(args, "--snapshot-size")?.Split('x') is [var sw, var sh] && double.TryParse(sw, out var ww) && double.TryParse(sh, out var hh)) { w.Width = ww; w.Height = hh; }
            return Snapshot(w, snapshot);
        }
        if (demo) w.DemoTray();
        else WinToast.Register(Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Lan-Line.exe"));
        if (Arg(args, "--test-notify") is { } tn) { WinToast.Register(Environment.ProcessPath!); w.Loaded += (_, _) => w.TestNotify(tn); }
        if (link != null) w.Loaded += (_, _) => w.HandleLink(link);   // Lan-Line wasn't running when the toast was clicked
        app.SessionEnding += (_, _) => w.PrepareToQuit();   // sign-out / shutdown: close for real, not to the tray
        if (Arg(args, "--test-close-after") is { } tc && double.TryParse(tc, out var tcs))   // checks of the tray path (beta.9)
            Delay(tcs, w.UserCloseForTest);
        if (Arg(args, "--test-reopen-after") is { } tr && double.TryParse(tr, out var trs))
            Delay(trs, w.ShowFromTrayForTest);
        Theme.Follow(app, w.ThemeChanged);
        using var stop = new CancellationTokenSource();
        _ = StageRequest.Listen(pipe, paths => w.Dispatcher.BeginInvoke(() => w.Stage(paths)), stop.Token,
                                onLink: l => w.Dispatcher.BeginInvoke(() => w.HandleLink(l)));
        if (stage is { Count: > 0 }) w.Loaded += (_, _) => w.Stage(stage);
        int code;
        if (args.Contains(SignIn.BackgroundFlag) && w.CanStartHidden)
        {
            // Opened at sign-in: wait in the tray (the window comes up when something arrives or from the tray).
            new System.Windows.Interop.WindowInteropHelper(w).EnsureHandle();
            app.MainWindow = w;
            code = app.Run();
        }
        else code = app.Run(w);
        stop.Cancel();
        return code;
    }

    static void Delay(double seconds, Action act)
    {
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); act(); };
        t.Start();
    }

    static string? Arg(string[] a, string f) { var i = Array.IndexOf(a, f); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }

    /// <summary>--snapshot PATH: lay the window's content out off-screen, render it at 2x to a PNG, exit.</summary>
    static int Snapshot(MainWindow w, string path)
    {
        var root = (FrameworkElement)w.Content;
        w.Content = null;
        var host = new System.Windows.Controls.Border { Child = root, Width = w.Width, Height = w.Height };
        host.SetResourceReference(System.Windows.Controls.Border.BackgroundProperty, "Bg");
        host.Resources.MergedDictionaries.Add(Application.Current.Resources);
        host.Measure(new Size(w.Width, w.Height));
        host.Arrange(new Rect(0, 0, w.Width, w.Height));
        host.UpdateLayout();
        // let background work land (Explorer thumbnails come from their own thread): pump for a moment
        var frame = new System.Windows.Threading.DispatcherFrame();
        var wait = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        wait.Tick += (_, _) => { wait.Stop(); frame.Continue = false; };
        wait.Start();
        System.Windows.Threading.Dispatcher.PushFrame(frame);
        host.UpdateLayout();
        System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        host.UpdateLayout();
        var bmp = new RenderTargetBitmap((int)(w.Width * 2), (int)(w.Height * 2), 192, 192, PixelFormats.Pbgra32);
        bmp.Render(host);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(path);
        enc.Save(fs);
        return 0;
    }
}

/// <summary>--demo: sample items for screenshots and design checks (no network).</summary>
static class Demo
{
    public static void Multi(MainWindow w) => Fill(w, empty: false, multi: true);

    public static void Fill(MainWindow w, bool empty, bool multi = false)
    {
        var dir = Path.Combine(Path.GetTempPath(), "lan-line-demo");
        Directory.CreateDirectory(dir);
        var png = Path.Combine(dir, "hero-export.png");
        if (!File.Exists(png))
        {
            // a small sample image: the app icon
            var dec = BitmapDecoder.Create(new Uri("pack://application:,,,/Lan-Line;component/LanLine.ico"), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            var big = dec.Frames.OrderByDescending(f => f.PixelWidth).First();
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(big));
            using var fs = File.Create(png);
            enc.Save(fs);
        }
        var pdf = Path.Combine(dir, "Q4 plan.pdf");
        if (!File.Exists(pdf)) File.WriteAllBytes(pdf, new byte[412_000]);
        if (empty) { w.SetDemo("MacBook Pro", []); return; }
        if (multi)
        {
            w.SetDemoMulti(
            [
                (new Item("1", true, "Can you send the new deck?", null, 0, null, ItemState.ReceivedState), "from MacBook Pro"),
                (new Item("2", false, "Updated deck & icons", null, 0, null, ItemState.Delivered), "to everyone"),
                (new Item("3", false, null, "hero-export.png", 2_400_000, png, ItemState.Delivered), "to Intel Mac"),
                (new Item("4", false, null, "Q4 plan.pdf", 412_000, pdf, ItemState.Sent), "to everyone · ✓ 1/2"),
            ]);
            return;
        }
        w.SetDemo("MacBook Pro",
        [
            new Item("1", false, "Can you send the new deck?", null, 0, null, new ItemState(ItemStateKind.Delivered)),
            new Item("2", true, "Updated deck & icons", null, 0, null, ItemState.ReceivedState),
            new Item("3", true, null, "hero-export.png", 2_400_000, png, ItemState.ReceivedState),
            new Item("4", false, null, "Q4 plan.pdf", 412_000, pdf, new ItemState(ItemStateKind.Sending, 0.42)),
        ]);
    }
}
