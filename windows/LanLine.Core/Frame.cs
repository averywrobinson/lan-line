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

    public const int ProtocolVersion = 1;
    static readonly JsonSerializerOptions Opts = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static Frame Hello(string token, string name) => new() { Type = "hello", V = ProtocolVersion, Token = token, Name = name };
    public static Frame HelloOk(string name) => new() { Type = "hello_ok", Name = name };
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
