using System.Globalization;
using System.Text.RegularExpressions;

namespace LanLine.Core;

/// <summary>A colour from a message (beta.10).</summary>
public sealed record SmartColor(int R, int G, int B, double A = 1)
{
    public string Hex => $"#{R:X2}{G:X2}{B:X2}" + (A < 1 ? $"{(int)Math.Round(A * 255, MidpointRounding.AwayFromZero):X2}" : "");
    public string Rgb => A < 1 ? $"rgba({R}, {G}, {B}, {SmartText.Trim(A)})" : $"rgb({R}, {G}, {B})";
    public string Hsl
    {
        get
        {
            var (h, s, l) = SmartText.ToHsl(R, G, B);
            return A < 1 ? $"hsla({h}, {s}%, {l}%, {SmartText.Trim(A)})" : $"hsl({h}, {s}%, {l}%)";
        }
    }
}

public sealed record SmartCode(string Body, string? Language);

public sealed record SmartInfo
{
    public string? Otp { get; init; }
    public SmartColor? Color { get; init; }
    public SmartCode? Code { get; init; }
    public Uri? SingleLink { get; init; }
    public List<Uri> Links { get; init; } = [];
}

/// <summary>What a text item is, beyond plain words (beta.10): a one-time code, a colour, code, a link. The same rules
/// and cases as SmartText on the Mac.</summary>
public static class SmartText
{
    public static SmartInfo Analyze(string text)
    {
        var t = text.Trim();
        if (t.Length == 0 || t.Length > 100_000) return new SmartInfo();
        var code = Code(t);
        var links = Links(t);
        Uri? single = null;
        if (code == null && links.Count == 1 && !t.Any(char.IsWhiteSpace))
        {
            static string N(string s) => s.TrimEnd('/');   // .NET adds a "/" after a bare host; the Mac doesn't
            var only = N(links[0].AbsoluteUri);
            if (N(t) == only || N("https://" + t) == only || N("http://" + t) == only) single = links[0];
        }
        return new SmartInfo { Code = code, Otp = code == null ? Otp(t) : null, Color = code == null ? Color(t) : null, Links = links, SingleLink = single };
    }

    const string OtpWords = @"(?i)\b(code|passcode|otp|verification|verify|2fa|one[- ]time|security code|login|sign[- ]in|pin)\b";

    public static string? Otp(string t)
    {
        static string Digits(string s) => new(s.SkipWhile(c => !char.IsDigit(c)).Where(char.IsDigit).ToArray());
        if (Regex.IsMatch(t, @"^(?:[A-Z]{1,3}-)?(\d{3}[ -]\d{3}|\d{4,8})$")) return Digits(t);
        if (t.Length > 400 || !Regex.IsMatch(t, OtpWords)) return null;
        var m = Regex.Match(t, @"(?<![\d.,:/])(?:[A-Z]{1,3}-)?(\d{3}[ -]\d{3}|\d{4,8})(?![\d/]|[.,:]\d)");
        return m.Success ? Digits(m.Value) : null;
    }

