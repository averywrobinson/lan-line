using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace LanLine.Core;

/// <summary>One-click updates (beta.10), the same rules as the Mac's SignedUpdate.swift. update.json is
/// {"payload": base64 JSON, "sig": base64 P-256 ECDSA (r||s) over the payload bytes}; it is accepted only when the
/// signature verifies with the built-in key, the version is newer and the URL is Lan-Line's own GitHub release
/// download. The downloaded file must then match the size and SHA-256 exactly.</summary>
public static class SignedUpdate
{
    public const string PublicKeyBase64 = "q2SRNVgYuzy0KDhRFFkP24vfKIMkSm8sRvuevCsQajMJj7WBFftW8qqfmFbvIZ76mOoGX6CigiUGzlIuBQOUMg==";
    public const string ManifestUrl = "https://averywrobinson.com/lan-line/update.json";
    const string DownloadPrefix = "https://github.com/averywrobinson/lan-line/releases/download/";
    const string FileChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-";

    public sealed record Asset(string Url, long Size, string Sha256);
    public sealed record Offer(LanLineVersion Version, Asset Asset, string? NotesUrl);
    public enum Platform { Mac, Windows }

    public static bool IsAllowedDownload(string s, LanLineVersion version)
    {
        var prefix = $"{DownloadPrefix}v{version}/";
        if (s.Length > 300 || !s.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var file = s[prefix.Length..];
        return file.Length > 0 && file.All(c => FileChars.Contains(c)) && !file.StartsWith('.');
    }

    public static Offer? Verify(byte[] data, LanLineVersion current, Platform platform, string key = PublicKeyBase64)
    {
        if (data.Length > 64 * 1024) return null;
        try
        {
            using var env = JsonDocument.Parse(data);
            var payload = Convert.FromBase64String(env.RootElement.GetProperty("payload").GetString()!);
            var sig = Convert.FromBase64String(env.RootElement.GetProperty("sig").GetString()!);
            var k = Convert.FromBase64String(key);
            if (k.Length != 64 || sig.Length != 64) return null;
            using var ec = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = k[..32], Y = k[32..] } });
            if (!ec.VerifyData(payload, sig, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)) return null;
            using var p = JsonDocument.Parse(payload);
            var r = p.RootElement;
            if (LanLineVersion.Parse(r.GetProperty("version").GetString()) is not { } v || !(v > current)) return null;
            if (!r.TryGetProperty(platform == Platform.Mac ? "mac" : "windows", out var a) || a.ValueKind != JsonValueKind.Object) return null;
            var asset = new Asset(a.GetProperty("url").GetString()!, a.GetProperty("size").GetInt64(), a.GetProperty("sha256").GetString()!);
            if (!IsAllowedDownload(asset.Url, v) || asset.Size <= 0 || asset.Size > 1_000_000_000
                || asset.Sha256.Length != 64 || !asset.Sha256.All(c => "0123456789abcdef".Contains(c))) return null;
            string? notes = r.TryGetProperty("notes_url", out var n) && n.ValueKind == JsonValueKind.String && Updates.IsAllowedUrl(n.GetString()) ? n.GetString() : null;
            return new Offer(v, asset, notes);
        }
        catch (Exception e) when (e is JsonException or FormatException or KeyNotFoundException or InvalidOperationException or CryptographicException) { return null; }
    }

    public static bool Matches(string file, Asset a)
    {
        try
        {
            var fi = new FileInfo(file);
            if (!fi.Exists || fi.Length != a.Size) return false;
            using var s = File.OpenRead(file);
            return Convert.ToHexStringLower(SHA256.HashData(s)) == a.Sha256;
        }
        catch (IOException) { return false; }
    }

    static HttpClient Client(string current, bool redirects, TimeSpan timeout)
    {
        var h = new HttpClient(new HttpClientHandler { UseCookies = false, AllowAutoRedirect = redirects, MaxAutomaticRedirections = 5 }) { Timeout = timeout };
        h.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Lan-Line", current));
        h.DefaultRequestHeaders.CacheControl = new CacheControlHeaderValue { NoCache = true };
        return h;
    }

    public static async Task<Offer?> FetchOffer(string current, Platform platform, string url = ManifestUrl, string key = PublicKeyBase64)
    {
        if (LanLineVersion.Parse(current) is not { } own) return null;
        try
        {
            using var h = Client(current, false, TimeSpan.FromSeconds(10));
            using var resp = await h.GetAsync(url).ConfigureAwait(false);
            if (resp.StatusCode != System.Net.HttpStatusCode.OK) return null;
            var body = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            return Verify(body, own, platform, key);
        }
        catch (Exception) { return null; }
    }

    /// <summary>Download into dir and check it. Returns the file path, or throws UpdateException with the reason.
    /// GitHub release downloads redirect to its file host; the size and hash check is what makes that safe.</summary>
    public static async Task<string> Download(Offer o, string current, string dir, Action<double>? progress = null)
    {
        Directory.CreateDirectory(dir);
        var dest = Path.Combine(dir, o.Asset.Url[(o.Asset.Url.LastIndexOf('/') + 1)..]);
        if (Matches(dest, o.Asset)) return dest;
        var tmp = dest + ".part";
        try
        {
            using var h = Client(current, true, TimeSpan.FromMinutes(30));
            using var resp = await h.GetAsync(o.Asset.Url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            if (resp.StatusCode != System.Net.HttpStatusCode.OK) throw new UpdateException("Couldn't download the update (the server said no).");
            if (resp.RequestMessage?.RequestUri?.Scheme is { } sch && sch != "https" && !o.Asset.Url.StartsWith("http://127.0.0.1", StringComparison.Ordinal))
                throw new UpdateException("Couldn't download the update (it was redirected off HTTPS).");
            await using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
            await using (var f = File.Create(tmp))
            {
                var buf = new byte[1 << 20]; long got = 0; int n;
                while ((n = await src.ReadAsync(buf).ConfigureAwait(false)) > 0)
                {
                    got += n;
                    if (got > o.Asset.Size) throw new UpdateException(Mismatch);
                    await f.WriteAsync(buf.AsMemory(0, n)).ConfigureAwait(false);
                    progress?.Invoke((double)got / o.Asset.Size);
                }
            }
            File.Move(tmp, dest, overwrite: true);
        }
        catch (UpdateException) { TryDelete(tmp); throw; }
        catch (Exception e) { TryDelete(tmp); throw new UpdateException($"Couldn't download the update ({e.Message})."); }
        if (!Matches(dest, o.Asset)) { TryDelete(dest); throw new UpdateException(Mismatch); }
        return dest;
    }

    public const string Mismatch = "The download didn't match the signed update, so it wasn't used.";
    static void TryDelete(string p) { try { File.Delete(p); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
}

public sealed class UpdateException(string message) : Exception(message);
