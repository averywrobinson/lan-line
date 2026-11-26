using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Sound and motion (beta.10): the arrival chime and the send tick (made by Chime, the same as the Mac), new items
/// rising into place, and the status dot breathing while Lan-Line reconnects. Motion follows Windows' "Animation
/// effects" setting (Settings → Accessibility → Visual effects).
/// </summary>
sealed partial class MainWindow
{
    static readonly Lazy<System.Media.SoundPlayer> ArriveSound = new(() => Player(Chime.Kind.Arrive));
    static readonly Lazy<System.Media.SoundPlayer> SentSound = new(() => Player(Chime.Kind.Sent));
    readonly SoundGate _soundGate = new();

    static System.Media.SoundPlayer Player(Chime.Kind k)
    {
        var p = new System.Media.SoundPlayer(new MemoryStream(Chime.Wav(k)));
        p.Load();
        return p;
    }

    static bool Animations => SystemParameters.ClientAreaAnimation;

    void ChimeArrival(bool notificationShown)
    {
        if (_demo || !_soundGate.Arrive(_storage.SoundsValue, notificationShown, DateTime.UtcNow)) return;
        try { ArriveSound.Value.Play(); } catch (Exception) { }   // no audio device: stay quiet
    }

    void TickSent()
    {
        if (_demo || !_storage.SoundsValue) return;
        try { SentSound.Value.Play(); } catch (Exception) { }
    }

    /// <summary>A new item rises into place: from 94 % and 8 px lower, fading in, over 280 ms (ease out).</summary>
    void AnimateIn(FrameworkElement v, bool incoming)
    {
        if (_demo || !Animations) return;
        var scale = new ScaleTransform(0.94, 0.94);
        var move = new TranslateTransform(0, 8);
        v.RenderTransformOrigin = new Point(incoming ? 0 : 1, 1);
        v.RenderTransform = new TransformGroup { Children = { scale, move } };
        v.Opacity = 0;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var d = new Duration(TimeSpan.FromMilliseconds(280));
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, d) { EasingFunction = ease });
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, d) { EasingFunction = ease });
        move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, d) { EasingFunction = ease });
        var fade = new DoubleAnimation(1, new Duration(TimeSpan.FromMilliseconds(200)));
        fade.Completed += (_, _) => { v.BeginAnimation(OpacityProperty, null); v.Opacity = 1; v.RenderTransform = null; };
        v.BeginAnimation(OpacityProperty, fade);
    }

    bool _dotPulsing;

    /// <summary>Breathe while reconnecting (paired, not connected); still otherwise.</summary>
    void RefreshDotPulse()
    {
        var want = !_connected && _partners.Count > 0 && !_pairing && Animations && !_demo;
        if (want == _dotPulsing) return;
        _dotPulsing = want;
        if (want)
            _dot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, new Duration(TimeSpan.FromSeconds(0.9)))
                { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
        else { _dot.BeginAnimation(OpacityProperty, null); _dot.Opacity = 1; }
    }
}
