namespace LanLine.Core;

/// <summary>
/// Lan-Line's two small sounds (beta.10), made in code so both apps sound the same and ship no audio files: arrive,
/// two soft notes rising (A5 → E6), and sent, one short quiet tick. 16-bit mono PCM WAV, 44.1 kHz. The same recipe as
/// Chime in LanLineCore; the tests pin the length, the header and the loudness.
/// </summary>
public static class Chime
{
    public enum Kind { Arrive, Sent }
    public const int SampleRate = 44_100;

    /// <summary>Times in whole milliseconds, so both platforms get exactly the same number of samples.</summary>
    sealed record Note(double Hz, int StartMs, int LengthMs, double Level);

    static Note[] Notes(Kind k) => k switch
    {
        Kind.Arrive => [new(880, 0, 160, 0.32), new(1318.51, 85, 340, 0.30)],
        _ => [new(1567.98, 0, 70, 0.12)],
    };

    /// <summary>Each note is a sine with a 4 ms fade-in and an exponential fade-out, plus a quiet octave above.</summary>
    public static short[] Samples(Kind k)
    {
        var ns = Notes(k);
        var endMs = ns.Max(n => n.StartMs + n.LengthMs);
        var count = endMs * SampleRate / 1000;
        var o = new short[count];
        for (var i = 0; i < count; i++)
        {
            var v = 0.0;
            foreach (var n in ns)
            {
                int first = n.StartMs * SampleRate / 1000, last = (n.StartMs + n.LengthMs) * SampleRate / 1000;
                if (i < first || i >= last) continue;
                double u = (double)(i - first) / SampleRate, len = n.LengthMs / 1000.0;
                var attack = Math.Min(1, u / 0.004);
                var decay = Math.Exp(-u * 5.0 / len);
                v += n.Level * attack * decay * (Math.Sin(2 * Math.PI * n.Hz * u) + 0.18 * Math.Sin(4 * Math.PI * n.Hz * u));
            }
            o[i] = (short)(Math.Clamp(v, -1, 1) * 32_000);
        }
        return o;
    }

    public static byte[] Wav(Kind k)
    {
        var s = Samples(k);
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + s.Length * 2); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(SampleRate); w.Write(SampleRate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(s.Length * 2);
        foreach (var v in s) w.Write(v);
        w.Flush();
        return ms.ToArray();
    }
}

/// <summary>When the app plays a sound (beta.10). Pure: the app asks, then plays.</summary>
public sealed class SoundGate
{
    public DateTime? LastArrive { get; private set; }
    /// <summary>Bursts get one chime.</summary>
    public static readonly TimeSpan Gap = TimeSpan.FromSeconds(1.5);

    /// <summary>A notification plays its own sound, so only chime when none is shown.</summary>
    public bool Arrive(bool soundsOn, bool notificationShown, DateTime now)
    {
        if (!soundsOn || notificationShown) return false;
        if (LastArrive is { } l && now - l < Gap) return false;
        LastArrive = now;
        return true;
    }
}
