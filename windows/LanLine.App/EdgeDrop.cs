using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// The edge drop zone (beta.10, Windows' answer to dropping on the Mac's menu bar icon: the notification area takes no
/// drops). A slim strip at the right edge of the main screen, off unless turned on in Settings. Drag files, a folder or
/// text over it and it opens into a panel that names where it will go; drop to send without opening Lan-Line.
/// It never takes the keyboard and never appears in Alt+Tab or the taskbar.
/// </summary>
sealed class EdgeDropZone : Window
{
    readonly MainWindow _owner;
    readonly Border _panel = new() { CornerRadius = new CornerRadius(12, 0, 0, 12) };
    readonly TextBlock _title = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _hint = new() { FontSize = 11.5, Foreground = new SolidColorBrush(Color.FromArgb(0xD0, 0xFF, 0xFF, 0xFF)), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
    readonly StackPanel _words = new() { Margin = new Thickness(16, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center, Opacity = 0 };
    const double Slim = 6, Open = 220, Tall = 150;

    public EdgeDropZone(MainWindow owner)
    {
        _owner = owner;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; ResizeMode = ResizeMode.NoResize;
        Width = Slim; Height = Tall; AllowDrop = true; Title = "Lan-Line drop zone";
        _panel.Background = (Brush)Application.Current.Resources["Accent"];
        _panel.Opacity = 0.55;
        _words.Children.Add(_title); _words.Children.Add(_hint);
        _panel.Child = _words;
        Content = _panel;
        ToolTip = "Drop files here to send them with Lan-Line";
        System.Windows.Automation.AutomationProperties.SetName(this, "Lan-Line drop zone");
        Place();
        SystemParameters.StaticPropertyChanged += (_, e) => { if (e.PropertyName == nameof(SystemParameters.WorkArea)) Place(); };
        SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(this).Handle;
            SetWindowLong(h, GWL_EXSTYLE, GetWindowLong(h, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };
        DragEnter += (_, e) => { Expand(e.Data); e.Effects = DragDropEffects.Copy; e.Handled = true; };
        DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
        DragLeave += (_, _) => Collapse();
        Drop += (_, e) => { Collapse(); _owner.SendDropped(e.Data); e.Handled = true; };
        MouseLeftButtonUp += (_, _) => _owner.ShowFromEdge();
    }

    /// <summary>--render-edge PATH: the open panel (3 files) and the slim strip, off-screen, 2x (design checks).</summary>
    internal void RenderTo(string path)
    {
        _title.Text = $"Send to {_owner.DropTargetName}";
        _hint.Text = "3 items: drop to send";
        _words.Opacity = 1; _panel.Opacity = 0.95;
        var host = new Grid { Width = Open + 40, Height = Tall + 20, Background = new SolidColorBrush(Color.FromRgb(0x30, 0x34, 0x3C)) };
        Content = null;
        _panel.Width = Open; _panel.Height = Tall; _panel.HorizontalAlignment = HorizontalAlignment.Left; _panel.VerticalAlignment = VerticalAlignment.Center;
        var strip = new Border { Width = Slim, Height = Tall, Background = (Brush)Application.Current.Resources["Accent"], Opacity = 0.55, HorizontalAlignment = HorizontalAlignment.Right, CornerRadius = new CornerRadius(3, 0, 0, 3) };
        host.Children.Add(_panel); host.Children.Add(strip);
        host.Measure(new Size(host.Width, host.Height)); host.Arrange(new Rect(0, 0, host.Width, host.Height)); host.UpdateLayout();
        var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap((int)host.Width * 2, (int)host.Height * 2, 192, 192, PixelFormats.Pbgra32);
        bmp.Render(host);
        var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
        enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
        using var fs = System.IO.File.Create(path);
        enc.Save(fs);
    }

    void Place()
    {
        var wa = SystemParameters.WorkArea;
        Left = wa.Right - Width;
        Top = wa.Top + (wa.Height - Tall) / 2;
    }

    void Expand(IDataObject data)
    {
        var n = data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] f ? f.Length : 0;
        _title.Text = $"Send to {_owner.DropTargetName}";
        _hint.Text = n > 0 ? $"{n} item{(n == 1 ? "" : "s")}: drop to send" : "Drop to send";
        Animate(Open, 1, 0.95);
    }

    void Collapse() => Animate(Slim, 0, 0.55);

    void Animate(double width, double words, double panel)
    {
        var d = new Duration(TimeSpan.FromMilliseconds(SystemParameters.ClientAreaAnimation ? 160 : 0));
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var wa = SystemParameters.WorkArea;
        BeginAnimation(WidthProperty, new DoubleAnimation(width, d) { EasingFunction = ease });
        BeginAnimation(LeftProperty, new DoubleAnimation(wa.Right - width, d) { EasingFunction = ease });
        _words.BeginAnimation(OpacityProperty, new DoubleAnimation(words, d));
        _panel.BeginAnimation(OpacityProperty, new DoubleAnimation(panel, d));
    }

    const int GWL_EXSTYLE = -20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80;
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
}

sealed partial class MainWindow
{
    EdgeDropZone? _edge;

    /// <summary>Show or remove the edge drop zone to match the setting (at start and after Save).</summary>
    void ApplyEdgeDrop()
    {
        if (_demo) return;
        if (_storage.EdgeDropZoneValue && _edge == null) { _edge = new EdgeDropZone(this); _edge.Show(); }
        else if (!_storage.EdgeDropZoneValue && _edge != null) { _edge.Close(); _edge = null; }
    }

    internal string DropTargetName => _sendTarget is { } t ? NameOf(t) : Multi ? "everyone" : PeerLabel;

    internal void ShowFromEdge() => ShowFromTray();

    /// <summary>Dropped on the edge zone: files and folders, a picture or text, sent to the current target; a
    /// notification says where it went.</summary>
    internal void SendDropped(IDataObject data)
    {
        if (_hub == null || _partners.Count == 0 || _pairing) { System.Media.SystemSounds.Beep.Play(); ShowFromTray(); return; }
        string? body = null;
        if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0)
        {
            var n = SendFiles(files);   // "Sent" only for what went out
            if (n > 0) body = n == 1 && files.Length == 1 ? System.IO.Path.GetFileName(System.IO.Path.TrimEndingDirectorySeparator(files[0])) : $"{n} item{(n == 1 ? "" : "s")}";
        }
        else if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string s && s.Trim().Length > 0)
        {
            UpsertOutgoing(_hub.SendText(s, _sendTarget));
            TickSent();
            body = ArrivalNotices.Preview(s);
        }
        if (body == null) { System.Media.SystemSounds.Beep.Play(); return; }
        PostNotice(new ArrivalNotice($"Sent to {DropTargetName}", body, []));
    }
}
