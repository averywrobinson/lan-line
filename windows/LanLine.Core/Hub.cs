using System.Net.WebSockets;

namespace LanLine.Core;

/// <summary>Settings for a Hub: what every partner Session shares.</summary>
public sealed class HubConfig
{
    public required string Name { get; init; }
    public required string DeviceId { get; init; }
    public required string DownloadDir { get; init; }
    public int Port { get; init; } = 47830;
    /// <summary>null = all interfaces.</summary>
    public string? BindHost { get; init; }
    public string AppVersion { get; init; } = "";
    public Updates.Available? LatestKnown { get; init; }
    public string[] Advertise { get; init; } = [];
    /// <summary>Tests: adjust every partner Session's config.</summary>
    public Func<SessionConfig, SessionConfig>? Tune { get; init; }
}

/// <summary>One outgoing item as the window shows it: to one partner or to everyone, with each partner's state.</summary>
public sealed record HubItem(string Id, Item Item, string[] To, IReadOnlyDictionary<string, ItemState> States)
{
    public int Delivered => States.Values.Count(s => s.Kind == ItemStateKind.Delivered);
    public int Total => To.Length;

    /// <summary>One state for the row: delivered when everyone has it, failed when someone refused and nobody is still busy,
    /// otherwise the least advanced state (waiting &lt; sending &lt; sent).</summary>
    public ItemState Summary
    {
        get
        {
            var s = To.Where(States.ContainsKey).Select(t => States[t]).ToList();
            if (s.Count == To.Length && s.All(x => x.Kind == ItemStateKind.Delivered)) return ItemState.Delivered;
            var busy = s.Where(x => x.Kind is not (ItemStateKind.Delivered or ItemStateKind.Failed or ItemStateKind.Cancelled)).ToList();
            var failed = s.Where(x => x.Kind == ItemStateKind.Failed).ToList();
            if (busy.Count == 0 && failed.Count > 0)
                return new ItemState(ItemStateKind.Failed, Error: To.Length > 1 ? $"{failed.Count} of {To.Length}: {failed[0].Error}" : failed[0].Error);
            if (busy.Count == 0 && s.Any(x => x.Kind == ItemStateKind.Cancelled)) return ItemState.CancelledState;
            if (s.Count < To.Length || busy.Any(x => x.Kind == ItemStateKind.Waiting)) return ItemState.Waiting;
            var sending = busy.Where(x => x.Kind == ItemStateKind.Sending).ToList();
            if (sending.Count > 0) return new ItemState(ItemStateKind.Sending, sending.Average(x => x.Progress));
            return ItemState.Sent;
        }
    }
}

public abstract record HubEvent
{
    public sealed record Listening(int Port) : HubEvent;
    public sealed record Connected(string Partner, string Name) : HubEvent;
    public sealed record Disconnected(string Partner, string Reason) : HubEvent;
    public sealed record Received(string Partner, Item Item) : HubEvent;
    public sealed record Outgoing(HubItem Item) : HubEvent;
    /// <summary>An incoming file or folder still arriving, or stopped short (beta.10).</summary>
    public sealed record Incoming(string Partner, Item Item) : HubEvent;
    /// <summary>A partner's clipboard (clipboard sharing, beta.10).</summary>
    public sealed record Clipboard(string Partner, ClipContent Content) : HubEvent;
    /// <summary>Id: the item that failed (the same id its progress card had, if it had one).</summary>
    public sealed record ReceiveFailed(string Partner, string Name, string Reason, string Id = "") : HubEvent;
    public sealed record Status(string Partner, string Text) : HubEvent;
    /// <summary>Pairing: the code was swapped for this long-term secret; save it for that partner.</summary>
    public sealed record Rekeyed(string Partner, string Token) : HubEvent;
    public sealed record PeerAddresses(string Partner, string[] Addrs) : HubEvent;
    /// <summary>The partner's real device id (its hello).</summary>
    public sealed record PeerDevice(string Partner, string Device) : HubEvent;
    public sealed record UpdateAvailable(string Version, string Url) : HubEvent;
    public sealed record Error(string Message) : HubEvent;
}

