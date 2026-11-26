using System.Text;

namespace LanLine.Core;

/// <summary>
/// A small QR code encoder (beta.10: the pairing link the iPhone scans), standard library only: ISO/IEC 18004 byte mode,
/// error correction level M, versions 1–10 (up to 213 bytes), all eight masks scored by the four penalty rules. The Mac
/// uses Core Image's generator; this one's output is checked by decoding it with Apple's Vision on the Mac.
/// </summary>
public static class QrCode
{
    // Level M: (total codewords, EC codewords per block, blocks in group 1, data per block g1, blocks g2, data per block g2)
    static readonly (int Total, int Ec, int B1, int D1, int B2, int D2)[] M =
    [
        default, (26, 10, 1, 16, 0, 0), (44, 16, 1, 28, 0, 0), (70, 26, 1, 44, 0, 0), (100, 18, 2, 32, 0, 0), (134, 24, 2, 43, 0, 0),
        (172, 16, 4, 27, 0, 0), (196, 18, 4, 31, 0, 0), (242, 22, 2, 38, 2, 39), (292, 22, 3, 36, 2, 37), (346, 26, 4, 43, 1, 44),
    ];
    static readonly int[][] Align = [[], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

    /// <summary>The modules, [row, column], true = dark; no quiet zone (add four modules around it when drawing).</summary>
    public static bool[,] Encode(string text) => Encode(Encoding.UTF8.GetBytes(text));

    public static bool[,] Encode(byte[] data)
    {
        var version = Enumerable.Range(1, 10).FirstOrDefault(v => Capacity(v) >= data.Length);
        if (version == 0) throw new ArgumentException($"QR: {data.Length} bytes is more than version 10-M holds (213)");
        var codewords = Interleave(version, Pack(version, data));
        var size = 17 + 4 * version;
        var m = new bool[size, size];
        var fn = new bool[size, size];   // function modules (never masked)
        DrawFunctions(version, m, fn);
        PlaceData(codewords, m, fn, version);
        var best = -1; var bestScore = int.MaxValue; bool[,]? bestM = null;
        for (var mask = 0; mask < 8; mask++)
        {
            var t = (bool[,])m.Clone();
            ApplyMask(t, fn, mask);
            DrawFormat(t, mask);
            var score = Penalty(t);
            if (score < bestScore) { bestScore = score; best = mask; bestM = t; }
        }
        return bestM!;
    }

    static int Capacity(int v) { var e = M[v]; var data = e.B1 * e.D1 + e.B2 * e.D2; return data - (v < 10 ? 2 : 3); }

    /// <summary>Mode, count, bytes, terminator, padding: the data codewords.</summary>
    static byte[] Pack(int v, byte[] data)
    {
        var e = M[v];
        var dataCw = e.B1 * e.D1 + e.B2 * e.D2;
        var bits = new List<bool>();
        void Put(int val, int n) { for (var i = n - 1; i >= 0; i--) bits.Add(((val >> i) & 1) == 1); }
        Put(0b0100, 4);
        Put(data.Length, v < 10 ? 8 : 16);
        foreach (var b in data) Put(b, 8);
        Put(0, Math.Min(4, dataCw * 8 - bits.Count));
        while (bits.Count % 8 != 0) bits.Add(false);
        var o = new List<byte>();
        for (var i = 0; i < bits.Count; i += 8) { var b = 0; for (var j = 0; j < 8; j++) b = (b << 1) | (bits[i + j] ? 1 : 0); o.Add((byte)b); }
        for (var pad = 0; o.Count < dataCw; pad++) o.Add(pad % 2 == 0 ? (byte)0xEC : (byte)0x11);
        return [.. o];
    }

    static byte[] Interleave(int v, byte[] data)
    {
        var e = M[v];
        var blocks = new List<byte[]>();
        var pos = 0;
        for (var i = 0; i < e.B1; i++) { blocks.Add(data[pos..(pos + e.D1)]); pos += e.D1; }
        for (var i = 0; i < e.B2; i++) { blocks.Add(data[pos..(pos + e.D2)]); pos += e.D2; }
        var ecs = blocks.Select(b => ReedSolomon(b, e.Ec)).ToList();
        var o = new List<byte>();
        for (var i = 0; i < Math.Max(e.D1, e.D2); i++) foreach (var b in blocks) if (i < b.Length) o.Add(b[i]);
        for (var i = 0; i < e.Ec; i++) foreach (var ec in ecs) o.Add(ec[i]);
        return [.. o];
    }

    // GF(256) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1
    static readonly byte[] Exp = new byte[512], Log = new byte[256];
    static QrCode()
    {
        var x = 1;
        for (var i = 0; i < 255; i++) { Exp[i] = (byte)x; Log[x] = (byte)i; x <<= 1; if (x >= 256) x ^= 0x11D; }
        for (var i = 255; i < 512; i++) Exp[i] = Exp[i - 255];
    }
    static byte Mul(byte a, byte b) => a == 0 || b == 0 ? (byte)0 : Exp[Log[a] + Log[b]];

    static byte[] ReedSolomon(byte[] data, int ec)
    {
        var gen = new byte[] { 1 };   // (x - α^0)(x - α^1)…(x - α^(ec-1))
        for (var i = 0; i < ec; i++)
        {
            var next = new byte[gen.Length + 1];
            for (var j = 0; j < gen.Length; j++) { next[j] ^= gen[j]; next[j + 1] ^= Mul(gen[j], Exp[i]); }
            gen = next;
        }
        var rem = new byte[ec];
        foreach (var d in data)
        {
            var f = (byte)(d ^ rem[0]);
            Array.Copy(rem, 1, rem, 0, ec - 1);
            rem[ec - 1] = 0;
            for (var j = 0; j < ec; j++) rem[j] ^= Mul(gen[j + 1], f);
        }
        return rem;
    }

    static void DrawFunctions(int v, bool[,] m, bool[,] fn)
    {
        var size = m.GetLength(0);
        void Set(int r, int c, bool dark) { m[r, c] = dark; fn[r, c] = true; }
        void Finder(int r0, int c0)
        {
            for (var r = -1; r <= 7; r++)
                for (var c = -1; c <= 7; c++)
                {
                    int rr = r0 + r, cc = c0 + c;
                    if (rr < 0 || cc < 0 || rr >= size || cc >= size) continue;
                    var dark = r is >= 0 and <= 6 && c is >= 0 and <= 6 && (r is 0 or 6 || c is 0 or 6 || (r is >= 2 and <= 4 && c is >= 2 and <= 4));
                    Set(rr, cc, dark);
                }
        }
        Finder(0, 0); Finder(0, size - 7); Finder(size - 7, 0);
        for (var i = 8; i < size - 8; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
        var a = Align[v];
        foreach (var r in a)
            foreach (var c in a)
            {
                if ((r == 6 && c == 6) || (r == 6 && c == a[^1]) || (r == a[^1] && c == 6)) continue;   // the finders' corners
                for (var dr = -2; dr <= 2; dr++)
                    for (var dc = -2; dc <= 2; dc++)
                        Set(r + dr, c + dc, Math.Max(Math.Abs(dr), Math.Abs(dc)) != 1);
            }
        // format areas (filled per mask later) and the dark module
        for (var i = 0; i <= 8; i++) { if (!fn[8, i]) Set(8, i, false); if (!fn[i, 8]) Set(i, 8, false); }
        for (var i = 0; i < 8; i++) { Set(8, size - 1 - i, false); Set(size - 1 - i, 8, false); }
        Set(size - 8, 8, true);
        if (v >= 7)   // version information, BCH(18,6)
        {
            var rem = v;
            for (var i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            var bits = (v << 12) | rem;
            for (var i = 0; i < 18; i++)
            {
                var dark = ((bits >> i) & 1) == 1;
                Set(size - 11 + i % 3, i / 3, dark);
                Set(i / 3, size - 11 + i % 3, dark);
            }
        }
    }

    static void PlaceData(byte[] cw, bool[,] m, bool[,] fn, int v)
    {
        var size = m.GetLength(0);
        var bit = 0; var total = cw.Length * 8;
        var up = true;
        for (var right = size - 1; right >= 1; right -= 2)
        {
            if (right == 6) right = 5;   // the vertical timing column is skipped
            for (var i = 0; i < size; i++)
            {
                var r = up ? size - 1 - i : i;
                for (var k = 0; k < 2; k++)
                {
                    var c = right - k;
                    if (fn[r, c]) continue;
                    m[r, c] = bit < total && ((cw[bit / 8] >> (7 - bit % 8)) & 1) == 1;   // remainder bits stay light
                    bit++;
                }
            }
            up = !up;
        }
    }

    static bool MaskBit(int mask, int r, int c) => mask switch
    {
        0 => (r + c) % 2 == 0, 1 => r % 2 == 0, 2 => c % 3 == 0, 3 => (r + c) % 3 == 0,
        4 => (r / 2 + c / 3) % 2 == 0, 5 => r * c % 2 + r * c % 3 == 0, 6 => (r * c % 2 + r * c % 3) % 2 == 0, _ => ((r + c) % 2 + r * c % 3) % 2 == 0,
    };

    static void ApplyMask(bool[,] m, bool[,] fn, int mask)
    {
        var size = m.GetLength(0);
        for (var r = 0; r < size; r++) for (var c = 0; c < size; c++) if (!fn[r, c] && MaskBit(mask, r, c)) m[r, c] = !m[r, c];
    }

    static void DrawFormat(bool[,] m, int mask)
    {
        var size = m.GetLength(0);
        var data = (0b00 << 3) | mask;   // level M = 00
        var rem = data;
        for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        var bits = ((data << 10) | rem) ^ 0x5412;
        bool B(int i) => ((bits >> i) & 1) == 1;
        // [row, column]: first copy down column 8 then along row 8 (around the top-left finder), second copy along
        // row 8 at the right and down column 8 at the bottom.
        for (var i = 0; i <= 5; i++) m[i, 8] = B(i);
        m[7, 8] = B(6); m[8, 8] = B(7); m[8, 7] = B(8);
        for (var i = 9; i < 15; i++) m[8, 14 - i] = B(i);
        for (var i = 0; i < 8; i++) m[8, size - 1 - i] = B(i);
        for (var i = 8; i < 15; i++) m[size - 15 + i, 8] = B(i);
        m[size - 8, 8] = true;
    }

    static int Penalty(bool[,] m)
    {
        var n = m.GetLength(0); var score = 0;
        for (var pass = 0; pass < 2; pass++)   // rule 1: runs of 5+ in rows, then columns
            for (var a = 0; a < n; a++)
            {
                var run = 1;
                for (var b = 1; b < n; b++)
                {
                    bool cur = pass == 0 ? m[a, b] : m[b, a], prev = pass == 0 ? m[a, b - 1] : m[b - 1, a];
                    if (cur == prev) { run++; if (run == 5) score += 3; else if (run > 5) score++; } else run = 1;
                }
            }
        for (var r = 0; r < n - 1; r++)   // rule 2: 2×2 blocks
            for (var c = 0; c < n - 1; c++)
                if (m[r, c] == m[r, c + 1] && m[r, c] == m[r + 1, c] && m[r, c] == m[r + 1, c + 1]) score += 3;
        bool[] p1 = [true, false, true, true, true, false, true, false, false, false, false], p2 = [false, false, false, false, true, false, true, true, true, false, true];
        for (var a = 0; a < n; a++)   // rule 3: finder-like patterns
            for (var b = 0; b <= n - 11; b++)
            {
                bool rowP1 = true, rowP2 = true, colP1 = true, colP2 = true;
                for (var k = 0; k < 11; k++)
                {
                    if (m[a, b + k] != p1[k]) rowP1 = false;
                    if (m[a, b + k] != p2[k]) rowP2 = false;
                    if (m[b + k, a] != p1[k]) colP1 = false;
                    if (m[b + k, a] != p2[k]) colP2 = false;
                }
                score += 40 * ((rowP1 ? 1 : 0) + (rowP2 ? 1 : 0) + (colP1 ? 1 : 0) + (colP2 ? 1 : 0));
            }
        var dark = 0;   // rule 4: balance
        for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) if (m[r, c]) dark++;
        score += Math.Abs(dark * 20 - n * n * 10) / (n * n) * 10;
        return score;
    }
}
