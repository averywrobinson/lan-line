using System.Text.Json;
using System.Text.Json.Serialization;

namespace LanLine.Core;

/// <summary>One JSON control frame (see PROTOCOL.md). Null fields are left out.</summary>
public sealed record Frame
{
    [JsonPropertyName("type")] public string Type { get; init; } = "";
    [JsonPropertyName("v")] public int? V { get; init; }
    [JsonPropertyName("token")] public string? Token { get; init; }
    [JsonPropertyName("name")] public string? Name { get; init; }
    [JsonPropertyName("id")] public string? Id { get; init; }
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("size")] public long? Size { get; init; }
    [JsonPropertyName("sha256")] public string? Sha256 { get; init; }
    [JsonPropertyName("ok")] public bool? Ok { get; init; }
    [JsonPropertyName("err")] public string? Err { get; init; }
    /// <summary>In hello_ok right after pairing: the long-term secret that replaces the short pairing code.</summary>
    [JsonPropertyName("rekey")] public string? Rekey { get; init; }
    /// <summary>In hello_ok: the listener's own addresses (LAN, Tailscale…), so the dialer has fallbacks.</summary>
    [JsonPropertyName("addrs")] public string[]? Addrs { get; init; }

    public const int ProtocolVersion = 1;
    static readonly JsonSerializerOptions Opts = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    /// <summary>Rekey = "?" in a hello says "I can take a new long-term secret" (0.9.0-beta.2 and later).</summary>
    public static Frame Hello(string token, string name) => new() { Type = "hello", V = ProtocolVersion, Token = token, Name = name, Rekey = "?" };
    public static Frame HelloOk(string name, string? rekey = null, string[]? addrs = null) => new() { Type = "hello_ok", Name = name, Rekey = rekey, Addrs = addrs };
    public static Frame TextItem(string id, string text) => new() { Type = "text", Id = id, Text = text };
    public static Frame FileBegin(string id, string name, long size, string sha) => new() { Type = "file_begin", Id = id, Name = name, Size = size, Sha256 = sha };
    public static Frame FileEnd(string id) => new() { Type = "file_end", Id = id };
    public static Frame Ack(string id, bool ok, string? err = null) => new() { Type = "ack", Id = id, Ok = ok, Err = err };
    public static readonly Frame Beat = new() { Type = "beat" };

    [JsonIgnore] public string Json => JsonSerializer.Serialize(this, Opts);

    public static Frame? Decode(string s)
    {
        try { return JsonSerializer.Deserialize<Frame>(s, Opts); } catch (JsonException) { return null; }
    }
}
