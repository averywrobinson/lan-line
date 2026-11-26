using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Explorer's own thumbnails (beta.10): IShellItemImageFactory, the same source Explorer's large icons use, so a
/// PDF shows its first page, a video a frame, an Office file its preview (when Windows has a handler for it).
/// Runs on its own STA thread; results are frozen bitmaps, cached by path and modified time.
/// </summary>
static class ShellThumbs
{
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(Size2 size, int flags, out IntPtr hbitmap); }

    [StructLayout(LayoutKind.Sequential)] struct Size2 { public int Cx, Cy; }
    [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int Type, Width, Height, WidthBytes; public ushort Planes, BitsPixel; public IntPtr Bits; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER { public int Size, Width, Height; public short Planes, BitCount; public int Compression, SizeImage, XPels, YPels, ClrUsed, ClrImportant; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr bc, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, out BITMAP bm);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER bi, uint usage);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    const int ThumbnailOnly = 0x8, BiggerSizeOk = 0x1;

    static readonly Dictionary<string, BitmapSource?> Cache = [];
    static readonly System.Collections.Concurrent.BlockingCollection<Action> Work = [];

    static ShellThumbs()
    {
        var t = new Thread(() => { foreach (var a in Work.GetConsumingEnumerable()) { try { a(); } catch (Exception) { } } })
            { IsBackground = true, Name = "Lan-Line thumbnails" };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
    }

    static string Key(string path, int px, bool thumbOnly)
    {
        DateTime m;
        try { m = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : Directory.GetLastWriteTimeUtc(path); } catch (Exception) { m = default; }
        return $"{path}|{m.Ticks}|{px}|{thumbOnly}";
    }

    /// <summary>A thumbnail (or, with thumbOnly false, the large icon) at px pixels; null when there is none.
    /// done runs on the UI thread.</summary>
    public static void Load(string path, int px, bool thumbOnly, Action<BitmapSource?> done)
    {
        var key = Key(path, px, thumbOnly);
        lock (Cache) if (Cache.TryGetValue(key, out var hit)) { done(hit); return; }
        var ui = System.Windows.Threading.Dispatcher.CurrentDispatcher;
        Work.Add(() =>
        {
            var img = Get(path, px, thumbOnly);
            lock (Cache) Cache[key] = img;
            ui.BeginInvoke(() => done(img));
        });
    }

    static BitmapSource? Get(string path, int px, bool thumbOnly)
    {
        var iid = typeof(IShellItemImageFactory).GUID;
        IShellItemImageFactory? f = null;
        var hbm = IntPtr.Zero;
        try
        {
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out f);
            if (f.GetImage(new Size2 { Cx = px, Cy = px }, (thumbOnly ? ThumbnailOnly : 0) | BiggerSizeOk, out hbm) < 0 || hbm == IntPtr.Zero) return null;
            return ToBitmap(hbm);
        }
        catch (Exception) { return null; }
        finally
        {
            if (hbm != IntPtr.Zero) DeleteObject(hbm);
            if (f != null) Marshal.ReleaseComObject(f);
        }
    }

    /// <summary>HBITMAP → BGRA, asked for top-down so the orientation is certain and the alpha (icons) survives.</summary>
    static BitmapSource? ToBitmap(IntPtr hbm)
    {
        if (GetObject(hbm, Marshal.SizeOf<BITMAP>(), out var bm) == 0 || bm.Width <= 0 || bm.Height <= 0) return null;
        var bi = new BITMAPINFOHEADER { Size = Marshal.SizeOf<BITMAPINFOHEADER>(), Width = bm.Width, Height = -bm.Height, Planes = 1, BitCount = 32 };
        var bits = new byte[bm.Width * bm.Height * 4];
        var dc = GetDC(IntPtr.Zero);
        try { if (GetDIBits(dc, hbm, 0, (uint)bm.Height, bits, ref bi, 0) == 0) return null; }
        finally { ReleaseDC(IntPtr.Zero, dc); }
        // 24-bit sources come back with alpha 0 everywhere: treat those as opaque.
        var anyAlpha = false;
        for (var i = 3; i < bits.Length; i += 4) if (bits[i] != 0) { anyAlpha = true; break; }
        if (!anyAlpha) for (var i = 3; i < bits.Length; i += 4) bits[i] = 255;
        var src = BitmapSource.Create(bm.Width, bm.Height, 96, 96, PixelFormats.Pbgra32, null, bits, bm.Width * 4);
        src.Freeze();
        return src;
    }
}

