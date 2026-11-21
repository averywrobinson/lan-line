using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using LanLine.Core;

namespace LanLine.App;

/// <summary>One feed entry: a text bubble or a file card. Ours sit on the right, received ones on the left (blue tint).</summary>
sealed class ItemRow
{
    public readonly FrameworkElement View;
    public string? Path => _item.Path;
    readonly TextBlock _mark = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    readonly ProgressBar? _progress;
    TextBlock? _sizeText;
    FrameworkElement? _icon;
    Button? _copyButton;
    bool _removed;
    Item _item;

    public ItemRow(Item item, MainWindow owner)
    {
        _item = item;
        var iconFont = (FontFamily)Application.Current.Resources["IconFont"];
        _mark.FontFamily = iconFont;
        var copy = new Button { Content = MainWindow.Glyph_Copy, ToolTip = "Copy" };
        copy.SetResourceReference(FrameworkElement.StyleProperty, "IconButton");
        MainWindow.Automation(copy, "Copy");
        copy.Click += (_, _) => { Copy(); Flash(copy); };
        _copyButton = copy;

        Border bubble;
        if (!item.IsFile)
        {
            var tb = new TextBox { Text = item.Text, VerticalAlignment = VerticalAlignment.Center };
            tb.SetResourceReference(FrameworkElement.StyleProperty, "ReadOnlyText");
            MainWindow.Automation(tb, item.Incoming ? "Received text" : "Sent text");
            var side = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
            side.Children.Add(copy);
            if (!item.Incoming) { _mark.Margin = new Thickness(4, 0, 2, 0); side.Children.Add(_mark); }
            var dock = new DockPanel();
            DockPanel.SetDock(side, Dock.Right);
            dock.Children.Add(side);
            dock.Children.Add(tb);
            bubble = new Border { Child = dock, Padding = new Thickness(13, 7, 7, 7) };
            bubble.ContextMenu = Menu(("Copy", Copy));
        }
        else
        {
            var name = new TextBlock { Text = item.FileName, FontSize = 13, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis };
            name.SetResourceReference(TextBlock.ForegroundProperty, "Text");
            var detail = item.IsFolder ? $"{item.Count} file{(item.Count == 1 ? "" : "s")} · {FormatSize(item.Size)}" : FormatSize(item.Size);
            var size = _sizeText = new TextBlock { Text = detail, FontSize = 11, Margin = new Thickness(0, 2, 0, 0) };
            size.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(11, 0, 8, 0), MinWidth = 90 };
            names.Children.Add(name);
            names.Children.Add(size);
            var side = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            side.Children.Add(copy);
            if (!item.Incoming) side.Children.Add(_mark);
            var row = new DockPanel();
            var icon = _icon = FileIcon(item.Path);
            DockPanel.SetDock(icon, Dock.Left);
            DockPanel.SetDock(side, Dock.Right);
            row.Children.Add(icon);
            row.Children.Add(side);
            row.Children.Add(names);
            var stack = new StackPanel();
            stack.Children.Add(row);
            _progress = new ProgressBar { Margin = new Thickness(0, 9, 0, 1), Visibility = Visibility.Collapsed };
            _progress.SetResourceReference(FrameworkElement.StyleProperty, "ThinProgress");
            stack.Children.Add(_progress);
            bubble = new Border { Child = stack, Padding = new Thickness(11), MaxWidth = 300, Cursor = Cursors.Hand,
                                  ToolTip = "Double-click to open. Drag out to copy." };
            bubble.Effect = new DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Direction = 270, Opacity = Theme.IsDark ? 0.35 : 0.10, Color = Colors.Black };
            bubble.ContextMenu = Menu(("Open", Open), ("Show in folder", Reveal), ("Copy", Copy));
            Point? down = null;
            bubble.MouseLeftButtonDown += (_, e) =>
            {
                if (e.ClickCount == 2) { if (!_removed) Open(); return; }
                down = e.GetPosition(bubble);
            };
            bubble.MouseMove += (_, e) =>
            {
                if (_removed || down is not { } d || e.LeftButton != MouseButtonState.Pressed || _item.Path is not { } p) return;
                var now = e.GetPosition(bubble);
                if (Math.Abs(now.X - d.X) < 4 && Math.Abs(now.Y - d.Y) < 4) return;
                down = null;
                owner.DragOut(bubble, p);
            };
            bubble.MouseLeftButtonUp += (_, _) => down = null;
        }
        bubble.CornerRadius = new CornerRadius(14);
        bubble.BorderThickness = new Thickness(1);
        bubble.SetResourceReference(Border.BackgroundProperty, item.Incoming ? "InFill" : item.IsFile ? "CardFill" : "OutFill");
        bubble.SetResourceReference(Border.BorderBrushProperty, item.Incoming ? "InStroke" : item.IsFile ? "CardStroke" : "OutStroke");
        bubble.HorizontalAlignment = item.Incoming ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        bubble.Margin = item.Incoming ? new Thickness(0, 4, 44, 4) : new Thickness(44, 4, 0, 4);
        bubble.Tag = item.Id;
        _caption.HorizontalAlignment = item.Incoming ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        _caption.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var outer = new StackPanel { Tag = item.Id };
        outer.Children.Add(bubble);
        outer.Children.Add(_caption);
        View = outer;
        Update(item);
    }

    /// <summary>The storage cleanup moved this file to the Recycle Bin: say so and stop offering open/drag/copy.</summary>
    public void MarkRemoved()
    {
        if (_removed || _sizeText == null) return;
        _removed = true;
        _sizeText.Text = "Moved to Recycle Bin";
        if (_icon != null) _icon.Opacity = 0.45;
        if (_copyButton != null) _copyButton.Visibility = Visibility.Collapsed;
        View.ToolTip = null;
        View.Cursor = null;
        View.ContextMenu = null;
    }

    readonly TextBlock _caption = new() { FontSize = 10, Margin = new Thickness(6, -2, 6, 4), Visibility = Visibility.Collapsed };

    /// <summary>"from STUDIO-PC" / "to everyone · ✓ 2/3": only with 2+ paired computers.</summary>
    public void SetCaption(string? text)
    {
        _caption.Text = text ?? "";
        _caption.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
    }

    public void Update(Item item)
    {
        _item = item;
        var (glyph, tip, danger) = item.State.Kind switch
        {
            ItemStateKind.Waiting => (MainWindow.Glyph_Clock, "Waiting for the Mac", false),
            ItemStateKind.Sending => ($"{(int)(item.State.Progress * 100)}%", "Sending", false),
            ItemStateKind.Sent => (MainWindow.Glyph_More, "Sent, waiting for confirmation", false),
            ItemStateKind.Delivered => (MainWindow.Glyph_Check, "Delivered", false),
            ItemStateKind.Failed => (MainWindow.Glyph_Error, $"Failed: {item.State.Error}", true),
            _ => ("", "", false),
        };
        _mark.Text = glyph;
        _mark.FontFamily = item.State.Kind == ItemStateKind.Sending
            ? (FontFamily)Application.Current.Resources["UiFont"] : (FontFamily)Application.Current.Resources["IconFont"];
        _mark.FontSize = item.State.Kind == ItemStateKind.Sending ? 10 : 11;
        _mark.ToolTip = tip.Length > 0 ? tip : null;
        _mark.SetResourceReference(TextBlock.ForegroundProperty, danger ? "Danger" : "Icon");
        if (_progress != null)
        {
            _progress.Visibility = item.State.Kind == ItemStateKind.Sending ? Visibility.Visible : Visibility.Collapsed;
            _progress.Value = item.State.Progress;
        }
        System.Windows.Automation.AutomationProperties.SetName(View,
            $"{(item.Incoming ? "Received" : "Sent")} {(item.IsFolder ? $"folder {item.FileName}, {item.Count} files" : item.IsFile ? "file " + item.FileName : "text")} ({item.State.Kind})");
    }

    static ContextMenu Menu(params (string Label, Action Do)[] items)
    {
        var m = new ContextMenu();
        foreach (var (label, act) in items) { var mi = new MenuItem { Header = label }; mi.Click += (_, _) => act(); m.Items.Add(mi); }
        return m;
    }

    void Copy()
    {
        try
        {
            if (!_item.IsFile) Clipboard.SetText(_item.Text ?? "");
            else if (_item.Path is { } p) Clipboard.SetFileDropList([p]);
        }
        catch (Exception) { /* clipboard busy: the user can click again */ }
    }

    static void Flash(Button b)
    {
        b.Content = MainWindow.Glyph_Check;
        b.SetResourceReference(Control.ForegroundProperty, "Green");
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        t.Tick += (_, _) => { t.Stop(); b.Content = MainWindow.Glyph_Copy; b.ClearValue(Control.ForegroundProperty); };
        t.Start();
    }

    void Open()
    {
        if (_item.Path is not { } p) return;
        if (Directory.Exists(p)) Process.Start("explorer.exe", $"\"{p}\"");
        else if (File.Exists(p)) Process.Start(new ProcessStartInfo(p) { UseShellExecute = true });
    }
    void Reveal() { if (_item.Path is { } p) Process.Start("explorer.exe", $"/select,\"{p}\""); }

    /// <summary>A real thumbnail for images, the shell's icon for other files.</summary>
    static FrameworkElement FileIcon(string? path)
    {
        ImageSource? src = null;
        var isImage = false;
        if (path != null && File.Exists(path))
        {
            var ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
            if (ext is ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" or ".webp" or ".tif" or ".tiff")
            {
                try
                {
                    var bi = new BitmapImage();
                    bi.BeginInit();
                    bi.CacheOption = BitmapCacheOption.OnLoad;
                    bi.DecodePixelWidth = 96;
                    bi.UriSource = new Uri(path);
                    bi.EndInit();
                    bi.Freeze();
                    src = bi; isImage = true;
                }
                catch (Exception) { }
            }
            if (src == null)
            {
                try
                {
                    using var ic = System.Drawing.Icon.ExtractAssociatedIcon(path);
                    if (ic != null) src = Imaging.CreateBitmapSourceFromHIcon(ic.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                }
                catch (Exception) { }
            }
        }
        if (src == null)
        {
            var glyph = new TextBlock { Text = path != null && Directory.Exists(path) ? MainWindow.Glyph_Folder : MainWindow.Glyph_Doc, FontSize = 26, Width = 36, Height = 36, TextAlignment = TextAlignment.Center,
                                        FontFamily = (FontFamily)Application.Current.Resources["IconFont"], Padding = new Thickness(0, 4, 0, 0) };
            glyph.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            return glyph;
        }
        var img = new Image { Source = src, Width = 36, Height = 36, Stretch = isImage ? Stretch.UniformToFill : Stretch.Uniform };
        if (!isImage) return img;
        return new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(6), ClipToBounds = true,
                            Child = img, Clip = new RectangleGeometry(new Rect(0, 0, 36, 36), 6, 6) };
    }

    static string FormatSize(long b) => b < 1000 ? $"{b} B" : b < 1_000_000 ? $"{b / 1000.0:0} KB" : b < 1_000_000_000 ? $"{b / 1_000_000.0:0.0} MB" : $"{b / 1_000_000_000.0:0.00} GB";
}
