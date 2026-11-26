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
    /// <summary>hello / hello_ok (beta.6+): "sha_end" (SHA-256 may come in file_end), "folders". Absent = beta.5.</summary>
    [JsonPropertyName("caps")] public string[]? Caps { get; init; }
    /// <summary>file_begin and mkdir inside a folder: the folder item's id and the "/"-separated path inside it.</summary>
    [JsonPropertyName("folder")] public string? Folder { get; init; }
    [JsonPropertyName("path")] public string? RelPath { get; init; }
    /// <summary>folder_begin: how many files follow.</summary>
    [JsonPropertyName("count")] public int? Count { get; init; }
    /// <summary>"version" (encrypted, both ways, beta.6+): this side's version, and the newest version it knows of.</summary>
    [JsonPropertyName("version")] public string? Version { get; init; }
    [JsonPropertyName("latest_known")] public LatestKnownInfo? LatestKnown { get; init; }
    /// <summary>hello / hello_ok (beta.7+): this computer's device id.</summary>
    [JsonPropertyName("device")] public string? Device { get; init; }
    /// <summary>clip (beta.10, "clip" cap): a picture from the other computer's clipboard, PNG, base64.</summary>
    [JsonPropertyName("png")] public string? Png { get; init; }
    /// <summary>beta.10 ("resume" cap): file_begin with resume = true offers to continue an interrupted file; the
    /// receiver answers "resume" with the offset it already has (0 = from the start).</summary>
    [JsonPropertyName("resume")] public bool? Resume { get; init; }
    [JsonPropertyName("offset")] public long? Offset { get; init; }

    public sealed record LatestKnownInfo([property: JsonPropertyName("version")] string Version, [property: JsonPropertyName("url")] string Url);

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
    /// <summary>sha null = it comes in file_end (the peer has "sha_end").</summary>
    public static Frame FileBegin(string id, string name, long size, string? sha, string? folder = null, string? path = null) =>
        new() { Type = "file_begin", Id = id, Name = name, Size = size, Sha256 = sha, Folder = folder, RelPath = path };
    public static Frame FileEnd(string id, string? sha = null) => new() { Type = "file_end", Id = id, Sha256 = sha };
    public static Frame FolderBegin(string id, string name, int count, long size) => new() { Type = "folder_begin", Id = id, Name = name, Count = count, Size = size };
    public static Frame Mkdir(string folder, string path) => new() { Type = "mkdir", Folder = folder, RelPath = path };
    public static Frame FolderEnd(string id) => new() { Type = "folder_end", Id = id };
    /// <summary>The answer to a resumable file_begin: carry on from this byte.</summary>
    public static Frame ResumeAt(string id, long offset) => new() { Type = "resume", Id = id, Offset = offset };
    /// <summary>beta.10 ("cancel" cap): the sender stopped this file or folder; the receiver deletes what arrived.</summary>
    public static Frame Cancel(string id) => new() { Type = "cancel", Id = id };
    public static Frame VersionInfo(string own, LatestKnownInfo? latest) => new() { Type = "version", Version = own, LatestKnown = latest };
    public static Frame Ack(string id, bool ok, string? err = null) => new() { Type = "ack", Id = id, Ok = ok, Err = err };
    public static readonly Frame Beat = new() { Type = "beat" };
    /// <summary>beta.10 ("clip" cap): the sender's clipboard changed. Text or a PNG; may come between file chunks like ack.</summary>
    public static Frame Clip(ClipContent c) => new()
    {
        Type = "clip", Id = Guid.NewGuid().ToString(),
        Text = c is ClipContent.TextClip t ? t.Text : null,
        Png = c is ClipContent.PngClip p ? Convert.ToBase64String(p.Data) : null,
    };

    [JsonIgnore] public string Json => JsonSerializer.Serialize(this, Opts);

    public static Frame? Decode(string s)
    {
        try { return JsonSerializer.Deserialize<Frame>(s, Opts); } catch (JsonException) { return null; }
    }
}
