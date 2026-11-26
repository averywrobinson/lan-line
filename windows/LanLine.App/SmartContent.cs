using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Smart text items (beta.10): a one-time code to copy on its own, a colour swatch, code in a block, a link card and
/// link chips. What a message is comes from SmartText (shared with the Mac).
/// </summary>
static class SmartContent
{
    static FontFamily Mono => new("Cascadia Mono, Consolas");

    /// <summary>The text part of a text bubble, plus extra context-menu entries.</summary>
    public static FrameworkElement Build(string text, MainWindow owner, out List<(string, Action)> menu)
    {
        var info = SmartText.Analyze(text);
        menu = [];
        if (info.Otp is { } otp) menu.Add(($"Copy code {otp}", () => TryCopy(otp)));
        if (info.Color is { } c)
        {
            menu.Add(($"Copy as {c.Hex}", () => TryCopy(c.Hex)));
            menu.Add(($"Copy as {c.Rgb}", () => TryCopy(c.Rgb)));
            menu.Add(($"Copy as {c.Hsl}", () => TryCopy(c.Hsl)));
        }
        foreach (var u in info.Links) menu.Add(($"Open {LinkPreview.Host(u)}", () => Open(u)));

        if (info.SingleLink is { } link) return LinkCard(link, owner);
        var stack = new StackPanel();
        if (info.Code is { } code)
        {
            var lang = new TextBlock { Text = code.Language ?? "Code", FontSize = 10, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 3) };
            lang.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
            var body = new TextBox { Text = code.Body, FontFamily = Mono, FontSize = 12, TextWrapping = TextWrapping.NoWrap, IsReadOnly = true,
                                     BorderThickness = new Thickness(0), Background = Brushes.Transparent, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
            body.SetResourceReference(Control.ForegroundProperty, "Text");
            var block = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 6, 8, 6), MaxWidth = 300,
                                     Background = new SolidColorBrush(Color.FromArgb(Theme.IsDark ? (byte)0x48 : (byte)0x0D, 0, 0, 0)) };
            var inner = new StackPanel(); inner.Children.Add(lang); inner.Children.Add(body);
            block.Child = inner;
            stack.Children.Add(block);
            return stack;
        }
        var tb = new TextBox { Text = text, VerticalAlignment = VerticalAlignment.Center };
        tb.SetResourceReference(FrameworkElement.StyleProperty, "ReadOnlyText");
        if (info.Color is { } col)
        {
            var row = new DockPanel();
            var sw = new Ellipse { Width = 16, Height = 16, Margin = new Thickness(0, 0, 8, 0), StrokeThickness = 1, VerticalAlignment = VerticalAlignment.Center,
                                   Fill = new SolidColorBrush(Color.FromArgb((byte)Math.Round(col.A * 255), (byte)col.R, (byte)col.G, (byte)col.B)),
                                   Stroke = new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80)) };
            System.Windows.Automation.AutomationProperties.SetName(sw, $"Colour {col.Hex}");
            DockPanel.SetDock(sw, Dock.Left);
            row.Children.Add(sw); row.Children.Add(tb);
            stack.Children.Add(row);
        }
        else stack.Children.Add(tb);
        if (info.Otp is { } code2) stack.Children.Add(CodeChip(code2));
        if (info.Links.Count > 0)
        {
            var chips = new WrapPanel { Margin = new Thickness(0, 5, 0, 0) };
            foreach (var u in info.Links.Take(3)) chips.Children.Add(LinkChip(u));
            stack.Children.Add(chips);
        }
        return stack;
    }

    static void TryCopy(string s) { try { Clipboard.SetText(s); } catch (Exception) { } }

    /// <summary>Only web links ever open (SmartText only finds http(s)); the default browser opens them.</summary>
    public static void Open(Uri u)
    {
        if (u.Scheme is not ("http" or "https")) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true }); } catch (Exception) { }
    }

    static Button CodeChip(string code)
    {
        var grouped = code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;
        var label = new TextBlock { Text = "Copy code  ", FontSize = 11.5, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
        var digits = new TextBlock { Text = grouped, FontSize = 13, FontWeight = FontWeights.SemiBold, FontFamily = Mono, VerticalAlignment = VerticalAlignment.Center };
        var key = new TextBlock { Text = "\uE8D7", FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 7, 0) };
        foreach (var t in new[] { key, label, digits }) t.SetResourceReference(TextBlock.ForegroundProperty, "OnAccent");   // white, or a contrast theme's selected-text colour
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(key); content.Children.Add(label); content.Children.Add(digits);
        var b = new Button { Content = content, Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, ToolTip = "Copy only the code" };
        b.SetResourceReference(FrameworkElement.StyleProperty, "ChipButton");
        MainWindow.Automation(b, $"Copy code {code}");
        b.Click += (_, _) =>
        {
            TryCopy(code);
            label.Text = "Copied  ";
            var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
            t.Tick += (_, _) => { t.Stop(); label.Text = "Copy code  "; };
            t.Start();
        };
        return b;
    }

    static Button LinkChip(Uri u)
    {
        var b = new Button { Content = "🔗 " + LinkPreview.Host(u), FontSize = 11, Margin = new Thickness(0, 0, 6, 0), ToolTip = u.AbsoluteUri };
        b.SetResourceReference(FrameworkElement.StyleProperty, "LinkButton");
        b.Click += (_, _) => Open(u);
        return b;
    }

    /// <summary>A message that is one link: the site, the path, Open; with link previews on, the page's title and picture.</summary>
    static FrameworkElement LinkCard(Uri u, MainWindow owner)
    {
        var title = new TextBlock { Text = LinkPreview.Host(u), FontSize = 12.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        var path = new TextBlock { Text = LinkPreview.Host(u) + (u.AbsolutePath.Length > 1 ? u.AbsolutePath : ""), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
        path.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(title); names.Children.Add(path);
        var icon = new TextBlock { Text = "", FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 18, Margin = new Thickness(0, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center };
        icon.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
        var open = new Button { Content = "Open", FontSize = 12, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        open.SetResourceReference(FrameworkElement.StyleProperty, "SecondaryButton");
        open.Click += (_, _) => Open(u);
        var row = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left); DockPanel.SetDock(open, Dock.Right);
        row.Children.Add(icon); row.Children.Add(open); row.Children.Add(names);
        var picture = new Image { Height = 120, Stretch = Stretch.UniformToFill, Visibility = Visibility.Collapsed };
        // Up to 260 wide, narrower in a narrow window: the names shrink (they are the DockPanel's fill), Open keeps its
        // size. A fixed 260 was wider than a 380 px window allows and cut Open off (design refresh, beta.10).
        var stack = new StackPanel { MaxWidth = 260, MinWidth = 150 };
        stack.Children.Add(picture);
        stack.Children.Add(new Border { Child = row, Padding = new Thickness(9) });
        var card = new Border { Child = stack, CornerRadius = new CornerRadius(10), ClipToBounds = true, ToolTip = u.AbsoluteUri,
                                Background = new SolidColorBrush(Color.FromArgb(Theme.IsDark ? (byte)0x38 : (byte)0x0A, 0, 0, 0)) };
        if (owner.LinkPreviewsOn) _ = PreviewFetcher.Fill(u, title, picture);
        return card;
    }
}

/// <summary>Fetches link previews (only while "Show link previews" is on): the first 512 KB of the page, 5 s at most,
/// no cookies; pictures up to 2 MB. Results are kept for this session.</summary>
static class PreviewFetcher
{
    static readonly HttpClient Http = new(new HttpClientHandler { UseCookies = false, AllowAutoRedirect = true, MaxAutomaticRedirections = 5 }) { Timeout = LinkPreview.Timeout };
    static readonly Dictionary<Uri, LinkPreview?> Pages = [];

    static PreviewFetcher() { Http.DefaultRequestHeaders.UserAgent.ParseAdd("Lan-Line-link-preview"); }

    public static async Task Fill(Uri u, TextBlock title, Image picture)
    {
        try
        {
            if (!Pages.TryGetValue(u, out var p))
            {
                p = null;
                using var resp = await Http.GetAsync(u, HttpCompletionOption.ResponseHeadersRead);
                if (resp.IsSuccessStatusCode && resp.Content.Headers.ContentType?.MediaType?.Contains("html") == true)
                {
                    await using var s = await resp.Content.ReadAsStreamAsync();
                    var buf = new byte[LinkPreview.MaxHtml];
                    var n = await s.ReadAtLeastAsync(buf, buf.Length, throwOnEndOfStream: false);
                    var parsed = LinkPreview.Parse(System.Text.Encoding.UTF8.GetString(buf, 0, n), resp.RequestMessage?.RequestUri ?? u);
                    if (parsed.Title != null || parsed.Image != null) p = parsed;
                }
                Pages[u] = p;
            }
            if (p?.Title is { } t) title.Text = t;
            if (p?.Image is { } img)
            {
                using var r = await Http.GetAsync(img, HttpCompletionOption.ResponseHeadersRead);
                if (!r.IsSuccessStatusCode || r.Content.Headers.ContentType?.MediaType?.StartsWith("image/") != true || r.Content.Headers.ContentLength > LinkPreview.MaxImage) return;
                // Read as a stream and stop at the cap: a server that sends no length (or lies) can't make us buffer more.
                await using var body = await r.Content.ReadAsStreamAsync();
                var capped = new byte[LinkPreview.MaxImage + 1];
                var got = await body.ReadAtLeastAsync(capped, capped.Length, throwOnEndOfStream: false);
                if (got > LinkPreview.MaxImage) return;
                var bytes = capped[..got];
                var bi = new BitmapImage();
                bi.BeginInit(); bi.CacheOption = BitmapCacheOption.OnLoad; bi.StreamSource = new MemoryStream(bytes); bi.DecodePixelWidth = 520; bi.EndInit(); bi.Freeze();
                picture.Source = bi; picture.Visibility = Visibility.Visible;
            }
        }
        catch (Exception) { /* offline, slow or odd page: the plain card stays */ }
    }
}
