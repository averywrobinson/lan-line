using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using LanLine.Core;
using Microsoft.Win32;

namespace LanLine.App;

/// <summary>
/// The accessibility pass (beta.10): text size, Narrator names for option groups, and announcements.
/// High contrast is in Theme.cs.
/// </summary>
sealed partial class MainWindow
{
    /// <summary>--text-scale N (checks): the effective scale, instead of Windows' setting times Lan-Line's.</summary>
    internal static double? ForcedTextScale;
    double _textScale = 1;

    /// <summary>Windows' Settings › Accessibility › Text size, 100–225 (100 when it was never changed).</summary>
    static double SystemTextPercent()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Accessibility");
            return k?.GetValue("TextScaleFactor") is int v ? v : 100;
        }
        catch (Exception) { return 100; }
    }

    /// <summary>
    /// Scale the whole window's content by Windows' Text size times Lan-Line's own setting (a LayoutTransform, so
    /// everything is laid out again at the new size and stays sharp). The window grows with it, within the screen.
    /// </summary>
    internal void ApplyTextScale()
    {
        var s = ForcedTextScale ?? StorageSettings.EffectiveTextScale(SystemTextPercent(), _storage.TextScaleValue);
        if (Math.Abs(s - _textScale) < 0.001) return;
        var old = _textScale;
        _textScale = s;
        if (Content is FrameworkElement root) root.LayoutTransform = Math.Abs(s - 1) < 0.001 ? Transform.Identity : new ScaleTransform(s, s);
        MinWidth = 300 * s; MinHeight = 230 * s;
        if (WindowState != WindowState.Normal || double.IsNaN(Width) || double.IsNaN(Height)) return;
        var wa = SystemParameters.WorkArea;
        var right = Left + Width; var bottom = Top + Height;   // it sits bottom-right by default: grow up and to the left
        Width = Math.Min(Width * s / old, wa.Width); Height = Math.Min(Height * s / old, wa.Height);
        Left = Math.Max(wa.Left, Math.Min(right, wa.Right) - Width); Top = Math.Max(wa.Top, Math.Min(bottom, wa.Bottom) - Height);
    }

    void WatchTextScale() =>
        SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(ApplyTextScale);   // Windows' Text size slider

    /// <summary>Say something through Narrator (or any screen reader): what arrived, without moving focus.</summary>
    void Announce(string text)
    {
        try
        {
            var peer = UIElementAutomationPeer.FromElement(this) ?? UIElementAutomationPeer.CreatePeerForElement(this);
            peer?.RaiseNotificationEvent(AutomationNotificationKind.ItemAdded, AutomationNotificationProcessing.ImportantMostRecent, text, "LanLine.Arrival");
        }
        catch (Exception) { }   // no automation client listening
    }

    /// <summary>
    /// A row of option pills is a question and its answers, but a screen reader only hears the answers ("Off, radio
    /// button"). Give each pill the question too ("Play sounds: Off"), taken from the label above its row.
    /// </summary>
    internal static void NamePillGroups(DependencyObject root)
    {
        string? question = null;
        void Walk(DependencyObject o)
        {
            foreach (var child in LogicalTreeHelper.GetChildren(o))
            {
                switch (child)
                {
                    case TextBlock { FontWeight: var w } t when w == FontWeights.SemiBold && t.FontSize <= 12.5: question = t.Text; break;
                    case RadioButton r when question != null && r.Content is string answer: AutomationProperties.SetName(r, $"{question}: {answer}"); break;
                    case Slider or TextBox when question != null && child is DependencyObject d && string.IsNullOrEmpty(AutomationProperties.GetName(d)): AutomationProperties.SetName(d, question); break;
                    case DependencyObject d: Walk(d); break;
                }
            }
        }
        Walk(root);
    }
}