    public static SmartColor? Color(string t)
    {
        var s = t.ToLowerInvariant().Replace(" ", "");
        if (s.StartsWith('#'))
        {
            var h = s[1..];
            if (h.Length is not (3 or 4 or 6 or 8) || !h.All(Uri.IsHexDigit)) return null;
            var full = h.Length <= 4 ? string.Concat(h.Select(c => $"{c}{c}")) : h;
            int Byte(int i) => Convert.ToInt32(full.Substring(i * 2, 2), 16);
            return new SmartColor(Byte(0), Byte(1), Byte(2), full.Length == 8 ? Byte(3) / 255.0 : 1);
        }
        var open = s.IndexOf('(');
        if (open < 0 || !s.EndsWith(')')) return null;
        var fn = s[..open];
        var parts = s[(open + 1)..^1].Split(',');
        static double? Num(string p) => double.TryParse(p.Replace("%", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
        switch (fn)
        {
            case "rgb" or "rgba":
            {
                if (parts.Length != (fn == "rgb" ? 3 : 4) || Num(parts[0]) is not { } r || Num(parts[1]) is not { } g || Num(parts[2]) is not { } b) return null;
                if (new[] { r, g, b }.Any(v => v < 0 || v > 255)) return null;
                var a = parts.Length == 4 ? Num(parts[3]) : 1;
                if (a is not { } av || av < 0 || av > 1) return null;
                return new SmartColor((int)r, (int)g, (int)b, av);
            }
            case "hsl" or "hsla":
            {
                if (parts.Length != (fn == "hsl" ? 3 : 4) || Num(parts[0]) is not { } h || Num(parts[1]) is not { } sat || Num(parts[2]) is not { } l) return null;
                if (h < 0 || h > 360 || sat < 0 || sat > 100 || l < 0 || l > 100) return null;
                var a = parts.Length == 4 ? Num(parts[3]) : 1;
                if (a is not { } av || av < 0 || av > 1) return null;
                var (r, g, b) = FromHsl(h, sat / 100, l / 100);
                return new SmartColor(r, g, b, av);
            }
            default: return null;
        }
    }

    static (int, int, int) FromHsl(double h, double s, double l)
    {
        double c = (1 - Math.Abs(2 * l - 1)) * s, hp = h / 60, x = c * (1 - Math.Abs(hp % 2 - 1)), m = l - c / 2;
        var (r1, g1, b1) = hp switch
        {
            < 1 => (c, x, 0.0), < 2 => (x, c, 0.0), < 3 => (0.0, c, x), < 4 => (0.0, x, c), < 5 => (x, 0.0, c), _ => (c, 0.0, x),
        };
        int To255(double v) => (int)Math.Round((v + m) * 255, MidpointRounding.AwayFromZero);
        return (To255(r1), To255(g1), To255(b1));
    }

    internal static (int, int, int) ToHsl(int r, int g, int b)
    {
        double rf = r / 255.0, gf = g / 255.0, bf = b / 255.0;
        double mx = Math.Max(rf, Math.Max(gf, bf)), mn = Math.Min(rf, Math.Min(gf, bf)), l = (mx + mn) / 2, d = mx - mn;
        int R(double v) => (int)Math.Round(v, MidpointRounding.AwayFromZero);
        if (d <= 0) return (0, 0, R(l * 100));
        var s = d / (1 - Math.Abs(2 * l - 1));
        double h = mx == rf ? ((gf - bf) / d) % 6 : mx == gf ? (bf - rf) / d + 2 : (rf - gf) / d + 4;
        h *= 60; if (h < 0) h += 360;
        return (R(h) % 360, R(s * 100), R(l * 100));
    }

    internal static string Trim(double a) => a.ToString("0.##", CultureInfo.InvariantCulture);

    static readonly Regex CodeHints = new(@"^\s*(func |def |class |import |from \S+ import|return\b|let |var |const |public |private |#include|using |package |fn |SELECT |INSERT |UPDATE |CREATE |if \(|for \(|while \(|\$ |sudo |git |npm |pip |brew |cd |curl )", RegexOptions.IgnoreCase);

    public static SmartCode? Code(string t)
    {
        if (t.StartsWith("```"))
        {
            var lines = t.Split('\n').ToList();
            var lang = lines[0][3..].Trim();
            lines.RemoveAt(0);
            if (lines.Count > 0 && lines[^1].Trim() == "```") lines.RemoveAt(lines.Count - 1);
            return new SmartCode(string.Join("\n", lines), lang.Length == 0 ? null : lang);
        }
        var ls = t.Split('\n').Where(l => l.Trim().Length > 0).ToList();
        if (ls.Count < 2) return null;
        var codey = ls.Count(l =>
        {
            var s = l.Trim();
            return l.StartsWith("  ") || l.StartsWith('\t')
                || new[] { "{", "}", ";", "};", ")", "]", "):", "=>", "->", "\\" }.Any(s.EndsWith)
                || CodeHints.IsMatch(s)
                || new[] { "==", "!=", "=>", "::", "&&", "||", "</", "/>" }.Any(s.Contains);
        });
        var sentences = ls.Count(l => Regex.IsMatch(l.Trim(), @"[a-z][.!?]$"));
        return codey >= 2 && (double)codey / ls.Count >= 0.5 && sentences * 2 < ls.Count ? new SmartCode(t, null) : null;
    }

    static readonly Regex LinkRx = new(@"(?i)\b(?:https?://|www\.)[^\s<>""']+");

    public static List<Uri> Links(string t)
    {
        var o = new List<Uri>();
        foreach (Match m in LinkRx.Matches(t))
        {
            var s = m.Value;
            while (s.Length > 0 && ".,;:!?)]}'\"".Contains(s[^1]))
            {
                if (s[^1] == ')' && s.Count(c => c == '(') >= s.Count(c => c == ')')) break;
                s = s[..^1];
            }
            if (s.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) s = "https://" + s;
            if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || u.Scheme is not ("http" or "https") || u.Host.Length == 0) continue;
            if (!o.Contains(u)) o.Add(u);
            if (o.Count == 5) break;
        }
        return o;
    }
}

/// <summary>Link previews (beta.10, off unless turned on). The same parsing as LinkPreview on the Mac.</summary>
public sealed record LinkPreview(string? Title, string? Site, Uri? Image)
{
    public const int MaxHtml = 512 * 1024, MaxImage = 2_000_000;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    public static LinkPreview Parse(string html, Uri baseUri)
    {
        string? Meta(string key)
        {
            var k = Regex.Escape(key);
            foreach (var pat in new[] { @"<meta[^>]+(?:property|name)\s*=\s*[""']" + k + @"[""'][^>]*content\s*=\s*[""']([^""']*)[""']",
                                        @"<meta[^>]+content\s*=\s*[""']([^""']*)[""'][^>]*(?:property|name)\s*=\s*[""']" + k + @"[""']" })
            {
                var m = Regex.Match(html, pat, RegexOptions.IgnoreCase);
                if (m.Success && Decode(m.Groups[1].Value).Trim() is { Length: > 0 } v) return v;
            }
            return null;
        }
        var title = Meta("og:title") ?? Meta("twitter:title");
        if (title == null && Regex.Match(html, @"<title[^>]*>([^<]{1,500})</title>", RegexOptions.IgnoreCase) is { Success: true } tm)
        {
            var v = string.Join(" ", Decode(tm.Groups[1].Value).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            if (v.Length > 0) title = v;
        }
        if (title is { Length: > 200 }) title = title[..200] + "…";
        Uri? image = null;
        if ((Meta("og:image") ?? Meta("twitter:image")) is { } img && Uri.TryCreate(baseUri, img, out var u) && u.Scheme is "http" or "https") image = u;
        return new LinkPreview(title, Meta("og:site_name"), image);
    }

    static string Decode(string s)
    {
        foreach (var (k, v) in new[] { ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ") })
            s = s.Replace(k, v);
        return s;
    }

    public static string Host(Uri u) => u.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? u.Host[4..] : u.Host;
}
