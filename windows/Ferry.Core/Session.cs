using System.Net.WebSockets;
using System.Security.Cryptography;

namespace Ferry.Core;

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

/// <summary>A text (Text set) or a file (FileName/Path set).</summary>
public sealed record Item(string Id, bool Incoming, string? Text, string? FileName, long Size, string? Path, ItemState State)
{
    public bool IsFile => Text == null;
}

public abstract record SessionEvent
{
    public sealed record Listening(int Port) : SessionEvent;
    public sealed record Connected(string Peer) : SessionEvent;
    public sealed record Disconnected(string Reason) : SessionEvent;
    public sealed record Received(Item Item) : SessionEvent;
    public sealed record Outgoing(Item Item) : SessionEvent;
    public sealed record ReceiveFailed(string Name, string Reason) : SessionEvent;
    public sealed record Error(string Message) : SessionEvent;
    /// <summary>Diagnostics while not connected (which host is being dialed, why a dial failed).</summary>
    public sealed record Status(string Text) : SessionEvent;
}

/// <summary>
/// The one Ferry session object; the window, the headless modes and the tests all drive it.
/// All state lives on one SerialQueue thread, and the handler is called there too:
/// a UI must hop to its own thread in one place.
/// </summary>
public sealed class Session : IDisposable
{
    public Role Role { get; }
    public SessionConfig Config { get; }
    readonly SerialQueue _q = new("ferry.session");
    readonly Action<SessionEvent> _handler;
    readonly Func<DateTime> _now;

    sealed class Out { public required Item Item; public string? Sha; public bool OnWire; }
    sealed class InFile
    {
        public required string Id, Name, Sha; public long Size;
        public string? Part; public FileStream? Stream; public IncrementalHash Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public long Received; public string? Reject;
    }

    Listener? _listener;
    readonly Dictionary<Link, bool> _pending = [];
    Link? _link;
    bool _linkUp;
    Link? _dialing;
    int _hostIndex, _attempt, _redialGen;
    Timer? _timer;
    bool _stopped;

    readonly List<Out> _out = [];
    bool _busy;
    FileSend? _fileSend;   // the file currently streaming out
    const int Window = 4;  // chunks in flight: keeps a LAN busy, memory stays Window × ChunkSize

    sealed class FileSend
    {
        public required string Id; public required FileStream Fs; public long Size; public required Link Link;
        public int InFlight; public long SentBytes; public bool Eof; public int LastStep = -1;
    }
    InFile? _in;
    readonly HashSet<string> _done = [];
    DateTime _lastHeard, _lastBeat;

    public Session(Role role, SessionConfig config, Action<SessionEvent> handler, Func<DateTime>? clock = null)
    {
        Role = role; Config = config; _handler = handler; _now = clock ?? (() => DateTime.UtcNow);
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
        _q.Post(() =>
        {
            Enqueue(new Out { Item = item });
            Task.Run(() => Hashing.Sha256File(path)).ContinueWith(t => _q.Post(() => Hashed(item.Id, t)));
        });
        return item;
    }

