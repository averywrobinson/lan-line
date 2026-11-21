using System.Text.Json;
using System.Text.Json.Serialization;

namespace LanLine.Core;

/// <summary>One paired computer, with its own secret. The computer that showed the code listens; the one that typed it dials.</summary>
public sealed record Partner
{
    /// <summary>The partner's device id (from its hello), or a placeholder until it is known.</summary>
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("secret")] public required string Secret { get; init; }
    /// <summary>"listen" or "connect".</summary>
    [JsonPropertyName("role")] public required string Role { get; init; }
    [JsonPropertyName("hosts")] public string[] Hosts { get; init; } = [];
    /// <summary>Port to dial; null = the usual 47830 (tests use other ports).</summary>
    [JsonPropertyName("port")] public int? Port { get; init; }
    [JsonPropertyName("paired_at")] public DateTime PairedAt { get; init; } = TruncatedNow();

    [JsonIgnore] public bool Connects => Role == "connect";
    static DateTime TruncatedNow() { var n = DateTime.UtcNow; return new DateTime(n.Ticks - n.Ticks % TimeSpan.TicksPerSecond, DateTimeKind.Utc); }

    public bool SameAs(Partner o) => Id == o.Id && Name == o.Name && Secret == o.Secret && Role == o.Role && Hosts.SequenceEqual(o.Hosts) && Port == o.Port && PairedAt == o.PairedAt;
}

public sealed class TooManyPartnersException() : Exception($"at most {DeviceConfig.MaxPartners} paired computers");

/// <summary>config.json from beta.7 on: this computer's id and a list of partners. A beta.6 file (one token) is read as one
/// partner; on save the first partner is also written to the old single-pairing fields, so going back to beta.6 keeps it.</summary>
public sealed class DeviceConfig
{
    public const int MaxPartners = 8;
    public string DeviceId { get; set; } = NewDeviceId();
    public int Port { get; set; } = 47830;
    public List<Partner> Peers { get; set; } = [];

    public static string NewDeviceId() => Secrets.NewToken()[..32];

    public Partner? Partner(string id) => Peers.FirstOrDefault(p => p.Id == id);

    /// <summary>Add a partner; one with the same id (paired again) is replaced in place.</summary>
    public void Add(Partner p)
    {
        var i = Peers.FindIndex(x => x.Id == p.Id);
        if (i >= 0) { Peers[i] = p; return; }
        if (Peers.Count >= MaxPartners) throw new TooManyPartnersException();
        Peers.Add(p);
    }

    /// <summary>Forget a partner: its secret is gone, so it can't connect any more.</summary>
    public void Forget(string id) => Peers.RemoveAll(p => p.Id == id);

    public void Rename(string id, string name)
    {
        var i = Peers.FindIndex(x => x.Id == id);
        if (i >= 0) Peers[i] = Peers[i] with { Name = name.Length > 64 ? name[..64] : name };
    }

    sealed class FileShape
    {
        [JsonPropertyName("device_id")] public string? DeviceId { get; set; }
        [JsonPropertyName("port")] public int? Port { get; set; }
        [JsonPropertyName("peers")] public List<Partner>? Peers { get; set; }
        [JsonPropertyName("token")] public string? Token { get; set; }
        [JsonPropertyName("hosts")] public string[]? Hosts { get; set; }
        [JsonPropertyName("role")] public string? Role { get; set; }
        [JsonPropertyName("peer")] public string? Peer { get; set; }
    }

    static readonly JsonSerializerOptions Opts = new() { WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    /// <summary>Read config.json, migrating a single beta.6 pairing. defaultRole is this platform's role when an old file has none ("connect" on Windows).</summary>
    public static DeviceConfig Load(string? path, string defaultRole)
    {
        var f = JsonSerializer.Deserialize<FileShape>(File.ReadAllText(path ?? LanLineConfig.DefaultPath), Opts) ?? new FileShape();
        var c = new DeviceConfig { DeviceId = f.DeviceId ?? NewDeviceId(), Port = f.Port ?? 47830, Peers = f.Peers ?? [] };
        if (f.Peers == null && !string.IsNullOrEmpty(f.Token))
            c.Peers = [new Partner { Id = "legacy-" + PairCode.PairId(f.Token), Name = f.Peer ?? "Partner", Secret = f.Token, Role = f.Role ?? defaultRole, Hosts = f.Hosts ?? [] }];
        return c;
    }

    /// <summary>Write atomically next to the target, then replace it. %APPDATA% is already private to the user.</summary>
    public void Save(string? path = null)
    {
        path ??= LanLineConfig.DefaultPath;
        var f = new FileShape { DeviceId = DeviceId, Port = Port, Peers = Peers };
        if (Peers.FirstOrDefault() is { } first) { f.Token = first.Secret; f.Hosts = first.Hosts; f.Role = first.Role; f.Peer = first.Name; }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(f, Opts));
        File.Move(path + ".tmp", path, overwrite: true);
    }
}
