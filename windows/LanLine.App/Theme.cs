using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace LanLine.App;

/// <summary>
/// Light/dark palettes (the same values as the Mac app) applied as application-wide brushes,
/// following the Windows "app mode" setting and switching live when it changes.
/// </summary>
static class Theme
{
    public static bool IsDark { get; private set; }

    /// <summary>Forced by --theme light|dark (screenshots); null = follow Windows.</summary>
    public static bool? Forced { get; set; }

    public static bool SystemIsDark()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch (Exception) { return false; }
    }

    static readonly Dictionary<string, (string Dark, string Light)> Colors = new()
    {
        ["BgTop"] = ("#1B2029", "#FBFCFD"),
        ["BgBottom"] = ("#11151C", "#EFF1F4"),
        ["Hairline"] = ("#14FFFFFF", "#14000000"),
        ["Text"] = ("#FFF8FAFC", "#DE000000"),
        ["Text2"] = ("#FF94A3B8", "#85000000"),
        ["Icon"] = ("#FF94A3B8", "#73000000"),
        ["OutFill"] = ("#AD444A56", "#0B000000"),
        ["OutStroke"] = ("#24FFFFFF", "#12000000"),
        ["InFill"] = ("#D9263B54", "#FFDBEBFB"),
        ["InStroke"] = ("#4793C5FD", "#FFA8C7EB"),
        ["CardFill"] = ("#80444A56", "#FFFFFFFF"),
        ["CardStroke"] = ("#1FFFFFFF", "#17000000"),
        ["InputFill"] = ("#0DFFFFFF", "#FFFFFFFF"),
        ["InputStroke"] = ("#21FFFFFF", "#21000000"),
        ["SendIdle"] = ("#29FFFFFF", "#2E000000"),
        ["Accent"] = ("#FF4085F5", "#FF2673EB"),
        ["Green"] = ("#FF34D359", "#FF22A447"),
        ["IdleDot"] = ("#FF64748B", "#FF94A3B8"),
        ["Danger"] = ("#FFFF6B66", "#FFD62E29"),
        ["CaptionHover"] = ("#1AFFFFFF", "#0F000000"),
        ["Scroll"] = ("#40FFFFFF", "#33000000"),
        ["DropFill"] = ("#1A4085F5", "#142673EB"),
        ["PinOn"] = ("#FFE0463A", "#FFD2392D"),
    };

    public static void Apply(ResourceDictionary res)
    {
        IsDark = Forced ?? SystemIsDark();
        foreach (var (key, (dark, light)) in Colors)
        {
            var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(IsDark ? dark : light));
            b.Freeze();
            res[key] = b;
        }
        // Over Acrylic the background is a tint (about 75 %), otherwise solid.
        var a = Glass ? (IsDark ? "BD" : "CC") : "FF";
        var bg = new LinearGradientBrush(
            (Color)ColorConverter.ConvertFromString("#" + a + (IsDark ? "1B2029" : "FBFCFD")),
            (Color)ColorConverter.ConvertFromString("#" + a + (IsDark ? "11151C" : "EFF1F4")), 90);
        bg.Freeze();
        res["Bg"] = bg;
        res["Shadow"] = IsDark ? 0.35 : 0.10;
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [StructLayout(LayoutKind.Sequential)] struct Margins { public int L, R, T, B; }
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins m);

    /// <summary>
    /// Smoked glass: Windows 11 22H2+ draws an Acrylic backdrop behind the (partly transparent) window.
    /// Off for snapshots and on older Windows, where the background stays solid.
    /// </summary>
    public static bool Glass { get; set; }
    public static bool GlassSupported => Environment.OSVersion.Version.Build >= 22621;

    /// <summary>Dark/light window frame (border, shadow) and rounded corners on Windows 11.</summary>
    public static void ApplyFrame(Window w)
    {
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = IsDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));      // DWMWA_USE_IMMERSIVE_DARK_MODE
        var round = 2;
        DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));     // DWMWA_WINDOW_CORNER_PREFERENCE = round
        if (Glass)
        {
            HwndSource.FromHwnd(hwnd).CompositionTarget.BackgroundColor = System.Windows.Media.Colors.Transparent;
            var m = new Margins { L = -1, R = -1, T = -1, B = -1 };
            DwmExtendFrameIntoClientArea(hwnd, ref m);
            var acrylic = 3;
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE = transient (Acrylic)
        }
    }

    /// <summary>Re-apply when the Windows app mode changes.</summary>
    public static void Follow(Application app, Action changed)
    {
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (Forced != null || e.Category != UserPreferenceCategory.General) return;
            app.Dispatcher.BeginInvoke(() =>
            {
                if (SystemIsDark() == IsDark) return;
                Apply(app.Resources);
                changed();
            });
        };
    }
}
