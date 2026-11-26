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
    /// <summary>Changed only on the session's queue (Session.SetDownloadDir, beta.10).</summary>
    public required string DownloadDir { get; set; }
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
    public long? FreeSpaceOverride { get; set; }
    /// <summary>Tests: take texts but never answer them, so the sender's item stays "sent, waiting for the ack".</summary>
    public bool HoldTextAcksForTests { get; init; }
    /// <summary>Listener, while pairing: answer the first good hello with a fresh 32-byte secret (rekey) and switch
    /// to it, so the short on-screen code is never the long-term secret. The code stays accepted until restart.</summary>
    public bool RekeyOnPair { get; init; }
    /// <summary>Listener: addresses to tell an authenticated dialer about (its fallbacks).</summary>
    public string[] Advertise { get; init; } = [];
    /// <summary>What this side tells its peer it can do (PROTOCOL.md "Capabilities"). Tests set [] to act like beta.5.</summary>
    public string[] Caps { get; init; } = ["sha_end", "folders", "multi", "cancel", "clip", "resume"];
    /// <summary>How long a half-received file is kept for the sender to resume ("resume" cap, beta.10).</summary>
    public TimeSpan PartialKeep { get; init; } = TimeSpan.FromHours(2);
    /// <summary>An incoming item gets a progress card once it has been arriving this long (small files never flicker).</summary>
    public TimeSpan ProgressDelay { get; init; } = TimeSpan.FromSeconds(0.3);
    /// <summary>At most one progress event per item this often (plus one per whole percent at the most).</summary>
    public TimeSpan ProgressInterval { get; init; } = TimeSpan.FromSeconds(0.25);
    /// <summary>This computer's device id, sent in hello / hello_ok (beta.7+).</summary>
    public string DeviceId { get; init; } = "";
    /// <summary>A listener that owns no socket: the Hub accepts connections and hands this Session its partner's.</summary>
    public bool External { get; init; }
    /// <summary>This app's version ("0.9.0-beta.6"), told to the other computer so either can say "an update is available".</summary>
    public string AppVersion { get; init; } = "";
    /// <summary>The newest version this computer already knows of (saved by the app), passed on to the other computer.</summary>
    public Updates.Available? LatestKnown { get; init; }
    /// <summary>Liveness tick period; zero = no timer (tests call Tick themselves).</summary>
    public TimeSpan TickInterval { get; init; } = TimeSpan.FromSeconds(1);
}

/// <summary>Receiving: an incoming file or folder still arriving (Progress 0…1); Cancelled: stopped by either side (beta.10).</summary>
public enum ItemStateKind { Waiting, Sending, Sent, Delivered, Failed, Received, Receiving, Cancelled }

public sealed record ItemState(ItemStateKind Kind, double Progress = 0, string? Error = null)
{
    public static readonly ItemState Waiting = new(ItemStateKind.Waiting);
    public static readonly ItemState Sent = new(ItemStateKind.Sent);
    public static readonly ItemState Delivered = new(ItemStateKind.Delivered);
    public static readonly ItemState ReceivedState = new(ItemStateKind.Received);
    public static readonly ItemState CancelledState = new(ItemStateKind.Cancelled);
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
    /// <summary>The other computer's device id, from its hello / hello_ok (beta.7+).</summary>
    public sealed record PeerDevice(string Device) : SessionEvent;
    public sealed record Disconnected(string Reason) : SessionEvent;
    public sealed record Received(Item Item) : SessionEvent;
    public sealed record Outgoing(Item Item) : SessionEvent;
    /// <summary>An incoming file or folder still arriving (Receiving), or stopped before it finished (Failed,
    /// Cancelled); Received follows when it lands (beta.10). Only items that take a moment get these.</summary>
    public sealed record Incoming(Item Item) : SessionEvent;
    /// <summary>The other computer's clipboard changed (clipboard sharing, beta.10). Never queued or kept.</summary>
    public sealed record Clipboard(ClipContent Content) : SessionEvent;
    /// <summary>Id: the item that failed (the same id its progress card had, if it had one).</summary>
    public sealed record ReceiveFailed(string Name, string Reason, string Id = "") : SessionEvent;
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
    readonly SerialQueue _q;
    readonly bool _ownsQueue;
    readonly Action<SessionEvent> _handler;
    readonly Func<DateTime> _now;