/// <summary>Select a file card and press Space: the preview layer (pictures, text, or Explorer's thumbnail).</summary>
sealed partial class MainWindow
{
    ItemRow? _selected;
    Grid? _previewLayer;
    List<ItemRow> _previewList = [];
    int _previewIndex = -1;

    bool PreviewOpen => _previewLayer is { Visibility: Visibility.Visible };

    /// <summary>A click on a file card: select it (keys now go to the feed: Space previews).</summary>
    internal void Select(ItemRow row)
    {
        if (_selected == row) { FocusFeed(); return; }
        _selected?.SetSelected(false);
        _selected = row;
        row.SetSelected(true);
        FocusFeed();
        if (PreviewOpen) ShowPreviewAt(PreviewFiles().IndexOf(row));
    }

    void Deselect()
    {
        _selected?.SetSelected(false);
        _selected = null;
    }

    void FocusFeed() { _scroll.Focusable = true; Keyboard.Focus(_scroll); }

    internal void QuickLook(ItemRow row) { Select(row); OpenPreview(); }

    /// <summary>--demo-preview ID: the preview layer open on a demo item (screenshots).</summary>
    internal void DemoPreview(string id)
    {
        if (File.Exists(id))   // a path: add it as a received file first (checks of the text and thumbnail views)
        {
            var path = Path.GetFullPath(id);
            Upsert(new Item("preview-demo", true, null, Path.GetFileName(path), new FileInfo(path).Length, path, ItemState.ReceivedState));
            id = "preview-demo";
        }
        if (_rows.TryGetValue(id, out var r)) QuickLook(r);
    }

    List<ItemRow> PreviewFiles() => FeedRows().Where(r => r is { Item.IsFile: true, Exists: true, Unavailable: false }).ToList();

    void OpenPreview()
    {
        if (_selected == null) return;
        _previewList = PreviewFiles();
        var i = _previewList.IndexOf(_selected);
        if (i < 0) return;
        EnsurePreviewLayer();
        _previewLayer!.Visibility = Visibility.Visible;
        ShowPreviewAt(i);
    }

    void ClosePreview()
    {
        if (_previewLayer != null) { _previewLayer.Visibility = Visibility.Collapsed; _previewBody.Child = null; }
        FocusFeed();
    }

    void Page(int delta)
    {
        var i = Preview.Step(_previewIndex, _previewList.Count, delta);
        if (i < 0 || i == _previewIndex) return;
        _selected?.SetSelected(false);
        _selected = _previewList[i];
        _selected.SetSelected(true);
        _selected.View.BringIntoView();
        ShowPreviewAt(i);
    }

