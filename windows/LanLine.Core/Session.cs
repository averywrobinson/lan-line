using System.Net.WebSockets;
using System.Security.Cryptography;

namespace LanLine.Core;

public abstract record Role
{
    /// <summary>Listen for one peer (the Mac's role; on the PC only for tests and the reverse selftest).</summary>
    public sealed record Listen(int Port, string? BindHost = null) : Role;
    /// <summary>Dial the listener, trying each host in turn (the PC's normal role).</summary>
    public sealed record Dial(string[] Hosts, int Port) : Role;
}

public sealed class SessionConfig
{
    public required string Token { get; init; }
    public required string Name { get; init; }
    public required string DownloadDir { get; init; }
    public TimeSpan BeatInterval { get; init; } = TimeSpan.FromSeconds(15);
    public TimeSpan DeadAfter { get; init; } = TimeSpan.FromSeconds(45);
    public TimeSpan HelloTimeout { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan DialTimeout { get; init; } = TimeSpan.FromSeconds(4);
    public double[] Backoff { get; init; } = [1, 2, 4, 8, 10];
    public int ChunkSize { get; init; } = 256 * 1024;
    /// <summary>A sanity bound on the size field, not a practical limit: the real limit is free disk space.</summary>
    public long MaxFileSize { get; init; } = 1L << 40;
    /// <summary>Keep this much free on the receiving disk after a file lands.</summary>
    public long DiskReserve { get; init; } = 64L << 20;
    /// <summary>Tests: pretend the download disk has this many bytes free.</summary>
    public long? FreeSpaceOverride { get; init; }
    /// <summary>Listener, while pairing: answer the first good hello with a fresh 32-byte secret (rekey) and switch
    /// to it, so the short on-screen code is never the long-term secret. The code stays accepted until restart.</summary>
    public bool RekeyOnPair { get; init; }
    /// <summary>Listener: addresses to tell an authenticated dialer about (its fallbacks).</summary>
    public string[] Advertise { get; init; } = [];
    /// <summary>What this side tells its peer it can do (PROTOCOL.md "Capabilities"). Tests set [] to act like beta.5.</summary>
    public string[] Caps { get; init; } = ["sha_end", "folders"];
    /// <summary>This app's version ("0.9.0-beta.6"), told to the other computer so either can say "an update is available".</summary>
    public string AppVersion { get; init; } = "";
    /// <summary>The newest version this computer already knows of (saved by the app), passed on to the other computer.</summary>
    public Updates.Available? LatestKnown { get; init; }
    /// <summary>Liveness tick period; zero = no timer (tests call Tick themselves).</summary>
    public TimeSpan TickInterval { get; init; } = TimeSpan.FromSeconds(1);
}

public enum ItemStateKind { Waiting, Sending, Sent, Delivered, Failed, Received }

public sealed record ItemState(ItemStateKind Kind, double Progress = 0, string? Error = null)
{
    public static readonly ItemState Waiting = new(ItemStateKind.Waiting);
    public static readonly ItemState Sent = new(ItemStateKind.Sent);
    public static readonly ItemState Delivered = new(ItemStateKind.Delivered);
    public static readonly ItemState ReceivedState = new(ItemStateKind.Received);
}

/// <summary>A text (Text set), a file (FileName/Path set) or a folder (also Count: how many files inside).</summary>
public sealed record Item(string Id, bool Incoming, string? Text, string? FileName, long Size, string? Path, ItemState State, int? Count = null)
{
    public bool IsFile => Text == null;
    public bool IsFolder => Count != null;
}

/// <summary>One entry of an outgoing folder, in send order (a folder before what's inside it). File: FullPath set.</summary>
public sealed record FolderEntry(string RelPath, string? FullPath, long Size);

/// <summary>What Session.ScanFolder found; symlinks and junctions are never followed (Skipped).</summary>
public sealed record FolderScan(List<FolderEntry> Entries, int Count, long Size, int Skipped);

public abstract record SessionEvent
{
    public sealed record Listening(int Port) : SessionEvent;
    public sealed record Connected(string Peer) : SessionEvent;
    /// <summary>The pairing code was swapped for this long-term secret (both sides); save it in the config.</summary>
    public sealed record Rekeyed(string Token) : SessionEvent;
    /// <summary>Dialer: the listener's addresses (from hello_ok); keep them as fallback hosts.</summary>
    public sealed record PeerAddresses(string[] Addrs) : SessionEvent;
    /// <summary>A newer Lan-Line exists (from the other computer or an update check): show a link, nothing more.</summary>
    public sealed record UpdateAvailable(string Version, string Url) : SessionEvent;
    public sealed record Disconnected(string Reason) : SessionEvent;
    public sealed record Received(Item Item) : SessionEvent;
    public sealed record Outgoing(Item Item) : SessionEvent;
    public sealed record ReceiveFailed(string Name, string Reason) : SessionEvent;
    public sealed record Error(string Message) : SessionEvent;
    /// <summary>Diagnostics while not connected (which host is being dialed, why a dial failed).</summary>
    public sealed record Status(string Text) : SessionEvent;
}

/// <summary>
/// The one Lan-Line session object; the window, the headless modes and the tests all drive it.
/// All state lives on one SerialQueue thread, and the handler is called there too:
/// a UI must hop to its own thread in one place.
/// </summary>
public sealed class Session : IDisposable
{
    public Role Role { get; }
    public SessionConfig Config { get; }
    readonly SerialQueue _q = new("lan-line.session");
    readonly Action<SessionEvent> _handler;
    readonly Func<DateTime> _now;

