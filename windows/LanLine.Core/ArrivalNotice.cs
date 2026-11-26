using System.Text.RegularExpressions;

namespace LanLine.Core;

public enum NoticeAction { Show, Copy, Open, Reveal }

/// <summary>
/// What a system notification about arrived items says (beta.10). Pure, so the Windows and Mac apps word it the same
/// way and the tests pin it ("arrival notices" here, <c>ArrivalNoticeTests</c> on the Mac). The app decides when to
/// post (only while Lan-Line isn't the window in use) and does the posting.
/// </summary>
public sealed record ArrivalNotice(string Title, string Body, NoticeAction[] Actions, string? ItemId = null, string? ImagePath = null)
{
    public bool Equals(ArrivalNotice? o) => o is not null && Title == o.Title && Body == o.Body && Actions.SequenceEqual(o.Actions)
                                             && ItemId == o.ItemId && ImagePath == o.ImagePath;
    public override int GetHashCode() => HashCode.Combine(Title, Body, ItemId, ImagePath);
}

public static class ArrivalNotices
{
    public static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
        { "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp" };
    /// <summary>Longest text preview, in characters (an ellipsis is added when cut).</summary>
    public const int MaxPreview = 160;
    /// <summary>Arrivals this close together become one notification.</summary>
    public static readonly TimeSpan Coalesce = TimeSpan.FromSeconds(0.8);

    /// <summary>One notification for everything that arrived in one short burst (From = the sender's name).</summary>
    public static ArrivalNotice? Make(IReadOnlyList<(string From, Item Item)> arrivals)
    {
        if (arrivals.Count == 0) return null;
        if (arrivals.Count == 1) return Single(arrivals[0].From, arrivals[0].Item);
        var senders = arrivals.Select(a => a.From).Distinct().ToList();
        int files = arrivals.Count(a => a.Item.IsFile && !a.Item.IsFolder), folders = arrivals.Count(a => a.Item.IsFolder),
            texts = arrivals.Count(a => !a.Item.IsFile);
        var parts = new List<string>();
        if (files > 0) parts.Add(Count(files, "file"));
        if (folders > 0) parts.Add(Count(folders, "folder"));
        if (texts > 0) parts.Add(Count(texts, "message"));
        var what = List(parts);
        return senders.Count == 1
            ? new ArrivalNotice(senders[0], $"Sent you {what}", [])
            : new ArrivalNotice("Lan-Line", $"{char.ToUpperInvariant(what[0])}{what[1..]} from {List(senders)}", []);
    }

    /// <summary>An incoming item that could not be saved.</summary>
    public static ArrivalNotice Failed(string from, string name, string reason) => new($"Couldn't receive {name}", $"From {from}: {reason}", []);

    static ArrivalNotice Single(string from, Item item)
    {
        if (!item.IsFile) return new ArrivalNotice(from, Preview(item.Text ?? ""), [NoticeAction.Copy], item.Id);
        var name = item.FileName ?? "file";
        if (item.IsFolder)
            return new ArrivalNotice(from, $"{name} · {Count(item.Count ?? 0, "file")}, {Cleanup.FormatBytes(item.Size)}", [NoticeAction.Open, NoticeAction.Reveal], item.Id);
        var ext = Path.GetExtension(name).TrimStart('.');
        return new ArrivalNotice(from, $"{name} · {Cleanup.FormatBytes(item.Size)}", [NoticeAction.Open, NoticeAction.Reveal], item.Id,
                                 ImageExtensions.Contains(ext) ? item.Path : null);
    }

    /// <summary>Whitespace runs (newlines included) become one space; long texts are cut at a word with "…".</summary>
    public static string Preview(string text)
    {
        var flat = Regex.Replace(text, @"\s+", " ").Trim();
        if (flat.Length == 0) return "(empty message)";
        if (flat.Length <= MaxPreview) return flat;
        var cut = flat[..MaxPreview];
        var space = cut.LastIndexOf(' ');
        if (space >= MaxPreview * 2 / 3) cut = cut[..space];
        return cut + "…";
    }

    static string Count(int n, string noun) => $"{n} {noun}{(n == 1 ? "" : "s")}";

    /// <summary>"a", "a and b", "a, b and c".</summary>
    static string List(IReadOnlyList<string> p) => p.Count switch
    {
        0 => "",
        1 => p[0],
        _ => string.Join(", ", p.Take(p.Count - 1)) + " and " + p[^1],
    };

