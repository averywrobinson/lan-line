using System.Net.Http.Headers;
using System.Text.Json;

namespace LanLine.Core;

/// <summary>A Lan-Line version: MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N, parsed strictly (no "v", no spaces,
/// no leading zeros, at most 6 digits per number). A release sorts after every beta of the same number.</summary>
public sealed record LanLineVersion(int Major, int Minor, int Patch, int? Beta) : IComparable<LanLineVersion>
{
    public static LanLineVersion? Parse(string? s)
    {
        if (s == null || s.Length > 32 || s.Any(c => c > 127)) return null;
        string main = s; string? b = null;
        var dash = s.IndexOf('-');
        if (dash >= 0)
        {
            main = s[..dash];
            var rest = s[(dash + 1)..];
            if (!rest.StartsWith("beta.", StringComparison.Ordinal)) return null;
            b = rest[5..];
        }
        static int? Num(string t) =>
            t.Length is > 0 and <= 6 && t.All(c => c is >= '0' and <= '9') && (t == "0" || t[0] != '0') ? int.Parse(t) : null;
        var parts = main.Split('.');
        if (parts.Length != 3 || Num(parts[0]) is not { } x || Num(parts[1]) is not { } y || Num(parts[2]) is not { } z) return null;
        int? beta = null;
        if (b != null) { if (Num(b) is not { } n) return null; beta = n; }
        return new LanLineVersion(x, y, z, beta);
    }

    public override string ToString() => $"{Major}.{Minor}.{Patch}" + (Beta is { } b ? $"-beta.{b}" : "");

    public int CompareTo(LanLineVersion? o)
    {
        if (o is null) return 1;
        var c = (Major, Minor, Patch).CompareTo((o.Major, o.Minor, o.Patch));
        if (c != 0) return c;
        return (Beta, o.Beta) switch
        {
            (int x, int y) => x.CompareTo(y),
            (int, null) => -1,      // a beta comes before its release
            (null, int) => 1,
            _ => 0,
        };
    }
    public static bool operator >(LanLineVersion a, LanLineVersion b) => a.CompareTo(b) > 0;
    public static bool operator <(LanLineVersion a, LanLineVersion b) => a.CompareTo(b) < 0;
    public static bool operator >=(LanLineVersion a, LanLineVersion b) => a.CompareTo(b) >= 0;
    public static bool operator <=(LanLineVersion a, LanLineVersion b) => a.CompareTo(b) <= 0;
}

/// <summary>Update notices. Lan-Line never downloads or installs anything: it only shows a link to the release page.
/// The only network call is FetchLatest, and only when the user asks (or turned on the daily check).</summary>
public static class Updates
{
    public const string VersionUrl = "https://averywrobinson.com/lan-line/version.json";
    static readonly string[] AllowedPrefixes = ["https://averywrobinson.com/lan-line/", "https://github.com/averywrobinson/lan-line/"];
    const string UrlChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-~/#";

    public sealed record Available(LanLineVersion Version, string Url);

    public enum Outcome { UpToDate, Available, Failed }
    public sealed record CheckResult(Outcome Kind, LanLineVersion? Version = null, Available? Found = null)
    {
        public static readonly CheckResult Failed = new(Outcome.Failed);
    }

    /// <summary>Only Lan-Line's own pages, so a peer or a tampered file can't make the window show an arbitrary link.</summary>
    public static bool IsAllowedUrl(string? s)
    {
        if (s == null || s.Length > 300) return false;
        var prefix = AllowedPrefixes.FirstOrDefault(p => s.StartsWith(p, StringComparison.Ordinal));
        if (prefix == null) return false;
        var rest = s[prefix.Length..];
        return rest.All(c => UrlChars.Contains(c)) && !rest.Contains("..") && !rest.Contains("//") && !rest.StartsWith('/');
    }

    public static string ReleasePage(LanLineVersion v) => $"https://github.com/averywrobinson/lan-line/releases/tag/v{v}";

    /// <summary>A version.json body → what it announces, or null if anything about it is off.</summary>
    public static Available? Parse(byte[] d)
    {
        if (d.Length > 64 * 1024) return null;
        try
        {
            using var doc = JsonDocument.Parse(d);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object || !r.TryGetProperty("version", out var v) || !r.TryGetProperty("url", out var u)
                || v.ValueKind != JsonValueKind.String || u.ValueKind != JsonValueKind.String) return null;
            return LanLineVersion.Parse(v.GetString()) is { } ver && IsAllowedUrl(u.GetString()) ? new Available(ver, u.GetString()!) : null;
        }
        catch (JsonException) { return null; }
    }

    /// <summary>Fetch version.json: one GET, no cookies, no query string, user agent "Lan-Line/&lt;version&gt;". Never throws.</summary>
    public static async Task<CheckResult> FetchLatest(string current, string url = VersionUrl)
    {
        if (LanLineVersion.Parse(current) is not { } own) return CheckResult.Failed;
        try
        {
            using var h = new HttpClient(new HttpClientHandler { UseCookies = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(10) };
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.UserAgent.Add(new ProductInfoHeaderValue("Lan-Line", current));
            req.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            using var resp = await h.SendAsync(req).ConfigureAwait(false);
            if (resp.StatusCode != System.Net.HttpStatusCode.OK) return CheckResult.Failed;
            var body = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            if (Parse(body) is not { } a) return CheckResult.Failed;
            return a.Version > own ? new CheckResult(Outcome.Available, a.Version, a) : new CheckResult(Outcome.UpToDate, own);
        }
        catch (Exception) { return CheckResult.Failed; }
    }

    /// <summary>What the window says after a check. Automatic checks stay quiet unless there is something new.</summary>
    public static string? Message(CheckResult r, bool manual) => r.Kind switch
    {
        Outcome.Available => $"Lan-Line {r.Found!.Version} is available",
        Outcome.UpToDate => manual ? $"Lan-Line {r.Version} is up to date" : null,
        _ => manual ? "Couldn't check for updates. Try again later." : null,
    };

    /// <summary>The daily check runs only if the user turned it on, at most once a day.</summary>
    public static bool DueForAutoCheck(StorageSettings s, DateTime nowUtc) =>
        s.AutoUpdateCheck == true && (s.LastUpdateCheck is not { } last || nowUtc - last >= TimeSpan.FromHours(24));
}