/// <summary>
/// Several partners at once (beta.7): one listener for all listening partners, routed by secret, and one dialer per partner
/// this computer connects to. Each partner gets today's two-computer Session; there is no relaying between partners.
/// Everything runs on one SerialQueue; events arrive on it.
/// </summary>
public sealed class Hub : IDisposable
{
    public HubConfig Config { get; }
    readonly SerialQueue _q = new("lan-line.hub");
    readonly Action<HubEvent> _handler;
    readonly Dictionary<string, Partner> _partners = [];
    readonly List<string> _order = [];
    readonly Dictionary<string, Session> _sessions = [];
    readonly Dictionary<string, Tag> _tags = [];
    readonly Dictionary<Link, DateTime> _pending = [];
    readonly Dictionary<string, HubItem> _items = [];
    readonly Dictionary<string, (string Hub, string Partner)> _routes = [];
    readonly HashSet<string> _up = [];
    Listener? _listener;
    DiscoveryResponder? _responder;
    Timer? _timer;
    bool _stopped;
    int? _boundPort;

    sealed class Tag(string id) { public string Id = id; }

    public Hub(HubConfig config, IEnumerable<Partner> partners, Action<HubEvent> handler)
    {
        Config = config; _handler = handler;
        foreach (var p in partners) { _partners[p.Id] = p; _order.Add(p.Id); }
    }

    public int? BoundPort => _q.Sync(() => _boundPort);
    public HashSet<string> ConnectedPartners => _q.Sync(() => new HashSet<string>(_up));

    public void Start() => _q.Post(() =>
    {
        foreach (var id in _order.ToList()) MakeSession(id, pairing: false);
        EnsureListener();
        _timer = new Timer(_ => _q.Post(DropSilent), null, 1000, 1000);
    });

    public void Stop()
    {
        var all = _q.Sync(() =>
        {
            _stopped = true;
            _timer?.Dispose(); _timer = null;
            _listener?.Stop(); _listener = null;
            _responder?.Dispose(); _responder = null;
            foreach (var l in _pending.Keys.ToList()) l.Close("stopped");
            _pending.Clear();
            return _sessions.Values.ToList();
        });
        foreach (var s in all) s.Stop();
    }

    public void Dispose() { Stop(); _q.Dispose(); }

    /// <summary>Add a partner (or replace one with the same id). pairing: this computer shows a code for it.</summary>
    public void Add(Partner p, bool pairing)
    {
        var old = _q.Sync(() =>
        {
            _sessions.Remove(p.Id, out var o);
            _partners[p.Id] = p;
            if (!_order.Contains(p.Id)) _order.Add(p.Id);
            _up.Remove(p.Id);
            return o;
        });
        var kept = old?.StopKeepingPartials();   // half-received files stay resumable across the swap
        _q.Post(() =>
        {
            if (!_stopped) { MakeSession(p.Id, pairing, kept); EnsureListener(); }
            else if (kept != null) foreach (var k in kept.Values) try { File.Delete(k.Part); } catch (Exception) { }
        });
    }

    /// <summary>The partner's name changed (it said so in its hello, or it was renamed here): with a folder per computer,
    /// what arrives from now on goes to the folder of that name. A file already arriving finishes where it started.</summary>
    public void SetName(string id, string name) => _q.Post(() => SetNameOnQueue(id, name));

    void SetNameOnQueue(string id, string name)
    {
        if (name.Length == 0 || !_partners.TryGetValue(id, out var p) || p.Name == name) return;
        _partners[id] = p with { Name = name };
        if (_perComputer && _sessions.TryGetValue(id, out var s)) s.SetDownloadDir(FolderFor(id));
    }

    /// <summary>Forget a partner: its Session stops and its secret is no longer accepted.</summary>
    public void Remove(string id)
    {
        var old = _q.Sync(() => { _partners.Remove(id); _order.Remove(id); _up.Remove(id); _sessions.Remove(id, out var o); return o; });
        old?.Stop();
        _q.Post(() => _handler(new HubEvent.Disconnected(id, "forgotten")));
    }