    // ---------- the links a Windows toast opens (lanline://notify?a=copy&id=…)

    public const string Scheme = "lanline";

    public static string Link(NoticeAction a, string? id) =>
        $"{Scheme}://notify?a={a.ToString().ToLowerInvariant()}" + (id == null ? "" : "&id=" + Uri.EscapeDataString(id));

    /// <summary>A toast's link back to (action, item id); null for anything else. Strict: only our own shape.</summary>
    public static (NoticeAction Action, string? Id)? ParseLink(string? url)
    {
        if (url == null || url.Length > 300 || !Uri.TryCreate(url, UriKind.Absolute, out var u)) return null;
        if (!u.Scheme.Equals(Scheme, StringComparison.OrdinalIgnoreCase) || !u.Host.Equals("notify", StringComparison.OrdinalIgnoreCase)) return null;
        string? a = null, id = null;
        foreach (var kv in u.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var i = kv.IndexOf('=');
            if (i <= 0) continue;
            var v = Uri.UnescapeDataString(kv[(i + 1)..]);
            if (kv[..i] == "a") a = v; else if (kv[..i] == "id") id = v;
        }
        if (id != null && (id.Length == 0 || id.Length > 100 || id.Any(c => char.IsControl(c)))) return null;
        NoticeAction? act = a switch { "show" => NoticeAction.Show, "copy" => NoticeAction.Copy, "open" => NoticeAction.Open, "reveal" => NoticeAction.Reveal, _ => null };
        if (act is not { } x || (x != NoticeAction.Show && id == null)) return null;
        return (x, id);
    }
}

/// <summary>The Windows toast XML for a notice (beta.10). Every click is a lanline:// link that a second Lan-Line.exe
/// hands to the running window over the stage pipe, so buttons work for an unpackaged app without a COM server.</summary>
public static class ToastXml
{
    /// <summary>Text as XML 1.0 allows it: control characters (an ESC from copied terminal output, a NUL) and lone
    /// surrogates become spaces. One such character would make Windows refuse the whole notification.</summary>
    public static string XmlSafe(string s)
    {
        System.Text.StringBuilder? sb = null;
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            var ok = c is '\t' or '\n' or '\r' || (c >= 0x20 && c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD);
            var pair = !ok && char.IsHighSurrogate(c) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]);
            if (ok || pair)
            {
                sb?.Append(c);
                if (pair) { sb?.Append(s[i + 1]); i++; }
                continue;
            }
            sb ??= new System.Text.StringBuilder(s, 0, i, s.Length);
            sb.Append(' ');
        }
        return sb?.ToString() ?? s;
    }

    /// <summary>Pictures bigger than this are left out of the toast (Windows won't show them).</summary>
    public const long MaxImageBytes = 3_000_000;

    public static string Build(ArrivalNotice n, Func<string, long>? sizeOf = null)
    {
        sizeOf ??= p => new FileInfo(p).Length;
        static string E(string s) => System.Security.SecurityElement.Escape(XmlSafe(s)) ?? "";
        var sb = new System.Text.StringBuilder();
        sb.Append($"<toast launch=\"{E(ArrivalNotices.Link(NoticeAction.Show, n.ItemId))}\" activationType=\"protocol\">");
        sb.Append("<visual><binding template=\"ToastGeneric\">");
        sb.Append($"<text hint-maxLines=\"1\">{E(n.Title)}</text><text>{E(n.Body)}</text>");
        if (n.ImagePath is { } img)
        {
            long size;
            try { size = sizeOf(img); } catch (Exception) { size = -1; }
            if (size > 0 && size <= MaxImageBytes) sb.Append($"<image src=\"{E(new Uri(img).AbsoluteUri)}\"/>");
        }
        sb.Append("</binding></visual>");
        if (n.Actions.Length > 0)
        {
            sb.Append("<actions>");
            foreach (var a in n.Actions)
            {
                var label = a switch { NoticeAction.Copy => "Copy", NoticeAction.Open => "Open", NoticeAction.Reveal => "Show in folder", _ => "Show" };
                sb.Append($"<action content=\"{label}\" activationType=\"protocol\" arguments=\"{E(ArrivalNotices.Link(a, n.ItemId))}\"/>");
            }
            sb.Append("</actions>");
        }
        sb.Append("</toast>");
        return sb.ToString();
    }
}