    readonly Border _previewBody = new() { Margin = new Thickness(0, 10, 0, 10) };
    readonly TextBlock _previewName = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _previewInfo = new() { FontSize = 11, Margin = new Thickness(0, 2, 0, 0) };
    readonly TextBlock _previewPos = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };

    void EnsurePreviewLayer()
    {
        if (_previewLayer != null) return;
        var layer = new Grid { Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)), Visibility = Visibility.Collapsed };
        layer.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource == layer) ClosePreview(); };   // click outside the card
        var card = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(14, 12, 14, 12), Margin = new Thickness(14, 40, 14, 14), BorderThickness = new Thickness(1) };
        card.SetResourceReference(Border.BackgroundProperty, "Bg");
        card.SetResourceReference(Border.BorderBrushProperty, "CardStroke");
        card.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Direction = 270, Opacity = 0.35, Color = Colors.Black };
        var dock = new DockPanel();
        // header: name, size · kind, position, close
        var head = new DockPanel();
        var close = new Button { Content = Glyph_Close, FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 10, ToolTip = "Close (Esc)", VerticalAlignment = VerticalAlignment.Top };
        close.SetResourceReference(StyleProperty, "IconButton");
        Automation(close, "Close preview");
        close.Click += (_, _) => ClosePreview();
        DockPanel.SetDock(close, Dock.Right);
        DockPanel.SetDock(_previewPos, Dock.Right);
        _previewName.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _previewInfo.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        _previewPos.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var names = new StackPanel();
        names.Children.Add(_previewName); names.Children.Add(_previewInfo);
        head.Children.Add(close); head.Children.Add(_previewPos); head.Children.Add(names);
        DockPanel.SetDock(head, Dock.Top);
        // footer: Open, Show in folder
        var foot = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var (text, act) in new (string, Action)[] { ("Show in folder", () => _selected?.Reveal()), ("Open", () => _selected?.Open()) })
        {
            var b = new Button { Content = text, Margin = new Thickness(8, 0, 0, 0), MinWidth = 88 };
            b.SetResourceReference(StyleProperty, text == "Open" ? "PrimaryButton" : "SecondaryButton");
            b.Click += (_, _) => act();
            foot.Children.Add(b);
        }
        DockPanel.SetDock(foot, Dock.Bottom);
        dock.Children.Add(head); dock.Children.Add(foot); dock.Children.Add(_previewBody);
        card.Child = dock;
        layer.Children.Add(card);
        _previewLayer = layer;
        ((Grid)Content).Children.Add(layer);
    }

    void ShowPreviewAt(int i)
    {
        if (i < 0 || i >= _previewList.Count) return;
        _previewIndex = i;
        var row = _previewList[i];
        var item = row.Item;
        var path = item.Path!;
        _previewName.Text = item.FileName;
        var kind = Preview.Of(item.FileName ?? path, item.IsFolder);
        _previewInfo.Text = item.IsFolder ? $"Folder · {item.Count} file{(item.Count == 1 ? "" : "s")} · {Cleanup.FormatBytes(item.Size)}" : Cleanup.FormatBytes(item.Size);
        var pos = Preview.Position(i, _previewList.Count);
        _previewPos.Text = pos ?? "";
        _previewPos.ToolTip = pos == null ? null : "Arrow keys: previous / next";
        _previewBody.Child = kind switch
        {
            PreviewKind.Image => ImagePreview(path) ?? ThumbnailPreview(path),
            PreviewKind.Text => TextPreview(path),
            _ => ThumbnailPreview(path),
        };
    }

    static FrameworkElement? ImagePreview(string path)
    {
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.DecodePixelWidth = 1600;
            bi.UriSource = new Uri(path);
            bi.EndInit();
            bi.Freeze();
            var img = new Image { Source = bi, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly };
            RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
            return img;
        }
        catch (Exception) { return null; }   // no codec (HEIC without the extension, …): Explorer's thumbnail instead
    }

    static FrameworkElement TextPreview(string path)
    {
        string text;
        var cut = false;
        try
        {
            using var fs = File.OpenRead(path);
            var buf = new byte[Math.Min(fs.Length, Preview.MaxTextBytes)];
            var n = fs.ReadAtLeast(buf, buf.Length, throwOnEndOfStream: false);
            cut = fs.Length > Preview.MaxTextBytes;
            using var sr = new StreamReader(new MemoryStream(buf, 0, n), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            text = sr.ReadToEnd();
        }
        catch (Exception e) { text = $"Couldn't read this file: {e.Message}"; }
        if (cut) text += "\n\n… (the rest is longer than the preview shows; Open to see it all)";
        var tb = new TextBox { Text = text, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap,
                               BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                               HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false };
        tb.SetResourceReference(Control.ForegroundProperty, "Text");
        return tb;
    }

    static FrameworkElement ThumbnailPreview(string path)
    {
        var img = new Image { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, MaxWidth = 256, MaxHeight = 256,
                              HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var note = new TextBlock { FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
        note.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var stack = new DockPanel { LastChildFill = true };   // the picture fits the space left above the note
        DockPanel.SetDock(note, Dock.Bottom);
        stack.Children.Add(note); stack.Children.Add(img);
        ShellThumbs.Load(path, 256, thumbOnly: true, thumb =>
        {
            if (thumb != null) { img.Source = thumb; return; }
            note.Text = "No preview for this kind of file. Open it, or show it in its folder.";
            ShellThumbs.Load(path, 256, thumbOnly: false, icon => img.Source = icon);   // the large icon instead
        });
        return stack;
    }
}