    sealed class Out
    {
        public required Item Item; public string? Sha; public bool Hashing; public bool OnWire; public List<FolderEntry> Entries = [];
        /// <summary>The link dropped while this file was streaming: offer to resume it ("resume" cap, beta.10).</summary>
        public bool Resumable;
    }
    /// <summary>A half-received single file kept after a dropped link, for the sender to resume (beta.10).</summary>
    internal sealed record Partial(string Name, long Size, string Part, long Received, DateTime At);
    readonly Dictionary<string, Partial> _partials = [];
    /// <summary>Receiver: a kept partial is being read back from disk (off this queue) to rebuild its hash; "resume"
    /// is answered when that is done.</summary>
    (string Id, Partial Partial, Link Link)? _rehashing;
    /// <summary>Sender: the part the receiver already has is being hashed (off this queue) before the rest is streamed.</summary>
    (string Id, Link Link)? _hashingPrefix;
    /// <summary>Sender: a resumable file_begin went out; waiting for the receiver's "resume" answer.</summary>
    (string Id, string Path, long Size, Link Link)? _awaitingResume;
    sealed class InFile
    {
        public required string Id, Name; public string? Sha; public long Size;
        public string? Folder, Dir; public bool Acked;
        /// <summary>A single file: the folder it is saved in, fixed when it began.</summary>
        public string? Dest;
        public string? Part; public FileStream? Stream; public IncrementalHash Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public long Received; public string? Reject;
    }
    sealed class InFolder
    {
        public required string Id, Name; public int Count; public long Size;
        public string? Stage; public int Files; public long Bytes; public string? Reject; public bool Acked;
        /// <summary>The folder it is saved in, fixed when it began.</summary>
        public string? Dest;
    }
    InFolder? _inFolder;
    /// <summary>The top-level incoming item (a file, or a whole folder) and how far it is, for progress cards (beta.10).</summary>
    sealed class InProgress
    {
        public required Item Item; public long Total; public DateTime Started;
        public long Done; public bool Shown; public DateTime LastEmit = DateTime.MinValue; public int LastPct = -1;
    }
    InProgress? _progress;
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
    /// <summary>Which item has the wire. A cancel or a refusal can free the wire while one of the item's writes is
    /// still finishing; that late completion must not free it a second time (the next item already has it).</summary>
    string? _wireItem;
    FileSend? _fileSend;   // the file currently streaming out
    const int Window = 4;  // chunks in flight: keeps a LAN busy, memory stays Window × ChunkSize

    sealed class FileSend
    {
        public required string Id, ItemId; public required FileStream Fs; public long Size; public required Link Link;
        public IncrementalHash? Hasher;       // set when the SHA-256 goes in file_end
        public long Base, Total;              // progress across a folder
        public Action? Next;                  // inside a folder: what comes after this file
        public int InFlight; public long SentBytes; public bool Eof; public int LastStep = -1; public DateTime LastEmit = DateTime.MinValue;
    }
    InFile? _in;
    readonly HashSet<string> _done = [];
    DateTime _lastHeard, _lastBeat;

    public Session(Role role, SessionConfig config, Action<SessionEvent> handler, Func<DateTime>? clock = null, SerialQueue? queue = null)
    {
        _q = queue ?? new SerialQueue("lan-line.session");
        _ownsQueue = queue == null;
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
        foreach (var p in StopKeepingPartials().Values) try { File.Delete(p.Part); } catch (Exception) { }   // quitting: nothing to resume
    }

    /// <summary>Stop, but hand back the half-received files still worth resuming: the Hub replaces a partner's Session
    /// when its address changes, and the Session that takes over carries on with them (AdoptPartials).</summary>
    internal Dictionary<string, Partial> StopKeepingPartials() =>
        _q.Sync(() =>
        {
            _stopped = true;
            _timer?.Dispose(); _timer = null;
            _listener?.Stop(); _listener = null;
            foreach (var l in _pending.Keys.ToList()) l.Close("stopped");
            _pending.Clear();
            _dialing?.Close("stopped"); _dialing = null;
            _link?.Close("stopped");   // LinkDown shelves a file in mid-air and a part being rehashed
            ShelveRehash();
            var kept = new Dictionary<string, Partial>(_partials);
            _partials.Clear();
            return kept;
        });

    /// <summary>Take over another Session's kept partials (before Start).</summary>
    internal void AdoptPartials(Dictionary<string, Partial> kept) =>
        _q.Post(() => { foreach (var (id, p) in kept) _partials.TryAdd(id, p); });

    /// <summary>Tests: change what the receiver believes is free on its disk.</summary>
    internal void SetFreeSpaceForTests(long? bytes) => _q.Post(() => Config.FreeSpaceOverride = bytes);

    /// <summary>Left over from a run that ended without cleaning up (a crash, a kill, power loss): this app's hidden
    /// part files and folders, ".&lt;name&gt;.&lt;8 hex digits&gt;.part", untouched for longer than a partial is ever kept.
    /// Returns how many it removed.</summary>
    public static int SweepOrphans(string dir, TimeSpan olderThan, DateTime? now = null)
    {
        var t = now ?? DateTime.UtcNow;
        var removed = 0;
        string[] entries;
        try { entries = Directory.GetFileSystemEntries(dir, ".*.part"); } catch (Exception) { return 0; }
        foreach (var path in entries)
        {
            if (!IsPartName(Path.GetFileName(path))) continue;
            try
            {
                var isDir = Directory.Exists(path);
                var made = isDir ? Directory.GetLastWriteTimeUtc(path) : File.GetLastWriteTimeUtc(path);
                if (t - made <= olderThan) continue;
                if (isDir) Directory.Delete(path, true); else File.Delete(path);
                removed++;
            }
            catch (Exception) { }
        }
        return removed;
    }

    internal static bool IsPartName(string name)
    {
        if (!name.StartsWith('.') || !name.EndsWith(".part", StringComparison.Ordinal)) return false;
        var stem = name[..^5];   // ".<name>.<8 hex>"
        var dot = stem.LastIndexOf('.');
        return stem.Length >= 11 && dot > 1 && stem.Length - dot - 1 == 8 && stem[(dot + 1)..].All(Uri.IsHexDigit);
    }

    public void Dispose() { Stop(); if (_ownsQueue) _q.Dispose(); }