    public bool IsConnected => _q.Sync(() => _linkUp);

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
                if (ReferenceEquals(l, _dialing)) l.SendText(Frame.Hello(Config.Token, Config.Name).Json);
                break;
            case LinkEventKind.Closed:
                _pending.Remove(l);
                if (ReferenceEquals(l, _dialing)) { _dialing = null; Emit(new SessionEvent.Status(ev.Reason ?? "dial failed")); ScheduleRedial(afterFailure: true); }
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
        if (f is not { Type: "hello" } || f.V != Frame.ProtocolVersion || f.Token is null || !Secrets.Equal(f.Token, Config.Token))
        {
            l.Close("bad hello");
            return;
        }
        if (_link is { } old)   // a new authenticated peer replaces the old one
        {
            LinkDown("replaced by a new connection");
            old.Close("replaced");
        }
        l.SendText(Frame.HelloOk(Config.Name).Json);
        BecomeUp(l, f.Name ?? l.Peer);
    }

    void HandleHelloOk(string s, Link l)
    {
        var f = Frame.Decode(s);
        if (f is not { Type: "hello_ok" }) { l.Close("expected hello_ok"); return; }
        _dialing = null;
        _attempt = 0;
        BecomeUp(l, f.Name ?? l.Peer);
    }

    void BecomeUp(Link l, string peer)
    {
        _link = l;
        _linkUp = true;
        _lastHeard = _lastBeat = _now();
        Emit(new SessionEvent.Connected(peer));
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
                BeginFile(f.Id, f.Name ?? "file", f.Size ?? -1, (f.Sha256 ?? "").ToLowerInvariant());
                break;
            case "file_end" when f.Id != null && _in is { } file && file.Id == f.Id:
                _in = null;
                FinishFile(file, l);
                break;
            case "ack" when f.Id != null:
                var i = _out.FindIndex(o => o.Item.Id == f.Id);
                if (i < 0) return;
                var done = _out[i];
                _out.RemoveAt(i);
                var st = f.Ok == true ? ItemState.Delivered : new ItemState(ItemStateKind.Failed, Error: f.Err ?? "rejected");
                Emit(new SessionEvent.Outgoing(done.Item with { State = st }));
                break;
        }
    }

    long? FreeSpace()
    {
        if (Config.FreeSpaceOverride is { } o) return o;
        try { Directory.CreateDirectory(Config.DownloadDir); return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Config.DownloadDir))!).AvailableFreeSpace; }
        catch (Exception) { return null; }
    }

    void BeginFile(string id, string raw, long size, string sha)
    {
        var name = Names.Sanitize(raw);
        var f = new InFile { Id = id, Name = name, Sha = sha, Size = size };
        if (size < 0 || size > Config.MaxFileSize) f.Reject = "too big or bad size";
        else if (FreeSpace() is { } free && size + Config.DiskReserve > free) f.Reject = $"not enough disk space ({free / 1e9:0.0} GB free)";
        else if (sha.Length != 64 || !sha.All(Uri.IsHexDigit)) f.Reject = "bad sha256";
        else
        {
            try
            {
                Directory.CreateDirectory(Config.DownloadDir);
                f.Part = Path.Combine(Config.DownloadDir, $".{name}.{Guid.NewGuid().ToString("N")[..8]}.part");
                f.Stream = new FileStream(f.Part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16);
            }
            catch (Exception e) { f.Reject = $"cannot write: {e.Message}"; }
        }
        _in = f;
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

    void FinishFile(InFile f, Link l)
    {
        var reason = f.Reject;
        if (reason == null && f.Received != f.Size) reason = "size mismatch";
        var digest = Convert.ToHexStringLower(f.Hasher.GetHashAndReset());
        if (reason == null && digest != f.Sha) reason = "sha256 mismatch";
        try { f.Stream?.Dispose(); } catch (Exception) { }
        f.Stream = null;
        if (reason != null)
        {
            DropPart(f);
            l.SendText(Frame.Ack(f.Id, false, reason).Json);
            Emit(new SessionEvent.ReceiveFailed(f.Name, reason));
            return;
        }
        if (f.Part is not { } part) return;
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
        if (t.IsCompletedSuccessfully) o.Sha = t.Result;
        else
        {
            _out.Remove(o);
            var why = t.Exception?.InnerException?.Message ?? "unknown";
            Emit(new SessionEvent.Outgoing(o.Item with { State = new ItemState(ItemStateKind.Failed, Error: $"cannot read: {why}") }));
        }
        Pump();
    }

    /// <summary>Put the next queued item on the wire: one item at a time, in order.</summary>
    void Pump()
    {
        if (!_linkUp || _busy || _link is not { } l) return;
        var o = _out.Find(x => !x.OnWire);
        if (o == null || o.Sha == null) return;   // nothing queued, or first in line is still hashing
        o.OnWire = true;
        _busy = true;
        var item = o.Item;
        if (!item.IsFile)
        {
            l.SendText(Frame.TextItem(item.Id, item.Text!).Json, ok => Wrote(item.Id, l, ok));
            return;
        }
        FileStream fs;
        long size;
        try
        {
            fs = new FileStream(item.Path!, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
            size = fs.Length;
        }
        catch (Exception e)
        {
            _out.Remove(o);
            _busy = false;
            Emit(new SessionEvent.Outgoing(item with { State = new ItemState(ItemStateKind.Failed, Error: $"cannot read: {e.Message}") }));
            Pump();
            return;
        }
        l.SendText(Frame.FileBegin(item.Id, item.FileName!, size, o.Sha).Json);
        _fileSend = new FileSend { Id = item.Id, Fs = fs, Size = size, Link = l };
        FillWindow(_fileSend);
    }

    void FillWindow(FileSend f)
    {
        if (!ReferenceEquals(f, _fileSend) || !ReferenceEquals(f.Link, _link) || !_linkUp) return;   // resent later
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
            f.InFlight++;
            f.Link.SendData(chunk, ok =>
            {
                f.InFlight--;
                if (!ok || !ReferenceEquals(f, _fileSend)) return;
                f.SentBytes += chunk.Length;
                var step = f.Size > 0 ? (int)(f.SentBytes * 20 / f.Size) : 20;   // progress in 5 % steps
                if (step != f.LastStep && _out.Find(x => x.Item.Id == f.Id) is { } o)
                {
                    f.LastStep = step;
                    o.Item = o.Item with { State = new ItemState(ItemStateKind.Sending, (double)f.SentBytes / Math.Max(f.Size, 1)) };
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
            l.SendText(Frame.FileEnd(f.Id).Json, ok => Wrote(f.Id, l, ok));
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