    sealed class Out { public required Item Item; public string? Sha; public bool Hashing; public bool OnWire; public List<FolderEntry> Entries = []; }
    sealed class InFile
    {
        public required string Id, Name; public string? Sha; public long Size;
        public string? Folder, Dir; public bool Acked;
        public string? Part; public FileStream? Stream; public IncrementalHash Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public long Received; public string? Reject;
    }
    sealed class InFolder
    {
        public required string Id, Name; public int Count; public long Size;
        public string? Stage; public int Files; public long Bytes; public string? Reject; public bool Acked;
    }
    InFolder? _inFolder;
    HashSet<string> _peerCaps = [];
    string _peerName = "the other computer";
    Updates.Available? _latestKnown;

    string _token;            // current secret (starts as Config.Token)
    string? _oldToken;        // the pairing code, still accepted after a rekey until restart
    bool _rekeyOnPair;
    Listener? _listener;
    readonly Dictionary<Link, bool> _pending = [];
    Link? _link;
    bool _linkUp;
    Link? _dialing;
    DialerHandshake? _dialHs;   // our half of the v2 handshake on _dialing
    int _hostIndex, _attempt, _redialGen;
    Timer? _timer;
    bool _stopped;

    readonly List<Out> _out = [];
    bool _busy;
    FileSend? _fileSend;   // the file currently streaming out
    const int Window = 4;  // chunks in flight: keeps a LAN busy, memory stays Window × ChunkSize

    sealed class FileSend
    {
        public required string Id, ItemId; public required FileStream Fs; public long Size; public required Link Link;
        public IncrementalHash? Hasher;       // set when the SHA-256 goes in file_end
        public long Base, Total;              // progress across a folder
        public Action? Next;                  // inside a folder: what comes after this file
        public int InFlight; public long SentBytes; public bool Eof; public int LastStep = -1;
    }
    InFile? _in;
    readonly HashSet<string> _done = [];
    DateTime _lastHeard, _lastBeat;

    public Session(Role role, SessionConfig config, Action<SessionEvent> handler, Func<DateTime>? clock = null)
    {
        Role = role; Config = config; _handler = handler; _now = clock ?? (() => DateTime.UtcNow);
        _token = config.Token;
        _latestKnown = config.LatestKnown;
        // A short token is a pairing code from 0.9.0-beta.1: upgrade it on the next connection too.
        _rekeyOnPair = config.RekeyOnPair || (config.Token.Length < 32 && role is Role.Listen);
    }

    // ---------- public API (any thread) ----------

    public void Start() => _q.Post(StartOnQueue);

    public void Stop()
    {
        _q.Sync(() =>
        {
            _stopped = true;
            _timer?.Dispose(); _timer = null;
            _listener?.Stop(); _listener = null;
            foreach (var l in _pending.Keys.ToList()) l.Close("stopped");
            _pending.Clear();
            _dialing?.Close("stopped"); _dialing = null;
            _link?.Close("stopped");
            return 0;
        });
    }

    public void Dispose() { Stop(); _q.Dispose(); }

    public Item SendText(string text)
    {
        var item = new Item(Guid.NewGuid().ToString(), false, text, null, text.Length, null, ItemState.Waiting);
        _q.Post(() => Enqueue(new Out { Item = item, Sha = "" }));
        return item;
    }

    public Item SendFile(string path)
    {
        long size = -1;
        try { size = new FileInfo(path).Length; } catch (Exception) { }
        var item = new Item(Guid.NewGuid().ToString(), false, null, Path.GetFileName(path), size, path, ItemState.Waiting);
        _q.Post(() => Enqueue(new Out { Item = item }));   // hashed while it streams (or first, for a beta.5 peer)
        return item;
    }

    /// <summary>Send a whole folder as one item. Symlinks and junctions are left out (see ScanFolder).</summary>
    public Item SendFolder(string path)
    {
        var scan = ScanFolder(path);
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        var item = new Item(Guid.NewGuid().ToString(), false, null, name, scan.Size, path, ItemState.Waiting, scan.Count);
        _q.Post(() => Enqueue(new Out { Item = item, Sha = "", Entries = scan.Entries }));
        return item;
    }

