using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// The welcome tour (beta.10): three cards over the window, once, on a new install after pairing and the first-run
/// settings; again any time from the status line's menu. The wording is Tour.Cards(Windows), shared with the Mac.
/// </summary>
sealed partial class MainWindow
{
    Grid? _tourLayer;

    void MaybeShowTour()
    {
        if (_demo || _pairing || _showingSettings || _tourLayer != null) return;
        if (Tour.ShouldShow(_storage.TourSeen, _device.Peers.Count > 0, _storage.Confirmed)) ShowTour(0);
    }

    static string TourGlyph(string id) => id switch { "send" => "", "anywhere" => "", _ => "" };   // Send, Share, Pin

    internal void ShowTour(int page)
    {
        var cards = Tour.Cards(Tour.Platform.Windows);
        page = Math.Clamp(page, 0, cards.Count - 1);
        var card = cards[page];
        var last = page == cards.Count - 1;
        if (_tourLayer != null) ((Grid)Content).Children.Remove(_tourLayer);
        var layer = new Grid { Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)) };
        var iconFont = (FontFamily)Application.Current.Resources["IconFont"];
        var glyph = new TextBlock { Text = TourGlyph(card.Id), FontFamily = iconFont, FontSize = 24, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        glyph.SetResourceReference(TextBlock.ForegroundProperty, "OnAccent");
        var icon = new Border { Width = 54, Height = 54, CornerRadius = new CornerRadius(14), HorizontalAlignment = HorizontalAlignment.Center, Child = glyph };
        icon.SetResourceReference(Border.BackgroundProperty, "Accent");
        var title = new TextBlock { Text = card.Title, FontSize = 15, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        var body = new TextBlock { Text = card.Body, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 5, 0, 0) };
        body.SetResourceReference(TextBlock.ForegroundProperty, "Text2");
        var dots = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
        for (var i = 0; i < cards.Count; i++)
        {
            var d = new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Margin = new Thickness(3, 0, 3, 0), Opacity = i == page ? 1 : 0.4 };
            d.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, i == page ? "Accent" : "Text2");
            dots.Children.Add(d);
        }
        var quiet = new Button { Content = last ? "Back" : "Skip", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0), Visibility = last && page == 0 ? Visibility.Collapsed : Visibility.Visible };
        quiet.SetResourceReference(StyleProperty, "LinkButton");
        quiet.Click += (_, _) => { if (last) ShowTour(page - 1); else FinishTour(); };
        var next = new Button { Content = last ? "Done" : "Next", Width = 88, Height = 30, IsDefault = true };
        next.SetResourceReference(StyleProperty, "PrimaryButton");
        next.Click += (_, _) => { if (last) FinishTour(); else ShowTour(page + 1); };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(quiet); buttons.Children.Add(next);
        var col = new StackPanel();
        col.Children.Add(icon); col.Children.Add(title); col.Children.Add(body); col.Children.Add(dots); col.Children.Add(buttons);
        var box = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(20, 18, 20, 18), Margin = new Thickness(18), MaxWidth = 320,
                               VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Child = col };
        box.SetResourceReference(Border.BackgroundProperty, "MenuBg");
        box.SetResourceReference(Border.BorderBrushProperty, "CardStroke");
        box.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 4, Direction = 270, Opacity = 0.35, Color = Colors.Black };
        Automation(box, $"{card.Title}. {card.Body} Card {page + 1} of {cards.Count}.");
        layer.Children.Add(box);
        layer.PreviewKeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) { FinishTour(); e.Handled = true; } };
        _tourLayer = layer;
        ((Grid)Content).Children.Add(layer);
        next.Focus();
        Announce($"{card.Title}. {card.Body}");
    }

    void FinishTour()
    {
        if (_tourLayer != null) { ((Grid)Content).Children.Remove(_tourLayer); _tourLayer = null; }
        _input.Focus();
        if (_demo || _storage.TourSeen == true) return;
        _storage.TourSeen = true;
        try { _storage.Save(SettingsPath); } catch (Exception) { }   // shown again next time at worst
    }
}
