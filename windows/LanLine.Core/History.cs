using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LanLine.Core;

/// <summary>One finished item in this computer's history (beta.10). Kept in history.jsonl next to the settings
/// (one JSON object per line), never sent anywhere. The same fields as HistoryEntry on the Mac.</summary>
public sealed record HistoryEntry
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("incoming")] public bool Incoming { get; init; }
    /// <summary>"text", "file" or "folder".</summary>
    [JsonPropertyName("kind")] public string Kind { get; init; } = "text";
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("name")] public string? Name { get; init; }
    [JsonPropertyName("size")] public long? Size { get; init; }
    [JsonPropertyName("path")] public string? Path { get; init; }
    [JsonPropertyName("count")] public int? Count { get; init; }
    [JsonPropertyName("at")] public DateTime At { get; init; }
    /// <summary>The other computer's name (from / to); "everyone" for an item sent to several.</summary>
    [JsonPropertyName("who")] public string? Who { get; init; }
    /// <summary>"received", "delivered", "failed" or "cancelled".</summary>
    [JsonPropertyName("state")] public string State { get; init; } = "received";
    [JsonPropertyName("error")] public string? Error { get; init; }
}

public enum HistoryFilter { All, Text, Pictures, Files, Links }

public static class History
{
    public const int Cap = 1000;
    public const string FileName = "history.jsonl";
    public const int MaxText = 20_000;

    static readonly JsonSerializerOptions Opts = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string Title(HistoryFilter f) => f switch
    {
        HistoryFilter.Text => "Text", HistoryFilter.Pictures => "Pictures", HistoryFilter.Files => "Files", HistoryFilter.Links => "Links", _ => "All",
    };

    /// <summary>Oldest first, one per id (the last line wins), at most Cap. Unreadable lines are skipped.</summary>
    public static List<HistoryEntry> Load(string path)
    {
        if (!File.Exists(path)) return [];
        var byId = new Dictionary<string, HistoryEntry>();
        var order = new List<string>();
        foreach (var line in File.ReadLines(path))
        {
            if (line.Length == 0) continue;
            HistoryEntry? e;
            try { e = JsonSerializer.Deserialize<HistoryEntry>(line, Opts); } catch (Exception) { continue; }
            if (e == null || string.IsNullOrEmpty(e.Id)) continue;
            if (!byId.ContainsKey(e.Id)) order.Add(e.Id);
            byId[e.Id] = e;
        }
        var all = order.Select(id => byId[id]).OrderBy(e => e.At).ToList();
        return all.Count > Cap ? all[^Cap..] : all;
    }

    public static void Append(HistoryEntry e, string path)
    {
        if (e.Text is { Length: > MaxText } t) e = e with { Text = t[..MaxText] };
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        File.AppendAllText(path, JsonSerializer.Serialize(e, Opts) + "\n", new UTF8Encoding(false));
    }

    public static void Compact(IEnumerable<HistoryEntry> entries, string path)
    {
        var list = entries.ToList();
        if (list.Count > Cap) list = list[^Cap..];
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", string.Concat(list.Select(e => JsonSerializer.Serialize(e, Opts) + "\n")), new UTF8Encoding(false));
        File.Move(path + ".tmp", path, overwrite: true);
    }

    public static void Clear(string path) { try { File.Delete(path); } catch (Exception) { } }

    // ---------- search

    static readonly HashSet<string> Pictures = new(StringComparer.OrdinalIgnoreCase) { "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp" };
    static readonly Regex LinkRx = new(@"(?i)\bhttps?://\S+|\bwww\.[a-z0-9-]+\.[a-z]{2,}\S*", RegexOptions.Compiled);

    public static bool IsPicture(HistoryEntry e) => e.Kind == "file" && Pictures.Contains(System.IO.Path.GetExtension(e.Name ?? "").TrimStart('.'));
    public static bool IsLink(HistoryEntry e) => e.Kind == "text" && e.Text is { } t && LinkRx.IsMatch(t);

    /// <summary>Lower case, accents removed: "Résumé" → "resume".</summary>
    public static string Fold(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s.Normalize(NormalizationForm.FormKD))
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    /// <summary>Every word of the query must appear in the text, file name or computer name (any order).</summary>
    public static bool Matches(HistoryEntry e, string query, HistoryFilter filter)
    {
        var ok = filter switch
        {
            HistoryFilter.Text => e.Kind == "text",
            HistoryFilter.Pictures => IsPicture(e),
            HistoryFilter.Files => e.Kind is "file" or "folder",
            HistoryFilter.Links => IsLink(e),
            _ => true,
        };
        if (!ok) return false;
        var words = Fold(query).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return true;
        var hay = Fold(string.Join(" ", new[] { e.Text, e.Name, e.Who }.Where(x => x != null)));
        return words.All(hay.Contains);
    }
}