    /// <summary>Save files that arrive from now on in another folder (beta.10: the folder setting, a folder per computer).
    /// A file already arriving finishes where it started.</summary>
    public void SetDownloadDir(string dir) => _q.Post(() => Config.DownloadDir = dir);

    /// <summary>Send the clipboard (beta.10): straight away, only while connected and only to a side with the "clip" cap.
    /// Never queued. Calls back whether it went out.</summary>
    public void SendClip(ClipContent c, Action<bool>? done = null) => _q.Post(() =>
    {
        if (!_linkUp || _link is not { } l || !_peerCaps.Contains("clip") || !ClipRules.Fits(c)) { done?.Invoke(false); return; }
        l.SendText(Frame.Clip(c).Json, ok => done?.Invoke(ok));
    });

    /// <summary>Whether the connected side can take clipboard items (null while not connected).</summary>
    public void PeerTakesClips(Action<bool?> result) => _q.Post(() => result(_linkUp ? _peerCaps.Contains("clip") : null));

    /// <summary>Stop an outgoing item (beta.10): a queued one is dropped; one on the wire stops at once and the
    /// receiver throws away what arrived (cancel to a beta.10 peer; an early file_end / folder_end to an older one,
    /// which it refuses as a size mismatch). An item already fully sent can't be called back.</summary>
    public void Cancel(string id) => _q.Post(() => CancelOnQueue(id));

    /// <summary>Refuse the incoming file or folder that is arriving (beta.10): the sender stops (the same ack ok:false
    /// a full disk gives, which every version understands) and the part files are deleted.</summary>
    public void CancelIncoming(string id) => _q.Post(() => CancelIncomingOnQueue(id));

    public Item SendText(string text, string? id = null)
    {
        var item = new Item(id ?? Guid.NewGuid().ToString(), false, text, null, text.Length, null, ItemState.Waiting);
        _q.Post(() => Enqueue(new Out { Item = item, Sha = "" }));
        return item;
    }

    public Item SendFile(string path, string? id = null)
    {
        long size = -1;
        try { size = new FileInfo(path).Length; } catch (Exception) { }
        var item = new Item(id ?? Guid.NewGuid().ToString(), false, null, Path.GetFileName(path), size, path, ItemState.Waiting);
        _q.Post(() => Enqueue(new Out { Item = item }));   // hashed while it streams (or first, for a beta.5 peer)
        return item;
    }