    /// <summary>Walk a folder: every subfolder and file, parents first. Reparse points (symlinks, junctions) are never
    /// followed or sent, since one could point outside the folder; they are counted in Skipped.</summary>
    public static FolderScan ScanFolder(string root)
    {
        var entries = new List<FolderEntry>();
        int count = 0, skipped = 0; long size = 0;
        void Walk(DirectoryInfo dir, string rel)
        {
            FileSystemInfo[] items;
            try { items = dir.GetFileSystemInfos(); } catch (Exception) { return; }
            foreach (var fi in items.OrderBy(i => i.Name, StringComparer.Ordinal))
            {
                var r = rel.Length == 0 ? fi.Name : rel + "/" + fi.Name;
                if (fi.Attributes.HasFlag(FileAttributes.ReparsePoint)) { skipped++; continue; }
                if (fi is DirectoryInfo d) { entries.Add(new FolderEntry(r, null, 0)); Walk(d, r); }
                else if (fi is FileInfo f) { entries.Add(new FolderEntry(r, f.FullName, f.Length)); count++; size += f.Length; }
            }
        }
        Walk(new DirectoryInfo(root), "");
        return new FolderScan(entries, count, size, skipped);
    }

    public bool IsConnected => _q.Sync(() => _linkUp);

    /// <summary>An update check found this: remember it, show it if it's newer, and tell the other computer.</summary>
    public void NoteLatest(Updates.Available a) => _q.Post(() => Consider(a));

    Frame VersionFrame() => Frame.VersionInfo(Config.AppVersion, _latestKnown is { } k ? new Frame.LatestKnownInfo(k.Version.ToString(), k.Url) : null);

    /// <summary>Keep the newest version above our own; if it changed, say so and pass it on.</summary>
    void Consider(Updates.Available a)
    {
        if (LanLineVersion.Parse(Config.AppVersion) is not { } own || !(a.Version > own) || !Updates.IsAllowedUrl(a.Url)) return;
        if (_latestKnown is { } k && k.Version >= a.Version) return;
        _latestKnown = a;
        Emit(new SessionEvent.UpdateAvailable(a.Version.ToString(), a.Url));
        if (_linkUp && _link is { } l) l.SendText(VersionFrame().Json);
    }

    /// <summary>Liveness check; the timer calls it every TickInterval. Tests call it after moving the clock.</summary>
    public void Tick() => _q.Post(TickOnQueue);

    internal void DropLink() => _q.Post(() => _link?.Close("dropped"));

    // ---------- lifecycle ----------

    void Emit(SessionEvent e) => _handler(e);

    void StartOnQueue()
    {
        if (Config.TickInterval > TimeSpan.Zero)
            _timer = new Timer(_ => _q.Post(TickOnQueue), null, Config.TickInterval, Config.TickInterval);
        switch (Role)
        {
            case Role.Listen r:
                try
                {
                    _listener = new Listener(r.BindHost, r.Port, (ws, peer) => _q.Post(() => Accept(ws, peer)));
                    Emit(new SessionEvent.Listening(_listener.Port));
                }
                catch (Exception e) { Emit(new SessionEvent.Error($"listen failed: {e.Message}")); }
                break;
            case Role.Dial:
                DialNext();
                break;
        }
    }

    void Accept(WebSocket ws, string peer)
    {
        if (_stopped) { ws.Abort(); return; }
        var l = Link.Accepted(ws, peer, _q, _now(), OnLinkEvent);
        _pending[l] = true;
    }

    void DialNext()
    {
        if (_stopped || Role is not Role.Dial d || d.Hosts.Length == 0) return;
        var host = d.Hosts[_hostIndex % d.Hosts.Length];
        Emit(new SessionEvent.Status($"dialing {host}"));
        _dialing = Link.Dial(host, d.Port, Config.DialTimeout, _q, _now(), OnLinkEvent);
    }

    void ScheduleRedial(bool afterFailure)
    {
        if (_stopped || Role is not Role.Dial d) return;
        double delay = 0;
        if (afterFailure)
        {
            _hostIndex++;
            if (_hostIndex % Math.Max(d.Hosts.Length, 1) == 0)   // every host failed once: back off
            {
                delay = Config.Backoff[Math.Min(_attempt, Config.Backoff.Length - 1)];
                _attempt++;
            }
        }
        else
        {
            _hostIndex = 0;
            delay = Config.Backoff.Length > 0 ? Config.Backoff[0] : 1;
        }
        var gen = ++_redialGen;
        _q.PostAfter(TimeSpan.FromSeconds(delay), () => { if (gen == _redialGen && _dialing == null && !_linkUp) DialNext(); });
    }

    // ---------- link events ----------

