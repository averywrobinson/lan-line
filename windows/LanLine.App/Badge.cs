using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Microsoft.Win32;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// The unread badge (beta.10): a count on the taskbar button (overlay icon) and a dot on the tray icon for items that
/// arrived while Lan-Line wasn't the window in use; cleared when the window is activated. And "Open Lan-Line when I
/// sign in" (the per-user Run value, started with --background so it waits in the tray).
/// </summary>
sealed partial class MainWindow
{
    readonly Unread _unread = new();
    System.Drawing.Icon? _trayOnDot, _trayOffDot;

    bool InUse => IsActive && IsVisible && WindowState != WindowState.Minimized;

    void CountArrival() { _unread.Arrived(InUse); RefreshBadge(); }

    void SeenAll()
    {
        if (_unread.Count == 0) return;
        _unread.Seen();
        RefreshBadge();
    }

    void RefreshBadge()
    {
        TaskbarItemInfo ??= new TaskbarItemInfo();
        TaskbarItemInfo.Overlay = _unread.Badge is { } b ? BadgeImage(b) : null;
        TaskbarItemInfo.Description = _unread.Phrase ?? "";
        RefreshTray();
    }

    /// <summary>A red disc with the count in white, drawn at 32 px (Windows shows overlays at 16 px, twice on high DPI).</summary>
    static ImageSource BadgeImage(string text)
    {
        const int px = 32;
        var v = new DrawingVisual();
        using (var dc = v.RenderOpen())
        {
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(0xD9, 0x2D, 0x20)), new Pen(Brushes.White, 2), new Point(px / 2.0, px / 2.0), px / 2.0 - 1, px / 2.0 - 1);
            var size = text.Length switch { 1 => 20.0, 2 => 16.0, _ => 11.5 };
            var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal), size, Brushes.White, 1.0);
            dc.DrawText(ft, new Point((px - ft.Width) / 2, (px - ft.Height) / 2));
        }
        var bmp = new RenderTargetBitmap(px, px, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(v);
        bmp.Freeze();
        return bmp;
    }

    /// <summary>The tray icon with a red dot at the top right (a transparent ring keeps it apart from the mark).</summary>
    static System.Drawing.Icon WithDot(System.Drawing.Icon baseIcon)
    {
        using var src = baseIcon.ToBitmap();
        using var bmp = new System.Drawing.Bitmap(src.Width, src.Height);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.DrawImage(src, 0, 0, src.Width, src.Height);
            var d = src.Width * 0.46f;
            var dot = new System.Drawing.RectangleF(src.Width - d, 0, d, d);
            var ring = dot; ring.Inflate(src.Width * 0.07f, src.Width * 0.07f);
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            using (var clear = new System.Drawing.SolidBrush(System.Drawing.Color.Transparent)) g.FillEllipse(clear, ring);
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver;
            using var red = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(0xD9, 0x2D, 0x20));
            g.FillEllipse(red, dot);
        }
        var h = bmp.GetHicon();
        var icon = (System.Drawing.Icon)System.Drawing.Icon.FromHandle(h).Clone();
        DestroyIcon(h);
        return icon;
    }

    System.Drawing.Icon? TrayIconNow()
    {
        if (_unread.Count == 0) return _connected ? _trayOn : _trayOff;
        if (_trayOn == null || _trayOff == null) return null;
        _trayOnDot ??= WithDot(_trayOn);
        _trayOffDot ??= WithDot(_trayOff);
        return _connected ? _trayOnDot : _trayOffDot;
    }

    /// <summary>--render-badges PATH: the taskbar overlays (1, 12, 99+) and the tray icon with and without the dot,
    /// 4x, on a light and a dark strip, then exit. Design checks without showing anything.</summary>
    internal void RenderBadges(string path)
    {
        LoadTrayIcons();
        var v = new DrawingVisual();
        using (var dc = v.RenderOpen())
        {
            for (var row = 0; row < 2; row++)
            {
                dc.DrawRectangle(row == 0 ? new SolidColorBrush(Color.FromRgb(0xEE, 0xEE, 0xEE)) : new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x20)), null, new Rect(0, row * 48, 7 * 48, 48));
                var icons = new[] { _trayOn!, WithDot(_trayOn!), _trayOff!, WithDot(_trayOff!) };
                for (var i = 0; i < icons.Length; i++)
                {
                    using var bmp = icons[i].ToBitmap();
                    var h = bmp.GetHbitmap(System.Drawing.Color.FromArgb(0, 0, 0, 0));
                    var src = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(h, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    dc.DrawImage(src, new Rect(i * 48 + 8, row * 48 + 8, 32, 32));
                }
                var x = 4 * 48;
                foreach (var t in new[] { "1", "12", "99+" }) { dc.DrawImage(BadgeImage(t), new Rect(x + 8, row * 48 + 8, 32, 32)); x += 48; }
            }
        }
        var rtb = new RenderTargetBitmap(7 * 48 * 4, 96 * 4, 96 * 4, 96 * 4, PixelFormats.Pbgra32);
        rtb.Render(v);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var fs = System.IO.File.Create(path);
        enc.Save(fs);
    }

    // ---------- open at sign-in

    static string ExePath => Environment.ProcessPath ?? System.IO.Path.Combine(AppContext.BaseDirectory, "Lan-Line.exe");

    static bool OpensAtSignIn()
    {
        try { using var k = Registry.CurrentUser.OpenSubKey(SignIn.RunKey); return SignIn.IsOn(k?.GetValue(SignIn.ValueName) as string, ExePath); }
        catch (Exception) { return false; }
    }

    void SetOpenAtSignIn(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(SignIn.RunKey);
            if (on) k.SetValue(SignIn.ValueName, SignIn.Command(ExePath));
            else if (k.GetValue(SignIn.ValueName) != null) k.DeleteValue(SignIn.ValueName);
        }
        catch (Exception e) { Note($"Couldn't change opening at sign-in: {e.Message}"); }
    }

    /// <summary>Started with --background (at sign-in): stay in the tray if paired, settings saved and the tray is on.</summary>
    internal bool CanStartHidden => _tray != null && _partners.Count > 0 && _storage.Confirmed;
}