    /// <summary>Change a partner's id to its real device id, keeping its link.</summary>
    public void Rename(string oldId, string newId) => _q.Post(() =>
    {
        if (oldId == newId || !_partners.Remove(oldId, out var p) || _partners.ContainsKey(newId)) return;
        _partners[newId] = p with { Id = newId };
        var i = _order.IndexOf(oldId); if (i >= 0) _order[i] = newId;
        if (_sessions.Remove(oldId, out var s)) _sessions[newId] = s;
        if (_tags.Remove(oldId, out var t)) { t.Id = newId; _tags[newId] = t; }
        if (_up.Remove(oldId)) _up.Add(newId);
        foreach (var k in _routes.Where(r => r.Value.Partner == oldId).Select(r => r.Key).ToList()) _routes[k] = (_routes[k].Hub, newId);
    });

    /// <summary>An update check found a newer version: every partner Session shows it once and passes it on.</summary>
    public void NoteLatest(Updates.Available a)
    {
        foreach (var s in _q.Sync(() => _sessions.Values.ToList())) s.NoteLatest(a);
    }

    // ---------- sending

    /// <summary>Share the clipboard with every connected partner that takes it (beta.10); never queued. done gets how
    /// many it went to and how many connected partners are too old for it.</summary>
    public void SendClip(ClipContent c, Action<int, int>? done = null) => _q.Post(() =>
    {
        var ss = _order.Where(_sessions.ContainsKey).Select(id => _sessions[id]).ToList();
        int pending = ss.Count, sent = 0, old = 0;
        if (pending == 0) { done?.Invoke(0, 0); return; }
        void One() { if (Interlocked.Decrement(ref pending) == 0) done?.Invoke(sent, old); }
        foreach (var s in ss)
            s.PeerTakesClips(t =>
            {
                if (t == false) Interlocked.Increment(ref old);
                if (t == true) s.SendClip(c, ok => { if (ok) Interlocked.Increment(ref sent); One(); });
                else One();
            });
    });

    /// <summary>Where received files go (beta.10): one folder, or a folder per computer inside it; for every partner
    /// now and those added later.</summary>
    public void SetDownloads(string baseDir, bool perComputer) => _q.Post(() =>
    {
        _downloadBase = baseDir; _perComputer = perComputer;
        foreach (var (id, s) in _sessions) s.SetDownloadDir(FolderFor(id));
    });

    string? _downloadBase;
    bool _perComputer;
    string FolderFor(string id) =>
        ReceiveOptions.Folder(_downloadBase ?? Config.DownloadDir, _perComputer, _partners.TryGetValue(id, out var p) ? p.Name : id);

    /// <summary>Stop an outgoing item for everyone it is still going to (beta.10).</summary>
    public void Cancel(string hubId) => _q.Post(() =>
    {
        foreach (var (sid, r) in _routes.Where(r => r.Value.Hub == hubId).ToList())
            if (_sessions.TryGetValue(r.Partner, out var s)) s.Cancel(sid);
    });

    /// <summary>Refuse an incoming item that is still arriving from a partner (beta.10).</summary>
    public void CancelIncoming(string partner, string id) => _q.Post(() => { if (_sessions.TryGetValue(partner, out var s)) s.CancelIncoming(id); });

    public HubItem SendText(string text, string? to) =>
        FanOut(new Item("", false, text, null, text.Length, null, ItemState.Waiting), to, s => s.SendText(text));

    public HubItem SendFile(string path, string? to)
    {
        long size = -1; try { size = new FileInfo(path).Length; } catch (Exception) { }
        return FanOut(new Item("", false, null, Path.GetFileName(path), size, path, ItemState.Waiting), to, s => s.SendFile(path));
    }

    public HubItem SendFolder(string path, string? to)
    {
        var scan = Session.ScanFolder(path);
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        return FanOut(new Item("", false, null, name, scan.Size, path, ItemState.Waiting, scan.Count), to, s => s.SendFolder(path));
    }

    /// <summary>Everyone (to null) or one partner. Each partner's Session queues its own copy, so an offline partner gets it later.</summary>
    HubItem FanOut(Item template, string? to, Func<Session, Item> send)
    {
        var targets = _q.Sync(() => (to == null ? _order : [to]).Where(_sessions.ContainsKey).Select(id => (id, _sessions[id])).ToList());
        var id = Guid.NewGuid().ToString();
        var states = targets.ToDictionary(t => t.id, _ => ItemState.Waiting);
        var hub = new HubItem(id, template with { Id = id }, [.. targets.Select(t => t.id)], states);
        var sent = targets.Select(t => (t.id, send(t.Item2))).ToList();
        _q.Sync(() =>
        {
            foreach (var (pid, it) in sent) _routes[it.Id] = (id, pid);
            _items[id] = hub;
            return 0;
        });
        _q.Post(() => { if (_items.TryGetValue(id, out var h)) _handler(new HubEvent.Outgoing(h)); });
        return hub;
    }