    /// <summary>Send a whole folder as one item. Symlinks and junctions are left out (see ScanFolder).</summary>
    public Item SendFolder(string path, string? id = null, FolderScan? given = null)
    {
        var scan = given ?? ScanFolder(path);   // the hub passes the walk it already did (beta.11)
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        var item = new Item(id ?? Guid.NewGuid().ToString(), false, null, name, scan.Size, path, ItemState.Waiting, scan.Count);
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
        var sweepDir = Config.DownloadDir; var sweepAge = Config.PartialKeep + TimeSpan.FromMinutes(10);
        _ = Task.Run(() => SweepOrphans(sweepDir, sweepAge));
        if (Config.TickInterval > TimeSpan.Zero)
            _timer = new Timer(_ => _q.Post(TickOnQueue), null, Config.TickInterval, Config.TickInterval);
        switch (Role)
        {
            case Role.Listen when Config.External: break;   // the Hub owns the socket
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

    // ---------- Hub entry points (on the queue) ----------

    /// <summary>Does this hello's MAC match this partner's secret (or the code it is replacing)?</summary>
    internal bool MatchesHello(Frame f)
    {
        if (_stopped || f is not { Type: "hello", V: LL2.Version } || LL2.B64(f.Nonce) is not { } n || LL2.B64(f.Epk) is not { } e || LL2.B64(f.Mac) is not { } m) return false;
        var t1 = LL2.T1(f.Name ?? "", n, e);
        return LL2.Verify(LL2.MacKey(_token), t1, m) || (_oldToken != null && LL2.Verify(LL2.MacKey(_oldToken), t1, m));
    }

    /// <summary>Take over a link the Hub accepted, and answer its hello.</summary>
    internal void Adopt(Link l, string hello)
    {
        l.Retarget(OnLinkEvent);
        HandleHello(hello, l);
    }

    /// <summary>Connections that haven't said hello yet (each is dropped after 10 s): no more than this at once.</summary>
    internal const int MaxPending = 32;

    internal static bool IsDeviceId(string s) => s.Length is >= 8 and <= 64 && s.All(c => c < 128 && (char.IsLetterOrDigit(c) || c == '-'));

    void Accept(WebSocket ws, string peer)
    {
        if (_stopped || _pending.Count >= MaxPending) { ws.Abort(); return; }   // strangers can't pile up connections
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
                    l.SendText((_dialHs.Hello with { Caps = Config.Caps, Device = Config.DeviceId.Length > 0 ? Config.DeviceId : null }).Json);   // outside the MAC: stripping it only means beta.5 behaviour
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
        if (f.Device is { } fd && IsDeviceId(fd)) Emit(new SessionEvent.PeerDevice(fd));
        l.SendText((ans.Ok with { Caps = Config.Caps, Device = Config.DeviceId.Length > 0 ? Config.DeviceId : null }).Json);
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
        if (f.Device is { } dev && IsDeviceId(dev)) Emit(new SessionEvent.PeerDevice(dev));
        _dialHs = null;
        _dialing = null;
        _attempt = 0;
        BecomeUp(l, f.Name ?? l.Peer);
    }

    internal static bool IsIPv4(string a) =>
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
        _wireItem = null;
        _hashingPrefix = null;
        ShelveRehash();
        if (_fileSend is { } fsend) { fsend.Fs.Dispose(); _fileSend = null; }
        // A half-received file: kept for the sender to resume ("resume" cap), else thrown away.
        if (_in is { Folder: null, Reject: null, Part: { } part } kin && kin.Received > 0 && _peerCaps.Contains("resume"))
        {
            try { kin.Stream?.Dispose(); } catch (Exception) { }
            kin.Stream = null;
            _partials[kin.Id] = new Partial(kin.Name, kin.Size, part, kin.Received, _now());
            TrimPartials();
            _in = null;
        }
        AbortIncoming();
        DropFolder();
        _awaitingResume = null;
        foreach (var o in _out.Where(o => o.OnWire && o.Item.IsFile && !o.Item.IsFolder && o.Item.State.Kind != ItemStateKind.Sent)) o.Resumable = true;
        EndProgress(new ItemState(ItemStateKind.Failed, Error: "interrupted"));   // sent again after the reconnect
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
        foreach (var (id, p) in _partials.Where(kv => t - kv.Value.At > Config.PartialKeep).ToList())
        {
            try { File.Delete(p.Part); } catch (Exception) { }
            _partials.Remove(id);
        }
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
                if (!Config.HoldTextAcksForTests) l.SendText(Frame.Ack(f.Id, true).Json);
                break;
            case "file_begin" when f.Id != null:
                AbortIncoming();
                if (f.Folder == null) { DropFolder(); EndProgress(new ItemState(ItemStateKind.Failed, Error: "interrupted")); }
                BeginFile(f.Id, f.Name ?? "file", f.Size ?? -1, f.Sha256?.ToLowerInvariant(), f.Folder, f.RelPath, l, resume: f.Resume == true && f.Folder == null);
                break;
            case "file_end" when f.Id != null && _in is { } file && file.Id == f.Id:
                _in = null;
                FinishFile(file, f.Sha256?.ToLowerInvariant(), l);
                break;
            case "folder_begin" when f.Id != null:
                AbortIncoming(); DropFolder(); EndProgress(new ItemState(ItemStateKind.Failed, Error: "interrupted"));
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
            case "resume" when f.Id != null && _awaitingResume is { } aw && aw.Id == f.Id && ReferenceEquals(aw.Link, l):
                // beta.10: the receiver has Offset bytes of our interrupted file; send the rest
                _awaitingResume = null;
                {
                    var offset = Math.Clamp(f.Offset ?? 0, 0, aw.Size);
                    if (offset == 0) { StartFile(f.Id, aw.Path, aw.Size, l); break; }
                    // Hash what the receiver already has off this queue: on a slow disk that takes longer than the
                    // dead-link timeout, and beats must keep going meanwhile.
                    _hashingPrefix = (f.Id, l);
                    var (rid, rpath, rsize, hashing) = (f.Id, aw.Path, aw.Size, _peerCaps.Contains("sha_end"));
                    _ = Task.Run(() =>
                    {
                        var opened = OpenAt(rpath, offset, hashing);
                        _q.Post(() => PrefixHashed(rid, rsize, offset, opened));
                    });
                }
                break;
            case "clip":   // beta.10: the other computer's clipboard (only sent to sides with the "clip" cap)
                if (f.Text is { } ct && System.Text.Encoding.UTF8.GetByteCount(ct) <= ClipRules.MaxText) Emit(new SessionEvent.Clipboard(new ClipContent.TextClip(ct)));
                else if (f.Png is { } pb)
                {
                    byte[]? d = null;
                    try { d = Convert.FromBase64String(pb); } catch (FormatException) { }
                    if (d != null && ClipRules.Fits(new ClipContent.PngClip(d))) Emit(new SessionEvent.Clipboard(new ClipContent.PngClip(d)));
                }
                break;
            case "cancel" when f.Id != null && _rehashing is { } rh && rh.Id == f.Id:
                // stopped while its kept part was being read back
                _rehashing = null;
                try { File.Delete(rh.Partial.Part); } catch (Exception) { }
                EndProgress(ItemState.CancelledState);
                break;
            case "cancel" when f.Id != null && (_progress?.Item.Id == f.Id || _inFolder?.Id == f.Id || _in?.Id == f.Id):
                // beta.10: the sender stopped this item; throw away what arrived
                AbortIncoming();
                if (_inFolder?.Id == f.Id) DropFolder();
                EndProgress(ItemState.CancelledState);
                break;
            case "ack" when f.Id != null:
                var i = _out.FindIndex(o => o.Item.Id == f.Id);
                if (i < 0) return;
                var done = _out[i];
                _out.RemoveAt(i);
                var err = f.Err ?? "rejected";
                var st = f.Ok == true ? ItemState.Delivered
                       : err.StartsWith("cancelled", StringComparison.Ordinal) ? ItemState.CancelledState
                       : new ItemState(ItemStateKind.Failed, Error: err);
                Emit(new SessionEvent.Outgoing(done.Item with { State = st }));
                if (_awaitingResume?.Id == f.Id) _awaitingResume = null;   // refused instead of resumed
                if (_hashingPrefix?.Id == f.Id) _hashingPrefix = null;
                if (_fileSend is { } fsend && fsend.ItemId == f.Id)   // refused while streaming (too big): stop now
                {
                    _fileSend = null;
                    fsend.Fs.Dispose();
                }
                Release(f.Id);
                break;
        }
    }

