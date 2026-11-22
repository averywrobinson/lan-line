namespace LanLine.Core;

/// <summary>
/// The window's bookkeeping for paired computers, kept out of the UI so it can be tested (beta.8 fix; same as the Mac's
/// PairingBook.swift). A partner's id changes once, from a placeholder ("pairing-…", "legacy-…") to its device id, when its
/// hello says so. Hub events are delivered asynchronously, so events already on their way still carry the old id: every event
/// goes through Resolve, and a pairing in progress finishes on Connected whichever id that event carries.
/// </summary>
public sealed class PairingBook(DeviceConfig config)
{
    public DeviceConfig Config { get; } = config;
    /// <summary>The computer being paired right now, not saved until it connects.</summary>
    public Partner? Pending { get; private set; }
    readonly Dictionary<string, string> _aliases = [];

    /// <summary>What the app must do after an event, in this order.</summary>
    public abstract record Effect
    {
        public sealed record Save : Effect;
        public sealed record HubRemove(string Id) : Effect;
        public sealed record HubRename(string Old, string New) : Effect;
        public sealed record Finished(Partner Partner) : Effect;
        public sealed record RenamedLocally(string Old, string New) : Effect;
    }

    public string Resolve(string id)
    {
        var cur = id;
        for (var hops = 0; hops < 16 && _aliases.TryGetValue(cur, out var next); hops++) cur = next;
        return cur;
    }

    public void Begin(Partner p) => Pending = p;

    /// <summary>Cancel the pairing in progress; returns its id (the caller removes it from the Hub).</summary>
    public string? Cancel() { var id = Pending?.Id; Pending = null; return id; }

    public List<Effect> Forget(string id) { var cur = Resolve(id); Config.Forget(cur); return [new Effect.Save(), new Effect.HubRemove(cur)]; }

    public List<Effect> Rename(string id, string name) { Config.Rename(Resolve(id), name); return [new Effect.Save()]; }

    /// <summary>Bring an event's partner ids up to date and apply what it means for the saved list.</summary>
    public (HubEvent Event, List<Effect> Effects) Handle(HubEvent ev)
    {
        var e = Mapped(ev);
        var fx = new List<Effect>();
        switch (e)
        {
            case HubEvent.PeerDevice pd when pd.Partner != pd.Device && Session.IsDeviceId(pd.Device):
                var p = pd.Partner; var d = pd.Device;
                if (Config.Partner(d) is { } old) { Config.Forget(old.Id); fx.Add(new Effect.HubRemove(old.Id)); }   // an older pairing with this computer
                if (Pending?.Id == p) Pending = Pending with { Id = d };
                var i = Config.Peers.FindIndex(x => x.Id == p);
                if (i >= 0) { Config.Peers[i] = Config.Peers[i] with { Id = d }; fx.Add(new Effect.Save()); }   // in place: order kept
                _aliases[p] = d;
                fx.Add(new Effect.HubRename(p, d));
                fx.Add(new Effect.RenamedLocally(p, d));
                return (new HubEvent.PeerDevice(d, d), fx);
            case HubEvent.Connected c:
                if (Pending is { } q && q.Id == c.Partner)
                {
                    Pending = null;
                    var done = q with { Name = c.Name };
                    try { Config.Add(done); } catch (TooManyPartnersException) { return (e, fx); }
                    fx.Add(new Effect.Save()); fx.Add(new Effect.Finished(done));
                }
                else if (Config.Partner(c.Partner) is { } k && k.Name != c.Name) { Config.Add(k with { Name = c.Name }); fx.Add(new Effect.Save()); }
                break;
            case HubEvent.Rekeyed rk:
                if (Pending?.Id == rk.Partner) Pending = Pending with { Secret = rk.Token };
                else if (Config.Partner(rk.Partner) is { } k2) { Config.Add(k2 with { Secret = rk.Token }); fx.Add(new Effect.Save()); }
                break;
            case HubEvent.PeerAddresses pa when Config.Partner(pa.Partner) is { Connects: true } q2:   // a moved partner's new address first
                var ordered = pa.Addrs.Length > 0 && (q2.Hosts.Length == 0 || q2.Hosts[0] != pa.Addrs[0]) ? pa.Addrs.Concat(q2.Hosts) : q2.Hosts.Concat(pa.Addrs);
                string[] hosts = [.. ordered.Distinct(StringComparer.OrdinalIgnoreCase).Take(6)];
                if (!hosts.SequenceEqual(q2.Hosts)) { Config.Add(q2 with { Hosts = hosts }); fx.Add(new Effect.Save()); }
                break;
        }
        return (e, fx);
    }

    HubEvent Mapped(HubEvent e) => e switch
    {
        HubEvent.Connected c => c with { Partner = Resolve(c.Partner) },
        HubEvent.Disconnected d => d with { Partner = Resolve(d.Partner) },
        HubEvent.Received r => r with { Partner = Resolve(r.Partner) },
        HubEvent.ReceiveFailed f => f with { Partner = Resolve(f.Partner) },
        HubEvent.Status s => s.Partner.Length == 0 ? s : s with { Partner = Resolve(s.Partner) },
        HubEvent.Rekeyed rk => rk with { Partner = Resolve(rk.Partner) },
        HubEvent.PeerAddresses pa => pa with { Partner = Resolve(pa.Partner) },
        HubEvent.PeerDevice pd => pd with { Partner = Resolve(pd.Partner) },
        HubEvent.Outgoing o => o with { Item = o.Item with { To = [.. o.Item.To.Select(Resolve)], States = o.Item.States.ToDictionary(kv => Resolve(kv.Key), kv => kv.Value) } },
        _ => e,
    };
}