    // ---------- sessions

    void MakeSession(string id, bool pairing, Dictionary<string, Session.Partial>? partials = null)
    {
        if (!_partners.TryGetValue(id, out var p)) return;
        var sc = new SessionConfig
        {
            Token = p.Secret, Name = Config.Name, DownloadDir = FolderFor(id), AppVersion = Config.AppVersion, LatestKnown = Config.LatestKnown,
            DeviceId = Config.DeviceId, RekeyOnPair = pairing && !p.Connects, External = !p.Connects, Advertise = p.Connects ? [] : Config.Advertise,
        };
        if (Config.Tune != null) sc = Config.Tune(sc);
        Role role = p.Connects ? new Role.Dial(p.Hosts, p.Port ?? Config.Port) : new Role.Listen(0);
        var tag = new Tag(id);
        _tags[id] = tag;
        var s = new Session(role, sc, e => FromSession(tag.Id, e), queue: _q);
        _sessions[id] = s;
        if (partials is { Count: > 0 }) s.AdoptPartials(partials);
        s.Start();
    }

    void FromSession(string id, SessionEvent e)
    {
        switch (e)
        {
            case SessionEvent.Connected c:
                _up.Add(id);
                SetNameOnQueue(id, c.Peer);   // the folder per computer follows the name the computer gives itself
                _handler(new HubEvent.Connected(id, c.Peer));
                break;
            case SessionEvent.Disconnected d: _up.Remove(id); _handler(new HubEvent.Disconnected(id, d.Reason)); break;
            case SessionEvent.Received r: _handler(new HubEvent.Received(id, r.Item)); break;
            case SessionEvent.Incoming inc: _handler(new HubEvent.Incoming(id, inc.Item)); break;
            case SessionEvent.Clipboard cb: _handler(new HubEvent.Clipboard(id, cb.Content)); break;
            case SessionEvent.Outgoing o:
                if (!_routes.TryGetValue(o.Item.Id, out var r2) || !_items.TryGetValue(r2.Hub, out var h)) return;
                var st = new Dictionary<string, ItemState>(h.States) { [r2.Partner] = o.Item.State };
                _items[r2.Hub] = h = h with { States = st };
                _handler(new HubEvent.Outgoing(h));
                break;
            case SessionEvent.ReceiveFailed f: _handler(new HubEvent.ReceiveFailed(id, f.Name, f.Reason, f.Id)); break;
            case SessionEvent.Error err: _handler(new HubEvent.Error(err.Message)); break;
            case SessionEvent.Status s: _handler(new HubEvent.Status(id, s.Text)); break;
            case SessionEvent.Rekeyed rk:
                if (_partners.TryGetValue(id, out var p)) _partners[id] = p with { Secret = rk.Token };
                _handler(new HubEvent.Rekeyed(id, rk.Token));
                break;
            case SessionEvent.PeerAddresses pa: _handler(new HubEvent.PeerAddresses(id, pa.Addrs)); break;
            case SessionEvent.PeerDevice pd: _handler(new HubEvent.PeerDevice(id, pd.Device)); break;
            case SessionEvent.UpdateAvailable ua: _handler(new HubEvent.UpdateAvailable(ua.Version, ua.Url)); break;
        }
    }

    // ---------- discovery

    /// <summary>Answer "LANLINE?1" once per listening partner (and pairing code), with this device id.</summary>
    public void StartResponder(int? port = null) => _q.Post(() =>
    {
        if (_responder != null || _stopped) return;
        try { _responder = new DiscoveryResponder(port ?? Config.Port, Config.Name, Config.DeviceId, () => _q.Sync(ListeningPairIds)); }
        catch (Exception e) { _handler(new HubEvent.Error($"discovery: {e.Message}")); }
    });

    string[] ListeningPairIds() => [.. _order.Select(id => _partners[id]).Where(p => !p.Connects).Select(p => PairCode.PairId(p.Secret))];