    void OnLinkEvent(Link l, LinkEvent ev)
    {
        var isActive = ReferenceEquals(l, _link);
        switch (ev.Kind)
        {
            case LinkEventKind.Ready:
                if (ReferenceEquals(l, _dialing))
                {
                    _dialHs = new DialerHandshake(_token, Config.Name);
                    l.SendText((_dialHs.Hello with { Caps = Config.Caps }).Json);   // outside the MAC: stripping it only means beta.5 behaviour
                }
                break;
            case LinkEventKind.Closed:
                _pending.Remove(l);
                if (ReferenceEquals(l, _dialing))
                {
                    _dialing = null;
                    // A v1 listener (beta.4 or older) closes on a v2 hello without a word.
                    var reason = ev.Reason ?? "dial failed";
                    if (_dialHs != null && (reason == "closed by peer" || reason.StartsWith("receive:")))
                        reason = "Can't connect: update Lan-Line on the other computer too (it may run an older version).";
                    _dialHs = null;
                    Emit(new SessionEvent.Status(reason));
                    ScheduleRedial(afterFailure: true);
                }
                if (isActive) LinkDown(ev.Reason ?? "closed");
                break;
            case LinkEventKind.Text:
                if (isActive) { _lastHeard = _now(); HandleFrame(ev.Text!, l); }
                else if (_pending.ContainsKey(l)) HandleHello(ev.Text!, l);
                else if (ReferenceEquals(l, _dialing)) HandleHelloOk(ev.Text!, l);
                break;
            case LinkEventKind.Data:
                if (isActive) { _lastHeard = _now(); HandleChunk(ev.Data!); }
                else l.Close("binary before hello");
                break;
        }
    }

    void HandleHello(string s, Link l)
    {
        _pending.Remove(l);
        var f = Frame.Decode(s);
        if (f is not { Type: "hello" }) { l.Close("bad hello"); return; }
        if (f.V != LL2.Version)   // a beta.1…beta.4 peer: it sent the secret in the clear; tell it to update
        {
            Emit(new SessionEvent.Status("The other computer runs an older Lan-Line. Update it to connect."));
            var v = f.V ?? 0;
            l.SendText(Frame.Upgrade.Json, _ => l.Close($"peer speaks protocol v{v}"));
            return;
        }
        var secrets = _oldToken != null ? new[] { _token, _oldToken } : new[] { _token };
        if (ListenerHandshake.Respond(f, secrets, Config.Name) is not { } ans)
        {
            l.SendText(Frame.Refused.Json, _ => l.Close("bad hello"));
            return;
        }
        if (_link is { } old)   // a new authenticated peer replaces the old one
        {
            LinkDown("replaced by a new connection");
            old.Close("replaced");
        }
        string? rekey = null;
        var fresh = false;
        if (_rekeyOnPair)
        {
            _rekeyOnPair = false;
            rekey = Secrets.NewToken();
            fresh = true;
            _oldToken = _token;
            _token = rekey;
        }
        else if (ans.SecretIndex == 1) rekey = _token;   // the dialer still has the pairing code: it missed the swap
        _peerCaps = [.. f.Caps ?? []];
        l.SendText((ans.Ok with { Caps = Config.Caps }).Json);
        l.Secure = ans.Channel;   // everything after hello_ok is sealed
        if (rekey != null) l.SendText(Frame.RekeyTo(rekey).Json);
        if (Config.Advertise.Length > 0) l.SendText(Frame.Addresses(Config.Advertise).Json);
        if (fresh) Emit(new SessionEvent.Rekeyed(rekey!));
        BecomeUp(l, f.Name ?? l.Peer);
    }

    void HandleHelloOk(string s, Link l)
    {
        var f = Frame.Decode(s);
        if (f is { Type: "error" })
        {
            _dialHs = null;
            l.Close(f.Err switch
            {
                "upgrade" => "Can't connect: the other computer runs a newer Lan-Line. Update this one.",
                "auth" => "Refused: the other computer doesn't know this pairing. Pair again.",
                _ => $"Refused: {f.Err ?? "unknown error"}",
            });
            return;
        }
        if (f == null || _dialHs?.Finish(f) is not { } ch)
        {
            _dialHs = null;
            l.Close("Refused: the other computer's reply doesn't match this pairing.");
            return;
        }
        l.Secure = ch;
        _peerCaps = [.. f.Caps ?? []];
        _dialHs = null;
        _dialing = null;
        _attempt = 0;
        BecomeUp(l, f.Name ?? l.Peer);
    }

