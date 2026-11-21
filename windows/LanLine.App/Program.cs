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

    [STAThread]
    static int Main(string[] args)
    {
        if (Headless.Wants(args))
        {
            if (!Console.IsOutputRedirected) AttachConsole(-1);   // WinExe: borrow the parent console when there is one
            return Headless.Run(args);
        }
        var snapshot = Arg(args, "--snapshot");
        Theme.Forced = Arg(args, "--theme") switch { "dark" => true, "light" => false, _ => null };
        Theme.Glass = snapshot == null && !args.Contains("--no-glass") && Theme.GlassSupported;

        // One window per user: two PC instances would keep replacing each other at the Mac.
        using var single = new Mutex(true, snapshot == null ? @"Local\Lan-Line.SingleInstance" : @"Local\Lan-Line.Snapshot." + Environment.ProcessId, out var first);
        if (!first)
        {
            MessageBox.Show("Lan-Line is already running.", "Lan-Line");
            return 0;
        }
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Lan-Line;component/Styles.xaml") });
        Theme.Apply(app.Resources);
        var demoPair = Arg(args, "--demo-pair");
        var demoSettings = Arg(args, "--demo-settings");
        var demo = args.Contains("--demo") || demoPair != null || demoSettings != null;
        var w = new MainWindow(args, demo);
        if (demoSettings != null) { Demo.Fill(w, empty: false); w.DemoSettings(demoSettings == "first"); }
        else if (demoPair != null) w.DemoPair(demoPair);
        else if (demo) Demo.Fill(w, empty: args.Contains("--empty"));
        if (snapshot != null)
        {
            if (Arg(args, "--snapshot-size")?.Split('x') is [var sw, var sh] && double.TryParse(sw, out var ww) && double.TryParse(sh, out var hh)) { w.Width = ww; w.Height = hh; }
            return Snapshot(w, snapshot);
        }
        Theme.Follow(app, w.ThemeChanged);
        return app.Run(w);
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
    public static void Fill(MainWindow w, bool empty)
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
        w.SetDemo("MacBook Pro",
        [
            new Item("1", false, "Can you send the new deck?", null, 0, null, new ItemState(ItemStateKind.Delivered)),
            new Item("2", true, "Updated deck & icons", null, 0, null, ItemState.ReceivedState),
            new Item("3", true, null, "hero-export.png", 2_400_000, png, ItemState.ReceivedState),
            new Item("4", false, null, "Q4 plan.pdf", 412_000, pdf, new ItemState(ItemStateKind.Sending, 0.42)),
        ]);
    }
}