    long? FreeSpace(string? dir = null)
    {
        if (Config.FreeSpaceOverride is { } o) return o;
        var d = dir ?? Config.DownloadDir;
        try { Directory.CreateDirectory(d); return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(d))!).AvailableFreeSpace; }
        catch (Exception) { return null; }
    }

    static string Gb(long b) => b >= 1_000_000_000 ? $"{b / 1e9:0.#} GB" : b >= 1_000_000 ? $"{b / 1e6:0.#} MB" : $"{b / 1e3:0.#} KB";

    string? NoSpace(long size, string? dir = null) =>
        FreeSpace(dir) is { } free && size + Config.DiskReserve > free
            ? $"not enough disk space on {Config.Name} (needs {Gb(size)}, {Gb(Math.Max(free - Config.DiskReserve, 0))} free)" : null;

    /// <summary>A refusal the receiver can give at once, before any bytes: the sender stops and both windows say why.</summary>
    void RefuseNow(string id, string name, string reason, Link l)
    {
        l.SendText(Frame.Ack(id, false, reason).Json);
        Emit(new SessionEvent.ReceiveFailed(name, reason, id));
    }

    /// <summary>The wire is free again, if id is the item that has it (see _wireItem). Starts the next item.</summary>
    void Release(string id)
    {
        if (_wireItem != id) return;
        _wireItem = null;
        _busy = false;
        Pump();
    }

    /// <summary>A kept part that was being read back goes on the shelf again (the link dropped, or another item came).</summary>
    void ShelveRehash()
    {
        if (_rehashing is not { } r) return;
        _rehashing = null;
        _partials[r.Id] = r.Partial;
    }

    void BeginFile(string id, string raw, long size, string? sha, string? folder, string? path, Link l, bool resume = false)
    {
        var name = Names.Sanitize(raw);
        var f = new InFile { Id = id, Name = name, Sha = sha, Size = size, Folder = folder };
        if (resume && _partials.Remove(id, out var kept))
        {
            if (kept.Size == size && kept.Name == name)   // carry on where the link dropped
            {
                var keptDir = Path.GetDirectoryName(kept.Part)!;
                // Room for the rest is checked now: the check at the first file_begin can be hours old.
                if (NoSpace(size - kept.Received, keptDir) is { } full)
                {
                    try { File.Delete(kept.Part); } catch (Exception) { }
                    RefuseNow(id, name, full, l);
                    f.Reject = full; f.Acked = true; _in = f;
                    return;
                }
                // The part's hash is rebuilt from what is on disk, off this queue: a big part on a slow disk takes
                // longer than the dead-link timeout, and beats must keep going. Rehashed answers.
                _rehashing = (id, kept, l);
                _progress = new InProgress { Item = new Item(id, true, null, name, size, Path.Combine(keptDir, name), ItemState.ReceivedState), Total = size, Started = _now(), Done = kept.Received };
                _ = Task.Run(() =>
                {
                    var h = Rehash(kept);
                    _q.Post(() => Rehashed(id, name, size, sha, h));
                });
                return;
            }
            try { File.Delete(kept.Part); } catch (Exception) { }
        }
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
            if (folder == null) f.Dest = Config.DownloadDir;   // it finishes where it started, whatever the setting says by then
            OpenPart(f, f.Dir ?? Config.DownloadDir);
        }
        if (f.Reject is { } why && folder == null) { RefuseNow(id, name, why, l); f.Acked = true; }   // the sender stops now
        if (resume && f.Reject == null) l.SendText(Frame.ResumeAt(id, 0).Json);   // nothing kept: from the start
        if (folder == null && f.Reject == null && !_done.Contains(id))   // a resend of something already saved gets no card: it ends silently
            _progress = new InProgress { Item = new Item(id, true, null, name, size, Path.Combine(Config.DownloadDir, name), ItemState.ReceivedState), Total = size, Started = _now() };
        _in = f;
    }

    static void OpenPart(InFile f, string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            f.Part = Path.Combine(dir, $".{f.Name}.{Guid.NewGuid().ToString("N")[..8]}.part");
            f.Stream = new FileStream(f.Part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16);
        }
        catch (Exception e) { f.Reject = $"cannot write: {e.Message}"; }
    }

    /// <summary>The kept part has been read back (hasher null: it is gone or short). Answer the sender's resume offer.</summary>
    void Rehashed(string id, string name, long size, string? sha, IncrementalHash? hasher)
    {
        if (_rehashing is not { } r || r.Id != id) { hasher?.Dispose(); return; }   // cancelled, replaced or the link dropped: dealt with there
        _rehashing = null;
        var (p, l) = (r.Partial, r.Link);
        if (!ReferenceEquals(l, _link) || !_linkUp) { _partials[id] = p; hasher?.Dispose(); return; }
        var f = new InFile { Id = id, Name = name, Sha = sha, Size = size, Dest = Path.GetDirectoryName(p.Part)! };
        if (hasher != null)
        {
            try
            {
                var w = new FileStream(p.Part, FileMode.Open, FileAccess.Write, FileShare.None, 1 << 16);
                w.SetLength(p.Received);
                w.Seek(0, SeekOrigin.End);
                f.Part = p.Part; f.Stream = w; f.Hasher = hasher; f.Received = p.Received;
                _in = f;
                l.SendText(Frame.ResumeAt(id, p.Received).Json);
                return;
            }
            catch (Exception) { hasher.Dispose(); }
        }
        try { File.Delete(p.Part); } catch (Exception) { }   // nothing usable kept: from the start
        _progress = null;
        OpenPart(f, f.Dest ?? Config.DownloadDir);
        if (f.Reject is { } why) { RefuseNow(id, name, why, l); f.Acked = true; }
        else
        {
            l.SendText(Frame.ResumeAt(id, 0).Json);
            _progress = new InProgress { Item = new Item(id, true, null, name, size, Path.Combine(f.Dest ?? Config.DownloadDir, name), ItemState.ReceivedState), Total = size, Started = _now() };
        }
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
            d.Dest = Config.DownloadDir;   // it finishes where it started, whatever the setting says by then
            var stage = Path.Combine(Config.DownloadDir, $".{name}.{Guid.NewGuid().ToString("N")[..8]}.part");
            try { Directory.CreateDirectory(stage); d.Stage = stage; } catch (Exception) { d.Reject = "cannot write"; }
        }
        if (d.Reject is { } why) { RefuseNow(id, name, why, l); d.Acked = true; }
        else if (!_done.Contains(id)) _progress = new InProgress { Item = new Item(id, true, null, name, size, Path.Combine(Config.DownloadDir, name), ItemState.ReceivedState, count), Total = size, Started = _now() };
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
            if (_progress?.Item.Id == d.Id) EndProgress(new ItemState(ItemStateKind.Failed, Error: why));
            if (!d.Acked) RefuseNow(d.Id, d.Name, why, l);
            return;
        }
        if (d.Stage is not { } stage) { if (_progress?.Item.Id == d.Id) _progress = null; return; }
        if (_done.Contains(d.Id))   // a resend of something already saved: it had no card (see BeginFolder)
        {
            try { Directory.Delete(stage, true); } catch (Exception) { }
            if (_progress?.Item.Id == d.Id) _progress = null;
            l.SendText(Frame.Ack(d.Id, true).Json);
            return;
        }
        var destDir = d.Dest ?? Config.DownloadDir;   // where it started, even if the setting changed meanwhile
        string dest;
        try { Directory.CreateDirectory(destDir); dest = Names.Unique(d.Name, destDir); Directory.Move(stage, dest); }
        catch (Exception)
        {
            try { Directory.Delete(stage, true); } catch (Exception) { }
            if (_progress?.Item.Id == d.Id) EndProgress(new ItemState(ItemStateKind.Failed, Error: "save failed"));   // the card must not stay at "receiving"
            RefuseNow(d.Id, d.Name, "save failed", l);
            return;
        }
        if (_progress?.Item.Id == d.Id) _progress = null;   // Received replaces the progress card
        _done.Add(d.Id);
        l.SendText(Frame.Ack(d.Id, true).Json);
        Emit(new SessionEvent.Received(new Item(d.Id, true, null, Path.GetFileName(dest), d.Size, dest, ItemState.ReceivedState, d.Count)));
    }

    void HandleChunk(byte[] d)
    {
        if (_in is not { } f || f.Reject != null) return;
        f.Received += d.Length;
        if (f.Received > f.Size) { f.Reject = "size mismatch"; DropPart(f); return; }
        try { f.Stream!.Write(d); f.Hasher.AppendData(d); Progressed(d.Length); }
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
        ShelveRehash();   // the sender moved on to another item: the kept part waits for a later offer
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
            if (_progress?.Item.Id == f.Id) EndProgress(new ItemState(ItemStateKind.Failed, Error: reason));
            if (!f.Acked)
            {
                l.SendText(Frame.Ack(f.Id, false, reason).Json);
                Emit(new SessionEvent.ReceiveFailed(f.Name, reason, f.Id));
            }
            return;
        }
        if (f.Part is not { } part) { if (f.Folder == null && _progress?.Item.Id == f.Id) _progress = null; return; }
        if (f.Dir is { } fdir)   // inside a folder: put it in place, count it
        {
            try { File.Move(part, Names.Unique(f.Name, fdir)); if (_inFolder != null) _inFolder.Files++; }
            catch (Exception) { try { File.Delete(part); } catch (Exception) { } if (_inFolder != null) _inFolder.Reject = "save failed"; }
            return;
        }
        if (_done.Contains(f.Id))   // a resend of something we already saved: it had no card (see BeginFile)
        {
            try { File.Delete(part); } catch (Exception) { }
            if (_progress?.Item.Id == f.Id) _progress = null;
            l.SendText(Frame.Ack(f.Id, true).Json);
            return;
        }
        var destDir = f.Dest ?? Config.DownloadDir;   // where it started, even if the setting changed meanwhile
        string dest;
        try { Directory.CreateDirectory(destDir); dest = Names.Unique(f.Name, destDir); File.Move(part, dest); }
        catch (Exception e)
        {
            try { File.Delete(part); } catch (Exception) { }
            if (_progress?.Item.Id == f.Id) EndProgress(new ItemState(ItemStateKind.Failed, Error: "save failed"));   // the card must not stay at "receiving"
            l.SendText(Frame.Ack(f.Id, false, "save failed").Json);
            Emit(new SessionEvent.ReceiveFailed(f.Name, $"save failed: {e.Message}", f.Id));
            return;
        }
        if (_progress?.Item.Id == f.Id) _progress = null;   // Received replaces the progress card
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

    /// <summary>On the queue only (tests call it from an event handler to cancel at an exact moment).</summary>
    internal void CancelOnQueue(string id)
    {
        var o = _out.Find(x => x.Item.Id == id);
        if (o == null) return;
        if (o.OnWire)
        {
            if (o.Item.State.Kind == ItemStateKind.Sent) return;   // all on the wire, waiting for the ack: too late
            if (_link is not { } l) return;
            var viaCancel = _peerCaps.Contains("cancel");
            if (_fileSend is { } fs && fs.ItemId == id)
            {
                _fileSend = null;
                fs.Fs.Dispose();
                if (viaCancel) l.SendText(Frame.Cancel(id).Json);
                else
                {
                    l.SendText(Frame.FileEnd(fs.Id, null).Json);                    // short: refused as a size mismatch
                    if (fs.Id != fs.ItemId) l.SendText(Frame.FolderEnd(id).Json);   // and the folder with it
                }
            }
            else if (_awaitingResume?.Id == id || _hashingPrefix?.Id == id)   // waiting for the resume answer, or hashing after it
            {
                if (_awaitingResume?.Id == id) _awaitingResume = null;
                if (_hashingPrefix?.Id == id) _hashingPrefix = null;
                l.SendText(Frame.Cancel(id).Json);
            }
            else if (o.Item.IsFolder) l.SendText((viaCancel ? Frame.Cancel(id) : Frame.FolderEnd(id)).Json);   // between two files
            else return;   // a text: already sent
            if (_wireItem == id) { _wireItem = null; _busy = false; }   // a write of this item still finishing won't free the wire again
        }
        _out.Remove(o);
        Emit(new SessionEvent.Outgoing(o.Item with { State = ItemState.CancelledState }));
        Pump();
    }

    /// <summary>On the queue only (tests call it from an event handler).</summary>
    internal void CancelIncomingOnQueue(string id)
    {
        if (_progress is not { } p || p.Item.Id != id || _link is not { } l) return;
        if (_rehashing is { } rh && rh.Id == id)   // stopped while its kept part was being read back
        {
            _rehashing = null;
            try { File.Delete(rh.Partial.Part); } catch (Exception) { }
        }
        if (_in is { } f && (f.Id == id || f.Folder == id)) { DropPart(f); f.Reject = "cancelled"; f.Acked = true; }
        if (_inFolder is { } d && d.Id == id)
        {
            if (d.Stage != null) try { Directory.Delete(d.Stage, true); } catch (Exception) { }
            d.Stage = null; d.Reject = "cancelled"; d.Acked = true;
        }
        l.SendText(Frame.Ack(id, false, $"cancelled on {Config.Name}").Json);
        EndProgress(ItemState.CancelledState);
    }

    /// <summary>Bytes of the current incoming item landed: show its card once it takes a moment, then keep it moving.</summary>
    void Progressed(long n)
    {
        if (_progress is not { } p) return;
        p.Done += n;
        var t = _now();
        var pct = p.Total > 0 ? (int)(p.Done * 100 / p.Total) : 100;
        var due = p.Shown ? (pct != p.LastPct && t - p.LastEmit >= Config.ProgressInterval) || t - p.LastEmit >= TimeSpan.FromSeconds(1)
                          : t - p.Started >= Config.ProgressDelay;
        if (!due) return;
        p.Shown = true; p.LastEmit = t; p.LastPct = pct;
        Emit(new SessionEvent.Incoming(p.Item with { State = new ItemState(ItemStateKind.Receiving, (double)p.Done / Math.Max(p.Total, 1)) }));
    }

    /// <summary>The incoming item stopped short: tell the window if it was showing a card.</summary>
    void EndProgress(ItemState state)
    {
        if (_progress is not { } p) return;
        _progress = null;
        if (p.Shown) Emit(new SessionEvent.Incoming(p.Item with { State = state }));
    }

    void Fail(string id, string reason)
    {
        if (_out.Find(x => x.Item.Id == id) is { } o)
        {
            _out.Remove(o);
            Emit(new SessionEvent.Outgoing(o.Item with { State = new ItemState(ItemStateKind.Failed, Error: reason) }));
        }
        if (_wireItem == id) { _wireItem = null; _busy = false; }
        Pump();
    }

    /// <summary>Put the next queued item on the wire: one item at a time, in order.</summary>
    void Pump()
    {
        // A "sendonly" peer (the iPhone's share sheet, beta.10) only hands things over: what is queued for that
        // device waits for the app itself to connect.
        if (!_linkUp || _busy || _link is not { } l || _peerCaps.Contains("sendonly")) return;
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
        _wireItem = item.Id;
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
        long size;
        try { size = new FileInfo(item.Path!).Length; using var probe = File.OpenRead(item.Path!); }
        catch (Exception e) { Fail(item.Id, $"cannot read: {e.Message}"); return; }
        if (o.Resumable && shaEnd && _peerCaps.Contains("resume"))   // offer to carry on; wait for the offset
        {
            _awaitingResume = (item.Id, item.Path!, size, l);
            l.SendText((Frame.FileBegin(item.Id, item.FileName!, size, null) with { Resume = true }).Json);
            return;
        }
        l.SendText(Frame.FileBegin(item.Id, item.FileName!, size, shaEnd ? null : o.Sha).Json);
        StartFile(item.Id, item.Path!, size, l);
    }

    /// <summary>Stream a file from its start.</summary>
    void StartFile(string id, string path, long size, Link l)
    {
        FileStream fs;
        try { fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16); }
        catch (Exception e) { Fail(id, $"cannot read: {e.Message}"); return; }
        var hasher = _peerCaps.Contains("sha_end") ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : null;
        _fileSend = new FileSend { Id = id, ItemId = id, Fs = fs, Size = size, Link = l, Total = size, Hasher = hasher };
        FillWindow(_fileSend);
    }

    /// <summary>A file opened at offset, with the hash of everything before it (the part the receiver already has):
    /// with sha_end the hash in file_end still covers the whole file. Runs off the session queue.</summary>
    static (FileStream? Fs, IncrementalHash? Hasher, string? Error) OpenAt(string path, long offset, bool hashing)
    {
        FileStream? fs = null;
        try
        {
            fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
            if (!hashing) { fs.Seek(offset, SeekOrigin.Begin); return (fs, null, null); }
            var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buf = new byte[1 << 20];
            var left = offset;
            while (left > 0)
            {
                var n = fs.Read(buf, 0, (int)Math.Min(left, buf.Length));
                if (n <= 0) { fs.Dispose(); hasher.Dispose(); return (null, null, "the file is shorter than it was"); }
                hasher.AppendData(buf, 0, n);
                left -= n;
            }
            return (fs, hasher, null);
        }
        catch (Exception e) { fs?.Dispose(); return (null, null, e.Message); }
    }

    /// <summary>The prefix is hashed: stream the rest, unless the item was cancelled, refused or cut off meanwhile.</summary>
    void PrefixHashed(string id, long size, long offset, (FileStream? Fs, IncrementalHash? Hasher, string? Error) r)
    {
        void Close() { r.Fs?.Dispose(); r.Hasher?.Dispose(); }
        if (_hashingPrefix is not { } hp || hp.Id != id) { Close(); return; }
        _hashingPrefix = null;
        var l = hp.Link;
        if (!ReferenceEquals(l, _link) || !_linkUp || !_out.Exists(x => x.Item.Id == id)) { Close(); return; }
        if (r.Fs == null) { Fail(id, $"cannot read: {r.Error}"); return; }
        _fileSend = new FileSend { Id = id, ItemId = id, Fs = r.Fs, Size = size, Link = l, Total = size, Hasher = r.Hasher, SentBytes = offset };
        FillWindow(_fileSend);
    }

    /// <summary>The hash of a kept partial's first Received bytes, read back from disk; null if it is gone or short.
    /// Runs off the session queue.</summary>
    static IncrementalHash? Rehash(Partial p)
    {
        try
        {
            if (!File.Exists(p.Part) || new FileInfo(p.Part).Length < p.Received) return null;
            var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            using var r = File.OpenRead(p.Part);
            var buf = new byte[1 << 20];
            var left = p.Received;
            while (left > 0) { var n = r.Read(buf, 0, (int)Math.Min(left, buf.Length)); if (n <= 0) { h.Dispose(); return null; } h.AppendData(buf, 0, n); left -= n; }
            return h;
        }
        catch (Exception) { return null; }
    }

    void TrimPartials()
    {
        foreach (var (id, p) in _partials.OrderBy(kv => kv.Value.At).Take(Math.Max(0, _partials.Count - 5)).ToList())
        {
            try { File.Delete(p.Part); } catch (Exception) { }
            _partials.Remove(id);
        }
    }

    /// <summary>Send a folder's entries from start on: folders as mkdir, then the next file; its end continues here.</summary>
    void FolderStep(string itemId, List<FolderEntry> entries, int start, long baseBytes, long total, Link l)
    {
        if (!ReferenceEquals(l, _link) || !_linkUp) return;                                   // resent after reconnect
        if (!_out.Exists(x => x.Item.Id == itemId)) { Release(itemId); return; }        // refused or cancelled
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
        if (!_out.Exists(x => x.Item.Id == f.ItemId)) { _fileSend = null; f.Fs.Dispose(); Release(f.ItemId); return; }   // refused
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
                // progress events: each whole percent at most, and no more often than ProgressInterval
                var step = f.Total > 0 ? (int)(done * 100 / f.Total) : 100;
                var t = _now();
                if (step != f.LastStep && (t - f.LastEmit >= Config.ProgressInterval || step == 100) && _out.Find(x => x.Item.Id == f.ItemId) is { } o)
                {
                    f.LastStep = step; f.LastEmit = t;
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
        if (!ReferenceEquals(l, _link) || _wireItem != id) return;   // not the item on the wire any more (cancelled or refused meanwhile)
        _wireItem = null;
        _busy = false;
        if (ok && _out.Find(x => x.Item.Id == id) is { } o && o.Item.State.Kind != ItemStateKind.Delivered)
        {
            o.Item = o.Item with { State = ItemState.Sent };
            Emit(new SessionEvent.Outgoing(o.Item));
        }
        Pump();
    }
}