    static bool IsIPv4(string a) =>
        System.Net.IPAddress.TryParse(a, out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && a.Count(c => c == '.') == 3;

    void BecomeUp(Link l, string peer)
    {
        _link = l;
        _linkUp = true;
        _peerName = peer;
        _lastHeard = _lastBeat = _now();
        Emit(new SessionEvent.Connected(peer));
        if (Config.AppVersion.Length > 0) l.SendText(VersionFrame().Json);   // beta.5 ignores it
        Pump();
    }

    void LinkDown(string reason)
    {
        if (!_linkUp && _link == null) return;
        _link = null;
        _linkUp = false;
        _busy = false;
        if (_fileSend is { } fsend) { fsend.Fs.Dispose(); _fileSend = null; }
        AbortIncoming();   // a half-received file is thrown away; the sender resends it
        DropFolder();
        foreach (var o in _out.Where(o => o.OnWire))
        {
            o.OnWire = false;
            o.Item = o.Item with { State = ItemState.Waiting };
            Emit(new SessionEvent.Outgoing(o.Item));
        }
        Emit(new SessionEvent.Disconnected(reason));
        if (Role is Role.Dial) ScheduleRedial(afterFailure: false);
    }

    void TickOnQueue()
    {
        var t = _now();
        foreach (var l in _pending.Keys.Where(l => t - l.OpenedAt > Config.HelloTimeout).ToList())
        {
            _pending.Remove(l);
            l.Close($"no hello within {Config.HelloTimeout.TotalSeconds:0} s");
        }
        if (!_linkUp || _link is not { } link) return;
        if (t - _lastHeard > Config.DeadAfter)
        {
            link.Close($"dead link: nothing heard for {Config.DeadAfter.TotalSeconds:0} s");
            return;
        }
        if (t - _lastBeat >= Config.BeatInterval)
        {
            _lastBeat = t;
            link.SendText(Frame.Beat.Json);
        }
    }

    // ---------- incoming ----------

    void HandleFrame(string s, Link l)
    {
        var f = Frame.Decode(s);
        if (f == null) return;
        switch (f.Type)
        {
            case "text" when f.Id != null && f.Text != null:
                if (_done.Add(f.Id))
                    Emit(new SessionEvent.Received(new Item(f.Id, true, f.Text, null, f.Text.Length, null, ItemState.ReceivedState)));
                l.SendText(Frame.Ack(f.Id, true).Json);
                break;
            case "file_begin" when f.Id != null:
                AbortIncoming();
                if (f.Folder == null) DropFolder();
                BeginFile(f.Id, f.Name ?? "file", f.Size ?? -1, f.Sha256?.ToLowerInvariant(), f.Folder, f.RelPath, l);
                break;
            case "file_end" when f.Id != null && _in is { } file && file.Id == f.Id:
                _in = null;
                FinishFile(file, f.Sha256?.ToLowerInvariant(), l);
                break;
            case "folder_begin" when f.Id != null:
                AbortIncoming(); DropFolder();
                BeginFolder(f.Id, f.Name ?? "folder", f.Count ?? -1, f.Size ?? -1, l);
                break;
            case "mkdir" when _inFolder is { Reject: null, Stage: { } stage } d && d.Id == f.Folder:
                if (Names.SafePath(f.RelPath) is { } comps)
                {
                    var dir = Path.Combine([stage, .. comps]);
                    if (File.Exists(dir)) d.Reject = "bad folder entry";
                    else try { Directory.CreateDirectory(dir); } catch (Exception) { d.Reject = "cannot write"; }
                }
                else d.Reject = "bad path in folder";
                break;
            case "folder_end" when f.Id != null && _inFolder is { } fd && fd.Id == f.Id:
                AbortIncoming();
                _inFolder = null;
                FinishFolder(fd, l);
                break;
            case "rekey" when Role is Role.Dial && f.Token is { Length: 64 } r && r.All(Uri.IsHexDigit):
                if (r != _token) { _token = r; Emit(new SessionEvent.Rekeyed(r)); }
                break;
            case "addrs" when Role is Role.Dial:
                var addrs = (f.Addrs ?? []).Where(IsIPv4).Take(8).ToArray();
                if (addrs.Length > 0) Emit(new SessionEvent.PeerAddresses(addrs));
                break;
            case "version":   // the peer's version and the newest it knows of; strict parse, allowlisted links only
                if (LanLineVersion.Parse(f.Version) is { } pv) Consider(new Updates.Available(pv, Updates.ReleasePage(pv)));
                if (f.LatestKnown is { } lk && LanLineVersion.Parse(lk.Version) is { } kv && Updates.IsAllowedUrl(lk.Url)) Consider(new Updates.Available(kv, lk.Url));
                break;
            case "ack" when f.Id != null:
                var i = _out.FindIndex(o => o.Item.Id == f.Id);
                if (i < 0) return;
                var done = _out[i];
                _out.RemoveAt(i);
                var st = f.Ok == true ? ItemState.Delivered : new ItemState(ItemStateKind.Failed, Error: f.Err ?? "rejected");
                Emit(new SessionEvent.Outgoing(done.Item with { State = st }));
                if (_fileSend is { } fsend && fsend.ItemId == f.Id)   // refused while streaming (too big): stop now
                {
                    _fileSend = null;
                    fsend.Fs.Dispose();
                    _busy = false;
                    Pump();
                }
                break;
        }
    }

    long? FreeSpace()
    {
        if (Config.FreeSpaceOverride is { } o) return o;
        try { Directory.CreateDirectory(Config.DownloadDir); return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Config.DownloadDir))!).AvailableFreeSpace; }
        catch (Exception) { return null; }
    }

    static string Gb(long b) => b >= 1_000_000_000 ? $"{b / 1e9:0.#} GB" : b >= 1_000_000 ? $"{b / 1e6:0.#} MB" : $"{b / 1e3:0.#} KB";

    string? NoSpace(long size) =>
        FreeSpace() is { } free && size + Config.DiskReserve > free
            ? $"not enough disk space on {Config.Name} (needs {Gb(size)}, {Gb(Math.Max(free - Config.DiskReserve, 0))} free)" : null;

    /// <summary>A refusal the receiver can give at once, before any bytes: the sender stops and both windows say why.</summary>
    void RefuseNow(string id, string name, string reason, Link l)
    {
        l.SendText(Frame.Ack(id, false, reason).Json);
        Emit(new SessionEvent.ReceiveFailed(name, reason));
    }

    void BeginFile(string id, string raw, long size, string? sha, string? folder, string? path, Link l)
    {
        var name = Names.Sanitize(raw);
        var f = new InFile { Id = id, Name = name, Sha = sha, Size = size, Folder = folder };
        if (folder != null)   // a file inside the folder being received
        {
            if (_inFolder is not { Reject: null, Stage: { } stage } d || d.Id != folder) { f.Reject = "not in a folder"; _in = f; return; }
            d.Bytes += Math.Max(size, 0);
            if (size < 0 || d.Bytes > d.Size) d.Reject = "folder bigger than announced";
            else if (Names.SafePath(path) is { } comps) { f.Name = comps[^1]; f.Dir = Path.Combine([stage, .. comps[..^1]]); }
            else d.Reject = "bad path in folder";
            if (d.Reject != null) { f.Reject = d.Reject; _in = f; return; }
        }
        else if (size < 0 || size > Config.MaxFileSize) f.Reject = "too big or bad size";
        else if (NoSpace(size) is { } r) f.Reject = r;
        if (f.Reject == null && sha != null && (sha.Length != 64 || !sha.All(Uri.IsHexDigit))) f.Reject = "bad sha256";
        if (f.Reject == null)
        {
            try
            {
                var dir = f.Dir ?? Config.DownloadDir;
                Directory.CreateDirectory(dir);
                f.Part = Path.Combine(dir, $".{f.Name}.{Guid.NewGuid().ToString("N")[..8]}.part");
                f.Stream = new FileStream(f.Part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16);
            }
            catch (Exception e) { f.Reject = $"cannot write: {e.Message}"; }
        }
        if (f.Reject is { } why && folder == null) { RefuseNow(id, name, why, l); f.Acked = true; }   // the sender stops now
        _in = f;
    }

    void BeginFolder(string id, string raw, int count, long size, Link l)
    {
        var name = Names.Sanitize(raw);
        var d = new InFolder { Id = id, Name = name, Count = count, Size = size };
        if (count < 0 || count > 1_000_000 || size < 0 || size > Config.MaxFileSize) d.Reject = "too big or bad size";
        else if (NoSpace(size) is { } r) d.Reject = r;
        else
        {
            var stage = Path.Combine(Config.DownloadDir, $".{name}.{Guid.NewGuid().ToString("N")[..8]}.part");
            try { Directory.CreateDirectory(stage); d.Stage = stage; } catch (Exception) { d.Reject = "cannot write"; }
        }
        if (d.Reject is { } why) { RefuseNow(id, name, why, l); d.Acked = true; }
        _inFolder = d;
    }

    void DropFolder()
    {
        if (_inFolder?.Stage is { } st) try { Directory.Delete(st, true); } catch (Exception) { }
        _inFolder = null;
    }

    void FinishFolder(InFolder d, Link l)
    {
        if (d.Reject == null && d.Files != d.Count) d.Reject = "folder incomplete";
        if (d.Reject is { } why)
        {
            if (d.Stage != null) try { Directory.Delete(d.Stage, true); } catch (Exception) { }
            if (!d.Acked) RefuseNow(d.Id, d.Name, why, l);
            return;
        }
        if (d.Stage is not { } stage) return;
        if (_done.Contains(d.Id))
        {
            try { Directory.Delete(stage, true); } catch (Exception) { }
            l.SendText(Frame.Ack(d.Id, true).Json);
            return;
        }
        var dest = Names.Unique(d.Name, Config.DownloadDir);
        try { Directory.Move(stage, dest); }
        catch (Exception)
        {
            try { Directory.Delete(stage, true); } catch (Exception) { }
            RefuseNow(d.Id, d.Name, "save failed", l);
            return;
        }
        _done.Add(d.Id);
        l.SendText(Frame.Ack(d.Id, true).Json);
        Emit(new SessionEvent.Received(new Item(d.Id, true, null, Path.GetFileName(dest), d.Size, dest, ItemState.ReceivedState, d.Count)));
    }

    void HandleChunk(byte[] d)
    {
        if (_in is not { } f || f.Reject != null) return;
        f.Received += d.Length;
        if (f.Received > f.Size) { f.Reject = "size mismatch"; DropPart(f); return; }
        try { f.Stream!.Write(d); f.Hasher.AppendData(d); }
        catch (Exception e) { f.Reject = $"write failed: {e.Message}"; DropPart(f); }
    }

    static void DropPart(InFile f)
    {
        try { f.Stream?.Dispose(); } catch (Exception) { }
        f.Stream = null;
        if (f.Part != null) try { File.Delete(f.Part); } catch (Exception) { }
        f.Part = null;
    }

    void AbortIncoming()
    {
        if (_in is { } f) DropPart(f);
        _in = null;
    }

    void FinishFile(InFile f, string? endSha, Link l)
    {
        var reason = f.Reject;
        if (reason == null && f.Received != f.Size) reason = "size mismatch";
        var digest = Convert.ToHexStringLower(f.Hasher.GetHashAndReset());
        if (reason == null && digest != (f.Sha ?? endSha)) reason = "sha256 mismatch";
        try { f.Stream?.Dispose(); } catch (Exception) { }
        f.Stream = null;
        if (reason != null)
        {
            DropPart(f);
            if (f.Folder != null)   // the whole folder fails; folder_end answers
            {
                if (_inFolder is { Reject: null } d && d.Id == f.Folder) d.Reject = $"{f.Name}: {reason}";
                return;
            }
            if (!f.Acked)
            {
                l.SendText(Frame.Ack(f.Id, false, reason).Json);
                Emit(new SessionEvent.ReceiveFailed(f.Name, reason));
            }
            return;
        }
        if (f.Part is not { } part) return;
        if (f.Dir is { } fdir)   // inside a folder: put it in place, count it
        {
            try { File.Move(part, Names.Unique(f.Name, fdir)); if (_inFolder != null) _inFolder.Files++; }
            catch (Exception) { try { File.Delete(part); } catch (Exception) { } if (_inFolder != null) _inFolder.Reject = "save failed"; }
            return;
        }
        if (_done.Contains(f.Id))   // a resend of something we already saved
        {
            try { File.Delete(part); } catch (Exception) { }
            l.SendText(Frame.Ack(f.Id, true).Json);
            return;
        }
        var dest = Names.Unique(f.Name, Config.DownloadDir);
        try { File.Move(part, dest); }
        catch (Exception e)
        {
            try { File.Delete(part); } catch (Exception) { }
            l.SendText(Frame.Ack(f.Id, false, "save failed").Json);
            Emit(new SessionEvent.ReceiveFailed(f.Name, $"save failed: {e.Message}"));
            return;
        }
        _done.Add(f.Id);
        l.SendText(Frame.Ack(f.Id, true).Json);
        Emit(new SessionEvent.Received(new Item(f.Id, true, null, Path.GetFileName(dest), f.Size, dest, ItemState.ReceivedState)));
    }

    // ---------- outgoing ----------

    void Enqueue(Out o)
    {
        _out.Add(o);
        Emit(new SessionEvent.Outgoing(o.Item));
        Pump();
    }

    void Hashed(string id, Task<string> t)
    {
        var o = _out.Find(x => x.Item.Id == id);
        if (o == null) return;
        o.Hashing = false;
        if (t.IsCompletedSuccessfully) o.Sha = t.Result;
        else
        {
            _out.Remove(o);
            var why = t.Exception?.InnerException?.Message ?? "unknown";
            Emit(new SessionEvent.Outgoing(o.Item with { State = new ItemState(ItemStateKind.Failed, Error: $"cannot read: {why}") }));
        }
        Pump();
    }

    void Fail(string id, string reason)
    {
        if (_out.Find(x => x.Item.Id == id) is { } o)
        {
            _out.Remove(o);
            Emit(new SessionEvent.Outgoing(o.Item with { State = new ItemState(ItemStateKind.Failed, Error: reason) }));
        }
        _busy = false;
        Pump();
    }

    /// <summary>Put the next queued item on the wire: one item at a time, in order.</summary>
    void Pump()
    {
        if (!_linkUp || _busy || _link is not { } l) return;
        var o = _out.Find(x => !x.OnWire);
        if (o == null) return;
        var item = o.Item;
        var shaEnd = _peerCaps.Contains("sha_end");
        if (item.IsFile && !item.IsFolder && !shaEnd && o.Sha == null)   // a beta.5 peer wants the hash first
        {
            if (!o.Hashing)
            {
                o.Hashing = true;
                var path = item.Path!;
                Task.Run(() => Hashing.Sha256File(path)).ContinueWith(t => _q.Post(() => Hashed(item.Id, t)));
            }
            return;
        }
        o.OnWire = true;
        _busy = true;
        if (!item.IsFile)
        {
            l.SendText(Frame.TextItem(item.Id, item.Text!).Json, ok => Wrote(item.Id, l, ok));
            return;
        }
        if (item.IsFolder)
        {
            if (!_peerCaps.Contains("folders")) { Fail(item.Id, $"Update Lan-Line on {_peerName} to send folders"); return; }
            l.SendText(Frame.FolderBegin(item.Id, item.FileName!, item.Count!.Value, item.Size).Json);
            FolderStep(item.Id, o.Entries, 0, 0, item.Size, l);
            return;
        }
        FileStream fs;
        try { fs = new FileStream(item.Path!, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16); }
        catch (Exception e) { Fail(item.Id, $"cannot read: {e.Message}"); return; }
        var size = fs.Length;
        l.SendText(Frame.FileBegin(item.Id, item.FileName!, size, shaEnd ? null : o.Sha).Json);
        _fileSend = new FileSend { Id = item.Id, ItemId = item.Id, Fs = fs, Size = size, Link = l, Total = size,
                                   Hasher = shaEnd ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : null };
        FillWindow(_fileSend);
    }

    /// <summary>Send a folder's entries from start on: folders as mkdir, then the next file; its end continues here.</summary>
    void FolderStep(string itemId, List<FolderEntry> entries, int start, long baseBytes, long total, Link l)
    {
        if (!ReferenceEquals(l, _link) || !_linkUp) return;                                   // resent after reconnect
        if (!_out.Exists(x => x.Item.Id == itemId)) { _busy = false; Pump(); return; }        // refused
        var idx = start;
        while (idx < entries.Count && entries[idx].FullPath == null) { l.SendText(Frame.Mkdir(itemId, entries[idx].RelPath).Json); idx++; }
        if (idx == entries.Count) { l.SendText(Frame.FolderEnd(itemId).Json, ok => Wrote(itemId, l, ok)); return; }
        var e = entries[idx];
        FileStream fs;
        try { fs = new FileStream(e.FullPath!, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16); }
        catch (Exception)
        {
            l.SendText(Frame.FolderEnd(itemId).Json);   // the receiver throws the partial folder away
            Fail(itemId, $"cannot read {e.RelPath}");
            return;
        }
        var size = fs.Length;
        var sub = Guid.NewGuid().ToString();
        l.SendText(Frame.FileBegin(sub, Path.GetFileName(e.FullPath!), size, null, itemId, e.RelPath).Json);
        var next = idx + 1;
        _fileSend = new FileSend
        {
            Id = sub, ItemId = itemId, Fs = fs, Size = size, Link = l, Base = baseBytes, Total = total,
            Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256),
            Next = () => FolderStep(itemId, entries, next, baseBytes + size, total, l),
        };
        FillWindow(_fileSend);
    }

    void FillWindow(FileSend f)
    {
        if (!ReferenceEquals(f, _fileSend) || !ReferenceEquals(f.Link, _link) || !_linkUp) return;   // resent later
        if (!_out.Exists(x => x.Item.Id == f.ItemId)) { _fileSend = null; f.Fs.Dispose(); _busy = false; Pump(); return; }   // refused
        while (f.InFlight < Window && !f.Eof)
        {
            byte[] chunk;
            try
            {
                var buf = new byte[Config.ChunkSize];
                var n = f.Fs.ReadAtLeast(buf, buf.Length, throwOnEndOfStream: false);
                chunk = n == buf.Length ? buf : buf[..n];
            }
            catch (Exception)
            {
                _fileSend = null;
                f.Fs.Dispose();
                f.Link.Close("read failed mid-file");   // the peer drops the half file; we resend on reconnect
                return;
            }
            if (chunk.Length == 0) { f.Eof = true; break; }
            f.Hasher?.AppendData(chunk);
            f.InFlight++;
            f.Link.SendData(chunk, ok =>
            {
                f.InFlight--;
                if (!ok || !ReferenceEquals(f, _fileSend)) return;
                f.SentBytes += chunk.Length;
                var done = f.Base + f.SentBytes;
                var step = f.Total > 0 ? (int)(done * 20 / f.Total) : 20;   // progress in 5 % steps
                if (step != f.LastStep && _out.Find(x => x.Item.Id == f.ItemId) is { } o)
                {
                    f.LastStep = step;
                    o.Item = o.Item with { State = new ItemState(ItemStateKind.Sending, (double)done / Math.Max(f.Total, 1)) };
                    Emit(new SessionEvent.Outgoing(o.Item));
                }
                FillWindow(f);
            });
        }
        if (f.Eof && f.InFlight == 0)
        {
            _fileSend = null;
            f.Fs.Dispose();
            var l = f.Link;
            var sha = f.Hasher is { } h ? Convert.ToHexStringLower(h.GetHashAndReset()) : null;
            l.SendText(Frame.FileEnd(f.Id, sha).Json, ok =>
            {
                if (f.Next is { } next) { if (ok && ReferenceEquals(l, _link)) next(); }
                else Wrote(f.ItemId, l, ok);
            });
        }
    }

    void Wrote(string id, Link l, bool ok)
    {
        if (!ReferenceEquals(l, _link)) return;
        _busy = false;
        if (ok && _out.Find(x => x.Item.Id == id) is { } o && o.Item.State.Kind != ItemStateKind.Delivered)
        {
            o.Item = o.Item with { State = ItemState.Sent };
            Emit(new SessionEvent.Outgoing(o.Item));
        }
        Pump();
    }
}
