using LanLine.Core;
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
        ["Text2"] = ("#FFA3B0C2", "#A3000000"),   // light: 64 % black on #EFF1F4, about 6:1
        ["Icon"] = ("#FFA3B0C2", "#8C000000"),
        // Design refresh (beta.10), the same values as the Mac: content surfaces are near-opaque, so their text reads
        // the same over any wallpaper and opacity setting; groups hold settings and the pairing card; the input fill is
        // the solid control layer.
        ["OutFill"] = ("#EB3A404C", "#F0FFFFFF"),
        ["OutStroke"] = ("#1CFFFFFF", "#17000000"),
        ["InFill"] = ("#F0263B54", "#FFDBEBFB"),
        ["InStroke"] = ("#3D93C5FD", "#FFA8C7EB"),
        ["CardFill"] = ("#EB3A404C", "#F0FFFFFF"),
        ["CardStroke"] = ("#1CFFFFFF", "#17000000"),
        ["GroupFill"] = ("#EB282E39", "#EBFFFFFF"),
        ["GroupStroke"] = ("#14FFFFFF", "#14000000"),
        ["InputFill"] = ("#F52C323E", "#F7FFFFFF"),
        ["InputStroke"] = ("#24FFFFFF", "#21000000"),
        ["SendIdle"] = ("#29FFFFFF", "#2E000000"),
        ["Accent"] = ("#FF4085F5", "#FF2673EB"),
        ["Green"] = ("#FF34D359", "#FF22A447"),
        ["IdleDot"] = ("#FF64748B", "#FF94A3B8"),
        ["Danger"] = ("#FFFF6B66", "#FFD62E29"),
        ["CaptionHover"] = ("#1AFFFFFF", "#0F000000"),
        ["Scroll"] = ("#40FFFFFF", "#33000000"),
        ["DropFill"] = ("#1A4085F5", "#142673EB"),
        ["PinOn"] = ("#FFE0463A", "#FFD2392D"),
        ["MenuBg"] = ("#FF1E232C", "#FFFFFFFF"),
        ["MenuHover"] = ("#FF2C3442", "#FFE9EDF3"),
        ["MenuStroke"] = ("#33FFFFFF", "#24000000"),
    };

    /// <summary>A Windows contrast theme is on (accessibility pass, beta.10): every colour comes from the theme, there
    /// are no tints or glass, and shapes are outlined in the text colour. --theme hc forces a stand-in for checks.</summary>
    public static bool HighContrast { get; private set; }
    public static bool ForcedHighContrast { get; set; }

    /// <summary>The contrast theme's colours for our brush names. Fills are the window colour, strokes and text the
    /// text colour, actions the selection colours.</summary>
    static Dictionary<string, Color> ContrastColors()
    {
        // "Night sky", for --theme hc: an SSH or snapshot session has no contrast theme of its own.
        Color C(string hex) => (Color)ColorConverter.ConvertFromString(hex);
        var forced = ForcedHighContrast;
        Color win = forced ? C("#000000") : SystemColors.WindowColor, text = forced ? C("#FFFFFF") : SystemColors.WindowTextColor,
              hi = forced ? C("#D6B4FD") : SystemColors.HighlightColor, hiText = forced ? C("#2B2B2B") : SystemColors.HighlightTextColor,
              hot = forced ? C("#8080FF") : SystemColors.HotTrackColor, gray = forced ? C("#A6A6A6") : SystemColors.GrayTextColor;
        Color A(Color c, byte a) { c.A = a; return c; }
        var d = new Dictionary<string, Color>();
        foreach (var k in new[] { "BgTop", "BgBottom", "OutFill", "InFill", "CardFill", "GroupFill", "InputFill", "MenuBg", "DropFill" }) d[k] = win;
        foreach (var k in new[] { "Text", "Text2", "Icon", "Hairline", "OutStroke", "InStroke", "CardStroke", "GroupStroke", "InputStroke", "MenuStroke", "Scroll", "Danger" }) d[k] = text;
        d["Accent"] = hi; d["OnAccent"] = hiText; d["Green"] = hot; d["PinOn"] = hot; d["IdleDot"] = gray; d["SendIdle"] = gray;
        d["CaptionHover"] = A(hi, 0x66); d["MenuHover"] = A(hi, 0x66);
        return d;
    }

    public static void Apply(ResourceDictionary res)
    {
        IsDark = Forced ?? SystemIsDark();
        HighContrast = ForcedHighContrast || (Forced == null && SystemParameters.HighContrast);
        var contrast = HighContrast ? ContrastColors() : null;
        if (contrast != null) IsDark = contrast["BgTop"].R + contrast["BgTop"].G + contrast["BgTop"].B < 384;   // dark frame for a dark theme
        foreach (var (key, (dark, light)) in Colors)
        {
            var b = new SolidColorBrush(contrast != null && contrast.TryGetValue(key, out var c) ? c : (Color)ColorConverter.ConvertFromString(IsDark ? dark : light));
            b.Freeze();
            res[key] = b;
        }
        var onAccent = new SolidColorBrush(contrast?["OnAccent"] ?? System.Windows.Media.Colors.White); onAccent.Freeze();
        res["OnAccent"] = onAccent;   // text and glyphs on the accent colour (white, or the theme's selected-text colour)
        ApplyBackdrop(res);
        res["Shadow"] = IsDark ? 0.35 : 0.10;
    }

    /// <summary>The window opacity setting (beta.8): how opaque the tint over the Acrylic blur is.</summary>
    public static double GlassOpacity { get; set; } = StorageSettings.DefaultGlassOpacity;

    /// <summary>
    /// Over Acrylic the background is a tint (the opacity setting; 74 % dark / 80 % light by default), otherwise
    /// solid. Only this brush changes with the slider: text, bubbles and chips keep their own colors.
    /// </summary>
    public static void ApplyBackdrop(ResourceDictionary res)
    {
        var glass = Glass && !HighContrast;
        var a = glass ? (byte)Math.Round(255 * StorageSettings.TintAlpha(GlassOpacity, IsDark)) : (byte)255;
        Color C(string hex) { var c = (Color)ColorConverter.ConvertFromString(hex); c.A = a; return c; }
        var bg = HighContrast ? new LinearGradientBrush(((SolidColorBrush)res["BgTop"]).Color, ((SolidColorBrush)res["BgTop"]).Color, 90)
                              : new LinearGradientBrush(C(IsDark ? "#1B2029" : "#FBFCFD"), C(IsDark ? "#11151C" : "#EFF1F4"), 90);
        bg.Freeze();
        res["Bg"] = bg;
        // Text that sits directly on the body (title, captions, notes) gets this behind it: nothing at the default
        // opacity, the body colour at up to 62 % as the window is made more see-through.
        var sc = (Color)ColorConverter.ConvertFromString(IsDark ? "#1B2029" : "#FBFCFD");
        sc.A = glass ? (byte)Math.Round(255 * StorageSettings.ScrimMax * StorageSettings.ScrimStrength(GlassOpacity)) : (byte)0;
        var scrim = new SolidColorBrush(sc); scrim.Freeze();
        res["Scrim"] = scrim;
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [StructLayout(LayoutKind.Sequential)] struct Margins { public int L, R, T, B; }
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins m);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    /// <summary>
    /// Smoked glass: Windows 11 22H2+ draws an Acrylic backdrop behind the (partly transparent) window.
    /// Off for snapshots and on older Windows, where the background stays solid.
    /// </summary>
    public static bool Glass { get; set; }
    public static bool GlassSupported => Environment.OSVersion.Version.Build >= 22621;

    /// <summary>The material follows the window's role (design refresh, beta.10). Pinned on top, Lan-Line is a floating
    /// panel over other work: Acrylic, which shows what is behind it and stays live while the window is inactive. Unpinned
    /// it is an ordinary app window: Mica, the Windows 11 norm. The opacity setting tints both.</summary>
    public static void ApplyMaterial(Window w, bool pinned)
    {
        if (!Glass) return;
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        var type = pinned ? 3 : 2;   // DWMSBT_TRANSIENTWINDOW (Acrylic) : DWMSBT_MAINWINDOW (Mica)
        DwmSetWindowAttribute(hwnd, 38, ref type, sizeof(int));   // DWMWA_SYSTEMBACKDROP_TYPE
    }

    /// <summary>Dark/light window frame (border, shadow) and rounded corners on Windows 11.</summary>
    public static void ApplyFrame(Window w, bool pinned = true)
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
            ApplyMaterial(w, pinned);
            // With the frame extended over the whole window, DWM also paints the native minimize/maximize/close
            // buttons behind ours (a second, unsynced set). Without WS_SYSMENU it doesn't; our buttons do the work.
            const int GWL_STYLE = -16;
            const long WS_SYSMENU = 0x00080000;
            var style = (long)GetWindowLongPtr(hwnd, GWL_STYLE);
            if ((style & WS_SYSMENU) != 0)
            {
                SetWindowLongPtr(hwnd, GWL_STYLE, (IntPtr)(style & ~WS_SYSMENU));
                const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;
                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            }
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
                if (SystemIsDark() == IsDark && SystemParameters.HighContrast == HighContrast) return;
                Apply(app.Resources);
                changed();
            });
        };
        // a contrast theme switched on or off (left Alt + left Shift + Print Screen, or Settings › Accessibility)
        SystemParameters.StaticPropertyChanged += (_, e) =>
        {
            if (Forced != null || e.PropertyName != nameof(SystemParameters.HighContrast)) return;
            app.Dispatcher.BeginInvoke(() => { Apply(app.Resources); changed(); });
        };
    }
}
