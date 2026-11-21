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
    /// <summary>v1 hello_ok only (v2 sends the long-term secret in an encrypted "rekey" frame's token).</summary>
    [JsonPropertyName("rekey")] public string? Rekey { get; init; }
    /// <summary>In an encrypted "addrs" frame: the listener's own addresses, the dialer's fallbacks.</summary>
    [JsonPropertyName("addrs")] public string[]? Addrs { get; init; }
    /// <summary>v2 handshake (ENCRYPTION.md): 32 random bytes, the ephemeral P-256 key (X9.63), the HMAC; all base64.</summary>
    [JsonPropertyName("nonce")] public string? Nonce { get; init; }
    [JsonPropertyName("epk")] public string? Epk { get; init; }
    [JsonPropertyName("mac")] public string? Mac { get; init; }

    public const int ProtocolVersion = LL2.Version;
    static readonly JsonSerializerOptions Opts = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    /// <summary>A 0.9.0-beta.1…beta.4 (protocol v1) hello, with the secret in the clear. Only tests send it now.</summary>
    public static Frame LegacyHello(string token, string name) => new() { Type = "hello", V = 1, Token = token, Name = name, Rekey = "?" };
    /// <summary>Sent in the clear to a v1 peer before closing, so it can say "update".</summary>
    public static readonly Frame Upgrade = new() { Type = "error", V = ProtocolVersion, Err = "upgrade" };
    /// <summary>Sent in the clear before closing on a hello whose MAC matches no secret.</summary>
    public static readonly Frame Refused = new() { Type = "error", V = ProtocolVersion, Err = "auth" };
    /// <summary>Encrypted, listener → dialer: the long-term secret that replaces the pairing code.</summary>
    public static Frame RekeyTo(string token) => new() { Type = "rekey", Token = token };
    /// <summary>Encrypted, listener → dialer: the listener's own addresses.</summary>
    public static Frame Addresses(string[] a) => new() { Type = "addrs", Addrs = a };
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