    /// <summary>Partners this computer dials that aren't connected: look for them (by pair id or device id), and redial a
    /// moved one at its new address, reported as PeerAddresses.</summary>
    public async Task FindMoved(int? port = null, string[]? targets = null, TimeSpan? timeout = null)
    {
        var lost = _q.Sync(() => _order.Select(id => _partners[id]).Where(p => p.Connects && !_up.Contains(p.Id)).ToList());
        if (lost.Count == 0) return;
        var found = await Discovery.SearchAsync(port ?? Config.Port, timeout, targets).ConfigureAwait(false);
        foreach (var p in lost)
        {
            var pid = PairCode.PairId(p.Secret);
            var hit = found.FirstOrDefault(f => f.PairId == pid || (f.Device != null && f.Device == p.Id));
            if (hit == null || (p.Hosts.Length > 0 && p.Hosts[0] == hit.Host)) continue;
            var q = p with { Hosts = [hit.Host, .. p.Hosts.Where(h => h != hit.Host)] };
            var old = _q.Sync(() =>
            {
                if (_stopped || _up.Contains(p.Id) || !_partners.ContainsKey(p.Id)) return null;
                _partners[p.Id] = q;
                _sessions.Remove(p.Id, out var o);
                _handler(new HubEvent.PeerAddresses(p.Id, q.Hosts));
                return o;
            });
            if (old == null) continue;
            var kept = old.StopKeepingPartials();   // a file cut off by the address change stays resumable
            _q.Post(() =>
            {
                if (!_stopped && _partners.ContainsKey(p.Id) && !_sessions.ContainsKey(p.Id)) MakeSession(p.Id, pairing: false, kept);
                else foreach (var k in kept.Values) try { File.Delete(k.Part); } catch (Exception) { }
            });
        }
    }

    // ---------- the shared listener

    void EnsureListener()
    {
        if (_listener != null || _stopped || !_partners.Values.Any(p => !p.Connects)) return;
        try
        {
            _listener = new Listener(Config.BindHost, Config.Port, (ws, peer) => _q.Post(() => Accept(ws, peer)));
            _boundPort = _listener.Port;
            _handler(new HubEvent.Listening(_listener.Port));
        }
        catch (Exception e) { _handler(new HubEvent.Error($"listen failed: {e.Message}")); }
    }

    void Accept(WebSocket ws, string peer)
    {
        if (_stopped || _pending.Count >= Session.MaxPending) { ws.Abort(); return; }   // strangers can't pile up connections
        Link? link = null;
        link = Link.Accepted(ws, peer, _q, DateTime.UtcNow, (l, ev) =>
        {
            switch (ev.Kind)
            {
                case LinkEventKind.Text: Route(l, ev.Text!); break;
                case LinkEventKind.Closed: _pending.Remove(l); break;
                case LinkEventKind.Data: l.Close("binary before hello"); break;
            }
        });
        _pending[link] = DateTime.UtcNow;
    }

    /// <summary>The first frame decides which partner this is: the listening partner whose secret the MAC matches.</summary>
    void Route(Link l, string s)
    {
        _pending.Remove(l);
        var f = Frame.Decode(s);
        if (f is not { Type: "hello" }) { l.Close("bad hello"); return; }
        if (f.V != LL2.Version)
        {
            _handler(new HubEvent.Status("", "The other computer runs an older Lan-Line. Update it to connect."));
            var v = f.V ?? 0;
            l.SendText(Frame.Upgrade.Json, _ => l.Close($"peer speaks protocol v{v}"));
            return;
        }
        foreach (var id in _order)
        {
            if (!_partners.TryGetValue(id, out var p) || p.Connects || !_sessions.TryGetValue(id, out var session) || !session.MatchesHello(f)) continue;
            session.Adopt(l, s);
            return;
        }
        l.SendText(Frame.Refused.Json, _ => l.Close("bad hello"));
    }

    void DropSilent()
    {
        foreach (var (l, t) in _pending.Where(p => DateTime.UtcNow - p.Value > TimeSpan.FromSeconds(10)).ToList())
        {
            _pending.Remove(l);
            l.Close("no hello within 10 s");
        }
    }
}
