// LanLine.Tests: a plain console test runner (no NuGet). `dotnet run --project LanLine.Tests` runs every test;
// `... -- headless|selftest <options>` runs the shared headless modes instead (same as Lan-Line.exe --headless).
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LanLine.Core;

if (args.Length > 0 && (args[0] == "headless" || args[0] == "selftest" || args[0] == "check-updates"))
    return Headless.Run(["--" + args[0], .. args[1..]]);

if (args.Length >= 3 && args[0] == "tcpread")   // diagnostics: read a raw TCP stream to EOF and time it
{
    using var tc = new System.Net.Sockets.TcpClient();
    await tc.ConnectAsync(args[1], int.Parse(args[2]));
    var st = tc.GetStream();
    if (args.Length == 4 && args[3] == "upgrade")   // look like a WebSocket client first
        await st.WriteAsync(Encoding.ASCII.GetBytes($"GET /lan-line HTTP/1.1\r\nHost: {args[1]}:{args[2]}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")); var b = new byte[1 << 16]; long n = 0; var w = Stopwatch.StartNew(); int k;
    while ((k = await st.ReadAsync(b)) > 0) n += k;
    Console.WriteLine($"tcpread {n} bytes in {w.Elapsed.TotalSeconds:0.000} s = {n / w.Elapsed.TotalSeconds / 1e6:0.0} MB/s");
    return 0;
}

var tests = new List<(string Name, Func<Task> Body)>
{
    ("sanitize", T.Sanitize), ("unique names", T.UniqueNames), ("constant-time equal", T.ConstantTime),
    ("frame round trip", T.FrameRoundTrip), ("hello ok", T.HelloOk), ("bad token closed", T.BadToken),
    ("hello timeout", T.HelloTimeout), ("text both ways", T.TextBothWays), ("duplicate id once", T.DuplicateOnce),
    ("50 MB both ways", T.LargeFileBothWays), ("same name suffix", T.SameNameSuffix), ("bad name sanitized", T.BadName),
    ("sha mismatch rejected", T.ShaMismatch), ("oversize and short rejected", T.OversizeShort),
    ("dead link after 45 s", T.DeadLink), ("queued before first connect", T.QueuedBeforeConnect),
    ("queue drained after reconnect", T.QueueAfterReconnect), ("drop mid-file resends", T.DropMidFile),
    ("new peer replaces old", T.NewPeerReplaces), ("outbox: waiting items survive a restart, in order", T.OutboxRestart),
    ("outbox: everyone keeps only those still waiting", T.OutboxEveryone), ("outbox: a file gone since fails, not sent", T.OutboxGone),
    ("outbox: forgetting a partner drops what it was owed", T.OutboxForget), ("outbox: a replaced session keeps the queue", T.OutboxReplaced),
    ("outbox: sweep keeps what the outbox needs", T.OutboxSweep), ("outbox: fast answers are never lost", T.OutboxFastAnswers), ("outbox: an unanswered item isn't saved or sent again", T.OutboxUnanswered), ("outbox: re-pairing keeps what was owed", T.OutboxRePair), ("send-only peer: queue waits for the app", T.SendOnlyPeer), ("pair codes", T.PairCodes),
    ("discovery reply round trip", T.DiscoveryReply), ("discovery over loopback", T.DiscoveryLoopback),
    ("config save round trip", T.ConfigSave), ("not enough disk space", T.DiskSpace), ("pairing code swapped for long secret", T.Rekey), ("storage cleanup rules", T.StorageRules), ("listener addresses reach dialer", T.PeerAddrs),
    ("v2 shared test vectors", T.CryptoVectors), ("v2 handshake refusals", T.HandshakeRefusals),
    ("v2 channel tamper, replay, reorder", T.ChannelTamper), ("v2 nothing readable on the wire", T.WireCapture),
    ("v2 live link closes on tamper or plaintext", T.LiveTamper), ("v2 dialer with wrong secret refused", T.WrongSecretDialer),
    ("too big refused before hashing", T.TooBigEarly), ("over sanity bound refused", T.OverBound), ("beta.5 peers still get files", T.OldPeers),
    ("folder both ways and clash", T.FolderBothWays), ("large folder tree", T.LargeTree), ("folder links skipped", T.FolderLinks),
    ("folder too big refused up front", T.FolderTooBig), ("folder to beta.5 peer says update", T.FolderOldPeer), ("folder path escape refused", T.FolderEscape),
    ("version parse and order", T.VersionOrder), ("update url allowlist", T.UrlAllowlist), ("welcome tour wording and rules", T.TourRules), ("signed update: Mac-signed fixture verifies", T.SignedFixture), ("signed update: refusals", T.SignedRefusals), ("signed update: download must match", T.SignedDownload), ("version.json parse", T.VersionJson),
    ("failed update checks are quiet", T.ChecksQuiet), ("auto update check off by default", T.AutoOff),
    ("peer relays newer version", T.PeerRelay), ("peer version alone links release page", T.PeerVersionOnly), ("peer can't push bad links", T.PeerBadLinks),
    ("config migrates single pairing", T.CfgMigrate), ("config add, forget, rename, cap", T.CfgAddForget),
    ("hub triangle and everyone", T.HubTriangle), ("hub wrong secret refused", T.HubWrongSecret), ("hub same partner replaces only itself", T.HubReplace),
    ("hub offline partner gets queued items", T.HubOffline), ("hub pairing adds a partner, forget drops it", T.HubPairing),
    ("hub discovery answers per partner", T.HubResponder), ("hub finds a moved partner", T.HubFindMoved),
    ("pairing: connected with old id after rename finishes", T.PbOldId), ("pairing: connected before peerDevice", T.PbConnectedFirst),
    ("pairing: late rekey reaches renamed partner", T.PbLateRekey), ("pairing: same computer again replaces it", T.PbRePair),
    ("pairing: legacy partner learns device id", T.PbLegacy), ("pairing through hubs with async delivery", T.PbHubs),
    ("stage: args checked", T.StageArgs), ("stage: pipe hands paths over", T.StagePipe), ("glass opacity setting", T.GlassOpacity), ("keep running when closed setting", T.KeepRunning), ("arrival notices", T.ArrivalNotices), ("notice links and pipe", T.NoticeLinks), ("unread badge and sign-in value", T.UnreadAndSignIn), ("preview kinds and paging", T.PreviewKinds), ("transfer rate", T.TransferRates), ("progress and cancel: incoming progress", T.IncomingProgress), ("progress and cancel: small file no card", T.SmallFileNoCard), ("progress and cancel: sender cancels", T.SenderCancels), ("progress and cancel: sender cancels, old receiver", T.SenderCancelsOldReceiver), ("progress and cancel: receiver cancels", T.ReceiverCancels), ("progress and cancel: queued item", T.CancelQueued), ("progress and cancel: folder either side", T.FolderCancel), ("shortcuts", T.Shortcuts), ("sounds", T.Sounds), ("history and search", T.HistoryAndSearch), ("beta.10 sorts after beta.9", T.TwoDigitBeta), ("clipboard sharing: rules", T.ClipRulesTest), ("clipboard sharing: round trip, never queued", T.ClipRoundTrip), ("clipboard sharing: old partner", T.ClipOldPartner), ("clipboard sharing: during a file", T.ClipMidFile), ("receive options", T.ReceiveOptionsTest), ("receive options: session switches folder", T.SessionSwitchesFolder), ("resume: from where it stopped", T.ResumeWhereStopped), ("resume: older receiver starts over", T.ResumeOldReceiver), ("resume: older sender starts over", T.ResumeOldSender), ("resume: damaged partial caught", T.ResumeDamaged), ("smart items", T.SmartItems), ("pair link", T.PairLinkTest), ("link launch reads no other flags", T.LinkLaunchArgs), ("a big first message from a stranger is dropped", T.BigFirstMessage),
    ("review: folder cancelled between files starts one next item", T.ReviewFolderCancelGap), ("review: finishes where it started", T.ReviewFinishesWhereStarted),
    ("review: resume refused without room", T.ReviewResumeNoRoom), ("review: orphan parts swept", T.ReviewOrphans),
    ("review: kept partial survives a session swap", T.ReviewPartialSurvivesSwap), ("review: stop deletes kept partials", T.ReviewStopDeletesPartials),
    ("review: resend of a saved item shows no card", T.ReviewResendNoCard), ("review: failures name their item", T.ReviewFailureIds),
    ("review: folder per computer follows the name", T.ReviewHubFolderName), ("review: burst caps opens and reveals", T.ReviewBurst), ("review: toast text is valid XML", T.ReviewToastXml), ("qr code", T.QrCodeTest),
};
var filter = args.Length > 0 ? args[0] : null;
int pass = 0, fail = 0;
var sw = Stopwatch.StartNew();
foreach (var (name, body) in tests)
{
    if (filter != null && !name.Contains(filter)) continue;
    var t = Stopwatch.StartNew();
    try
    {
        var run = body();
        if (await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(90))) != run) throw new TimeoutException("test took over 90 s");
        await run;
        pass++;
        Console.WriteLine($"PASS {name} ({t.Elapsed.TotalSeconds:0.00} s)");
    }
    catch (Exception e)
    {
        fail++;
        Console.WriteLine($"FAIL {name}: {e.GetType().Name}: {e.Message}");
    }
}
Console.WriteLine($"{pass} passed, {fail} failed in {sw.Elapsed.TotalSeconds:0.0} s");
return fail == 0 ? 0 : 1;

sealed class Recorder
{
    readonly ConcurrentQueue<SessionEvent> _events = new();
    /// <summary>Runs on the session queue for every event (tests use it to act at an exact moment).</summary>
    public Action<SessionEvent>? Hook;
    public void Add(SessionEvent e) { _events.Enqueue(e); Hook?.Invoke(e); }
    public List<SessionEvent> All => [.. _events];
    public int? Port => All.OfType<SessionEvent.Listening>().Select(l => (int?)l.Port).FirstOrDefault();
    public int Connects => All.OfType<SessionEvent.Connected>().Count();
    public List<string> Disconnects => All.OfType<SessionEvent.Disconnected>().Select(d => d.Reason).ToList();
    public List<Item> Received => All.OfType<SessionEvent.Received>().Select(r => r.Item).ToList();
    public List<string> ReceiveFailures => All.OfType<SessionEvent.ReceiveFailed>().Select(r => r.Reason).ToList();
    public List<string> ReceiveFailureIds => All.OfType<SessionEvent.ReceiveFailed>().Select(r => r.Id).ToList();
    public List<ItemState> Incoming(string id) => All.OfType<SessionEvent.Incoming>().Where(i => i.Item.Id == id).Select(i => i.Item.State).ToList();
    public ItemState? LastState(string id) => All.OfType<SessionEvent.Outgoing>().LastOrDefault(o => o.Item.Id == id)?.Item.State;
    public bool Delivered(string id) => LastState(id)?.Kind == ItemStateKind.Delivered;
}

sealed class FakeClock
{
    long _ticks = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc).Ticks;
    public DateTime Now() => new(Interlocked.Read(ref _ticks), DateTimeKind.Utc);
    public void Advance(double s) => Interlocked.Add(ref _ticks, TimeSpan.FromSeconds(s).Ticks);
}

/// <summary>A raw protocol v2 client: Hello runs the handshake, then Send/Next go through the encrypted channel.</summary>
sealed class RawClient : IDisposable
{
    readonly ClientWebSocket _ws = new();
    public SecureChannel? Channel;
    public static async Task<RawClient> Connect(int port)
    {
        var c = new RawClient();
        await c._ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/lan-line"), CancellationToken.None);
        return c;
    }
    /// <summary>A text frame in the clear, whatever the state (tests of what the listener refuses).</summary>
    public Task SendPlain(Frame f) => _ws.SendAsync(Encoding.UTF8.GetBytes(f.Json), WebSocketMessageType.Text, true, CancellationToken.None);
    public Task SendPlain(byte[] d) => _ws.SendAsync(d, WebSocketMessageType.Binary, true, CancellationToken.None);
    public Task Send(Frame f) => Channel is { } ch ? SendPlain(ch.Seal(ChannelKind.Control, Encoding.UTF8.GetBytes(f.Json))!) : SendPlain(f);
    public Task Send(byte[] d) => Channel is { } ch ? SendPlain(ch.Seal(ChannelKind.Chunk, d)!) : SendPlain(d);
    /// <summary>Next control frame; null if the socket closed. Chunks read as "binary", unopenable messages as "undecryptable".</summary>
    public async Task<Frame?> Next(double timeout = 5)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
            var buf = new byte[1 << 16];
            var ms = new MemoryStream();
            while (true)
            {
                var r = await _ws.ReceiveAsync(buf, cts.Token);
                if (r.MessageType == WebSocketMessageType.Close) return null;
                ms.Write(buf, 0, r.Count);
                if (!r.EndOfMessage) continue;
                var data = ms.ToArray();
                if (r.MessageType == WebSocketMessageType.Text) return Frame.Decode(Encoding.UTF8.GetString(data)) ?? new Frame { Type = "garbage" };
                if (Channel is not { } ch) return new Frame { Type = "binary" };
                if (ch.Open(data) is not { } m) return new Frame { Type = "undecryptable" };
                return m.Kind == ChannelKind.Chunk ? new Frame { Type = "binary" } : Frame.Decode(Encoding.UTF8.GetString(m.Payload)) ?? new Frame { Type = "garbage" };
            }
        }
        catch (OperationCanceledException) { return new Frame { Type = "timeout" }; }
        catch (Exception) { return null; }
    }
    public async Task<Frame?> NextNonBeat(double timeout = 5)
    {
        while (true) { var f = await Next(timeout); if (f?.Type != "beat") return f; }
    }
    /// <summary>The v2 handshake. A hello_ok whose MAC doesn't check out comes back as type "badmac".</summary>
    public async Task<Frame?> Hello(string? token = null, string name = "raw")
    {
        var hs = new DialerHandshake(token ?? H.Token, name);
        await SendPlain(hs.Hello);
        var reply = await NextNonBeat();
        if (reply is { Type: "hello_ok" })
        {
            if (hs.Finish(reply) is not { } ch) return new Frame { Type = "badmac" };
            Channel = ch;
        }
        return reply;
    }
    public void Dispose() { try { _ws.Abort(); } catch (Exception) { } _ws.Dispose(); }
}

/// <summary>A TCP relay that records every byte both ways: what someone on the network would see.</summary>
sealed class TapProxy : IDisposable
{
    readonly System.Net.Sockets.TcpListener _l = new(System.Net.IPAddress.Loopback, 0);
    readonly MemoryStream _bytes = new();
    public int Port { get; }
    public byte[] Captured { get { lock (_bytes) return _bytes.ToArray(); } }
    public TapProxy(int target)
    {
        _l.Start();
        Port = ((System.Net.IPEndPoint)_l.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            while (true)
            {
                System.Net.Sockets.TcpClient c;
                try { c = await _l.AcceptTcpClientAsync(); } catch (Exception) { return; }
                var u = new System.Net.Sockets.TcpClient();
                await u.ConnectAsync(System.Net.IPAddress.Loopback, target);
                _ = Pump(c.GetStream(), u.GetStream()); _ = Pump(u.GetStream(), c.GetStream());
            }
        });
    }
    async Task Pump(Stream from, Stream to)
    {
        var buf = new byte[65536];
        try
        {
            int n;
            while ((n = await from.ReadAsync(buf)) > 0)
            {
                lock (_bytes) _bytes.Write(buf, 0, n);
                await to.WriteAsync(buf.AsMemory(0, n));
            }
        }
        catch (Exception) { }
        try { to.Close(); } catch (Exception) { }
    }
    public void Dispose() => _l.Stop();
}

static class H
{
    public static readonly string Token = string.Concat(Enumerable.Repeat("ab", 32));

    public static string TempDir(string tag)
    {
        var d = Path.Combine(Path.GetTempPath(), $"lan-line-test-{tag}-{Guid.NewGuid().ToString("N")[..6]}");
        Directory.CreateDirectory(d);
        return d;
    }

    public static SessionConfig Cfg(string tag, bool timer = true) => new()
    {
        Token = Token, Name = tag, DownloadDir = TempDir(tag), Backoff = [0.2, 0.4], DialTimeout = TimeSpan.FromSeconds(2),
        TickInterval = timer ? TimeSpan.FromSeconds(1) : TimeSpan.Zero,
    };

    public static async Task Until(Func<bool> cond, string what, double timeout = 10)
    {
        var end = DateTime.UtcNow.AddSeconds(timeout);
        while (DateTime.UtcNow < end) { if (cond()) return; await Task.Delay(20); }
        throw new Exception($"timed out waiting for {what}");
    }

    public static async Task<(Session S, Recorder R, int Port)> Listener(string tag, SessionConfig? cfg = null, FakeClock? clock = null, int port = 0)
    {
        var r = new Recorder();
        var s = new Session(new Role.Listen(port, "127.0.0.1"), cfg ?? Cfg(tag), r.Add, clock == null ? null : clock.Now);
        s.Start();
        await Until(() => r.Port != null, "listening", 5);
        return (s, r, r.Port!.Value);
    }

    public static (Session S, Recorder R) Dialer(string tag, int port, SessionConfig? cfg = null)
    {
        var r = new Recorder();
        var s = new Session(new Role.Dial(["127.0.0.1"], port), cfg ?? Cfg(tag), r.Add);
        s.Start();
        return (s, r);
    }

    public static string RandomFile(string dir, string name, int bytes)
    {
        var p = Path.Combine(dir, name);
        using var fs = File.Create(p);
        var buf = new byte[1 << 20];
        for (var left = bytes; left > 0; left -= buf.Length)
        {
            RandomNumberGenerator.Fill(buf);
            fs.Write(buf, 0, Math.Min(left, buf.Length));
        }
        return p;
    }

    public static string Sha(byte[] d) => Convert.ToHexStringLower(SHA256.HashData(d));

    public static void Eq<T>(T expected, T actual, string what)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"{what}: expected <{expected}>, got <{actual}>");
    }
    public static void True(bool c, string what) { if (!c) throw new Exception(what); }
    public static string[] Parts(string dir) => Directory.GetFiles(dir, "*.part");
}

static class T
{
    public static Task Sanitize()
    {
        H.Eq("passwd", Names.Sanitize("../../etc/passwd"), "unix traversal");
        H.Eq("win.ini", Names.Sanitize("..\\..\\Windows\\win.ini"), "windows traversal");
        H.Eq("file", Names.Sanitize(".."), "dots only");
        H.Eq("file", Names.Sanitize(""), "empty");
        H.Eq("hidden", Names.Sanitize(".hidden"), "leading dot");
        H.Eq("a.b.txt", Names.Sanitize("a..b.txt"), "double dot");
        H.Eq("control.png", Names.Sanitize("con<>:\"|?*trol\u0007.png"), "bad chars");
        H.Eq("photo 1.jpg", Names.Sanitize("photo 1.jpg"), "space kept");
        H.Eq("trailing", Names.Sanitize("trailing. "), "trailing dot/space");
        H.Eq("_CON.txt", Names.Sanitize("CON.txt"), "reserved device name");
        var longName = Names.Sanitize(new string('x', 500) + ".txt");
        H.True(longName.Length <= 200 && longName.EndsWith(".txt"), "long name capped with extension kept");
        return Task.CompletedTask;
    }

    public static Task UniqueNames()
    {
        var d = H.TempDir("unique");
        H.Eq("a.txt", Path.GetFileName(Names.Unique("a.txt", d)), "first");
        File.WriteAllText(Path.Combine(d, "a.txt"), "");
        H.Eq("a (2).txt", Path.GetFileName(Names.Unique("a.txt", d)), "second");
        File.WriteAllText(Path.Combine(d, "a (2).txt"), "");
        H.Eq("a (3).txt", Path.GetFileName(Names.Unique("a.txt", d)), "third");
        File.WriteAllText(Path.Combine(d, "noext"), "");
        H.Eq("noext (2)", Path.GetFileName(Names.Unique("noext", d)), "no extension");
        return Task.CompletedTask;
    }

    public static Task ConstantTime()
    {
        H.True(Secrets.Equal(H.Token, H.Token), "same");
        H.True(!Secrets.Equal(H.Token, H.Token[..^1] + "c"), "last char differs");
        H.True(!Secrets.Equal(H.Token, H.Token[..^1]), "shorter");
        H.True(!Secrets.Equal("", H.Token), "empty");
        var t = Secrets.NewToken();
        H.True(t.Length == 64 && t.All(Uri.IsHexDigit) && t != Secrets.NewToken(), "new token");
        return Task.CompletedTask;
    }

    public static Task FrameRoundTrip()
    {
        var f = Frame.FileBegin("1", "a.txt", 5, "00");
        H.Eq(f, Frame.Decode(f.Json), "round trip");
        H.True(!Frame.Beat.Json.Contains("null"), "nulls left out");
        H.True(Frame.Decode("not json") == null, "garbage");
        // a frame exactly as the Mac encodes it
        var mac = Frame.Decode("{\"id\":\"x\",\"ok\":false,\"err\":\"sha256 mismatch\",\"type\":\"ack\"}");
        H.True(mac is { Type: "ack", Ok: false, Err: "sha256 mismatch" }, "mac ack");
        return Task.CompletedTask;
    }

    public static async Task HelloOk()
    {
        var (s, r, port) = await H.Listener("hello");
        using var _ = s;
        using var c = await RawClient.Connect(port);
        var reply = await c.Hello();
        H.Eq("hello_ok", reply?.Type, "reply");
        H.Eq("hello", reply?.Name, "name");
        await H.Until(() => r.Connects == 1, "connected");
    }

    public static async Task BadToken()
    {
        var (s, r, port) = await H.Listener("badtoken");
        using var _ = s;
        foreach (var bad in new[] { string.Concat(Enumerable.Repeat("cd", 32)), "short", "" })
        {
            using var c = await RawClient.Connect(port);
            var reply = await c.Hello(bad, "evil");
            H.True(reply is { Type: "error", Err: "auth" } && c.Channel == null, $"refused for token '{bad}', got {reply}");
            H.True(await c.Next() == null, $"socket should close for token '{bad}'");
        }
        using (var c = await RawClient.Connect(port))   // a v1 hello, even with the right secret: "upgrade", then closed
        {
            await c.SendPlain(Frame.LegacyHello(H.Token, "beta4"));
            var up = await c.Next();
            H.True(up is { Type: "error", Err: "upgrade", V: 2 }, $"upgrade error, got {up}");
            H.True(await c.Next() == null, "closed after upgrade");
        }
        using (var c = await RawClient.Connect(port))
        {
            await c.SendPlain(Frame.TextItem("x", "hi"));
            H.True(await c.Next() == null, "non-hello first frame closes");
        }
        H.Eq(0, r.Connects, "no connects");
        H.Eq(0, r.Received.Count, "nothing received");
    }

    public static async Task HelloTimeout()
    {
        var clock = new FakeClock();
        var (s, _, port) = await H.Listener("hellotimeout", H.Cfg("hellotimeout", timer: false), clock);
        using var __ = s;
        using var c = await RawClient.Connect(port);
        await Task.Delay(300);
        clock.Advance(11);
        s.Tick();
        H.True(await c.Next() == null, "silent client dropped after 10 s");
    }

    public static async Task TextBothWays()
    {
        var (srv, sr, port) = await H.Listener("textsrv");
        using var _ = srv;
        var (cli, cr) = H.Dialer("textcli", port);
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        var a = cli.SendText("hello Mac\nline two");
        var b = srv.SendText("hello PC 👋");
        await H.Until(() => sr.Received.Count == 1 && cr.Received.Count == 1, "texts");
        H.Eq("hello Mac\nline two", sr.Received[0].Text, "to listener");
        H.Eq("hello PC 👋", cr.Received[0].Text, "to dialer");
        await H.Until(() => cr.Delivered(a.Id) && sr.Delivered(b.Id), "acks");
    }

    public static async Task DuplicateOnce()
    {
        var (s, r, port) = await H.Listener("dup");
        using var _ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        await c.Send(Frame.TextItem("same", "once"));
        H.Eq("ack", (await c.NextNonBeat())?.Type, "first ack");
        await c.Send(Frame.TextItem("same", "once"));
        H.Eq(true, (await c.NextNonBeat())?.Ok, "second ack ok");
        await Task.Delay(200);
        H.Eq(1, r.Received.Count, "delivered once");
    }

    public static async Task LargeFileBothWays()
    {
        var (srv, sr, port) = await H.Listener("bigsrv");
        using var _ = srv;
        var (cli, cr) = H.Dialer("bigcli", port);
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        var src = H.TempDir("bigsrc");
        var up = H.RandomFile(src, "up.bin", 50 << 20);
        var down = H.RandomFile(src, "down.bin", 50 << 20);
        var a = cli.SendFile(up);
        var b = srv.SendFile(down);
        await H.Until(() => cr.Delivered(a.Id) && sr.Delivered(b.Id), "files delivered", 60);
        var got1 = sr.Received.Single(); var got2 = cr.Received.Single();
        H.Eq("up.bin", got1.FileName, "name 1"); H.Eq("down.bin", got2.FileName, "name 2");
        H.Eq(50L << 20, got1.Size, "size 1");
        H.Eq(Hashing.Sha256File(up), Hashing.Sha256File(got1.Path!), "sha up");
        H.Eq(Hashing.Sha256File(down), Hashing.Sha256File(got2.Path!), "sha down");
        H.True(cr.All.OfType<SessionEvent.Outgoing>().Any(o => o.Item.Id == a.Id && o.Item.State.Kind == ItemStateKind.Sending), "progress reported");
        H.Eq(0, H.Parts(srv.Config.DownloadDir).Length, "no part files");
    }

    public static async Task SameNameSuffix()
    {
        var (srv, sr, port) = await H.Listener("samename");
        using var _ = srv;
        var (cli, cr) = H.Dialer("samenamecli", port);
        using var __ = cli;
        await H.Until(() => cr.Connects == 1, "connected");
        var f = H.RandomFile(H.TempDir("samesrc"), "note.txt", 1000);
        cli.SendFile(f); cli.SendFile(f);
        await H.Until(() => sr.Received.Count == 2, "two files");
        H.Eq("note.txt|note (2).txt", string.Join("|", sr.Received.Select(i => i.FileName)), "names");
    }

    public static async Task BadName()
    {
        var (s, r, port) = await H.Listener("badname");
        using var _ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        var body = Encoding.UTF8.GetBytes("not really a passwd file");
        await c.Send(Frame.FileBegin("f1", "../../../etc/..\\passwd", body.Length, H.Sha(body)));
        await c.Send(body);
        await c.Send(Frame.FileEnd("f1"));
        H.Eq(true, (await c.NextNonBeat())?.Ok, "ack ok");
        await H.Until(() => r.Received.Count == 1, "saved");
        var item = r.Received[0];
        H.Eq("passwd", item.FileName, "name");
        H.Eq(Path.GetFullPath(s.Config.DownloadDir), Path.GetDirectoryName(Path.GetFullPath(item.Path!)), "inside download dir");
        H.True(File.ReadAllBytes(item.Path!).SequenceEqual(body), "content");
    }

    public static async Task ShaMismatch()
    {
        var (s, r, port) = await H.Listener("badsha");
        using var _ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        var body = Enumerable.Repeat((byte)7, 300_000).ToArray();
        await c.Send(Frame.FileBegin("f2", "x.bin", body.Length, new string('0', 64)));
        await c.Send(body[..200_000]);
        await c.Send(body[200_000..]);
        await c.Send(Frame.FileEnd("f2"));
        var ack = await c.NextNonBeat();
        H.True(ack is { Type: "ack", Ok: false, Err: "sha256 mismatch" }, $"nack, got {ack}");
        await H.Until(() => r.ReceiveFailures.SequenceEqual(["sha256 mismatch"]), "failure event", 2);
        H.Eq(0, r.Received.Count, "nothing delivered");
        H.Eq(0, Directory.GetFileSystemEntries(s.Config.DownloadDir).Length, "folder empty");
    }

    public static async Task OversizeShort()
    {
        var (s, _, port) = await H.Listener("size");
        using var __ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        var sha = new string('a', 64);
        await c.Send(Frame.FileBegin("big", "big.bin", (1L << 40) + 1, sha));
        await c.Send(Frame.FileEnd("big"));
        H.Eq(false, (await c.NextNonBeat())?.Ok, "oversize refused");
        await c.Send(Frame.FileBegin("short", "s.bin", 10, sha));
        await c.Send(new byte[5]);
        await c.Send(Frame.FileEnd("short"));
        var ack = await c.NextNonBeat();
        H.True(ack is { Ok: false, Err: "size mismatch" }, $"short refused, got {ack}");
        H.Eq(0, Directory.GetFileSystemEntries(s.Config.DownloadDir).Length, "folder empty");
    }

    public static async Task DiskSpace()
    {
        var (s, _, port) = await H.Listener("disk", new SessionConfig { Token = H.Token, Name = "disk", DownloadDir = H.TempDir("disk"), FreeSpaceOverride = 100_000 });
        using var __ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        await c.Send(Frame.FileBegin("f", "f.bin", 200_000, new string('a', 64)));
        await c.Send(Frame.FileEnd("f"));
        var ack = await c.NextNonBeat();
        H.True(ack is { Ok: false } && ack.Err!.StartsWith("not enough disk space"), $"refused for space, got {ack}");
        H.Eq(0, Directory.GetFileSystemEntries(s.Config.DownloadDir).Length, "folder empty");
    }

    public static async Task Rekey()
    {
        var lc = new SessionConfig { Token = "ABCDE12345", Name = "rk-l", DownloadDir = H.TempDir("rk-l"), RekeyOnPair = true };
        var (s, lrec, port) = await H.Listener("rk-l", lc);
        using var __ = s;
        // a real dialer presenting the code: both sides get the same 64-hex secret
        var drec = new Recorder();
        using (var d = new Session(new Role.Dial(["127.0.0.1"], port), new SessionConfig { Token = "ABCDE12345", Name = "rk-d", DownloadDir = H.TempDir("rk-d") }, drec.Add))
        {
            d.Start();
            await H.Until(() => drec.All.OfType<SessionEvent.Connected>().Any(), "dialer connected", 5);
            var lt = lrec.All.OfType<SessionEvent.Rekeyed>().Select(r => r.Token).ToList();
            var dt = drec.All.OfType<SessionEvent.Rekeyed>().Select(r => r.Token).ToList();
            H.Eq(1, lt.Count, "listener rekeyed once");
            H.True(lt.SequenceEqual(dt), "same secret on both sides");
            H.Eq(64, lt[0].Length, "64-hex secret");
        }
        var newTok = lrec.All.OfType<SessionEvent.Rekeyed>().First().Token;
        // afterwards: the new secret works (no second rekey), the code still works, a wrong code fails
        using (var c = await RawClient.Connect(port))
        {
            var ok = await c.Hello(newTok);
            H.True(ok is { Type: "hello_ok", Rekey: null }, $"new secret accepted, got {ok}");
            H.Eq("timeout", (await c.NextNonBeat(1))?.Type, "only one rekey per pairing");
        }
        using (var c = await RawClient.Connect(port))
        {
            var ok = await c.Hello("ABCDE12345");
            H.True(ok is { Type: "hello_ok", Rekey: null }, $"code still accepted, got {ok}");
            var again = await c.NextNonBeat();   // still on the code: it missed the swap, so it gets the secret again (encrypted)
            H.True(again is { Type: "rekey" } && again.Token == newTok, $"secret resent, got {again}");
        }
        using (var c = await RawClient.Connect(port)) { var bad = await c.Hello("ZZZZZ99999"); H.True(bad is not { Type: "hello_ok" }, $"wrong code refused, got {bad}"); }
    }

    public static Task StorageRules()
    {
        var now = new DateTime(2033, 5, 18, 12, 0, 0, DateTimeKind.Utc);
        ReceivedFile F(string n, double daysAgo, double gb) => new("/x/" + n, (long)(gb * 1e9), now.AddDays(-daysAgo));
        var s = new StorageSettings();
        H.True(s.RetentionDays == 0 && s.LimitGB == 10 && s.OverLimit == "warn" && !s.Confirmed, "defaults");
        var p = Cleanup.Plan([F("a", 400, 5), F("b", 1, 3.5)], s, now);
        H.True(!p.ToTrash.Any() && p.Level == 1, "defaults delete nothing, warn at 80 %");
        H.Eq(2, Cleanup.Plan([F("a", 2, 7), F("b", 1, 4)], s, now).Level, "over limit");
        var r = new StorageSettings { RetentionDays = 30, LimitGB = 0 };
        H.Eq("/x/old,/x/edge", string.Join(",", Cleanup.Plan([F("old", 31, 1), F("edge", 30, 1), F("new", 29, 1)], r, now).Expired.Select(f => f.Path)), "retention");
        var t = new StorageSettings { LimitGB = 10, OverLimit = "trash" };
        var tp = Cleanup.Plan([F("c", 1, 4), F("a", 3, 4), F("b", 2, 4)], t, now);
        H.Eq("/x/a", string.Join(",", tp.OverLimit.Select(f => f.Path)), "oldest moved first");
        H.Eq(8_000_000_000L, tp.UsageBytes, "usage after"); H.Eq(1, tp.Level, "level after");
        var huge = Cleanup.Plan([F("big", 0, 30)], t, now);
        H.True(!huge.OverLimit.Any() && huge.Level == 2, "newest file never moved");
        H.True(Cleanup.ShouldWarnLimit(s, 1, now) && !Cleanup.ShouldWarnLimit(s, 0, now), "warn when level > 0");
        s.LastLimitWarning = now.AddHours(-1);
        H.True(!Cleanup.ShouldWarnLimit(s, 2, now), "at most once a day");
        H.True(Cleanup.ShouldRemindTrash(s, true, now) && !Cleanup.ShouldRemindTrash(s, false, now), "trash reminder only after a move");
        s.LastTrashReminder = now.AddDays(-13);
        H.True(!Cleanup.ShouldRemindTrash(s, true, now), "every 14 days at most");
        s.LastTrashReminder = null; s.TrashReminder = false;
        H.True(!Cleanup.ShouldRemindTrash(s, true, now), "reminder can be turned off");
        var dir = H.TempDir("store");
        var ss = new StorageSettings { RetentionDays = 60, Confirmed = true, LastTrashReminder = now };
        ss.Save(Path.Combine(dir, "settings.json"));
        var back = StorageSettings.Load(Path.Combine(dir, "settings.json"));
        H.True(back.RetentionDays == 60 && back.Confirmed && back.LastTrashReminder == now, "settings round trip");
        H.True(!StorageSettings.Load(Path.Combine(dir, "missing.json")).Confirmed, "missing settings = defaults");
        ReceivedLog.Save([F("a", 1, 1)], Path.Combine(dir, "received.json"));
        H.Eq(F("a", 1, 1), ReceivedLog.Load(Path.Combine(dir, "received.json")).Single(), "log round trip");
        return Task.CompletedTask;
    }

    public static async Task PeerAddrs()
    {
        var lc = new SessionConfig { Token = H.Token, Name = "ad-l", DownloadDir = H.TempDir("ad-l"), Advertise = ["192.168.1.20", "100.64.0.7", "not-an-ip", "999.1.1.1"] };
        var (s, _, port) = await H.Listener("ad-l", lc);
        using var __ = s;
        var drec = new Recorder();
        using var d = new Session(new Role.Dial(["127.0.0.1"], port), H.Cfg("ad-d"), drec.Add);
        d.Start();
        await H.Until(() => drec.All.OfType<SessionEvent.PeerAddresses>().Any(), "addresses", 5);
        H.Eq("192.168.1.20,100.64.0.7", string.Join(",", drec.All.OfType<SessionEvent.PeerAddresses>().First().Addrs), "valid IPv4 only");
    }

    public static async Task DeadLink()
    {
        var clock = new FakeClock();
        var (s, r, port) = await H.Listener("dead", H.Cfg("dead", timer: false), clock);
        using var _ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        await H.Until(() => r.Connects == 1, "connected");
        clock.Advance(16); s.Tick();
        H.Eq("beat", (await c.Next())?.Type, "beat at 16 s");
        clock.Advance(28); s.Tick();
        await Task.Delay(200);
        H.Eq(0, r.Disconnects.Count, "alive at 44 s");
        await c.Send(Frame.Beat);
        await Task.Delay(200);
        clock.Advance(30); s.Tick();
        await Task.Delay(200);
        H.Eq(0, r.Disconnects.Count, "peer beat resets silence");
        clock.Advance(16); s.Tick();
        await H.Until(() => r.Disconnects.Count > 0, "dead link", 5);
        H.True(r.Disconnects[0].Contains("dead link"), r.Disconnects[0]);
        H.True(!s.IsConnected, "not connected");
    }

    public static async Task QueuedBeforeConnect()
    {
        var (probe, _, port) = await H.Listener("probe");
        probe.Dispose();
        await Task.Delay(200);
        var (cli, cr) = H.Dialer("offline", port);
        using var _ = cli;
        var a = cli.SendText("sent while offline");
        await Task.Delay(700);
        H.Eq(ItemStateKind.Waiting, cr.LastState(a.Id)?.Kind, "waiting");
        var (srv, sr, _) = await H.Listener("offlinesrv", port: port);
        using var __ = srv;
        await H.Until(() => cr.Delivered(a.Id), "delivered after connect");
        H.Eq("sent while offline", string.Join("|", sr.Received.Select(i => i.Text)), "received once");
    }

    public static async Task QueueAfterReconnect()
    {
        var (srv, sr, port) = await H.Listener("recsrv");
        using var _ = srv;
        var (cli, cr) = H.Dialer("reccli", port);
        using var __ = cli;
        await H.Until(() => cr.Connects == 1, "connected");
        srv.DropLink();
        await H.Until(() => cr.Disconnects.Count > 0, "client sees the drop");
        var a = cli.SendText("during outage 1");
        var f = cli.SendFile(H.RandomFile(H.TempDir("recsrc"), "queued.bin", 3 << 20));
        var b = cli.SendText("during outage 2");
        await H.Until(() => cr.Connects == 2 && new[] { a, f, b }.All(i => cr.Delivered(i.Id)), "reconnected and drained");
        H.Eq("during outage 1|queued.bin|during outage 2",
             string.Join("|", sr.Received.Select(i => i.Text ?? i.FileName)), "in order, exactly once");
    }

    public static async Task DropMidFile()
    {
        var (srv, sr, port) = await H.Listener("midsrv");
        using var _ = srv;
        var (cli, cr) = H.Dialer("midcli", port);
        using var __ = cli;
        await H.Until(() => cr.Connects == 1, "connected");
        var url = H.RandomFile(H.TempDir("midsrc"), "mid.bin", 40 << 20);
        var dropped = 0;
        // Cut the link from inside the handler the moment progress passes 10 %, so the drop is mid-file
        // however fast the machine is (a polling test can miss the whole transfer).
        cr.Hook = e =>
        {
            if (e is SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending, Progress: > 0.1 } }
                && Interlocked.Exchange(ref dropped, 1) == 0) cli.DropLink();
        };
        var f = cli.SendFile(url);
        await H.Until(() => cr.Delivered(f.Id), "delivered after reconnect", 30);
        H.True(dropped == 1 && cr.Disconnects.Count == 1 && cr.Connects == 2, "dropped once mid-file and reconnected");
        H.Eq(1, sr.Received.Count, "once");
        H.Eq(Hashing.Sha256File(url), Hashing.Sha256File(sr.Received[0].Path!), "sha");
        H.Eq(0, H.Parts(srv.Config.DownloadDir).Length, "no part files");
    }

    public static Task PairCodes()
    {
        var c = PairCode.Generate();
        H.Eq(10, c.Length, "code length");
        H.Eq(c, PairCode.Normalize(c), "normalize own code");
        H.True(c != PairCode.Generate(), "codes differ");
        H.Eq("ABCDE-12345", PairCode.Display("ABCDE12345"), "display");
        H.Eq("ABCDE12345", PairCode.Normalize(" abcde-12345 "), "lower case and separators");
        H.Eq("0110011110", PairCode.Normalize("oil0o-ILLIO"), "look-alikes");
        H.True(PairCode.Normalize("ABCDE-1234") == null, "too short");
        H.True(PairCode.Normalize("ABCDE-123456") == null, "too long");
        H.True(PairCode.Normalize("ABCDE-1234U") == null, "U not allowed");
        H.Eq(8, PairCode.PairId("x").Length, "pair id length");
        H.True(PairCode.PairId("x") != PairCode.PairId("y"), "pair ids differ");
        // The Mac computes the same pair id: SHA-256("lan-line-pair:x")[0..4] as hex.
        H.Eq(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("lan-line-pair:x")))[..8], PairCode.PairId("x"), "pair id formula");
        return Task.CompletedTask;
    }

    public static Task DiscoveryReply()
    {
        var d = Discovery.Reply("Studio PC", 47830, "abcd1234");
        H.Eq(new DiscoveredPeer("Studio PC", "10.0.0.5", 47830, "abcd1234"), Discovery.Parse(d, "10.0.0.5"), "round trip");
        H.True(Discovery.Parse(Encoding.UTF8.GetBytes("{\"lanline\":2}"), "x") == null, "wrong version");
        H.True(Discovery.Parse(Encoding.UTF8.GetBytes("junk"), "x") == null, "junk");
        H.True(Discovery.Parse(Encoding.UTF8.GetBytes("{\"lanline\":1,\"name\":\"a\",\"port\":70000,\"pair\":\"p\"}"), "x") == null, "bad port");
        // The Mac's reply bytes (sorted keys) parse here too.
        H.Eq(new DiscoveredPeer("Mac", "h", 47830, "p"), Discovery.Parse(Encoding.UTF8.GetBytes("{\"lanline\":1,\"name\":\"Mac\",\"pair\":\"p\",\"port\":47830}"), "h"), "Mac reply");
        return Task.CompletedTask;
    }

    public static async Task DiscoveryLoopback()
    {
        using var r = new DiscoveryResponder(47911, "Test PC", "feedbeef");
        var peers = await Discovery.SearchAsync(47911, TimeSpan.FromSeconds(0.6), ["127.0.0.1"]);
        H.Eq(1, peers.Count, "one peer");
        H.Eq(new DiscoveredPeer("Test PC", "127.0.0.1", 47911, "feedbeef"), peers[0], "peer");
    }

    public static Task ConfigSave()
    {
        var dir = Path.Combine(Path.GetTempPath(), "lanline-cfg-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(dir, "config.json");
        new LanLineConfig { Token = "ABCDE12345", Hosts = ["10.0.0.2"], Role = "listen", Peer = "Mac" }.Save(path);
        var c = LanLineConfig.Load(path);
        H.Eq("ABCDE12345", c.Token, "token"); H.Eq("10.0.0.2", c.Hosts.Single(), "hosts"); H.True(c.Listens, "listens"); H.Eq("Mac", c.Peer, "peer");
        H.True(!new LanLineConfig().Listens, "default connects");
        H.Eq(0, new LanLineConfig().Hosts.Length, "no built-in hosts");
        Directory.Delete(dir, true);
        return Task.CompletedTask;
    }

    /// The iPhone's share sheet connects with the "sendonly" cap: it hands things over, and what is queued for
    /// the phone waits until the app itself connects.
    public static async Task SendOnlyPeer()
    {
        var (srv, sr, port) = await H.Listener("sendonly-srv");
        using var _ = srv;
        var c = H.Cfg("sendonly-sheet");
        c = new SessionConfig { Token = c.Token, Name = c.Name, DownloadDir = c.DownloadDir, Backoff = c.Backoff, DialTimeout = c.DialTimeout, Caps = ["sha_end", "folders", "multi", "cancel", "resume", "sendonly"] };
        var (sheet, shr) = H.Dialer("sendonly-sheet", port, c);
        await H.Until(() => sr.Connects == 1 && shr.Connects == 1, "sheet connected");
        var held = srv.SendText("for the phone");
        var given = sheet.SendText("from the share sheet");
        await H.Until(() => sr.Received.Count == 1 && shr.Delivered(given.Id), "sheet's text delivered");
        await Task.Delay(400);
        H.Eq(0, shr.Received.Count, "nothing goes to the sheet");
        H.True(!sr.Delivered(held.Id), "the queued text still waits");
        sheet.Dispose();
        var (app, ar) = H.Dialer("sendonly-app", port);
        using var __ = app;
        await H.Until(() => ar.Received.Count == 1 && sr.Delivered(held.Id), "the app gets the queued text");
        H.Eq("for the phone", ar.Received[0].Text, "text");
    }

    /// A lanline: link with a raw quote can split the command line; a launch that begins with --url is only that link.
    public static Task LinkLaunchArgs()
    {
        H.Eq("--url|lanline://notify?a=show", string.Join("|", LaunchArgs.LinkOnly(["--url", "lanline://notify?a=show", "--debug-log", @"C:\Users\x\Startup\x.cmd", "--downloads", @"\\evil\share", "--headless"])), "extra flags dropped");
        H.Eq("--url|lanline://notify?a=show", string.Join("|", LaunchArgs.LinkOnly(["--url", "lanline://notify?a=show"])), "the normal launch");
        H.Eq("", string.Join("|", LaunchArgs.LinkOnly(["--url"])), "no link: nothing");
        H.Eq("--stage|a.txt|--url|x", string.Join("|", LaunchArgs.LinkOnly(["--stage", "a.txt", "--url", "x"])), "other launches untouched");
        H.Eq("", string.Join("|", LaunchArgs.LinkOnly([])), "empty");
        return Task.CompletedTask;
    }

    /// Before the hello nothing big is taken in: a stranger's 200 KiB first message closes the connection, and
    /// the listener still pairs normally afterwards.
    public static async Task BigFirstMessage()
    {
        var (srv, sr, port) = await H.Listener("bigfirst");
        using var _ = srv;
        using (var ws = new System.Net.WebSockets.ClientWebSocket())
        {
            await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/lan-line"), CancellationToken.None);
            var closed = false;
            try
            {
                await ws.SendAsync(new byte[200 * 1024], System.Net.WebSockets.WebSocketMessageType.Text, true, CancellationToken.None);
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var r = await ws.ReceiveAsync(new byte[1024], cts.Token);
                closed = r.MessageType == System.Net.WebSockets.WebSocketMessageType.Close;
            }
            catch (Exception e) when (e is System.Net.WebSockets.WebSocketException or IOException) { closed = true; }
            H.True(closed, "the listener hung up");
        }
        H.Eq(0, sr.Connects, "never counted as connected");
        var (cli, cr) = H.Dialer("bigfirst-cli", port);
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "a real partner still connects");
    }

    // ---------- cases from the beta.10 code review (2026-11-25); the Mac runs the same ones (ReviewFixTests)

    static SessionConfig VCfg(string tag, double backoff = 0.2, long? free = null) => new()
    {
        Token = H.Token, Name = tag, DownloadDir = H.TempDir(tag), Backoff = [backoff, backoff * 2], DialTimeout = TimeSpan.FromSeconds(2),
        ProgressInterval = TimeSpan.FromSeconds(0.01), ProgressDelay = TimeSpan.Zero, FreeSpaceOverride = free,
    };

    /// Cancelling a folder between two of its files (most of the time, with thousands of empty files) must hand the
    /// line to exactly one next item: two files queued behind it both arrive whole.
    public static async Task ReviewFolderCancelGap()
    {
        for (var round = 0; round < 3; round++)
        {
            var (srv, sr, port) = await H.Listener($"gap{round}-srv", VCfg($"gap{round}-srv"));
            var (cli, cr) = H.Dialer($"gap{round}-cli", port, VCfg($"gap{round}-cli"));
            try
            {
                await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
                var root = Path.Combine(H.TempDir("gap-src"), "Empties");
                Directory.CreateDirectory(root);
                for (var i = 0; i < 3000; i++) File.WriteAllBytes(Path.Combine(root, $"e{i}"), []);
                var b = H.RandomFile(H.TempDir("gap-b"), "b.bin", 6 << 20);
                var c = H.RandomFile(H.TempDir("gap-c"), "c.bin", 6 << 20);
                var folder = cli.SendFolder(root);
                var sb = cli.SendFile(b); var sc = cli.SendFile(c);
                await Task.Delay(20 + round * 15);
                cli.Cancel(folder.Id);
                await H.Until(() => cr.Delivered(sb.Id) && cr.Delivered(sc.Id), $"both files behind it arrive (round {round})", 20);
                H.Eq("b.bin|c.bin", string.Join("|", sr.Received.Where(i => i.IsFile).Select(i => i.FileName)), "one after the other");
            }
            finally { cli.Dispose(); srv.Dispose(); }
        }
    }

    /// The folder setting changes while something is arriving (to a folder that doesn't exist yet): it finishes
    /// where it started, and the next one goes to the new folder. A file, then a folder.
    public static async Task ReviewFinishesWhereStarted()
    {
        var (srv, sr, port) = await H.Listener("dir-srv", VCfg("dir-srv"));
        using var _ = srv;
        var (cli, cr) = H.Dialer("dir-cli", port, VCfg("dir-cli"));
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        var old = srv.Config.DownloadDir;
        var mid = Path.Combine(H.TempDir("dir-new"), "Studio PC");   // not created
        var switched = 0;
        sr.Hook = e =>
        {
            if (e is SessionEvent.Incoming { Item.State: { Kind: ItemStateKind.Receiving, Progress: > 0.2 } } && Interlocked.Exchange(ref switched, 1) == 0) srv.SetDownloadDir(mid);
        };
        var f = cli.SendFile(H.RandomFile(H.TempDir("dir-src"), "big.bin", 40 << 20));
        await H.Until(() => cr.Delivered(f.Id), "delivered", 30);
        H.Eq(1, switched, "the folder was switched mid-transfer");
        H.Eq(Path.GetFullPath(old), Path.GetFullPath(Path.GetDirectoryName(sr.Received[0].Path!)!), "the file finished where it started");
        H.Eq(0, sr.ReceiveFailures.Count, "no failure");
        var g = cli.SendFile(H.RandomFile(H.TempDir("dir-src2"), "next.bin", 1 << 20));
        await H.Until(() => cr.Delivered(g.Id), "the next one");
        H.Eq(Path.GetFullPath(mid), Path.GetFullPath(Path.GetDirectoryName(sr.Received[1].Path!)!), "the next one goes to the new folder");

        var last = Path.Combine(H.TempDir("dir-new2"), "Other");
        switched = 0;
        sr.Hook = e =>
        {
            if (e is SessionEvent.Incoming { Item.State: { Kind: ItemStateKind.Receiving, Progress: > 0.2 } } && Interlocked.Exchange(ref switched, 1) == 0) srv.SetDownloadDir(last);
        };
        var root = Path.Combine(H.TempDir("fdir-src"), "Shoot");
        Directory.CreateDirectory(root);
        for (var i = 0; i < 4; i++) H.RandomFile(root, $"p{i}.bin", 8 << 20);
        var d = cli.SendFolder(root);
        await H.Until(() => cr.Delivered(d.Id), "folder delivered", 30);
        H.Eq(1, switched, "switched during the folder");
        H.Eq(Path.GetFullPath(mid), Path.GetFullPath(Path.GetDirectoryName(sr.Received[2].Path!)!), "the folder finished where it started");
        H.Eq(0, sr.ReceiveFailures.Count, "no failure");
    }

    /// A resumed file needs room for the rest. If the disk filled up while the link was down, the receiver says so at
    /// once and throws the part away.
    public static async Task ReviewResumeNoRoom()
    {
        var (srv, sr, port) = await H.Listener("room-srv", VCfg("room-srv"));
        using var _ = srv;
        var (cli, cr) = H.Dialer("room-cli", port, VCfg("room-cli"));
        using var __ = cli;
        await H.Until(() => cr.Connects == 1, "connected");
        var dropped = 0;
        cr.Hook = e =>
        {
            if (e is not SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending, Progress: > 0.4 } } || Interlocked.Exchange(ref dropped, 1) != 0) return;
            srv.SetFreeSpaceForTests(1 << 20);   // 1 MiB left: not enough for the other 60 %
            cli.DropLink();
        };
        var f = cli.SendFile(H.RandomFile(H.TempDir("room-src"), "big.bin", 60 << 20));
        await H.Until(() => cr.LastState(f.Id)?.Kind == ItemStateKind.Failed, "refused after the reconnect", 30);
        H.True(cr.LastState(f.Id)!.Error!.Contains("not enough disk space"), cr.LastState(f.Id)!.Error!);
        H.True(sr.ReceiveFailures.Any(r => r.Contains("not enough disk space")), "the receiver says why");
        H.Eq(f.Id, string.Join("|", sr.ReceiveFailureIds), "the failure names the item");
        H.Eq(0, sr.Received.Count, "nothing saved");
        H.Eq(0, H.Parts(srv.Config.DownloadDir).Length, "the part is thrown away");
        var after = cli.SendText("still talking");
        await H.Until(() => cr.Delivered(after.Id), "the link carries on");
    }

    /// Parts left by a run that ended without cleaning up are removed at the next start; nothing else is touched.
    public static Task ReviewOrphans()
    {
        var dir = H.TempDir("orphans");
        void Make(string name, double hoursOld, bool folder = false)
        {
            var path = Path.Combine(dir, name);
            if (folder) { Directory.CreateDirectory(path); File.WriteAllText(Path.Combine(path, "inner.bin"), "x"); Directory.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddHours(-hoursOld)); }
            else { File.WriteAllText(path, "x"); File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddHours(-hoursOld)); }
        }
        Make(".movie.mov.1a2b3c4d.part", 5);
        Make(".Trip photos.0f0f0f0f.part", 30, folder: true);
        Make(".fresh.bin.aaaaaaaa.part", 0.5);        // may still be resumed
        Make("notes.part", 50);                        // not ours: not hidden
        Make(".hidden.part", 50);                      // not ours: no id
        Make(".x.gggggggg.part", 50);                  // not ours: not hex
        Make("visible.1a2b3c4d.part", 50);             // not ours: not hidden
        Make(".movie.mov.1a2b3c4d.partial", 50);
        Make("keep.jpg", 50);
        H.Eq(2, Session.SweepOrphans(dir, TimeSpan.FromHours(2) + TimeSpan.FromMinutes(10)), "two removed");
        H.Eq(".fresh.bin.aaaaaaaa.part|.hidden.part|.movie.mov.1a2b3c4d.partial|.x.gggggggg.part|keep.jpg|notes.part|visible.1a2b3c4d.part",
             string.Join("|", Directory.GetFileSystemEntries(dir).Select(Path.GetFileName).Order(StringComparer.Ordinal)), "the rest untouched");
        H.Eq(0, Session.SweepOrphans(Path.Combine(dir, "missing"), TimeSpan.FromSeconds(1)), "a missing folder is fine");
        foreach (var (n, ok) in new[] { (".a.1A2B3C4D.part", true), (".a.b.c.00000000.part", true), ("..1A2B3C4D.part", false), (".1A2B3C4D.part", false), (".a.1A2B3C4.part", false) })
            H.Eq(ok, Session.IsPartName(n), n);
        return Task.CompletedTask;
    }

    /// The Hub swaps a partner's Session when its address changes. A half-received file survives the swap: the new
    /// Session carries on from where the old one stopped, in the folder the file started in.
    public static async Task ReviewPartialSurvivesSwap()
    {
        var (a, ar, port) = await H.Listener("swap-a", VCfg("swap-a"));
        var (cli, cr) = H.Dialer("swap-cli", port, VCfg("swap-cli", backoff: 1.5));   // slow to redial: time for the swap
        using var _ = cli;
        Session? b = null;
        try
        {
            await H.Until(() => cr.Connects == 1, "connected");
            var original = H.RandomFile(H.TempDir("swap-src"), "big.bin", 60 << 20);
            int dropped = 0; double? first = null;
            cr.Hook = e =>
            {
                if (e is not SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending } st }) return;
                if (dropped == 0 && st.Progress > 0.4) { dropped = 1; cli.DropLink(); }
                else if (dropped == 1 && cr.Connects >= 2 && first == null) first = st.Progress;
            };
            var f = cli.SendFile(original);
            await H.Until(() => ar.Disconnects.Count == 1, "cut off", 30);
            var aDir = a.Config.DownloadDir;
            var kept = a.StopKeepingPartials();
            H.Eq(1, kept.Count, "one partial handed over");
            H.True(File.Exists(kept.Values.Single().Part), "the part outlives the old Session");
            var br = new Recorder();
            b = new Session(new Role.Listen(port, "127.0.0.1"), VCfg("swap-b"), br.Add);
            b.AdoptPartials(kept);
            b.Start();
            await H.Until(() => cr.Delivered(f.Id), "delivered through the new Session", 60);
            H.True((first ?? 0) > 0.3, $"carried on, not from the start (first progress after the swap: {first})");
            H.Eq(Hashing.Sha256File(original), Hashing.Sha256File(br.Received.Single().Path!), "byte-identical");
            H.Eq(Path.GetFullPath(aDir), Path.GetFullPath(Path.GetDirectoryName(br.Received.Single().Path!)!), "where it started");
        }
        finally { b?.Dispose(); a.Dispose(); }
    }

    /// A plain stop (quitting) still throws kept parts away.
    public static async Task ReviewStopDeletesPartials()
    {
        var (srv, sr, port) = await H.Listener("quit-srv", VCfg("quit-srv"));
        var (cli, cr) = H.Dialer("quit-cli", port, VCfg("quit-cli", backoff: 30));   // stays away after the drop
        using var _ = cli;
        try
        {
            await H.Until(() => cr.Connects == 1, "connected");
            var dropped = 0;
            cr.Hook = e =>
            {
                if (e is SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending, Progress: > 0.4 } } && Interlocked.Exchange(ref dropped, 1) == 0) cli.DropLink();
            };
            cli.SendFile(H.RandomFile(H.TempDir("quit-src"), "big.bin", 60 << 20));
            await H.Until(() => sr.Disconnects.Count == 1, "cut off", 30);
            H.Eq(1, H.Parts(srv.Config.DownloadDir).Length, "the part is kept while the app runs");
            srv.Stop();
            H.Eq(0, H.Parts(srv.Config.DownloadDir).Length, "and deleted on quit");
        }
        finally { srv.Dispose(); }
    }

    /// The sender never saw our ack, so it sends a saved item again. It is acked and thrown away without a progress
    /// card: the card of the item already in the window must not go back to "receiving" and stay there.
    public static async Task ReviewResendNoCard()
    {
        var (srv, sr, port) = await H.Listener("resend", VCfg("resend"));
        using var _ = srv;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        var body = new byte[3 << 20];
        for (var i = 0; i < body.Length; i++) body[i] = (byte)(i * 31);
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(body));
        async Task<Frame?> SendOnce()
        {
            await c.Send(Frame.FileBegin("same-id", "report.pdf", body.Length, null));
            for (var off = 0; off < body.Length; off += 256 << 10) { await c.Send(body[off..Math.Min(off + (256 << 10), body.Length)]); await Task.Delay(3); }
            await c.Send(Frame.FileEnd("same-id", sha));
            while (true) { var f = await c.NextNonBeat(); if (f == null || f.Type is "ack" or "timeout") return f; }
        }
        var first = await SendOnce();
        H.Eq(true, first?.Ok, "saved");
        H.Eq(1, sr.Received.Count, "delivered once");
        var cards = sr.Incoming("same-id").Count;
        var second = await SendOnce();
        H.Eq(true, second?.Ok, "the resend is acked");
        H.Eq(1, sr.Received.Count, "and not delivered twice");
        H.Eq(cards, sr.Incoming("same-id").Count, "no progress card for the resend");
        H.Eq("report.pdf", string.Join("|", Directory.GetFileSystemEntries(srv.Config.DownloadDir).Select(Path.GetFileName)), "one file, no part");
    }

    /// A failure names its item, so a window can match it to that item's card and to nothing else.
    public static async Task ReviewFailureIds()
    {
        var (srv, sr, port) = await H.Listener("ids-srv", VCfg("ids-srv", free: 1 << 20));
        using var _ = srv;
        var (cli, cr) = H.Dialer("ids-cli", port, VCfg("ids-cli"));
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        var f = cli.SendFile(H.RandomFile(H.TempDir("ids-src"), "report.pdf", 4 << 20));
        await H.Until(() => cr.LastState(f.Id)?.Kind == ItemStateKind.Failed, "refused");
        H.Eq(f.Id, string.Join("|", sr.ReceiveFailureIds), "the failure carries the item's id");
    }

    /// Folder per computer: the folder is named after what the computer calls itself, as soon as it says so, and
    /// follows a rename.
    public static async Task ReviewHubFolderName()
    {
        var secret = Secrets.NewToken();
        var ra = new HubRec(); var rb = new HubRec();
        var a = new Hub(HubCfg("Mac", "device-aaaa"), [P("device-bbbb", "New computer", secret, "listen")], ra.Add);
        Hub? b = null;
        try
        {
            a.SetDownloads(H.TempDir("per-base"), perComputer: true);
            a.Start();
            await H.Until(() => ra.Port != null, "listening", 5);
            b = new Hub(HubCfg("Studio PC", "device-bbbb"), [P("device-aaaa", "Mac", secret, "connect", ra.Port)], rb.Add);
            b.Start();
            await H.Until(() => ra.Up("device-bbbb") && rb.Up("device-aaaa"), "connected");
            List<string> Files() => ra.All.OfType<HubEvent.Received>().Where(r => r.Item.IsFile).Select(r => r.Item.Path!).ToList();
            b.SendFile(H.RandomFile(H.TempDir("per-src"), "one.bin", 1 << 20), null);
            await H.Until(() => Files().Count == 1, "first file");
            H.Eq("Studio PC", Path.GetFileName(Path.GetDirectoryName(Files()[0])!), "not \"New computer\"");
            a.SetName("device-bbbb", "Desk PC");   // renamed here
            await Task.Delay(200);
            b.SendFile(H.RandomFile(H.TempDir("per-src2"), "two.bin", 1 << 20), null);
            await H.Until(() => Files().Count == 2, "second file");
            H.Eq("Desk PC", Path.GetFileName(Path.GetDirectoryName(Files()[1])!), "follows the rename");
        }
        finally { a.Stop(); b?.Stop(); }
    }

    /// A long stream of arrivals opens three files and shows the folder once; the count starts again only after a
    /// real quiet gap (measured from the last arrival, not the last open).
    public static Task ReviewBurst()
    {
        var b = new ArrivalBurst();
        var t0 = new DateTime(2026, 11, 25, 12, 0, 0, DateTimeKind.Utc);
        var did = Enumerable.Range(0, 60).Select(i => b.Next(AfterReceive.Open, $"p{i}.jpg", false, t0.AddSeconds(i))).ToList();
        H.Eq(3, did.Count(a => a == AfterReceive.Open), "three opened");
        H.Eq(1, did.Count(a => a == AfterReceive.Reveal), "the folder shown once");
        H.Eq("Open|Open|Open|Reveal|Nothing", string.Join("|", did.Take(5)), "in that order");
        H.Eq(AfterReceive.Nothing, b.Next(AfterReceive.Open, "later.jpg", false, t0.AddSeconds(63)), "still the same burst");
        H.Eq(AfterReceive.Open, b.Next(AfterReceive.Open, "next.jpg", false, t0.AddSeconds(69)), "after a quiet gap it starts again");
        var r = new ArrivalBurst();
        H.Eq(1, Enumerable.Range(0, 40).Count(i => r.Next(AfterReceive.Reveal, $"f{i}.zip", false, t0.AddSeconds(i * 0.2)) == AfterReceive.Reveal), "Explorer comes forward once");
        H.Eq(AfterReceive.Nothing, r.Next(AfterReceive.Nothing, "x.jpg", false, t0), "off is off");
        H.Eq(AfterReceive.Reveal, new ArrivalBurst().Next(AfterReceive.Open, "setup.exe", false, t0), "never opens what could run");
        return Task.CompletedTask;
    }

    /// Copied terminal output (ESC colour codes), a NUL or a lone surrogate in a message must not make Windows refuse
    /// the notification: the toast is still well-formed XML and keeps the readable text.
    public static Task ReviewToastXml()
    {
        var odd = "\u001b[31mred\u001b[0m text \0 and \uD800 lone, \U0001F600 kept, <tag> & \"quotes\"\tok";
        var xml = ToastXml.Build(new ArrivalNotice("From Mac \u0007", odd, [NoticeAction.Copy]) { ItemId = "id-1" });
        var doc = new System.Xml.XmlDocument();
        doc.LoadXml(xml);   // throws if it isn't well-formed
        var texts = doc.GetElementsByTagName("text");
        H.True(texts[1]!.InnerText.Contains("[31mred") && texts[1]!.InnerText.Contains("<tag> & \"quotes\"\tok"), "the readable text survives");
        H.True(texts[1]!.InnerText.Contains("\U0001F600"), "a real emoji (a surrogate pair) is kept");
        H.True(!xml.Contains('\u001b') && !xml.Contains('\0') && !xml.Contains('\uD800'), "nothing XML forbids is left");
        H.Eq("plain text", ToastXml.XmlSafe("plain text"), "ordinary text is untouched");
        return Task.CompletedTask;
    }

    public static async Task NewPeerReplaces()
    {
        var (s, r, port) = await H.Listener("replace");
        using var _ = s;
        using var c1 = await RawClient.Connect(port);
        await c1.Hello();
        using var c2 = await RawClient.Connect(port);
        H.Eq("hello_ok", (await c2.Hello())?.Type, "second peer accepted");
        await H.Until(() => r.Connects == 2, "two connects");
        H.True(await c1.NextNonBeat() == null, "old peer closed");
        H.True(s.IsConnected, "still connected");
    }

    // ---------- protocol v2 encryption (ENCRYPTION.md) ----------

    /// <summary>The same vectors as mac/Tests/LanLineCoreTests/EncryptionTests.swift (checked there against Python and OpenSSL).</summary>
    static class V
    {
        public static readonly string Secret = string.Concat(Enumerable.Repeat("0123456789abcdef", 4));
        public const string DPriv = "96d378741622987330bc9c86cf6320db2a8d8b03ca1b41952d2b4f88afec9d87";
        public const string SPriv = "9766ee84697f1f685124f912fc0af0a138b71c7ba914c975f8e25cac1e15060d";
        public static readonly byte[] NonceC = [.. Enumerable.Range(0, 32).Select(i => (byte)i)];
        public static readonly byte[] NonceS = [.. Enumerable.Range(32, 32).Select(i => (byte)i)];
        public const string EpkC = "043cdfbbfa399ce91b063c6c9a04886ac1c1052555919764e99558fc8d7acf6910a6e23a2bde6e33b5bbb83d3f0e126d66d1dec6c3c59795601fae93d55984a10d";
        public const string EpkS = "0474f4d2ce524a51341efdbcb8967d7507a2a9ec51ddf2eb03ccee3da2a5b15843d7883ec3b1667e24ac2a4f1b72fde364c4171d203eef7b671d59dc25a23918e9";
        public const string KMac = "56369e54a9d7137a62150b0f8f7c0d06371df6e4913e6595b0b15905abf5a341";
        public const string Mac1 = "37379b5a9644fcdbb65e45a8e17b878f014b2a40d7d1671230e6b63f5d74cfd7";
        public const string Mac2 = "7a561db236359efc855431b3b296a7ba6f95b78b95fac0064399a71f1058179b";
        public const string Z = "6c976a76036dbc925297e872860722a812f6065d2ffcec403b86fcb95bb6e906";
        public const string D2L = "103c2289e2ff41e4283a542ab18132c0d0fd5d0c595dd0adaf79652a4fd05056";
        public const string L2D = "a875fa75ca95485fbc9bf0d903a7b7a63a6fe971bf5482b66cff7560f45346a8";
        public const string Seal0 = "d63d5b918c65f89780b319df55d6430f8209dc095c73bc222e5fbccfb9e79b5a";
        public const string Seal1 = "d83d3bcc0edbe97cc896b0cde40d93f1024f8dcf";
    }
    static byte[] Hex(string h) => Convert.FromHexString(h);
    static string Hex(byte[] b) => Convert.ToHexStringLower(b);

    public static Task CryptoVectors()
    {
        using var dc = LL2.KeyFrom(Hex(V.DPriv), Hex(V.EpkC));
        using var ds = LL2.KeyFrom(Hex(V.SPriv), Hex(V.EpkS));
        H.Eq(V.EpkC, Hex(LL2.Epk(dc)), "dialer epk");
        H.Eq(V.KMac, Hex(LL2.MacKey(V.Secret)), "K_mac");
        var hs = new DialerHandshake(V.Secret, "mac", dc, V.NonceC);
        H.Eq(V.Mac1, Hex(Convert.FromBase64String(hs.Hello.Mac!)), "hello MAC");
        var a = ListenerHandshake.Respond(hs.Hello, [V.Secret], "pc", ds, V.NonceS) ?? throw new Exception("listener refused the vector hello");
        H.Eq(V.Mac2, Hex(Convert.FromBase64String(a.Ok.Mac!)), "hello_ok MAC");
        H.Eq(V.Z, Hex(LL2.Z(dc, Hex(V.EpkS))!), "ECDH Z");
        var t1 = LL2.T1("mac", V.NonceC, Hex(V.EpkC));
        var (d2l, l2d) = LL2.SessionKeys(Hex(V.Z), V.Secret, LL2.T2(t1, "pc", V.NonceS, Hex(V.EpkS)));
        H.Eq(V.D2L, Hex(d2l), "dialer→listener key"); H.Eq(V.L2D, Hex(l2d), "listener→dialer key");
        var ch = hs.Finish(a.Ok) ?? throw new Exception("dialer refused the vector hello_ok");
        H.Eq(V.Seal0, Hex(ch.Seal(ChannelKind.Control, "{\"type\":\"beat\"}"u8)!), "sealed message 0");
        H.Eq(V.Seal1, Hex(ch.Seal(ChannelKind.Chunk, new byte[] { 1, 2, 3 })!), "sealed message 1");
        H.Eq("{\"type\":\"beat\"}", Encoding.UTF8.GetString(a.Channel.Open(Hex(V.Seal0))!.Value.Payload), "listener opens 0");
        var m1 = a.Channel.Open(Hex(V.Seal1))!.Value;
        H.True(m1.Kind == ChannelKind.Chunk && m1.Payload.SequenceEqual(new byte[] { 1, 2, 3 }), "listener opens 1");
        return Task.CompletedTask;
    }

    public static Task HandshakeRefusals()
    {
        var sec = V.Secret;
        var hs = new DialerHandshake(sec, "mac");
        string OtherEpk() { using var k = LL2.NewKey(); return Convert.ToBase64String(LL2.Epk(k)); }
        H.True(ListenerHandshake.Respond(hs.Hello, [new string('f', 64)], "pc") == null, "wrong secret");
        H.True(ListenerHandshake.Respond(hs.Hello, [], "pc") == null, "no secret");
        H.True(ListenerHandshake.Respond(hs.Hello with { Epk = OtherEpk() }, [sec], "pc") == null, "swapped epk");
        H.True(ListenerHandshake.Respond(hs.Hello with { Nonce = Convert.ToBase64String(new byte[32]) }, [sec], "pc") == null, "changed nonce");
        H.True(ListenerHandshake.Respond(hs.Hello with { Name = "evil" }, [sec], "pc") == null, "changed name");
        H.True(ListenerHandshake.Respond(hs.Hello with { V = 1 }, [sec], "pc") == null, "v1");
        H.True(ListenerHandshake.Respond(hs.Hello with { Epk = Convert.ToBase64String(Enumerable.Repeat((byte)4, 65).ToArray()) }, [sec], "pc") == null, "not a curve point");
        H.True(ListenerHandshake.Respond(hs.Hello with { Mac = "%%%" }, [sec], "pc") == null, "bad base64");
        var hs2 = new DialerHandshake("ABCDE12345", "mac");
        var a = ListenerHandshake.Respond(hs2.Hello, [sec, "ABCDE12345"], "pc") ?? throw new Exception("previous secret refused");
        H.Eq(1, a.SecretIndex, "previous secret index");
        H.True(hs2.Finish(a.Ok) != null, "dialer accepts");
        var fake = ListenerHandshake.Respond(new DialerHandshake("other", "x").Hello, ["other"], "pc")!;
        H.True(hs2.Finish(fake.Ok) == null, "hello_ok made without our secret");
        H.True(hs2.Finish(a.Ok with { Epk = OtherEpk() }) == null, "tampered hello_ok");
        return Task.CompletedTask;
    }

    public static Task ChannelTamper()
    {
        var hs = new DialerHandshake(V.Secret, "mac");
        var a = ListenerHandshake.Respond(hs.Hello, [V.Secret], "pc")!;
        var d = hs.Finish(a.Ok)!;
        var m0 = d.Seal(ChannelKind.Control, "zero"u8)!; var m1 = d.Seal(ChannelKind.Control, "one"u8)!;
        var flipped = (byte[])m0.Clone(); flipped[3] ^= 1;
        H.True(new SecureChannel(new byte[32], new byte[32]).Open(m0) == null, "wrong key");
        H.True(a.Channel.Open(flipped) == null, "bit flip");
        H.True(a.Channel.Open(m1) == null, "out of order");
        H.Eq("zero", Encoding.UTF8.GetString(a.Channel.Open(m0)!.Value.Payload), "in order");
        H.True(a.Channel.Open(m0) == null, "replay");
        H.Eq("one", Encoding.UTF8.GetString(a.Channel.Open(m1)!.Value.Payload), "next");
        H.True(d.Open(m0) == null, "other direction's key");
        H.True(d.Open(a.Channel.Seal(ChannelKind.Chunk, new byte[] { 9 })!)?.Payload.SequenceEqual(new byte[] { 9 }) == true, "each direction counts from 0");
        H.True(a.Channel.Open(new byte[10]) == null, "too short");
        return Task.CompletedTask;
    }

    static bool Contains(byte[] hay, string needle) => hay.AsSpan().IndexOf(Encoding.UTF8.GetBytes(needle)) >= 0;

    /// <summary>Pair through the tap, send a marker and a patterned file both ways: none of it, and neither secret, is on the wire.</summary>
    public static async Task WireCapture()
    {
        const string code = "QWERT67890";
        var lc = new SessionConfig { Token = code, Name = "wire-l", DownloadDir = H.TempDir("wire-l"), RekeyOnPair = true, Advertise = ["10.9.8.7"] };
        var (s, srec, port) = await H.Listener("wire-l", lc);
        using var _ = s;
        using var tap = new TapProxy(port);
        var crec = new Recorder();
        using var cli = new Session(new Role.Dial(["127.0.0.1"], tap.Port),
            new SessionConfig { Token = code, Name = "wire-d", DownloadDir = H.TempDir("wire-d"), Backoff = [0.2, 0.4] }, crec.Add);
        cli.Start();
        await H.Until(() => srec.Connects == 1 && crec.Connects == 1, "connected through the tap", 5);
        var secret = srec.All.OfType<SessionEvent.Rekeyed>().First().Token;
        await H.Until(() => crec.All.OfType<SessionEvent.Rekeyed>().Any(r => r.Token == secret), "dialer got the secret", 5);
        await H.Until(() => crec.All.OfType<SessionEvent.PeerAddresses>().Any(), "dialer got the addresses", 5);
        var marker = "MARKER-" + Guid.NewGuid();
        var dir = H.TempDir("wire-src");
        var path = Path.Combine(dir, "secret-plans.txt");
        File.WriteAllText(path, string.Concat(Enumerable.Repeat("LANLINE-PATTERN-", 40_000)));
        var t1 = cli.SendText(marker); var f1 = cli.SendFile(path);
        var t2 = s.SendText(marker); var f2 = s.SendFile(path);
        await H.Until(() => crec.Delivered(t1.Id) && crec.Delivered(f1.Id) && srec.Delivered(t2.Id) && srec.Delivered(f2.Id), "delivered", 15);
        var wire = tap.Captured;
        H.True(wire.Length > 640_000, $"the tap saw the transfer ({wire.Length} bytes)");
        H.True(Contains(wire, "\"hello_ok\""), "sanity: the tap sees plaintext (the listener's handshake)");
        foreach (var (what, needle) in new[] { ("marker", marker), ("file content", "LANLINE-PATTERN"), ("file name", "secret-plans"),
                                               ("pairing code", code), ("long-term secret", secret), ("address", "10.9.8.7") })
            H.True(!Contains(wire, needle), $"{what} is readable on the wire");
    }

    public static async Task LiveTamper()
    {
        var (s, r, port) = await H.Listener("tamper");
        using var _ = s;
        using (var c = await RawClient.Connect(port))
        {
            await c.Hello();
            await H.Until(() => r.Connects == 1, "connected");
            await c.SendPlain(Enumerable.Repeat((byte)0x5a, 64).ToArray());
            H.True(await c.NextNonBeat() == null, "closed on a forged message");
            await H.Until(() => r.Disconnects.Contains("decrypt failed"), "decrypt failed", 5);
        }
        using (var c = await RawClient.Connect(port))
        {
            await c.Hello();
            await c.SendPlain(Frame.TextItem("p", "in the clear"));
            H.True(await c.NextNonBeat() == null, "closed on plaintext after the handshake");
        }
        H.Eq(0, r.Received.Count, "nothing received");
    }

    public static async Task WrongSecretDialer()
    {
        var (s, srec, port) = await H.Listener("wrong-l");
        using var _ = s;
        var crec = new Recorder();
        using var cli = new Session(new Role.Dial(["127.0.0.1"], port),
            new SessionConfig { Token = string.Concat(Enumerable.Repeat("cd", 32)), Name = "wrong-d", DownloadDir = H.TempDir("wrong-d"), Backoff = [0.2, 0.4] }, crec.Add);
        cli.Start();
        await H.Until(() => crec.All.OfType<SessionEvent.Status>().Any(x => x.Text == "Refused: the other computer doesn't know this pairing. Pair again."), "refusal", 5);
        H.Eq(0, crec.Connects, "dialer never connected"); H.Eq(0, srec.Connects, "listener never connected");
    }

    // ---------- beta.6: caps, too-big refused up front, folders ----------

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(Microsoft.Win32.SafeHandles.SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint ret, IntPtr ov);

    /// <summary>A sparse file: takes no real disk space, but hashing it would read every byte.</summary>
    static string Sparse(string dir, string name, long size)
    {
        var p = Path.Combine(dir, name);
        using var fs = new FileStream(p, FileMode.Create, FileAccess.ReadWrite);
        if (!DeviceIoControl(fs.SafeFileHandle, 0x000900C4 /* FSCTL_SET_SPARSE */, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero))
            throw new Exception("could not mark the file sparse");
        fs.SetLength(size);
        return p;
    }

    static async Task<(Session S, Recorder SR, Session C, Recorder CR)> Pair(string tag, SessionConfig? lc = null, SessionConfig? dc = null)
    {
        var (s, sr, port) = await H.Listener(tag + "-l", lc);
        var cr = new Recorder();
        var c = new Session(new Role.Dial(["127.0.0.1"], port), dc ?? H.Cfg(tag + "-d"), cr.Add);
        c.Start();
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected", 5);
        return (s, sr, c, cr);
    }

    static SessionConfig Old(string tag) => new() { Token = H.Token, Name = tag, DownloadDir = H.TempDir(tag), Backoff = [0.2, 0.4], Caps = [] };

    static bool FailedWith(Recorder r, string id, string text) => r.LastState(id) is { Kind: ItemStateKind.Failed } st && (st.Error ?? "").Contains(text);

    public static async Task TooBigEarly()
    {
        var lc = new SessionConfig { Token = H.Token, Name = "big-l", DownloadDir = H.TempDir("big-l"), FreeSpaceOverride = 10_000_000_000 };
        var (s, sr, c, cr) = await Pair("big", lc);
        using var _ = s; using var __ = c;
        var huge = Sparse(H.TempDir("big-src"), "huge.bin", 200_000_000_000);
        var sw = Stopwatch.StartNew();
        var item = c.SendFile(huge);
        await H.Until(() => cr.LastState(item.Id)?.Kind == ItemStateKind.Failed, "refused", 5);
        H.True(sw.Elapsed.TotalSeconds < 5, $"refused in {sw.Elapsed.TotalSeconds:0.0} s");
        var why = cr.LastState(item.Id)!.Error ?? "";
        H.True(why.Contains("not enough disk space") && why.Contains("200"), why);
        await H.Until(() => sr.ReceiveFailures.Any(x => x.Contains("not enough disk space")), "receiver noted it", 5);
        var t = c.SendText("still here");
        await H.Until(() => cr.Delivered(t.Id), "text after refusal", 5);
        File.Delete(huge);
    }

    public static async Task OverBound()
    {
        var (s, _, c, cr) = await Pair("bound");
        using var _1 = s; using var _2 = c;
        var huge = Sparse(H.TempDir("bound-src"), "2tb.bin", 2L << 40);
        var item = c.SendFile(huge);
        await H.Until(() => cr.LastState(item.Id)?.Kind == ItemStateKind.Failed, "refused", 5);
        File.Delete(huge);
    }

    public static async Task OldPeers()
    {
        foreach (var (lc, dc) in new[] { (Old("old-l"), H.Cfg("new-d")), (H.Cfg("new-l"), Old("old-d")) })
        {
            var (s, sr, c, cr) = await Pair("compat", lc, dc);
            using var _1 = s; using var _2 = c;
            var src = H.RandomFile(H.TempDir("compat-src"), "c.bin", 700_000);
            var a = c.SendFile(src); var b = s.SendFile(src);
            await H.Until(() => cr.Delivered(a.Id) && sr.Delivered(b.Id), "delivered both ways", 10);
            H.Eq(Hashing.Sha256File(src), Hashing.Sha256File(sr.Received.First().Path!), "same bytes");
        }
    }

    static Dictionary<string, string> Tree(string root) =>
        new DirectoryInfo(root).EnumerateFileSystemInfos("*", SearchOption.AllDirectories)
            .ToDictionary(e => Path.GetRelativePath(root, e.FullName).Replace('\\', '/'), e => e is DirectoryInfo ? "dir" : Hashing.Sha256File(e.FullName));

    static void Same(Dictionary<string, string> want, Dictionary<string, string> got, string what) =>
        H.True(want.Count == got.Count && want.All(kv => got.TryGetValue(kv.Key, out var v) && v == kv.Value),
               $"{what}: want [{string.Join(", ", want.Keys.Order())}], got [{string.Join(", ", got.Keys.Order())}]");

    static string SampleFolder(string tag, string name = "Project Ünïcødé 📁")
    {
        var root = Path.Combine(H.TempDir(tag), name);
        void Put(string rel, string text) { var p = Path.Combine(root, rel); Directory.CreateDirectory(Path.GetDirectoryName(p)!); File.WriteAllText(p, text); }
        Put("readme.txt", "top"); Put("a/b/c/deep.txt", "deep"); Put("日本/ファイル.txt", "日本語");
        Directory.CreateDirectory(Path.Combine(root, "empty", "inner-empty"));
        H.RandomFile(Path.Combine(root, "a"), "big.bin", 3 << 20);
        return root;
    }

    static List<Item> Folders(Recorder r) => r.Received.Where(i => i.IsFolder).ToList();

    public static async Task FolderBothWays()
    {
        var (s, sr, c, cr) = await Pair("fold");
        using var _1 = s; using var _2 = c;
        var src = SampleFolder("fold-src");
        var want = Tree(src);
        var a = c.SendFolder(src);
        H.Eq(4, a.Count, "count"); H.Eq((3L << 20) + 3 + 4 + 9, a.Size, "size");
        var b = s.SendFolder(src);
        await H.Until(() => cr.Delivered(a.Id) && sr.Delivered(b.Id), "delivered both ways", 15);
        Same(want, Tree(Folders(sr)[0].Path!), "listener copy");
        Same(want, Tree(Folders(cr)[0].Path!), "dialer copy");
        H.Eq("Project Ünïcødé 📁", Folders(sr)[0].FileName, "name");
        var again = c.SendFolder(src);
        await H.Until(() => cr.Delivered(again.Id), "second copy", 15);
        H.Eq("Project Ünïcødé 📁 (2)", Folders(sr)[^1].FileName, "clash name");
        H.Eq(0, Directory.EnumerateFileSystemEntries(s.Config.DownloadDir).Count(e => Path.GetFileName(e).StartsWith('.')), "no staging left");
    }

    public static async Task LargeTree()
    {
        var (s, sr, c, cr) = await Pair("tree");
        using var _1 = s; using var _2 = c;
        var root = Path.Combine(H.TempDir("tree-src"), "many");
        for (var i = 0; i < 300; i++) { var p = Path.Combine(root, $"d{i % 12}", $"sub{i % 5}", $"f{i}.txt"); Directory.CreateDirectory(Path.GetDirectoryName(p)!); File.WriteAllText(p, $"file {i}"); }
        H.RandomFile(root, "large.bin", 20 << 20);
        var item = c.SendFolder(root);
        await H.Until(() => cr.Delivered(item.Id), "delivered", 30);
        Same(Tree(root), Tree(Folders(sr)[0].Path!), "tree");
        H.Eq(301, Folders(sr)[0].Count, "count");
    }

    public static async Task FolderLinks()
    {
        var (s, sr, c, cr) = await Pair("link");
        using var _1 = s; using var _2 = c;
        var secretDir = H.TempDir("link-secret");
        File.WriteAllText(Path.Combine(secretDir, "secret.txt"), "do not send");
        var root = Path.Combine(H.TempDir("link-src"), "withlinks");
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "real.txt"), "ok");
        var mk = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{Path.Combine(root, "up")}\" \"{secretDir}\"") { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true })!;
        await mk.WaitForExitAsync();
        H.True(Directory.Exists(Path.Combine(root, "up")), "junction made");
        var skipped = 1;
        try { File.CreateSymbolicLink(Path.Combine(root, "escape.txt"), Path.Combine(secretDir, "secret.txt")); skipped++; } catch (Exception) { }   // needs Developer Mode
        H.Eq(skipped, Session.ScanFolder(root).Skipped, "links counted");
        var item = c.SendFolder(root);
        await H.Until(() => cr.Delivered(item.Id), "delivered", 10);
        Same(new() { ["real.txt"] = Hashing.Sha256File(Path.Combine(root, "real.txt")) }, Tree(Folders(sr)[0].Path!), "only the real file");
    }

    public static async Task FolderTooBig()
    {
        var lc = new SessionConfig { Token = H.Token, Name = "ftb-l", DownloadDir = H.TempDir("ftb-l"), FreeSpaceOverride = 2 << 20 };
        var (s, sr, c, cr) = await Pair("ftb", lc);
        using var _1 = s; using var _2 = c;
        var item = c.SendFolder(SampleFolder("ftb-src"));
        await H.Until(() => FailedWith(cr, item.Id, "not enough disk space"), "refused", 5);
        await H.Until(() => sr.ReceiveFailures.Count > 0, "receiver noted it", 5);
        H.Eq(0, Folders(sr).Count, "nothing saved");
    }

    public static async Task FolderOldPeer()
    {
        var (s, _, c, cr) = await Pair("fold-old", Old("fold-old-l"));
        using var _1 = s; using var _2 = c;
        var item = c.SendFolder(SampleFolder("fold-old-src"));
        await H.Until(() => FailedWith(cr, item.Id, "Update Lan-Line"), "says update", 5);
    }

    public static async Task FolderEscape()
    {
        var (s, r, port) = await H.Listener("escape");
        using var _ = s;
        foreach (var bad in new[] { "../evil.txt", "a/../../evil.txt", "/etc/evil.txt", "a\\..\\..\\evil.txt", "", "a//b", "." })
        {
            using var c = await RawClient.Connect(port);
            await c.Hello();
            await c.Send(Frame.FolderBegin("F", "x", 1, 4));
            await c.Send(Frame.FileBegin("f1", "evil.txt", 4, null, "F", bad));
            await c.Send("evil"u8.ToArray());
            await c.Send(Frame.FileEnd("f1", H.Sha("evil"u8.ToArray())));
            await c.Send(Frame.FolderEnd("F"));
            Frame? ack;
            do { ack = await c.NextNonBeat(); } while (ack != null && ack.Type != "ack");
            H.True(ack is { Ok: false }, $"path '{bad}' refused, got {ack}");
        }
        H.True(!File.Exists(Path.Combine(Path.GetDirectoryName(s.Config.DownloadDir)!, "evil.txt")), "nothing outside");
        H.Eq(0, Directory.EnumerateFileSystemEntries(s.Config.DownloadDir).Count(), "nothing left inside");
        H.Eq(0, r.Received.Count, "nothing received");
    }

    // ---------- update notices ----------

    public static Task VersionOrder()
    {
        foreach (var good in new[] { "0.9.0-beta.6", "1.0.0", "0.10.2", "12.0.0-beta.10", "0.0.0" }) H.True(LanLineVersion.Parse(good) != null, good);
        foreach (var bad in new[] { "v1.0.0", "1.0", "1.0.0.0", "1.0.0-rc.1", "1.0.0-beta.", "1.0.0-beta", "01.0.0", "1.0.0-beta.06", " 1.0.0",
                                    "1.0.0 ", "1.0.0\n", "1.0.0-beta.6+x", "1234567.0.0", "１.0.0", "", "-1.0.0", "1..0", "1.0.0-BETA.1" })
            H.True(LanLineVersion.Parse(bad) == null, $"should refuse '{bad}'");
        var order = new[] { "0.9.0-beta.5", "0.9.0-beta.6", "0.9.0-beta.10", "0.9.0", "0.9.1-beta.1", "0.10.0", "1.0.0" }.Select(v => LanLineVersion.Parse(v)!).ToList();
        for (var i = 0; i + 1 < order.Count; i++) H.True(order[i] < order[i + 1] && !(order[i + 1] < order[i]), $"{order[i]} < {order[i + 1]}");
        H.Eq("0.9.0-beta.6", LanLineVersion.Parse("0.9.0-beta.6")!.ToString(), "round trip");
        return Task.CompletedTask;
    }

    public static Task UrlAllowlist()
    {
        foreach (var ok in new[] { "https://averywrobinson.com/lan-line/", "https://averywrobinson.com/lan-line/#download",
                                   "https://github.com/averywrobinson/lan-line/releases/tag/v0.9.0-beta.6", "https://github.com/averywrobinson/lan-line/releases" })
            H.True(Updates.IsAllowedUrl(ok), ok);
        foreach (var bad in new[] { "http://averywrobinson.com/lan-line/", "https://averywrobinson.com/lan-line", "https://averywrobinson.com/",
                                    "https://averywrobinson.com.evil.com/lan-line/", "https://evil.com/https://averywrobinson.com/lan-line/",
                                    "https://averywrobinson.com/lan-line/../evil", "https://averywrobinson.com/lan-line//evil.com",
                                    "https://github.com/averywrobinson/lan-line-evil/", "https://github.com/evil/lan-line/",
                                    "https://github.com/averywrobinson/lan-line/@evil.com", "https://github.com/averywrobinson/lan-line/x?y=1",
                                    "https://github.com/averywrobinson/lan-line/x y", "https://github.com/averywrobinson/lan-line/\nx",
                                    "javascript:alert(1)", "HTTPS://averywrobinson.com/lan-line/", "https://averywrobinson.com/lan-line/ä",
                                    "https://averywrobinson.com/lan-line/" + new string('a', 300), "" })
            H.True(!Updates.IsAllowedUrl(bad), $"should refuse '{bad}'");
        return Task.CompletedTask;
    }

    public static Task VersionJson()
    {
        const string good = "{\"version\":\"0.9.1\",\"released\":\"2026-12-01\",\"url\":\"https://github.com/averywrobinson/lan-line/releases/tag/v0.9.1\",\"notes_url\":\"https://averywrobinson.com/lan-line/\"}";
        H.Eq("0.9.1", Updates.Parse(Encoding.UTF8.GetBytes(good))?.Version.ToString(), "good file");
        H.True(Updates.Parse(Encoding.UTF8.GetBytes(good.Replace("github.com", "evil.com"))) == null, "bad url");
        H.True(Updates.Parse(Encoding.UTF8.GetBytes(good.Replace("0.9.1\"", "v0.9.1\""))) == null, "bad version");
        H.True(Updates.Parse("<html>"u8.ToArray()) == null, "garbage");
        H.True(Updates.Parse(new byte[70_000]) == null, "too big");
        return Task.CompletedTask;
    }

    public static async Task ChecksQuiet()
    {
        var r = await Updates.FetchLatest("0.9.0-beta.6", "http://127.0.0.1:9/lan-line/version.json");
        H.Eq(Updates.Outcome.Failed, r.Kind, "refused port fails");
        H.Eq(Updates.Outcome.Failed, (await Updates.FetchLatest("not-a-version")).Kind, "bad own version fails before any network use");
        H.True(Updates.Message(r, manual: false) == null, "automatic failure is silent");
        H.True(Updates.Message(new Updates.CheckResult(Updates.Outcome.UpToDate, LanLineVersion.Parse("1.0.0")), manual: false) == null, "automatic up-to-date is silent");
        H.True(Updates.Message(r, manual: true) != null, "manual failure says so");
    }

    public static Task AutoOff()
    {
        var now = DateTime.UtcNow;
        H.True(!Updates.DueForAutoCheck(new StorageSettings(), now), "off unless turned on");
        var dir = H.TempDir("upd");
        var path = Path.Combine(dir, "settings.json");
        File.WriteAllText(path, "{\"confirmed\":true,\"limitGB\":25,\"overLimit\":\"trash\",\"retentionDays\":30,\"trashReminder\":false}");
        var s = StorageSettings.Load(path);
        H.True(s.RetentionDays == 30 && s.Confirmed && !Updates.DueForAutoCheck(s, now), "beta.5 settings keep values, stay off");
        var on = new StorageSettings { AutoUpdateCheck = true };
        H.True(Updates.DueForAutoCheck(on, now), "on: due");
        on.LastUpdateCheck = now.AddHours(-1);
        H.True(!Updates.DueForAutoCheck(on, now), "once a day at most");
        on.LastUpdateCheck = now.AddHours(-25);
        H.True(Updates.DueForAutoCheck(on, now), "due again after a day");
        return Task.CompletedTask;
    }

    static List<string> UpdatesOf(Recorder r) => r.All.OfType<SessionEvent.UpdateAvailable>().Select(u => $"{u.Version} {u.Url}").ToList();

    static SessionConfig Ver(string tag, string v, Updates.Available? latest = null) =>
        new() { Token = H.Token, Name = tag, DownloadDir = H.TempDir(tag), Backoff = [0.2, 0.4], AppVersion = v, LatestKnown = latest };

    public static async Task PeerRelay()
    {
        var (s, sr, c, cr) = await Pair("rel", Ver("rel-l", "0.9.0-beta.6", new Updates.Available(LanLineVersion.Parse("0.9.1")!, "https://averywrobinson.com/lan-line/")),
                                         Ver("rel-d", "0.9.0-beta.5"));
        using var _1 = s; using var _2 = c;
        await H.Until(() => UpdatesOf(cr).Contains("0.9.1 https://averywrobinson.com/lan-line/"), "dialer told", 5);
        H.Eq(0, UpdatesOf(sr).Count, "newer side hears nothing new");
        c.NoteLatest(new Updates.Available(LanLineVersion.Parse("0.9.2")!, "https://github.com/averywrobinson/lan-line/releases/tag/v0.9.2"));
        await H.Until(() => UpdatesOf(sr).Contains("0.9.2 https://github.com/averywrobinson/lan-line/releases/tag/v0.9.2"), "relayed", 5);
    }

    public static async Task PeerVersionOnly()
    {
        var (s, _, c, cr) = await Pair("pv", Ver("pv-l", "0.9.0-beta.7"), Ver("pv-d", "0.9.0-beta.6"));
        using var _1 = s; using var _2 = c;
        await H.Until(() => UpdatesOf(cr).SequenceEqual(["0.9.0-beta.7 https://github.com/averywrobinson/lan-line/releases/tag/v0.9.0-beta.7"]), "told", 5);
    }

    public static async Task PeerBadLinks()
    {
        var (s, r, port) = await H.Listener("bad-l", Ver("bad-l", "0.9.0-beta.6"));
        using var _ = s;
        using var c = await RawClient.Connect(port);
        await c.Hello();
        foreach (var (v, u) in new[] { ("9.9.9", "https://evil.com/lan-line/"), ("9.9.9", "https://averywrobinson.com/lan-line/../../evil"),
                                       ("v9.9.9", "https://averywrobinson.com/lan-line/"), ("9.9.9 ", "https://averywrobinson.com/lan-line/") })
            await c.Send(Frame.VersionInfo("0.9.0-beta.5", new Frame.LatestKnownInfo(v, u)));
        await c.Send(new Frame { Type = "version", Version = "9.9.9\nclick https://evil.com" });
        await c.Send(Frame.TextItem("after", "done"));
        await H.Until(() => r.Received.Count > 0, "text after", 5);
        H.Eq(0, UpdatesOf(r).Count, "nothing shown");
    }

    // ---------- beta.7: partners and the Hub ----------

    public static Task CfgMigrate()
    {
        var tok = string.Concat(Enumerable.Repeat("ab", 32));
        var path = Path.Combine(H.TempDir("cfg"), "config.json");
        File.WriteAllText(path, $"{{\"hosts\":[\"192.168.1.20\"],\"peer\":\"Mac\",\"port\":47830,\"role\":\"listen\",\"token\":\"{tok}\"}}");
        var c = DeviceConfig.Load(path, "connect");
        H.Eq(1, c.Peers.Count, "one partner");
        H.True(c.Peers[0] is { Role: "listen", Name: "Mac" } && c.Peers[0].Secret == tok && c.Peers[0].Hosts.SequenceEqual(["192.168.1.20"]), "migrated");
        H.Eq(32, c.DeviceId.Length, "device id made");
        c.Save(path);
        var again = DeviceConfig.Load(path, "connect");
        H.True(again.DeviceId == c.DeviceId && again.Peers.Count == 1 && again.Peers[0].SameAs(c.Peers[0]), "round trip");
        var legacy = LanLineConfig.Load(path);
        H.True(legacy.Token == tok && legacy.Role == "listen", "first partner mirrored for beta.6");
        File.WriteAllText(path, "{\"port\":47830,\"token\":\"ABCDE12345\"}");
        H.Eq("connect", DeviceConfig.Load(path, "connect").Peers[0].Role, "missing role = platform default");
        File.WriteAllText(path, "{\"port\":47830}");
        H.Eq(0, DeviceConfig.Load(path, "connect").Peers.Count, "fresh config: no partners");
        return Task.CompletedTask;
    }

    public static Task CfgAddForget()
    {
        var c = new DeviceConfig();
        for (var i = 0; i < DeviceConfig.MaxPartners; i++) c.Add(new Partner { Id = $"dev{i}", Name = $"C{i}", Secret = Secrets.NewToken(), Role = "listen" });
        try { c.Add(new Partner { Id = "dev9", Name = "x", Secret = Secrets.NewToken(), Role = "listen" }); throw new Exception("cap not enforced"); }
        catch (TooManyPartnersException) { }
        var fresh = Secrets.NewToken();
        c.Add(new Partner { Id = "dev3", Name = "again", Secret = fresh, Role = "connect" });
        H.True(c.Peers.Count == DeviceConfig.MaxPartners && c.Partner("dev3")!.Secret == fresh, "same id replaces");
        c.Rename("dev3", "Studio PC");
        H.Eq("Studio PC", c.Partner("dev3")!.Name, "renamed");
        c.Forget("dev3");
        H.True(c.Partner("dev3") == null && c.Peers.Count == DeviceConfig.MaxPartners - 1, "forgotten");
        foreach (var p in c.Peers.ToList()) c.Forget(p.Id);
        var path = Path.Combine(H.TempDir("cfg-empty"), "config.json");
        c.Save(path);
        H.True(!File.ReadAllText(path).Contains("\"token\""), "no legacy token left");
        return Task.CompletedTask;
    }

    sealed class HubRec
    {
        readonly System.Collections.Concurrent.ConcurrentQueue<HubEvent> _e = new();
        public void Add(HubEvent e) => _e.Enqueue(e);
        public List<HubEvent> All => [.. _e];
        public int? Port => All.OfType<HubEvent.Listening>().Select(l => (int?)l.Port).FirstOrDefault();
        public bool Up(string p)
        {
            var up = false;
            foreach (var e in All) { if (e is HubEvent.Connected c && c.Partner == p) up = true; if (e is HubEvent.Disconnected d && d.Partner == p) up = false; }
            return up;
        }
        public int Connects(string p) => All.OfType<HubEvent.Connected>().Count(c => c.Partner == p);
        public List<Item> Got(string? from = null) => All.OfType<HubEvent.Received>().Where(r => from == null || r.Partner == from).Select(r => r.Item).ToList();
        public HubItem? Last(string id) => All.OfType<HubEvent.Outgoing>().LastOrDefault(o => o.Item.Id == id)?.Item;
    }

    static HubConfig HubCfg(string tag, string device, int port = 0, string? outbox = null) => new()
    {
        Name = tag, DeviceId = device, DownloadDir = H.TempDir(tag), Port = port, BindHost = "127.0.0.1", OutboxPath = outbox,
        Tune = s => new SessionConfig { Token = s.Token, Name = s.Name, DownloadDir = s.DownloadDir, AppVersion = s.AppVersion, LatestKnown = s.LatestKnown,
                                        DeviceId = s.DeviceId, RekeyOnPair = s.RekeyOnPair, External = s.External, Advertise = s.Advertise,
                                        Backoff = [0.2, 0.4], DialTimeout = TimeSpan.FromSeconds(2) },
    };

    static Partner P(string id, string name, string secret, string role, int? port = null) =>
        new() { Id = id, Name = name, Secret = secret, Role = role, Hosts = role == "connect" ? ["127.0.0.1"] : [], Port = port };

    static readonly string AB = Secrets.NewToken(), AC = Secrets.NewToken(), BC = Secrets.NewToken();

    static async Task<(Hub A, HubRec RA, Hub B, HubRec RB, Hub C, HubRec RC)> Triangle()
    {
        HubRec ra = new(), rb = new(), rc = new();
        var a = new Hub(HubCfg("A", "device-aaaa"), [P("device-bbbb", "B", AB, "listen"), P("device-cccc", "C", AC, "listen")], ra.Add);
        a.Start();
        await H.Until(() => ra.Port != null, "A listening", 5);
        var c = new Hub(HubCfg("C", "device-cccc"), [P("device-aaaa", "A", AC, "connect", ra.Port), P("device-bbbb", "B", BC, "listen")], rc.Add);
        c.Start();
        await H.Until(() => rc.Port != null, "C listening", 5);
        var b = new Hub(HubCfg("B", "device-bbbb"), [P("device-aaaa", "A", AB, "connect", ra.Port), P("device-cccc", "C", BC, "connect", rc.Port)], rb.Add);
        b.Start();
        await H.Until(() => ra.Up("device-bbbb") && ra.Up("device-cccc") && rb.Up("device-aaaa") && rb.Up("device-cccc") && rc.Up("device-aaaa") && rc.Up("device-bbbb"), "six links up", 10);
        return (a, ra, b, rb, c, rc);
    }

    public static async Task HubTriangle()
    {
        var (a, ra, b, rb, c, rc) = await Triangle();
        try
        {
            H.True(ra.All.Contains(new HubEvent.PeerDevice("device-bbbb", "device-bbbb")), "A learns B's device id");
            var t = b.SendText("hello everyone", null);
            H.True(t.To.Order().SequenceEqual(["device-aaaa", "device-cccc"]), "to both");
            await H.Until(() => ra.Got("device-bbbb").Count == 1 && rc.Got("device-bbbb").Count == 1, "both got it", 5);
            await H.Until(() => rb.Last(t.Id)?.Delivered == 2, "2/2", 5);
            H.Eq(ItemStateKind.Delivered, rb.Last(t.Id)!.Summary.Kind, "summary delivered");
            var src = H.RandomFile(H.TempDir("hub-src"), "only-c.bin", 600_000);
            var f = b.SendFile(src, "device-cccc");
            await H.Until(() => rc.Got("device-bbbb").Count == 2, "C got the file", 10);
            await H.Until(() => rb.Last(f.Id)?.Summary.Kind == ItemStateKind.Delivered, "1/1", 5);
            H.Eq(1, ra.Got().Count, "A didn't get the file");
            H.Eq(Hashing.Sha256File(src), Hashing.Sha256File(rc.Got("device-bbbb")[^1].Path!), "same bytes");
            var d = a.SendFolder(SampleFolder("hub-fold"), null);
            await H.Until(() => ra.Last(d.Id)?.Delivered == 2, "folder 2/2", 15);
        }
        finally { a.Stop(); b.Stop(); c.Stop(); }
    }

    // ---------- outbox (beta.11): what is still waiting for a partner survives a restart of the sender

    static async Task<(Hub, HubRec)> OutSender(string outbox, params Partner[] partners)
    {
        var r = new HubRec();
        var h = new Hub(HubCfg("A", "device-aaaa", outbox: outbox), partners, r.Add);
        h.Start();
        await H.Until(() => r.Port != null, "A listening", 5);
        return (h, r);
    }

    static (Hub, HubRec) OutPhone(string tag, string device, string secret, int? port)
    {
        var r = new HubRec();
        var h = new Hub(HubCfg(tag, device), [P("device-aaaa", "A", secret, "connect", port)], r.Add);
        h.Start();
        return (h, r);
    }

    static Partner OB => P("device-bbbb", "B", AB, "listen");
    static Partner OC => P("device-cccc", "C", AC, "listen");

    public static async Task OutboxRestart()
    {
        var dir = H.TempDir("outbox-restart"); var outbox = Path.Combine(dir, "outbox.json");
        var file = H.RandomFile(dir, "photo.jpg", 50_000);
        var (a, _) = await OutSender(outbox, OB);
        a.SendText("first", "device-bbbb"); a.SendFile(file, "device-bbbb"); a.SendText("third", "device-bbbb");
        await H.Until(() => Outbox.Load(outbox).Count == 3, "three saved", 5);
        a.Stop();
        var saved = Outbox.Load(outbox);
        H.Eq("text,file,text", string.Join(",", saved.Select(e => e.Kind)), "in the order they were sent");
        HubRec ra; (a, ra) = await OutSender(outbox, OB);
        var (p, rp) = OutPhone("B", "device-bbbb", AB, ra.Port);
        try
        {
            await H.Until(() => rp.Got().Count == 3, "all three arrive", 10);
            H.Eq("first,third", string.Join(",", rp.Got().Where(i => i.Text != null).Select(i => i.Text)), "texts in order");
            H.Eq(Hashing.Sha256File(file), Hashing.Sha256File(rp.Got().Single(i => i.Text == null).Path!), "same bytes");
            await H.Until(() => saved.All(e => ra.Last(e.Id)?.Summary.Kind == ItemStateKind.Delivered), "delivered", 5);
            H.True(!File.Exists(outbox), "nothing owed: the file goes");
        }
        finally { p.Stop(); a.Stop(); }
    }

    public static async Task OutboxEveryone()
    {
        var dir = H.TempDir("outbox-everyone"); var outbox = Path.Combine(dir, "outbox.json");
        var (a, ra) = await OutSender(outbox, OB, OC);
        var (pc, rc) = OutPhone("C", "device-cccc", AC, ra.Port);
        Hub? pb = null;
        try
        {
            await H.Until(() => ra.Up("device-cccc"), "C connected", 5);
            var h = a.SendText("to everyone", null);
            await H.Until(() => rc.Got().Count == 1, "C has it", 5);
            try { await H.Until(() => Outbox.Load(outbox).FirstOrDefault()?.To.SequenceEqual(["device-bbbb"]) == true, "saved for B only", 5); }
            catch (Exception) { throw new Exception($"saved for B only; outbox: {(File.Exists(outbox) ? File.ReadAllText(outbox) : "none")}; A saw: {string.Join(" | ", ra.All.OfType<HubEvent.Outgoing>().Select(o => string.Join(",", o.Item.States.Select(x => x.Key + "=" + x.Value.Kind))))}"); }
            a.Stop();
            (a, ra) = await OutSender(outbox, OB, OC);
            HubRec rb; (pb, rb) = OutPhone("B", "device-bbbb", AB, ra.Port);
            await H.Until(() => rb.Got().Count == 1, "B gets it after the restart", 10);
            H.Eq("to everyone", rb.Got()[0].Text, "the text");
            H.True(ra.Last(h.Id)?.To.SequenceEqual(["device-bbbb"]) == true, "restored for B only");
            await Task.Delay(500);
            H.Eq(1, rc.Got().Count, "C isn't sent a second copy");
        }
        finally { pb?.Stop(); pc.Stop(); a.Stop(); }
    }

    public static async Task OutboxGone()
    {
        var dir = H.TempDir("outbox-gone"); var outbox = Path.Combine(dir, "outbox.json");
        var file = H.RandomFile(dir, "gone.png", 1000);
        var (a, _) = await OutSender(outbox, OB);
        a.SendFile(file, "device-bbbb");
        await H.Until(() => Outbox.Load(outbox).Count == 1, "saved", 5);
        a.Stop();
        var id = Outbox.Load(outbox)[0].Id;
        File.Delete(file);
        HubRec ra; (a, ra) = await OutSender(outbox, OB);
        try
        {
            await H.Until(() => ra.Last(id) != null, "shown failed", 5);
            var st = ra.Last(id)!.Summary;
            H.True(st.Kind == ItemStateKind.Failed && st.Error == "it's no longer there", "failed: it's no longer there");
            H.True(!File.Exists(outbox), "nothing left owed");
        }
        finally { a.Stop(); }
    }

    public static async Task OutboxForget()
    {
        var dir = H.TempDir("outbox-forget"); var outbox = Path.Combine(dir, "outbox.json");
        var (a, _) = await OutSender(outbox, OB, OC);
        try
        {
            a.SendText("for both", null);
            await H.Until(() => Outbox.Load(outbox).FirstOrDefault()?.To.Length == 2, "saved", 5);
            a.Remove("device-bbbb");
            await H.Until(() => Outbox.Load(outbox).FirstOrDefault()?.To.SequenceEqual(["device-cccc"]) == true, "only C left", 5);
            a.Remove("device-cccc");
            await H.Until(() => !File.Exists(outbox), "nothing left", 5);
        }
        finally { a.Stop(); }
    }

    public static async Task OutboxReplaced()
    {
        var dir = H.TempDir("outbox-replace"); var outbox = Path.Combine(dir, "outbox.json");
        var (a, ra) = await OutSender(outbox, OB);
        a.SendText("queued before", "device-bbbb");
        await H.Until(() => Outbox.Load(outbox).Count == 1, "saved", 5);
        a.Add(OB, pairing: false);
        var (p, rp) = OutPhone("B", "device-bbbb", AB, ra.Port);
        try
        {
            await H.Until(() => rp.Got().Count == 1, "arrives through the new Session", 10);
            H.Eq("queued before", rp.Got()[0].Text, "the text");
        }
        finally { p.Stop(); a.Stop(); }
    }

    public static async Task OutboxFastAnswers()
    {
        var dir = H.TempDir("outbox-fast"); var outbox = Path.Combine(dir, "outbox.json");
        var (a, ra) = await OutSender(outbox, OB);
        var (p, rp) = OutPhone("B", "device-bbbb", AB, ra.Port);
        try
        {
            await H.Until(() => ra.Up("device-bbbb"), "B connected", 5);
            var sent = Enumerable.Range(0, 200).Select(i => a.SendText($"n{i}", "device-bbbb").Id).ToList();
            await H.Until(() => rp.Got().Count == 200, "all arrive", 10);
            await H.Until(() => sent.All(id => ra.Last(id)?.Summary.Kind == ItemStateKind.Delivered), "every row says delivered", 5);
            await H.Until(() => !File.Exists(outbox), "nothing owed", 5);
        }
        finally { p.Stop(); a.Stop(); }
    }

        /// <summary>Review (beta.11): an item fully sent but not yet answered counts as delivered. Replacing the partner's Session, or
    /// quitting, resets it to "waiting" inside the Session; that must not put it in the outbox or send it again.</summary>
    public static async Task OutboxUnanswered()
    {
        var dir = H.TempDir("outbox-unacked"); var outbox = Path.Combine(dir, "outbox.json");
        var (a, ra) = await OutSender(outbox, OB);
        var rb = new HubRec();
        var bc = new HubConfig
        {
            Name = "B", DeviceId = "device-bbbb", DownloadDir = H.TempDir("B"), Port = 0, BindHost = "127.0.0.1",
            Tune = c => new SessionConfig { Token = c.Token, Name = c.Name, DownloadDir = c.DownloadDir, DeviceId = c.DeviceId, External = c.External,
                                            Advertise = c.Advertise, Backoff = [0.2, 0.4], DialTimeout = TimeSpan.FromSeconds(2), HoldTextAcksForTests = true },
        };
        var pb = new Hub(bc, [P("device-aaaa", "A", AB, "connect", ra.Port)], rb.Add);
        pb.Start();
        try
        {
            await H.Until(() => ra.Up("device-bbbb"), "B connected", 5);
            var h = a.SendText("once", "device-bbbb");
            await H.Until(() => rb.Got().Count == 1, "B has it", 5);
            await H.Until(() => ra.Last(h.Id)?.Summary.Kind == ItemStateKind.Sent, "sent, not answered", 5);
            await H.Until(() => !File.Exists(outbox), "not owed", 5);
            a.Add(OB, pairing: false);   // the partner's Session is replaced (as when it moves address)
            await H.Until(() => rb.Connects("device-aaaa") >= 2, "B back", 10);
            await Task.Delay(500);
            H.Eq(1, rb.Got().Count, "not sent a second time");
            a.Stop();
            await Task.Delay(300);
            H.True(!File.Exists(outbox), "quitting didn't put it in the outbox");
        }
        finally { pb.Stop(); a.Stop(); }
    }

    /// <summary>Review (beta.11): re-pairing pairs under a new id, forgets the older pairing, then renames the new one to the same
    /// device id. What the older pairing was owed must go on.</summary>
    public static async Task OutboxRePair()
    {
        var dir = H.TempDir("outbox-repair"); var outbox = Path.Combine(dir, "outbox.json");
        var (a, ra) = await OutSender(outbox, OB);
        Hub? p = null;
        try
        {
            a.SendText("before re-pairing", "device-bbbb");
            await H.Until(() => Outbox.Load(outbox).Count == 1, "saved", 5);
            var fresh = Secrets.NewToken();
            a.Add(P("pairing-1", "B", fresh, "listen"), pairing: false);
            a.Remove("device-bbbb");
            a.Rename("pairing-1", "device-bbbb");
            await H.Until(() => Outbox.Load(outbox).FirstOrDefault()?.To.SequenceEqual(["device-bbbb"]) == true, "still owed after the re-pair", 5);
            HubRec rp; (p, rp) = OutPhone("B", "device-bbbb", fresh, ra.Port);
            await H.Until(() => rp.Got().Count == 1, "arrives", 10);
            H.Eq("before re-pairing", rp.Got()[0].Text, "the text");
        }
        finally { p?.Stop(); a.Stop(); }
    }

    public static Task OutboxSweep()
    {
        var dir = H.TempDir("outbox-sweep"); var pasted = Path.Combine(dir, "Pasted");
        Directory.CreateDirectory(pasted);
        var old = DateTime.UtcNow.AddDays(-3);
        string Make(string name, DateTime at) { var u = Path.Combine(pasted, name); File.WriteAllBytes(u, [1]); File.SetLastWriteTimeUtc(u, at); return u; }
        var oldUnneeded = Make("a.png", old); var oldNeeded = Make("b.png", old); var recent = Make("c.png", DateTime.UtcNow);
        var sub = Path.Combine(pasted, "UUID-1"); Directory.CreateDirectory(sub);
        File.WriteAllBytes(Path.Combine(sub, "photo.heic"), [2]); Directory.SetLastWriteTimeUtc(sub, old);
        var outbox = Path.Combine(dir, "outbox.json");
        Outbox.Save(outbox, [new OutboxEntry { Id = "1", Kind = "file", Path = oldNeeded, To = ["x"] },
                             new OutboxEntry { Id = "2", Kind = "file", Path = Path.Combine(sub, "photo.heic"), To = ["x"] }]);
        H.Eq(1, Outbox.SweepUnsent(pasted, outbox, TimeSpan.FromDays(1)), "one removed");
        H.True(!File.Exists(oldUnneeded) && File.Exists(oldNeeded) && File.Exists(recent) && Directory.Exists(sub), "keeps what is owed or recent");
        return Task.CompletedTask;
    }

    public static async Task HubWrongSecret()
    {
        var (a, ra, b, _, c, _) = await Triangle();
        var rx = new HubRec();
        var x = new Hub(HubCfg("X", "device-xxxx"), [P("device-aaaa", "A", Secrets.NewToken(), "connect", ra.Port)], rx.Add);
        x.Start();
        try
        {
            await H.Until(() => rx.All.OfType<HubEvent.Status>().Any(s => s.Text.StartsWith("Refused")), "refused", 5);
            H.True(!rx.Up("device-aaaa"), "never connected");
            H.True(ra.Connects("device-bbbb") == 1 && ra.Connects("device-cccc") == 1, "others untouched");
        }
        finally { x.Stop(); a.Stop(); b.Stop(); c.Stop(); }
    }

    public static async Task HubReplace()
    {
        var (a, ra, b, _, c, _) = await Triangle();
        try
        {
            using var raw = await RawClient.Connect(ra.Port!.Value);
            H.Eq("hello_ok", (await raw.Hello(AB, "B again"))?.Type, "accepted");
            await H.Until(() => ra.Connects("device-bbbb") >= 2, "B reconnects", 5);
            H.True(ra.Connects("device-cccc") == 1 && ra.Up("device-cccc"), "C's link never touched");
        }
        finally { a.Stop(); b.Stop(); c.Stop(); }
    }

    public static async Task HubOffline()
    {
        var (a, ra, b, rb, c, _) = await Triangle();
        var cport = c.BoundPort!.Value;
        c.Stop();
        Hub? c2 = null;
        try
        {
            await H.Until(() => !rb.Up("device-cccc"), "C gone", 10);
            var t = b.SendText("while C was away", null);
            await H.Until(() => ra.Got("device-bbbb").Any(i => i.Text == "while C was away"), "A has it", 5);
            H.Eq(1, rb.Last(t.Id)!.Delivered, "1 of 2 so far");
            var rc2 = new HubRec();
            c2 = new Hub(HubCfg("C", "device-cccc", cport), [P("device-aaaa", "A", AC, "connect", ra.Port), P("device-bbbb", "B", BC, "listen")], rc2.Add);
            c2.Start();
            await H.Until(() => rc2.Got("device-bbbb").Any(i => i.Text == "while C was away"), "C gets it after coming back", 20);
            await H.Until(() => rb.Last(t.Id)?.Delivered == 2, "2/2", 5);
        }
        finally { a.Stop(); b.Stop(); c2?.Stop(); }
    }

    public static async Task HubPairing()
    {
        var (a, ra, b, _, c, _) = await Triangle();
        var rd = new HubRec();
        const string code = "PAIRD12345";
        a.Add(P("pairing-1", "New computer", code, "listen"), pairing: true);
        var d = new Hub(HubCfg("D", "device-dddd"), [P("pairing-1", "A", code, "connect", ra.Port)], rd.Add);
        d.Start();
        try
        {
            await H.Until(() => rd.Up("pairing-1") && ra.Up("pairing-1"), "D paired", 10);
            var ak = ra.All.OfType<HubEvent.Rekeyed>().FirstOrDefault(r => r.Partner == "pairing-1")?.Token;
            var dk = rd.All.OfType<HubEvent.Rekeyed>().FirstOrDefault(r => r.Partner == "pairing-1")?.Token;
            H.True(ak != null && ak == dk, "same new secret");
            H.True(ra.All.Contains(new HubEvent.PeerDevice("pairing-1", "device-dddd")), "A learns D's device id");
            H.True(ra.Connects("device-bbbb") == 1 && ra.Connects("device-cccc") == 1, "others untouched");
            a.Remove("pairing-1");
            await H.Until(() => !rd.Up("pairing-1"), "D dropped after Forget", 5);
        }
        finally { d.Stop(); a.Stop(); b.Stop(); c.Stop(); }
    }

    public static async Task HubResponder()
    {
        var port = Random.Shared.Next(40000, 49000);
        string s1 = Secrets.NewToken(), s2 = Secrets.NewToken();
        var hub = new Hub(HubCfg("disc", "device-disc"), [P("p1", "One", s1, "listen"), P("p2", "Two", s2, "listen"), P("p3", "Dialled", Secrets.NewToken(), "connect", 9)], _ => { });
        hub.Start();
        hub.StartResponder(port);
        try
        {
            await Task.Delay(300);
            var found = await Discovery.SearchAsync(port, TimeSpan.FromSeconds(0.6), ["127.0.0.1"]);
            H.True(found.Select(f => f.PairId).Order().SequenceEqual(new[] { PairCode.PairId(s1), PairCode.PairId(s2) }.Order()), "one reply per listening partner");
            H.True(found.All(f => f.Device == "device-disc"), "device id in each reply");
        }
        finally { hub.Stop(); }
    }

    public static async Task HubFindMoved()
    {
        var secret = Secrets.NewToken();
        HubRec rl = new(), rd = new();
        var l = new Hub(HubCfg("moved-l", "device-moved"), [P("device-dialer", "D", secret, "listen")], rl.Add);
        l.Start();
        await H.Until(() => rl.Port != null, "listening", 5);
        var dport = Random.Shared.Next(40000, 49000);
        l.StartResponder(dport);
        var d = new Hub(HubCfg("moved-d", "device-dialer"), [P("device-moved", "L", secret, "connect", rl.Port) with { Hosts = ["192.0.2.1"] }], rd.Add);
        d.Start();
        try
        {
            await Task.Delay(300);
            await d.FindMoved(dport, ["127.0.0.1"], TimeSpan.FromSeconds(0.5));
            await H.Until(() => rd.Up("device-moved"), "found and connected", 10);
            H.True(rd.All.OfType<HubEvent.PeerAddresses>().Any(p => p.Addrs.SequenceEqual(["127.0.0.1", "192.0.2.1"])), "new address first");
        }
        finally { d.Stop(); l.Stop(); }
    }

    // ---------- beta.8: pairing bookkeeping (the "second computer never finishes" fix) ----------

    static PairingBook Book(params Partner[] peers) => new(new DeviceConfig { DeviceId = "device-self", Peers = [.. peers] });
    static readonly Partner Existing = new() { Id = "device-pc01", Name = "STUDIO-PC", Secret = Secrets.NewToken(), Role = "connect", Hosts = ["10.0.0.2"] };
    static bool Finished(List<PairingBook.Effect> fx) => fx.Any(f => f is PairingBook.Effect.Finished);

    public static Task PbOldId()
    {
        var b = Book(Existing);
        b.Begin(new Partner { Id = "pairing-1", Name = "New computer", Secret = "ABCDE12345", Role = "listen" });
        var r1 = b.Handle(new HubEvent.PeerDevice("pairing-1", "device-m3m3"));
        H.True(r1.Effects.Any(f => f is PairingBook.Effect.HubRename { Old: "pairing-1", New: "device-m3m3" }), "rename to the device id");
        var r2 = b.Handle(new HubEvent.Connected("pairing-1", "M3 MacBook"));   // late, old id
        H.Eq(new HubEvent.Connected("device-m3m3", "M3 MacBook") as HubEvent, r2.Event, "event mapped to the new id");
        H.True(Finished(r2.Effects) && b.Pending == null, $"pairing finished: {string.Join(",", r2.Effects)}");
        H.True(b.Config.Peers.Select(p => p.Id).SequenceEqual(["device-pc01", "device-m3m3"]), "existing kept, new saved");
        return Task.CompletedTask;
    }

    public static Task PbConnectedFirst()
    {
        var b = Book();
        b.Begin(new Partner { Id = "pairing-1", Name = "x", Secret = "ABCDE12345", Role = "connect", Hosts = ["10.0.0.9"] });
        H.True(Finished(b.Handle(new HubEvent.Connected("pairing-1", "Intel Mac")).Effects), "finished");
        H.True(b.Handle(new HubEvent.PeerDevice("pairing-1", "device-intel")).Effects.Any(f => f is PairingBook.Effect.Save), "renamed and saved");
        H.True(b.Config.Peers.Select(p => p.Id).SequenceEqual(["device-intel"]), "saved under the device id");
        return Task.CompletedTask;
    }

    public static Task PbLateRekey()
    {
        var b = Book();
        b.Begin(new Partner { Id = "pairing-1", Name = "x", Secret = "ABCDE12345", Role = "listen" });
        b.Handle(new HubEvent.PeerDevice("pairing-1", "device-m3m3"));
        var tok = Secrets.NewToken();
        b.Handle(new HubEvent.Rekeyed("pairing-1", tok));
        b.Handle(new HubEvent.Connected("pairing-1", "M3"));
        H.Eq(tok, b.Config.Partner("device-m3m3")?.Secret, "secret on the saved partner");
        var tok2 = Secrets.NewToken();
        b.Handle(new HubEvent.Rekeyed("pairing-1", tok2));
        H.Eq(tok2, b.Config.Partner("device-m3m3")?.Secret, "a later rekey with the old id still lands");
        return Task.CompletedTask;
    }

    public static Task PbRePair()
    {
        var b = Book(Existing);
        b.Begin(new Partner { Id = "pairing-2", Name = "x", Secret = "ZZZZZ99999", Role = "listen" });
        var r = b.Handle(new HubEvent.PeerDevice("pairing-2", "device-pc01"));
        H.True(r.Effects[0] is PairingBook.Effect.HubRemove { Id: "device-pc01" }, "old pairing's Session goes first");
        b.Handle(new HubEvent.Connected("pairing-2", "STUDIO-PC"));
        H.True(b.Config.Peers.Count == 1 && b.Config.Peers[0] is { Id: "device-pc01", Secret: "ZZZZZ99999", Role: "listen" }, "replaced, not duplicated");
        return Task.CompletedTask;
    }

    public static Task PbLegacy()
    {
        var b = Book(new Partner { Id = "legacy-abcd1234", Name = "PC", Secret = Secrets.NewToken(), Role = "connect", Hosts = ["10.0.0.2"] });
        b.Handle(new HubEvent.PeerDevice("legacy-abcd1234", "device-pc01"));
        var r = b.Handle(new HubEvent.Connected("legacy-abcd1234", "PC"));
        H.True(r.Event is HubEvent.Connected { Partner: "device-pc01" } && !Finished(r.Effects), "mapped, nothing finishes");
        H.True(b.Config.Peers.Select(p => p.Id).SequenceEqual(["device-pc01"]), "renamed in place");
        return Task.CompletedTask;
    }

    /// <summary>End to end with real Hubs and window-like delivery (events hop to another queue; renames go back async).</summary>
    public static async Task PbHubs()
    {
        var main = new SerialQueue("fake-main");
        var book = new PairingBook(new DeviceConfig { DeviceId = "device-aaaa" });
        var ra = new HubRec(); var rd = new HubRec();
        Hub? a = null;
        a = new Hub(HubCfg("A", "device-aaaa"), [], e => main.Post(() =>
        {
            var (ev, fx) = book.Handle(e);
            ra.Add(ev);
            foreach (var f in fx)
            {
                if (f is PairingBook.Effect.HubRename rn) a!.Rename(rn.Old, rn.New);
                if (f is PairingBook.Effect.HubRemove rm) _ = Task.Run(() => a!.Remove(rm.Id));
            }
        }));
        a.Start();
        try
        {
            const string code = "PAIRM31234";
            var pending = new Partner { Id = "pairing-x", Name = "New computer", Secret = code, Role = "listen" };
            main.Sync(() => { book.Begin(pending); return 0; });
            a.Add(pending, pairing: true);
            await H.Until(() => a.BoundPort != null, "A listening", 5);
            var d = new Hub(HubCfg("D", "device-m3m3"), [P("pairing-y", "A", code, "connect", a.BoundPort)], rd.Add);
            d.Start();
            try
            {
                await H.Until(() => main.Sync(() => book.Pending == null && book.Config.Partner("device-m3m3") != null), "pairing finished and saved", 10);
                H.Eq(64, main.Sync(() => book.Config.Partner("device-m3m3")!.Secret.Length), "long-term secret saved");
                var t = d.SendText("hello A", null);
                await H.Until(() => ra.Got("device-m3m3").Count == 1, "text arrives under the new id", 5);
                await H.Until(() => rd.Last(t.Id)?.Summary.Kind == ItemStateKind.Delivered, "delivered", 5);
            }
            finally { d.Stop(); }
        }
        finally { a.Stop(); main.Dispose(); }
    }

    // ---------- beta.8: Explorer hand-off and the opacity setting

    public static Task StageArgs()
    {
        var dir = Directory.CreateTempSubdirectory("ll-stage").FullName;
        try
        {
            var f = Path.Combine(dir, "note one & ü.txt"); File.WriteAllText(f, "x");
            var d = Path.Combine(dir, "Folder & One"); Directory.CreateDirectory(d);
            H.Eq(null, StageRequest.FromArgs(["--demo"]), "no flag");
            var got = StageRequest.FromArgs(["--stage", f, "\"" + d + "\\\"", f.ToUpperInvariant(), "relative.txt", Path.Combine(dir, "..", "x"),
                                             Path.Combine(dir, "missing.txt"), "", "a\0b"])!;
            H.Eq(2, got.Count, "file + folder, the rest refused");
            H.Eq(f, got[0], "file kept as given");
            H.Eq(d, got[1], "folder: quotes and trailing slash dropped");
            H.Eq(0, StageRequest.FromArgs(["--stage"])!.Count, "flag alone = just show the window");
            var many = Enumerable.Range(0, 300).Select(i => $"C:\\x\\{i}.txt");
            H.Eq(StageRequest.MaxPaths, StageRequest.Clean(many, _ => true).Count, "capped");
            H.Eq(null, StageRequest.Decode("hello\nC:\\x", _ => true), "foreign message ignored");
            var back = StageRequest.Decode(StageRequest.Encode([f, d]))!;
            H.True(back.SequenceEqual([f, d]), "encode/decode round trip");
            H.Eq(0, StageRequest.Decode(StageRequest.Encode([f.Replace("note", "gone")]))!.Count, "decode re-checks paths");
        }
        finally { Directory.Delete(dir, true); }
        return Task.CompletedTask;
    }

    public static async Task StagePipe()
    {
        var dir = Directory.CreateTempSubdirectory("ll-stagepipe").FullName;
        var name = "Lan-Line.Stage.test." + Guid.NewGuid().ToString("N");
        using var cts = new CancellationTokenSource();
        var got = new ConcurrentQueue<List<string>>();
        try
        {
            var f = Path.Combine(dir, "a.txt"); File.WriteAllText(f, "x");
            // the client starts first, like a second Explorer launch racing the first window
            var send = Task.Run(() => StageRequest.TrySend(name, [f, "C:\\nope\\gone.txt"], TimeSpan.FromSeconds(5)));
            await Task.Delay(400);
            var server = StageRequest.Listen(name, got.Enqueue, cts.Token);
            H.True(await send, "sent after the server came up");
            await H.Until(() => got.Count == 1, "request arrived", 5);
            got.TryDequeue(out var first);
            H.True(first!.SequenceEqual([f]), "only the existing path staged");
            H.True(StageRequest.TrySend(name, [], TimeSpan.FromSeconds(2)), "show-only request");
            await H.Until(() => got.Count == 1, "second request", 5);
            H.True(!StageRequest.TrySend("Lan-Line.Stage.nobody." + Guid.NewGuid().ToString("N"), [f], TimeSpan.FromMilliseconds(600)), "no window: false");
            cts.Cancel();
            await server;
        }
        finally { cts.Cancel(); Directory.Delete(dir, true); }
    }

    public static Task KeepRunning()
    {
        var s = new StorageSettings();
        H.Eq(null, s.KeepRunningWhenClosed, "unset by default");
        H.True(s.KeepRunningWhenClosedValue, "on by default");
        H.True(!s.TrayHintShown, "hint not shown yet");
        var dir = Directory.CreateTempSubdirectory("ll-keep").FullName;
        try
        {
            var path = Path.Combine(dir, "settings.json");
            File.WriteAllText(path, "{\"retentionDays\":30,\"confirmed\":true,\"glassOpacity\":0.5}");   // a beta.8 file
            var old = StorageSettings.Load(path);
            H.True(old.KeepRunningWhenClosedValue && old.GlassOpacity == 0.5, "old file loads as on");
            old.KeepRunningWhenClosed = false; old.TrayHintShown = true; old.Save(path);
            var back = StorageSettings.Load(path);
            H.True(!back.KeepRunningWhenClosedValue && back.TrayHintShown, "saved and read back");
            H.True(File.ReadAllText(path).Contains("\"keepRunningWhenClosed\": false"), "same key as the Mac");
            H.True(old.Copy().KeepRunningWhenClosed == false && old.Copy().TrayHintShown, "copied with the other settings");
        }
        finally { Directory.Delete(dir, true); }
        return Task.CompletedTask;
    }

    // Arrival notifications (beta.10): the same cases as the Mac's ArrivalNoticeTests, so both apps word them alike.
    public static Task ArrivalNotices()
    {
        static Item Txt(string id, string t) => new(id, true, t, null, t.Length, null, ItemState.ReceivedState);
        static Item File(string id, string n, long size) => new(id, true, null, n, size, @"C:\dl\" + n, ItemState.ReceivedState);
        static Item Folder(string id, string n, int c, long size) => new(id, true, null, n, size, @"C:\dl\" + n, ItemState.ReceivedState, c);
        var t = LanLine.Core.ArrivalNotices.Make([("Studio PC", Txt("a", "  hello\n\n  there  "))]);
        H.True(t == new ArrivalNotice("Studio PC", "hello there", [NoticeAction.Copy], "a"), $"text: {t}");
        var words = string.Join(" ", Enumerable.Repeat("lorem", 60));
        var p = LanLine.Core.ArrivalNotices.Preview(words);
        H.True(p.EndsWith("lorem…") && p.Length == 156, $"cut at a word: {p.Length}");
        H.Eq(new string('x', 160) + "…", LanLine.Core.ArrivalNotices.Preview(new string('x', 200)), "no space: hard cut");
        H.Eq("(empty message)", LanLine.Core.ArrivalNotices.Preview(" \n\t "), "empty");
        var pdf = LanLine.Core.ArrivalNotices.Make([("MacBook Pro", File("f", "Q4 plan.pdf", 412_000))]);
        H.True(pdf == new ArrivalNotice("MacBook Pro", "Q4 plan.pdf · 412 KB", [NoticeAction.Open, NoticeAction.Reveal], "f"), $"pdf: {pdf}");
        var png = LanLine.Core.ArrivalNotices.Make([("MacBook Pro", File("g", "Hero.PNG", 2_400_000))])!;
        H.Eq("Hero.PNG · 2 MB", png.Body, "picture body");
        H.Eq(@"C:\dl\Hero.PNG", png.ImagePath, "picture thumbnail");
        H.Eq("Photos · 1 file, 3.5 GB", LanLine.Core.ArrivalNotices.Make([("Studio PC", Folder("d", "Photos", 1, 3_500_000_000))])!.Body, "folder 1");
        H.Eq("Photos · 12 files, 40 MB", LanLine.Core.ArrivalNotices.Make([("Studio PC", Folder("d", "Photos", 12, 40_000_000))])!.Body, "folder 12");
        var burst = LanLine.Core.ArrivalNotices.Make([("Studio PC", File("1", "a.png", 10)), ("Studio PC", Txt("2", "hi")), ("Studio PC", File("3", "b.txt", 10)), ("Studio PC", Folder("4", "F", 2, 20))]);
        H.True(burst == new ArrivalNotice("Studio PC", "Sent you 2 files, 1 folder and 1 message", []), $"burst: {burst}");
        var many = LanLine.Core.ArrivalNotices.Make([("Studio PC", Txt("1", "a")), ("Intel Mac", Txt("2", "b")), ("Studio PC", Txt("3", "c"))]);
        H.True(many == new ArrivalNotice("Lan-Line", "3 messages from Studio PC and Intel Mac", []), $"several: {many}");
        H.True(LanLine.Core.ArrivalNotices.Failed("Studio PC", "big.zip", "not enough disk space") == new ArrivalNotice("Couldn't receive big.zip", "From Studio PC: not enough disk space", []), "failed");
        H.True(LanLine.Core.ArrivalNotices.Make([]) == null, "nothing");

        var s = new StorageSettings();
        H.True(s.NotifyOnArrivalValue && s.PopUpOnArrivalValue, "both on by default");
        var dir = Directory.CreateTempSubdirectory("ll-notify").FullName;
        try
        {
            var path = Path.Combine(dir, "settings.json");
            System.IO.File.WriteAllText(path, "{\"retentionDays\":0,\"confirmed\":true,\"keepRunningWhenClosed\":true}");   // a beta.9 file
            var old = StorageSettings.Load(path);
            H.True(old.NotifyOnArrivalValue && old.PopUpOnArrivalValue, "old file loads as on");
            old.NotifyOnArrival = false; old.PopUpOnArrival = false;
            old.Save(path);
            var back = StorageSettings.Load(path);
            H.True(!back.NotifyOnArrivalValue && !back.PopUpOnArrivalValue, "off round-trips");
            var json = System.IO.File.ReadAllText(path);
            H.True(json.Contains("\"notifyOnArrival\": false") && json.Contains("\"popUpOnArrival\": false"), "same keys as the Mac: " + json);
        }
        finally { Directory.Delete(dir, true); }
        return Task.CompletedTask;
    }

    public static async Task NoticeLinks()
    {
        foreach (var a in new[] { NoticeAction.Copy, NoticeAction.Open, NoticeAction.Reveal, NoticeAction.Show })
        {
            var link = LanLine.Core.ArrivalNotices.Link(a, "id 1&x");
            H.True(LanLine.Core.ArrivalNotices.ParseLink(link) is { } r && r.Action == a && r.Id == "id 1&x", $"round trip {a}: {link}");
        }
        H.True(LanLine.Core.ArrivalNotices.ParseLink("lanline://notify?a=show") is { Action: NoticeAction.Show, Id: null }, "show without an item");
        foreach (var bad in new[] { "lanline://notify?a=copy", "lanline://notify?a=delete&id=1", "lanline://stage?a=copy&id=1", "https://notify?a=copy&id=1",
                                    "lanline://notify?a=open&id=", "lanline://notify?a=open&id=" + new string('x', 400), null, "not a url" })
            H.True(LanLine.Core.ArrivalNotices.ParseLink(bad) == null, $"refused: {bad}");
        // the pipe carries a link to the running window and keeps stage requests working
        var pipe = "Lan-Line.Test." + Guid.NewGuid().ToString("N");
        using var stop = new CancellationTokenSource();
        var got = new TaskCompletionSource<string>();
        _ = StageRequest.Listen(pipe, _ => got.TrySetResult("paths"), stop.Token, onLink: l => got.TrySetResult(l));
        var url = LanLine.Core.ArrivalNotices.Link(NoticeAction.Copy, "abc");
        H.True(StageRequest.TrySendLink(pipe, url, TimeSpan.FromSeconds(5)), "sent");
        var res = await got.Task.WaitAsync(TimeSpan.FromSeconds(10));
        stop.Cancel();
        H.Eq(url, res, "link arrived");

        // the toast XML: escaped, links per button, picture only when small enough
        var n = new ArrivalNotice("Mac <Pro>", "a & b \"c\"", [NoticeAction.Open, NoticeAction.Reveal], "i&1", @"C:\dl\pic one.png");
        var xml = ToastXml.Build(n, _ => 1000);
        var doc = System.Xml.Linq.XDocument.Parse(xml);   // well-formed
        H.Eq("lanline://notify?a=show&id=i%261", doc.Root!.Attribute("launch")!.Value, "launch link");
        H.Eq("protocol", doc.Root.Attribute("activationType")!.Value, "protocol activation");
        var texts = doc.Descendants("text").Select(x => x.Value).ToArray();
        H.True(texts.Length == 2 && texts[0] == "Mac <Pro>" && texts[1] == "a & b \"c\"", "title and body");
        H.Eq("file:///C:/dl/pic%20one.png", doc.Descendants("image").Single().Attribute("src")!.Value, "picture");
        var acts = doc.Descendants("action").Select(x => (x.Attribute("content")!.Value, x.Attribute("arguments")!.Value)).ToArray();
        H.True(acts.Length == 2 && acts[0] == ("Open", "lanline://notify?a=open&id=i%261") && acts[1] == ("Show in folder", "lanline://notify?a=reveal&id=i%261"), "buttons");
        H.True(!ToastXml.Build(n, _ => 5_000_000).Contains("<image"), "big picture left out");
        H.True(!ToastXml.Build(new ArrivalNotice("t", "b", []), _ => 1).Contains("<actions>"), "summary: no buttons");
    }

    public static Task UnreadAndSignIn()
    {
        var u = new Unread();
        H.True(u.Badge == null && u.Phrase == null, "none");
        u.Arrived(inUse: true);
        H.Eq(0, u.Count, "seen straight away");
        u.Arrived(false); u.Arrived(false);
        H.True(u.Badge == "2" && u.Phrase == "2 new", "two");
        u.Seen();
        H.Eq(0, u.Count, "cleared");
        for (var i = 0; i < 99; i++) u.Arrived(false);
        H.Eq("99", u.Badge, "99");
        u.Arrived(false);
        H.True(u.Badge == "99+" && u.Phrase == "99+ new", "capped");

        var exe = @"C:\Users\x\AppData\Local\Programs\Lan-Line\Lan-Line.exe";
        H.Eq("\"" + exe + "\" --background", SignIn.Command(exe), "command");
        H.True(SignIn.IsOn(SignIn.Command(exe), exe), "ours");
        H.True(SignIn.IsOn("\"" + exe + "\"", exe), "an older installer's value counts");
        H.True(!SignIn.IsOn(null, exe) && !SignIn.IsOn("\"D:\\Other\\Lan-Line.exe\"", exe), "missing or another copy");
        return Task.CompletedTask;
    }

    public static Task PreviewKinds()
    {
        foreach (var n in new[] { "a.PNG", "b.jpeg", "c.heic", "d.webp" }) H.Eq(PreviewKind.Image, Preview.Of(n, false), n);
        foreach (var n in new[] { "notes.txt", "README.md", "app.cs", "x.Swift", "Dockerfile", ".gitignore", "run.ps1", "data.jsonl" })
            H.Eq(PreviewKind.Text, Preview.Of(n, false), n);
        foreach (var n in new[] { "Q4 plan.pdf", "render.mov", "deck.pptx", "archive.zip", "noext" }) H.Eq(PreviewKind.Thumbnail, Preview.Of(n, false), n);
        H.Eq(PreviewKind.Thumbnail, Preview.Of("photos.png", true), "a folder named like a picture");
        H.Eq(1, Preview.Step(0, 3, 1), "next");
        H.Eq(2, Preview.Step(2, 3, 1), "stays on the last");
        H.Eq(0, Preview.Step(0, 3, -1), "stays on the first");
        H.Eq(-1, Preview.Step(0, 0, 1), "nothing to page");
        H.Eq("2 of 5", Preview.Position(1, 5), "position");
        H.Eq(null, Preview.Position(0, 1), "single file: no position");
        return Task.CompletedTask;
    }

    // ---------- live progress and cancel (beta.10): the same cases as the Mac's TransferTests / TransferRateTests

    public static Task TransferRates()
    {
        var t0 = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var r = new TransferRate();
        H.Eq("0%", r.Describe(0, 100_000_000), "nothing yet");
        r.Update(0, t0); r.Update(10_000_000, t0.AddSeconds(1)); r.Update(20_000_000, t0.AddSeconds(2));
        H.True(r.BytesPerSecond == 10_000_000, "10 MB/s");
        H.Eq("20% · 10 MB/s · 8 s left", r.Describe(20_000_000, 100_000_000), "describe");
        r = new TransferRate();
        r.Update(0, t0); r.Update(10_000_000, t0.AddSeconds(1)); r.Update(10_500_000, t0.AddSeconds(1.1));
        H.True(r.BytesPerSecond == 10_000_000, "noise skipped");
        r.Update(30_000_000, t0.AddSeconds(2));
        H.True(Math.Abs(r.BytesPerSecond!.Value - 13_000_000) < 1, "smoothed");
        r.Update(1_000, t0.AddSeconds(3));
        H.True(r.BytesPerSecond == null, "restart resets");
        H.Eq("a few seconds left", TransferRate.TimeLeft(3), "few");
        H.Eq("12 s left", TransferRate.TimeLeft(12.4), "s");
        H.Eq("3 min left", TransferRate.TimeLeft(170), "min");
        H.Eq("1 h left", TransferRate.TimeLeft(3600), "h");
        H.Eq("1 h 5 min left", TransferRate.TimeLeft(3900), "h min");
        r = new TransferRate();
        r.Update(0, t0); r.Update(1_500_000_000, t0.AddSeconds(1));
        H.Eq("50% · 1.5 GB/s · a few seconds left", r.Describe(1_500_000_000, 3_000_000_000), "GB/s");
        return Task.CompletedTask;
    }

    static SessionConfig PCfg(string tag, bool cancelCap = true) => new()
    {
        Token = H.Token, Name = tag, DownloadDir = H.TempDir(tag), Backoff = [0.2, 0.4], DialTimeout = TimeSpan.FromSeconds(2),
        ProgressDelay = TimeSpan.Zero, ProgressInterval = TimeSpan.FromSeconds(0.02),
        Caps = cancelCap ? ["sha_end", "folders", "multi", "cancel"] : ["sha_end", "folders", "multi"],
    };

    static async Task<(Session Srv, Recorder Sr, Session Cli, Recorder Cr)> PPair(string tag, bool receiverCancelCap = true, bool fast = true)
    {
        var (srv, sr, port) = await H.Listener(tag + "-srv", fast ? PCfg(tag + "-srv", receiverCancelCap) : null);
        var cr = new Recorder();
        var cli = new Session(new Role.Dial(["127.0.0.1"], port), fast ? PCfg(tag + "-cli") : H.Cfg(tag + "-cli"), cr.Add);
        cli.Start();
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        return (srv, sr, cli, cr);
    }

    static List<ItemState> Incoming(Recorder r, string id) => r.All.OfType<SessionEvent.Incoming>().Where(i => i.Item.Id == id).Select(i => i.Item.State).ToList();
    static bool IsCancelled(ItemState? s) => s?.Kind == ItemStateKind.Cancelled;

    public static async Task IncomingProgress()
    {
        var (srv, sr, cli, cr) = await PPair("iprog");
        using var _ = srv; using var __ = cli;
        var f = cli.SendFile(H.RandomFile(H.TempDir("iprog-src"), "big.bin", 40 << 20));
        await H.Until(() => cr.Delivered(f.Id), "delivered", 60);
        var fr = Incoming(sr, f.Id).Where(x => x.Kind == ItemStateKind.Receiving).Select(x => x.Progress).ToList();
        H.True(fr.Count > 1, $"progress while arriving ({fr.Count})");
        H.True(fr.SequenceEqual(fr.Order()), "never backwards");
        H.True(fr[^1] <= 1, "at most 100 %");
        H.Eq(f.Id, sr.Received.Single().Id, "then the file itself, same id");
        H.Eq(40L << 20, sr.All.OfType<SessionEvent.Incoming>().First().Item.Size, "size on the card");
    }

    public static async Task SmallFileNoCard()
    {
        var (srv, sr, cli, cr) = await PPair("ismall", fast: false);
        using var _ = srv; using var __ = cli;
        var f = cli.SendFile(H.RandomFile(H.TempDir("ismall-src"), "s.bin", 200_000));
        await H.Until(() => cr.Delivered(f.Id), "delivered");
        H.Eq(0, Incoming(sr, f.Id).Count, "no card for a quick file");
    }

    static async Task SenderCancel(string tag, bool newReceiver)
    {
        var (srv, sr, cli, cr) = await PPair(tag, receiverCancelCap: newReceiver);
        using var _ = srv; using var __ = cli;
        var once = 0;
        cr.Hook = e =>
        {
            if (e is SessionEvent.Outgoing { Item: { State: { Kind: ItemStateKind.Sending, Progress: > 0.1 } } it } && Interlocked.Exchange(ref once, 1) == 0) cli.CancelOnQueue(it.Id);
        };
        var f = cli.SendFile(H.RandomFile(H.TempDir(tag + "-src"), "stop.bin", 60 << 20));
        await H.Until(() => IsCancelled(cr.LastState(f.Id)), "cancelled", 30);
        var after = cli.SendText("after");
        await H.Until(() => cr.Delivered(after.Id), "next item");
        H.Eq(after.Id, sr.Received.Single().Id, "only the next item lands");
        if (newReceiver)
        {
            await H.Until(() => IsCancelled(Incoming(sr, f.Id).LastOrDefault()), "receiver card cancelled", 5);
            H.Eq(0, sr.ReceiveFailures.Count, "a cancel isn't a failure");
        }
        else H.Eq("size mismatch", string.Join("|", sr.ReceiveFailures), "an older receiver refuses the short file");
        H.True(IsCancelled(cr.LastState(f.Id)), "the late ack doesn't change it");
        H.Eq(0, H.Parts(srv.Config.DownloadDir).Length, "no part files");
    }

    public static Task SenderCancels() => SenderCancel("scan", true);
    public static Task SenderCancelsOldReceiver() => SenderCancel("sold", false);

    public static async Task ReceiverCancels()
    {
        var (srv, sr, cli, cr) = await PPair("rcan");
        using var _ = srv; using var __ = cli;
        var once = 0;
        sr.Hook = e =>
        {
            if (e is SessionEvent.Incoming { Item: { State: { Kind: ItemStateKind.Receiving, Progress: > 0.1 } } it } && Interlocked.Exchange(ref once, 1) == 0) srv.CancelIncomingOnQueue(it.Id);
        };
        var f = cli.SendFile(H.RandomFile(H.TempDir("rcan-src"), "nope.bin", 60 << 20));
        await H.Until(() => IsCancelled(cr.LastState(f.Id)), "sender sees it cancelled", 30);
        H.True(IsCancelled(Incoming(sr, f.Id).LastOrDefault()), "receiver card cancelled");
        var after = cli.SendText("after");
        await H.Until(() => cr.Delivered(after.Id), "next item");
        H.Eq(after.Id, sr.Received.Single().Id, "only the next item lands");
        H.Eq(0, sr.ReceiveFailures.Count, "no failure note");
        H.Eq(0, H.Parts(srv.Config.DownloadDir).Length, "no part files");
    }

    public static async Task CancelQueued()
    {
        var (srv, sr, cli, cr) = await PPair("cq");
        using var _ = srv; using var __ = cli;
        var src = H.TempDir("cq-src");
        var big = cli.SendFile(H.RandomFile(src, "first.bin", 40 << 20));
        var later = cli.SendFile(H.RandomFile(src, "later.bin", 1 << 20));
        cli.Cancel(later.Id);
        await H.Until(() => cr.Delivered(big.Id), "first delivered", 60);
        H.True(IsCancelled(cr.LastState(later.Id)), "queued one cancelled");
        H.Eq(big.Id, sr.Received.Single().Id, "only the first lands");
    }

    public static async Task FolderCancel()
    {
        foreach (var receiverStops in new[] { false, true })
        {
            var (srv, sr, cli, cr) = await PPair(receiverStops ? "fr" : "fs");
            using var _ = srv; using var __ = cli;
            var root = Path.Combine(H.TempDir("fold-src"), "Shoot");
            Directory.CreateDirectory(Path.Combine(root, "raw"));
            for (var i = 0; i < 6; i++) H.RandomFile(i < 3 ? Path.Combine(root, "raw") : root, $"p{i}.bin", 10 << 20);
            var once = 0;
            if (receiverStops)
                sr.Hook = e => { if (e is SessionEvent.Incoming { Item: { State: { Kind: ItemStateKind.Receiving, Progress: > 0.3 } } it } && Interlocked.Exchange(ref once, 1) == 0) srv.CancelIncomingOnQueue(it.Id); };
            else
                cr.Hook = e => { if (e is SessionEvent.Outgoing { Item: { State: { Kind: ItemStateKind.Sending, Progress: > 0.3 } } it } && Interlocked.Exchange(ref once, 1) == 0) cli.CancelOnQueue(it.Id); };
            var f = cli.SendFolder(root);
            await H.Until(() => IsCancelled(cr.LastState(f.Id)), "cancelled", 30);
            var after = cli.SendText("after");
            await H.Until(() => cr.Delivered(after.Id), "next item");
            await H.Until(() => IsCancelled(Incoming(sr, f.Id).LastOrDefault()), "receiver card cancelled", 5);
            H.Eq(after.Id, sr.Received.Single().Id, "no folder lands");
            var left = Directory.GetFileSystemEntries(srv.Config.DownloadDir);
            H.Eq(0, left.Length, "no folder and no hidden part folder: " + string.Join(", ", left));
        }
    }

    public static Task Shortcuts()
    {
        H.True(Shortcut.Parse("ctrl+alt+L") == new Shortcut(true, true, false, false, "L"), "parse");
        H.Eq("ctrl+alt+L", Shortcut.Parse("Alt + Ctrl + l")!.Text, "any order in, fixed order out");
        H.Eq("shift+cmd+Space", Shortcut.Parse("cmd+shift+space")!.Text, "space");
        H.Eq("F12", Shortcut.Parse("ctrl+f12")!.Key, "F-key");
        foreach (var bad in new[] { "", "ctrl+alt", "ctrl+L+K", "ctrl+Enter", "ctrl+F13", "hyper+L", "ctrl+é" }) H.True(Shortcut.Parse(bad) == null, "refused: " + bad);
        var s = new Shortcut(true, true, true, false, "V");
        H.Eq("⌃⌥⇧V", s.Display(true), "mac display"); H.Eq("Ctrl+Alt+Shift+V", s.Display(false), "windows display");
        H.Eq("⌘Space", new Shortcut(false, false, false, true, "Space").Display(true), "cmd space");
        H.True(Shortcut.DefaultShow.Problem(true) == null && Shortcut.DefaultShow.Problem(false) == null, "default fine");
        H.True(new Shortcut(false, false, true, false, "L").Problem(true) != null, "shift alone");
        H.True(new Shortcut(false, false, false, false, "F5").Problem(false) != null, "no modifier");
        H.Eq("⌘Q is used by every app.", new Shortcut(false, false, false, true, "Q").Problem(true), "cmd Q");
        H.Eq("Ctrl+C is used by every app.", new Shortcut(true, false, false, false, "C").Problem(false), "ctrl C");
        H.Eq("Windows has no ⌘ key.", new Shortcut(false, false, false, true, "L").Problem(false), "cmd on windows");
        H.True(new Shortcut(true, false, false, false, "Space").Problem(true) != null, "ctrl space mac");
        H.True(new Shortcut(false, true, false, false, "F4").Problem(false) != null, "alt f4");
        H.True(new Shortcut(true, false, false, false, "C").Problem(true) == null, "ctrl C free on a Mac");
        var st = new StorageSettings();
        H.True(st.ShowShortcut == Shortcut.DefaultShow && st.SendShortcut == null, "defaults");
        st.ShortcutShow = ""; st.ShortcutSend = "ctrl+alt+V";
        H.True(st.ShowShortcut == null && st.SendShortcut == Shortcut.SuggestedSend, "set");
        var dir = Directory.CreateTempSubdirectory("ll-keys").FullName;
        try
        {
            var path = Path.Combine(dir, "settings.json");
            st.Save(path);
            var json = File.ReadAllText(path);
            H.True(json.Contains("\"shortcutSend\": \"ctrl+alt+V\"") && json.Contains("\"shortcutShow\": \"\""), "same keys as the Mac: " + json);
            H.True(StorageSettings.Load(path).ShowShortcut == null, "off round-trips");
        }
        finally { Directory.Delete(dir, true); }
        var mac = KeyboardHelp.Rows(true, Shortcut.DefaultShow, null);
        var win = KeyboardHelp.Rows(false, Shortcut.DefaultShow, null);
        H.Eq("Anywhere|Sending|Items|Window", string.Join("|", mac.Select(x => x.Section)), "sections");
        H.True(mac.Select(x => x.Rows.Count).SequenceEqual(win.Select(x => x.Rows.Count)), "same list on both");
        H.True(mac[0].Rows[0].Keys == "⌃⌥L" && win[0].Rows[0].Keys == "Ctrl+Alt+L" && mac[0].Rows[1].Keys == "Off (Settings)", "anywhere rows");
        H.Eq(19, mac.Sum(x => x.Rows.Count), "row count");
        return Task.CompletedTask;
    }

    public static Task Sounds()
    {
        var a = Chime.Wav(Chime.Kind.Arrive); var sw = Chime.Wav(Chime.Kind.Sent);
        H.Eq("RIFF", System.Text.Encoding.ASCII.GetString(a, 0, 4), "riff");
        H.Eq("WAVE", System.Text.Encoding.ASCII.GetString(a, 8, 4), "wave");
        H.Eq(18_742, Chime.Samples(Chime.Kind.Arrive).Length, "arrive samples (the Mac's count)");
        H.Eq(3_087, Chime.Samples(Chime.Kind.Sent).Length, "sent samples");
        H.Eq(44 + 18_742 * 2, a.Length, "arrive bytes"); H.Eq(44 + 3_087 * 2, sw.Length, "sent bytes");
        H.Eq("cb7ee53dac2a1d3b409a8dc5be032dd6a230b818ab13093fdd13ae14ae38ae9d", Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(a)), "arrive byte-identical with the Mac");
        H.Eq("18714b8a51eaf264c45d2a601cdcddf0453662fbe81ae5c3596539f310fea352", Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(sw)), "sent byte-identical with the Mac");
        var sa = Chime.Samples(Chime.Kind.Arrive); var ss = Chime.Samples(Chime.Kind.Sent);
        int peakA = sa.Max(x => Math.Abs((int)x)), peakS = ss.Max(x => Math.Abs((int)x));
        H.True(peakA is >= 8_000 and <= 16_000, $"soft, never clipping: {peakA}");
        H.True(peakS < peakA / 2, "the send tick is quieter");
        H.True(sa[0] == 0 && Math.Abs((int)sa[^1]) < 300, "fades in and out");
        var g = new SoundGate(); var t = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        H.True(g.Arrive(true, false, t), "first");
        H.True(!g.Arrive(true, false, t.AddSeconds(1)), "one per burst");
        H.True(g.Arrive(true, false, t.AddSeconds(2)), "after the gap");
        H.True(!g.Arrive(true, true, t.AddSeconds(10)), "the notification plays its own");
        H.True(!g.Arrive(false, false, t.AddSeconds(20)), "off");
        H.True(new StorageSettings().SoundsValue, "on by default");
        if (Environment.GetEnvironmentVariable("LANLINE_CHIME_DIR") is { } cd)   // a parity check against the Mac's files
        { File.WriteAllBytes(Path.Combine(cd, "arrive.wav"), a); File.WriteAllBytes(Path.Combine(cd, "sent.wav"), sw); }
        return Task.CompletedTask;
    }

    public static Task HistoryAndSearch()
    {
        var t0 = new DateTime(2025, 11, 24, 16, 0, 0, DateTimeKind.Utc);
        HistoryEntry Txt(string id, string t, double s = 0, string who = "Studio PC") => new() { Id = id, Incoming = true, Kind = "text", Text = t, At = t0.AddSeconds(s), Who = who, State = "received" };
        HistoryEntry Fil(string id, string n, string kind = "file", double s = 0) => new() { Id = id, Kind = kind, Name = n, Size = 10, Path = @"C:\x\" + n, At = t0.AddSeconds(s), Who = "Studio PC", State = "delivered" };
        var dir = Directory.CreateTempSubdirectory("ll-hist").FullName;
        try
        {
            var path = Path.Combine(dir, History.FileName);
            H.Eq(0, History.Load(path).Count, "nothing yet");
            History.Append(Txt("b", "second", 2), path);
            History.Append(Txt("a", "first", 1), path);
            History.Append(Fil("c", "x.zip", s: 3) with { State = "failed", Error = "no space" }, path);
            History.Append(Txt("b", "second, edited", 2), path);
            File.AppendAllText(path, "not json\n{}\n");
            var back = History.Load(path);
            H.Eq("a|b|c", string.Join("|", back.Select(e => e.Id)), "oldest first, one per id");
            H.Eq("second, edited", back[1].Text, "the last line wins");
            H.Eq("no space", back[2].Error, "error kept");
            History.Compact(Enumerable.Range(0, History.Cap + 25).Select(i => Txt($"i{i}", $"n{i}", i)), path);
            var capped = History.Load(path);
            H.True(capped.Count == History.Cap && capped[0].Id == "i25", "capped, the oldest drop off");
            History.Append(Txt("long", new string('x', 30_000), 5_000), path);
            H.Eq(History.MaxText, History.Load(path)[^1].Text!.Length, "long text cut");
            History.Clear(path);
            H.Eq(0, History.Load(path).Count, "cleared");
        }
        finally { Directory.Delete(dir, true); }
        var e1 = Txt("1", "Le Résumé is in the Q4 folder", who: "Studio PC");
        H.True(History.Matches(e1, "resume q4", HistoryFilter.All), "words, accents");
        H.True(History.Matches(e1, "  RÉSUMÉ  ", HistoryFilter.All), "case");
        H.True(History.Matches(e1, "studio", HistoryFilter.All), "the computer's name counts");
        H.True(!History.Matches(e1, "resume q5", HistoryFilter.All), "every word must match");
        H.True(History.Matches(Fil("2", "Café Menu.PDF"), "cafe pdf", HistoryFilter.All), "file names");
        H.True(History.Matches(e1, "", HistoryFilter.All), "empty query");
        var all = new[] { Txt("1", "hello"), Txt("2", "see https://example.com/a?b=1"), Txt("3", "try www.example.org"), Fil("4", "IMG_2041.HEIC"), Fil("5", "plan.pdf"), Fil("6", "Shoot", "folder") };
        string Ids(HistoryFilter f) => string.Join(",", all.Where(e => History.Matches(e, "", f)).Select(e => e.Id));
        H.Eq("1,2,3,4,5,6", Ids(HistoryFilter.All), "all");
        H.Eq("1,2,3", Ids(HistoryFilter.Text), "text");
        H.Eq("2,3", Ids(HistoryFilter.Links), "links");
        H.Eq("4", Ids(HistoryFilter.Pictures), "pictures");
        H.Eq("4,5,6", Ids(HistoryFilter.Files), "files");
        H.Eq("All,Text,Pictures,Files,Links", string.Join(",", Enum.GetValues<HistoryFilter>().Select(History.Title)), "titles");
        H.True(new StorageSettings().KeepHistoryValue, "on by default");
        return Task.CompletedTask;
    }

    public static Task TwoDigitBeta()
    {
        var b9 = LanLineVersion.Parse("0.9.0-beta.9")!; var b10 = LanLineVersion.Parse("0.9.0-beta.10")!;
        H.True(b9.CompareTo(b10) < 0 && b10.CompareTo(b9) > 0, "numbers, not text");
        H.True(b10.CompareTo(LanLineVersion.Parse("0.9.0")!) < 0, "a beta comes before its release");
        return Task.CompletedTask;
    }

    static readonly byte[] TinyPng = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

    public static Task ClipRulesTest()
    {
        var t = new ClipContent.TextClip("hello");
        H.True(ClipRules.ShouldSend(t, ["UnicodeText"], true, false, true, null), "send");
        H.True(!ClipRules.ShouldSend(t, [], false, false, true, null), "off");
        H.True(!ClipRules.ShouldSend(t, [], true, true, true, null), "paused");
        H.True(!ClipRules.ShouldSend(t, ["ExcludeClipboardContentFromMonitorProcessing"], true, false, true, null), "a password manager's copy");
        H.True(!ClipRules.ShouldSend(t, [], true, false, true, null, historyExcluded: true), "kept out of clipboard history");
        H.True(!ClipRules.ShouldSend(t, [], true, false, true, ClipRules.Fingerprint(t)), "same again / the echo");
        H.True(!ClipRules.ShouldSend(new ClipContent.PngClip(TinyPng), [], true, false, false, null), "pictures off");
        H.True(ClipRules.ShouldSend(new ClipContent.PngClip(TinyPng), [], true, false, true, null), "picture");
        H.True(!ClipRules.Fits(new ClipContent.TextClip("")) && !ClipRules.Fits(new ClipContent.TextClip(new string('x', ClipRules.MaxText + 1))), "sizes");
        H.True(!ClipRules.Fits(new ClipContent.PngClip([1, 2, 3])), "not a PNG");
        H.Eq("t:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", ClipRules.Fingerprint(t), "the same as the Mac");
        H.True(!new StorageSettings().ShareClipboardValue && new StorageSettings().ShareClipboardPicturesValue, "off by default; pictures on once enabled");
        return Task.CompletedTask;
    }

    public static async Task ClipRoundTrip()
    {
        var (srv, sr, port) = await H.Listener("clip-srv");
        using var _ = srv;
        var early = new TaskCompletionSource<bool>();
        srv.SendClip(new ClipContent.TextClip("too early"), ok => early.TrySetResult(ok));
        H.True(!await early.Task.WaitAsync(TimeSpan.FromSeconds(5)), "not connected: dropped, not queued");
        var (cli, cr) = H.Dialer("clip-cli", port);
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        cli.SendClip(new ClipContent.TextClip("päste me ✓"));
        cli.SendClip(new ClipContent.PngClip(TinyPng));
        srv.SendClip(new ClipContent.TextClip("back"));
        bool Has(Recorder r, ClipContent c) => r.All.OfType<SessionEvent.Clipboard>().Any(x => x.Content.Equals(c));
        await H.Until(() => Has(sr, new ClipContent.TextClip("päste me ✓")) && Has(sr, new ClipContent.PngClip(TinyPng)) && Has(cr, new ClipContent.TextClip("back")), "clips");
        H.True(!Has(cr, new ClipContent.TextClip("too early")), "the early one never arrives");
        H.Eq(0, sr.Received.Count, "clips are not items");
    }

    public static async Task ClipOldPartner()
    {
        var old = H.Cfg("clip-old");
        old = new SessionConfig { Token = old.Token, Name = old.Name, DownloadDir = old.DownloadDir, Backoff = old.Backoff, DialTimeout = old.DialTimeout, Caps = ["sha_end", "folders", "multi", "cancel"] };
        var (srv, sr, port) = await H.Listener("clip-old", old);
        using var _ = srv;
        var (cli, cr) = H.Dialer("clip-new", port);
        using var __ = cli;
        await H.Until(() => sr.Connects == 1 && cr.Connects == 1, "connected");
        var sent = new TaskCompletionSource<bool>(); var takes = new TaskCompletionSource<bool?>();
        cli.SendClip(new ClipContent.TextClip("x"), ok => sent.TrySetResult(ok));
        cli.PeerTakesClips(t => takes.TrySetResult(t));
        H.True(!await sent.Task.WaitAsync(TimeSpan.FromSeconds(5)), "a beta.6–9 partner gets nothing");
        H.True(await takes.Task.WaitAsync(TimeSpan.FromSeconds(5)) == false, "and is reported as too old");
    }

    public static async Task ClipMidFile()
    {
        var (srv, sr, port) = await H.Listener("clip-mid");
        using var _ = srv;
        var (cli, cr) = H.Dialer("clip-mid-cli", port);
        using var __ = cli;
        await H.Until(() => cr.Connects == 1, "connected");
        var url = H.RandomFile(H.TempDir("clip-mid-src"), "big.bin", 30 << 20);
        var once = 0;
        cr.Hook = e => { if (e is SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending, Progress: > 0.2 } } && Interlocked.Exchange(ref once, 1) == 0) cli.SendClip(new ClipContent.TextClip("mid-file")); };
        var f = cli.SendFile(url);
        await H.Until(() => cr.Delivered(f.Id), "delivered", 30);
        H.True(sr.All.OfType<SessionEvent.Clipboard>().Any(x => x.Content.Equals(new ClipContent.TextClip("mid-file"))), "clip arrived mid-file");
        H.Eq(Hashing.Sha256File(url), Hashing.Sha256File(sr.Received.Single().Path!), "the file is intact around it");
    }

    public static Task ReceiveOptionsTest()
    {
        var b = @"C:\Users\x\Downloads\Lan-Line";
        H.Eq(b, ReceiveOptions.Folder(b, false, "Studio PC"), "one folder");
        H.Eq(Path.Combine(b, "Studio PC"), ReceiveOptions.Folder(b, true, "Studio PC"), "per computer");
        H.Eq("PC", Path.GetFileName(ReceiveOptions.Folder(b, true, "../Evil/PC")), "a name can't climb out (base name only)");
        AfterReceive A(AfterReceive s, string n, bool folder = false, int opens = 0) => ReceiveOptions.Action(s, n, folder, opens);
        H.Eq(AfterReceive.Nothing, A(AfterReceive.Nothing, "x.png"), "nothing");
        H.Eq(AfterReceive.Reveal, A(AfterReceive.Reveal, "setup.exe"), "reveal");
        foreach (var ok in new[] { "Photo.HEIC", "plan.pdf", "clip.mov" }) H.Eq(AfterReceive.Open, A(AfterReceive.Open, ok), ok);
        foreach (var risky in new[] { "setup.exe", "run.sh", "App.dmg", "tool.app", "x.ps1", "deck.docm", "a.zip", "noext" }) H.Eq(AfterReceive.Reveal, A(AfterReceive.Open, risky), risky);
        H.Eq(AfterReceive.Reveal, A(AfterReceive.Open, "Shoot", folder: true), "folders shown");
        H.Eq(AfterReceive.Reveal, A(AfterReceive.Open, "4.png", opens: 3), "3 opens per burst");
        var st = new StorageSettings();
        H.True(st.DownloadFolderValue == null && !st.FolderPerComputerValue && st.AfterReceiveValue == AfterReceive.Nothing, "defaults");
        st.DownloadFolder = @"C:\Users\x\Desktop"; st.AfterReceive = "open";
        H.True(st.DownloadFolderValue == @"C:\Users\x\Desktop" && st.AfterReceiveValue == AfterReceive.Open, "set");
        st.AfterReceive = "bogus"; st.DownloadFolder = "";
        H.True(st.AfterReceiveValue == AfterReceive.Nothing && st.DownloadFolderValue == null, "unknown values fall back");
        return Task.CompletedTask;
    }

    public static async Task SessionSwitchesFolder()
    {
        var (srv, sr, port) = await H.Listener("folder-srv");
        using var _ = srv;
        var (cli, cr) = H.Dialer("folder-cli", port);
        using var __ = cli;
        await H.Until(() => cr.Connects == 1, "connected");
        var src = H.TempDir("folder-src");
        var a = cli.SendFile(H.RandomFile(src, "first.bin", 1000));
        await H.Until(() => cr.Delivered(a.Id), "first");
        var newDir = Path.Combine(H.TempDir("folder-new"), "Studio PC");
        srv.SetDownloadDir(newDir);
        var b2 = cli.SendFile(H.RandomFile(src, "second.bin", 1000));
        await H.Until(() => cr.Delivered(b2.Id), "second");
        H.True(Path.GetDirectoryName(sr.Received[0].Path!) != newDir, "the first stayed where it was");
        H.Eq(newDir, Path.GetDirectoryName(sr.Received[1].Path!), "created on demand, used from then on");
    }

    static SessionConfig RCfg(string tag, bool resume = true) => new()
    {
        Token = H.Token, Name = tag, DownloadDir = H.TempDir(tag), Backoff = [0.2, 0.4], DialTimeout = TimeSpan.FromSeconds(2),
        ProgressInterval = TimeSpan.FromSeconds(0.02),
        Caps = resume ? ["sha_end", "folders", "multi", "cancel", "clip", "resume"] : ["sha_end", "folders", "multi", "cancel", "clip"],
    };

    /// <summary>Drop the link once progress passes 40 %; returns the first progress after the reconnect.</summary>
    static async Task<(double? First, Recorder Sr, Session Srv, string Original)> DropAndResend(string tag, bool receiverResume, bool senderResume = true)
    {
        var (srv, sr, port) = await H.Listener(tag + "-srv", RCfg(tag + "-srv", receiverResume));
        var cr = new Recorder();
        var cli = new Session(new Role.Dial(["127.0.0.1"], port), RCfg(tag + "-cli", senderResume), cr.Add);
        cli.Start();
        await H.Until(() => cr.Connects == 1, "connected");
        var url = H.RandomFile(H.TempDir(tag + "-src"), "big.bin", 60 << 20);
        int dropped = 0; double? first = null;
        cr.Hook = e =>
        {
            if (e is not SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending } st }) return;
            if (dropped == 0 && st.Progress > 0.4) { dropped = 1; cli.DropLink(); }
            else if (dropped == 1 && cr.Connects >= 2 && first == null) first = st.Progress;
        };
        var f = cli.SendFile(url);
        await H.Until(() => cr.Delivered(f.Id), "delivered after reconnect", 60);
        cli.Dispose();
        return (first, sr, srv, url);
    }

    public static async Task ResumeWhereStopped()
    {
        var r = await DropAndResend("wres", true);
        using var _ = r.Srv;
        H.True((r.First ?? 0) > 0.3, $"carried on from where the link dropped (first progress after reconnect: {r.First})");
        H.Eq(Hashing.Sha256File(r.Original), Hashing.Sha256File(r.Sr.Received.Single().Path!), "byte-identical");
        H.Eq(0, H.Parts(r.Srv.Config.DownloadDir).Length, "no part files");
    }

    public static async Task ResumeOldReceiver()
    {
        var r = await DropAndResend("wres-old", false);
        using var _ = r.Srv;
        H.True((r.First ?? 1) < 0.3, "no resume cap: from the start");
        H.Eq(Hashing.Sha256File(r.Original), Hashing.Sha256File(r.Sr.Received.Single().Path!), "intact");
    }

    public static async Task ResumeOldSender()
    {
        var r = await DropAndResend("wres-oldsend", true, senderResume: false);
        using var _ = r.Srv;
        H.True((r.First ?? 1) < 0.3, "the sender doesn't offer: from the start");
        H.Eq(Hashing.Sha256File(r.Original), Hashing.Sha256File(r.Sr.Received.Single().Path!), "intact");
        H.Eq(0, H.Parts(r.Srv.Config.DownloadDir).Length, "no partial kept for a sender that can't resume");
    }

    public static async Task ResumeDamaged()
    {
        var (srv, sr, port) = await H.Listener("wres-bad-srv", RCfg("wres-bad-srv"));
        using var _ = srv;
        var cr = new Recorder();
        using var cli = new Session(new Role.Dial(["127.0.0.1"], port), RCfg("wres-bad-cli"), cr.Add);
        cli.Start();
        await H.Until(() => cr.Connects == 1, "connected");
        var url = H.RandomFile(H.TempDir("wres-bad-src"), "big.bin", 60 << 20);
        var dropped = 0;
        cr.Hook = e => { if (e is SessionEvent.Outgoing { Item.State: { Kind: ItemStateKind.Sending, Progress: > 0.4 } } && Interlocked.Exchange(ref dropped, 1) == 0) cli.DropLink(); };
        var f = cli.SendFile(url);
        await H.Until(() => dropped == 1 && sr.Disconnects.Count >= 1, "dropped");
        var part = H.Parts(srv.Config.DownloadDir).FirstOrDefault() ?? throw new Exception("no partial kept");
        using (var w = new FileStream(part, FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) { w.Seek(1000, SeekOrigin.Begin); w.Write(Enumerable.Repeat((byte)0xEE, 64).ToArray()); }
        await H.Until(() => cr.LastState(f.Id)?.Kind is ItemStateKind.Failed or ItemStateKind.Delivered, "finished", 60);
        H.Eq("sha256 mismatch", cr.LastState(f.Id)!.Error, "the whole-file hash refuses it");
        H.Eq(0, sr.Received.Count, "nothing damaged lands");
    }

    public static Task SmartItems()
    {
        string? O(string t) => SmartText.Analyze(t).Otp;
        H.Eq("482913", O("482913"), "alone"); H.Eq("482913", O("482 913"), "spaced"); H.Eq("482913", O(" 482-913 "), "dashed"); H.Eq("482913", O("G-482913"), "prefixed");
        H.Eq("7731", O("Your verification code is 7731. It expires in 10 minutes."), "sentence");
        H.Eq("482913", O("G-482913 is your Google verification code."), "google style");
        H.Eq("552019", O("Use 552 019 to sign in"), "sign in");
        H.Eq(null, O("Meeting moved to 3:30 tomorrow"), "time"); H.Eq(null, O("The budget for 2026 is 450000 dollars"), "no code word");
        H.Eq(null, O("Your order 12345678901 shipped"), "too long"); H.Eq(null, O("code version 1.2.3456"), "version");
        SmartColor? C(string t) => SmartText.Analyze(t).Color;
        H.True(C("#3a7bd5") == new SmartColor(58, 123, 213), "hex6"); H.True(C("#FFF") == new SmartColor(255, 255, 255), "hex3");
        H.Eq("#3A7BD580", C("#3a7bd580")!.Hex, "hex8"); H.Eq("#3A7BD5", C("rgb(58, 123, 213)")!.Hex, "rgb");
        H.Eq("rgba(0, 0, 0, 0.5)", C("rgba(0,0,0,0.5)")!.Rgb, "rgba"); H.Eq("#397AD5", C("hsl(215, 65%, 53%)")!.Hex, "hsl (worked by hand)");
        H.Eq("hsl(215, 65%, 53%)", new SmartColor(58, 123, 213).Hsl, "to hsl"); H.Eq("hsl(0, 0%, 50%)", new SmartColor(128, 128, 128).Hsl, "grey");
        H.True(C("#12345") == null && C("rgb(300, 0, 0)") == null && C("my colour is #3a7bd5") == null, "not colours");
        var fenced = SmartText.Analyze("```swift\nlet x = 1\nprint(x)\n```").Code;
        H.True(fenced == new SmartCode("let x = 1\nprint(x)", "swift"), "fenced");
        var braces = "func hello() {\n    print(\"hi\")\n}";
        H.Eq(braces, SmartText.Analyze(braces).Code?.Body, "braces");
        H.True(SmartText.Analyze("git fetch origin\ngit rebase origin/main").Code != null, "shell");
        H.True(SmartText.Analyze("Can you send the deck?\nThe new one, with the icons.").Code == null, "prose");
        H.True(SmartText.Analyze("let me know").Code == null, "one line");
        H.Eq("https://example.com/a/b?c=1", SmartText.Analyze("https://example.com/a/b?c=1").SingleLink?.AbsoluteUri, "single link");
        H.Eq("https://www.example.org/", SmartText.Analyze("www.example.org").SingleLink?.AbsoluteUri, "www");
        var many = SmartText.Analyze("See https://a.com/x, and (https://b.org/y). Also https://a.com/x again; javascript:alert(1) file:///etc/passwd");
        H.Eq("https://a.com/x|https://b.org/y", string.Join("|", many.Links.Select(u => u.AbsoluteUri)), "links");
        H.True(many.SingleLink == null, "not single");
        H.Eq("https://en.wikipedia.org/wiki/Foo_(bar)", SmartText.Analyze("https://en.wikipedia.org/wiki/Foo_(bar)").Links[0].AbsoluteUri, "brackets");
        H.Eq("http://ok.org/", string.Join("|", SmartText.Analyze("ftp://x.org http://ok.org").Links.Select(u => u.AbsoluteUri)), "http(s) only");
        var bu = new Uri("https://www.example.com/post/1");
        var p = LinkPreview.Parse("<html><head><title>Fallback</title><meta property=\"og:title\" content=\"Q4 &amp; Beyond\"><meta content=\"Example News\" property=\"og:site_name\"><meta property=\"og:image\" content=\"/img/hero.png\"></head></html>", bu);
        H.True(p == new LinkPreview("Q4 & Beyond", "Example News", new Uri("https://www.example.com/img/hero.png")), "og tags");
        H.Eq("Just a title", LinkPreview.Parse("<title>\n  Just a   title\n</title>", bu).Title, "title");
        H.True(LinkPreview.Parse("<meta property=\"og:image\" content=\"javascript:alert(1)\">", bu).Image == null, "http(s) images only");
        H.Eq("example.com", LinkPreview.Host(bu), "host");
        return Task.CompletedTask;
    }

    public static Task PairLinkTest()
    {
        var l = new PairLink("7QK4M2XH9C", "Studio PC", 47830, ["192.168.1.20", "100.64.0.5"]);
        H.Eq("lanline://pair?v=1&c=7QK4M2XH9C&n=Studio%20PC&p=47830&h=192.168.1.20,100.64.0.5", l.Url, "url (the Mac's)");
        H.True(PairLink.Parse(l.Url) == l, "round trip");
        H.Eq("7QK4M2XH9C", PairLink.Parse("lanline://pair?v=1&c=7qk4m-2xh9c&n=Mac&p=47830&h=10.0.0.2")?.Code, "typed forms normalise");
        var odd = new PairLink("7QK4M2XH9C", "Mac & PC = ✓", 1, ["10.0.0.2"]);
        H.Eq("lanline://pair?v=1&c=7QK4M2XH9C&n=Mac%20%26%20PC%20%3D%20%E2%9C%93&p=1&h=10.0.0.2", odd.Url, "odd name, same as the Mac");
        H.Eq("Mac & PC = ✓", PairLink.Parse(odd.Url)?.Name, "odd name back");
        foreach (var bad in new[] { "https://pair?v=1&c=7QK4M2XH9C&p=1&h=10.0.0.2", "lanline://stage?v=1&c=7QK4M2XH9C&p=1&h=10.0.0.2", "lanline://pair?v=2&c=7QK4M2XH9C&p=47830&h=10.0.0.2",
                                    "lanline://pair?v=1&c=SHORT&p=47830&h=10.0.0.2", "lanline://pair?v=1&c=7QK4M2XH9C&p=0&h=10.0.0.2", "lanline://pair?v=1&c=7QK4M2XH9C&p=47830&h=evil.example.com",
                                    "lanline://pair?v=1&c=7QK4M2XH9C&p=47830", "" })
            H.True(PairLink.Parse(bad) == null, "refused: " + bad);
        H.Eq("10.0.0.2,10.0.0.3", string.Join(",", PairLink.Parse("lanline://pair?v=1&c=7QK4M2XH9C&p=47830&h=10.0.0.2,evil,10.0.0.3")!.Hosts), "only addresses");
        H.Eq("Computer", PairLink.Parse("lanline://pair?v=1&c=7QK4M2XH9C&p=47830&h=10.0.0.2")?.Name, "no name");
        return Task.CompletedTask;
    }

    /// <summary>Sizes and fixed patterns here; that phones can read it is checked on the Mac with Vision (LOG).</summary>
    public static Task QrCodeTest()
    {
        var q = QrCode.Encode("HELLO");
        H.Eq(21, q.GetLength(0), "5 bytes: version 1");
        bool Finder(int r0, int c0) { for (var r = 0; r < 7; r++) for (var c = 0; c < 7; c++) { var want = r is 0 or 6 || c is 0 or 6 || (r is >= 2 and <= 4 && c is >= 2 and <= 4); if (q[r0 + r, c0 + c] != want) return false; } return true; }
        H.True(Finder(0, 0) && Finder(0, 14) && Finder(14, 0), "finder patterns");
        H.True(Enumerable.Range(8, 5).All(i => q[6, i] == (i % 2 == 0)), "timing");
        H.True(q[21 - 8, 8], "dark module");
        var link = new PairLink("7QK4M2XH9C", "Studio PC", 47830, ["192.168.1.20", "100.64.0.5"]).Url;
        H.Eq(37, QrCode.Encode(link).GetLength(0), $"a pairing link ({link.Length} bytes): version 5");
        H.Eq(57, QrCode.Encode(new string('x', 213)).GetLength(0), "213 bytes: version 10");
        H.True(Throws(() => QrCode.Encode(new string('x', 214))), "too long");
        // Pinned after Apple's Vision decoded 13 samples (versions 1–10) made by this encoder (LOG, 2026-11-25):
        static string Grid(bool[,] g) => string.Join("\n", Enumerable.Range(0, g.GetLength(0)).Select(r => new string(Enumerable.Range(0, g.GetLength(1)).Select(c => g[r, c] ? '#' : '.').ToArray())));
        static string Sha(string s) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(s)));
        H.Eq("956b61f34d0cde4dcef805bd28a2fb720b576915521805cb284f68546442b25f", Sha(Grid(q)), "HELLO as decoded by Vision");
        H.Eq("38ed1f31a1680821bfe112c2bc270231714ba402e3542dd693ab46588f9d39f4", Sha(Grid(QrCode.Encode(link))), "the pairing link as decoded by Vision");
        if (Environment.GetEnvironmentVariable("LANLINE_QR_DIR") is { } dir)   // for the Vision check on the Mac
        {
            var samples = new List<string> { "HELLO", link, "lanline://pair?v=1&c=7QK4M2XH9C&n=Mac%20%26%20PC%20%3D%20%E2%9C%93&p=1&h=10.0.0.2" };
            foreach (var cap in new[] { 14, 26, 42, 62, 84, 106, 122, 152, 180, 213 }) samples.Add(string.Concat(Enumerable.Range(0, cap).Select(i => (char)('a' + i * 7 % 26))));
            for (var i = 0; i < samples.Count; i++)
            {
                File.WriteAllBytes(Path.Combine(dir, $"qr{i:00}.png"), Png(QrCode.Encode(samples[i]), 8));
                File.WriteAllText(Path.Combine(dir, $"qr{i:00}.txt"), samples[i]);
            }
        }
        return Task.CompletedTask;
        static bool Throws(Action a) { try { a(); return false; } catch (ArgumentException) { return true; } }
    }

    /// <summary>A grey PNG of a QR matrix with a 4-module quiet zone (tests only).</summary>
    static byte[] Png(bool[,] q, int scale)
    {
        var n = q.GetLength(0); var side = (n + 8) * scale;
        var raw = new byte[side * (side + 1)];
        for (var y = 0; y < side; y++)
        {
            raw[y * (side + 1)] = 0;   // filter: none
            for (var x = 0; x < side; x++)
            {
                int r = y / scale - 4, c = x / scale - 4;
                raw[y * (side + 1) + 1 + x] = r >= 0 && c >= 0 && r < n && c < n && q[r, c] ? (byte)0 : (byte)255;
            }
        }
        using var z = new MemoryStream();
        using (var zs = new System.IO.Compression.ZLibStream(z, System.IO.Compression.CompressionLevel.Optimal, true)) zs.Write(raw);
        using var o = new MemoryStream();
        o.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        void Chunk(string type, byte[] d)
        {
            var len = BitConverter.GetBytes(d.Length); Array.Reverse(len); o.Write(len);
            var td = Encoding.ASCII.GetBytes(type).Concat(d).ToArray(); o.Write(td);
            uint crc = 0xFFFFFFFF;
            foreach (var b in td) { crc ^= b; for (var k = 0; k < 8; k++) crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1; }
            var cb = BitConverter.GetBytes(~crc); Array.Reverse(cb); o.Write(cb);
        }
        var w = BitConverter.GetBytes(side); Array.Reverse(w);
        Chunk("IHDR", [.. w, .. w, 8, 0, 0, 0, 0]);
        Chunk("IDAT", z.ToArray());
        Chunk("IEND", []);
        return o.ToArray();
    }

    public static Task GlassOpacity()
    {
        var s = new StorageSettings();
        H.Eq(null, s.GlassOpacity, "unset by default");
        H.True(Math.Abs(StorageSettings.TintAlpha(s.GlassOpacityValue, true) - 0xBD / 255.0) < 0.002, "default dark = today's #BD");
        H.True(Math.Abs(StorageSettings.TintAlpha(s.GlassOpacityValue, false) - 0xCC / 255.0) < 0.002, "default light = today's #CC");
        foreach (var (v, want) in new[] { (0.1, 0.40), (0.55, 0.55), (1.7, 1.0), (double.NaN, 0.74) })
        {
            s.GlassOpacity = v;
            H.True(Math.Abs(s.GlassOpacityValue - want) < 1e-9, $"clamp {v}");
        }
        H.Eq(1.0, StorageSettings.TintAlpha(1.0, false), "never above 1");
        // accessibility pass (beta.10): the text size is always one of the choices; Windows multiplies its own setting in
        H.Eq(1.0, new StorageSettings().TextScaleValue, "default text size");
        H.Eq(1.3, new StorageSettings { TextScale = 1.3 }.TextScaleValue, "a choice");
        H.Eq(1.15, new StorageSettings { TextScale = 1.22 }.TextScaleValue, "snapped");
        H.Eq(1.5, new StorageSettings { TextScale = 9 }.TextScaleValue, "too big");
        H.Eq(0.9, new StorageSettings { TextScale = -3 }.TextScaleValue, "too small");
        H.Eq(1.0, new StorageSettings { TextScale = double.NaN }.TextScaleValue, "bad value");
        H.Eq(1.0, StorageSettings.EffectiveTextScale(100, 1), "system 100 %");
        H.Eq(1.5, StorageSettings.EffectiveTextScale(150, 1), "system 150 %");
        H.True(Math.Abs(StorageSettings.EffectiveTextScale(150, 1.3) - 1.95) < 1e-9, "both multiply");
        H.Eq(2.25, StorageSettings.EffectiveTextScale(225, 1.5), "capped at 225 %");
        H.Eq(0.9, StorageSettings.EffectiveTextScale(50, 0.9), "system below 100 counts as 100");
        H.Eq(1.0, StorageSettings.EffectiveTextScale(double.NaN, 1), "bad system value");
        // design refresh (beta.10): the scrim under text on the body, the same rule as the Mac
        H.Eq(0.0, StorageSettings.ScrimStrength(1.0), "no scrim when opaque");
        H.Eq(0.0, StorageSettings.ScrimStrength(StorageSettings.DefaultGlassOpacity), "none at the default");
        H.True(Math.Abs(StorageSettings.ScrimStrength(0.57) - 0.5) < 1e-9, "half way");
        H.True(Math.Abs(StorageSettings.ScrimStrength(0.40) - 1) < 1e-9, "full at the minimum");
        H.True(Math.Abs(StorageSettings.ScrimStrength(0.10) - 1) < 1e-9, "clamped like the setting");
        H.Eq(0.0, StorageSettings.ScrimStrength(double.NaN), "a bad value means the default");
        var dir = Directory.CreateTempSubdirectory("ll-glass").FullName;
        try
        {
            var path = Path.Combine(dir, "settings.json");
            File.WriteAllText(path, "{\"retentionDays\":30,\"confirmed\":true}");   // a beta.7 file
            var old = StorageSettings.Load(path);
            H.True(old.RetentionDays == 30 && old.GlassOpacity == null, "old file loads, default look");
            old.GlassOpacity = 0.5; old.Save(path);
            H.Eq(0.5, StorageSettings.Load(path).GlassOpacityValue, "saved and read back");
            H.True(File.ReadAllText(path).Contains("\"glassOpacity\": 0.5"), "same key as the Mac");
            H.Eq(0.5, old.Copy().GlassOpacity, "copied with the other settings");
        }
        finally { Directory.Delete(dir, true); }
        return Task.CompletedTask;
    }

    // beta.10 one-click updates: the release tool (CryptoKit, on the Mac) signs; .NET must verify the same bytes.
    const string UpdateFixture = "{\n  \"payload\" : \"eyJtYWMiOnsic2hhMjU2IjoiMmNmMjRkYmE1ZmIwYTMwZTI2ZTgzYjJhYzViOWUyOWUxYjE2MWU1YzFmYTc0MjVlNzMwNDMzNjI5MzhiOTgyNCIsInNpemUiOjUsInVybCI6Imh0dHBzOlwvXC9naXRodWIuY29tXC9hdmVyeXdyb2JpbnNvblwvbGFuLWxpbmVcL3JlbGVhc2VzXC9kb3dubG9hZFwvdjAuOS4wLWJldGEuOTlcL0xhbi1MaW5lLTAuOS4wLWJldGEuOTktbWFjLmRtZyJ9LCJub3Rlc191cmwiOiJodHRwczpcL1wvZ2l0aHViLmNvbVwvYXZlcnl3cm9iaW5zb25cL2xhbi1saW5lXC9yZWxlYXNlc1wvdGFnXC92MC45LjAtYmV0YS45OSIsInZlcnNpb24iOiIwLjkuMC1iZXRhLjk5Iiwid2luZG93cyI6eyJzaGEyNTYiOiIyY2YyNGRiYTVmYjBhMzBlMjZlODNiMmFjNWI5ZTI5ZTFiMTYxZTVjMWZhNzQyNWU3MzA0MzM2MjkzOGI5ODI0Iiwic2l6ZSI6NSwidXJsIjoiaHR0cHM6XC9cL2dpdGh1Yi5jb21cL2F2ZXJ5d3JvYmluc29uXC9sYW4tbGluZVwvcmVsZWFzZXNcL2Rvd25sb2FkXC92MC45LjAtYmV0YS45OVwvTGFuLUxpbmUtMC45LjAtYmV0YS45OS13aW5kb3dzLXNldHVwLmV4ZSJ9fQ==\",\n  \"sig\" : \"+Pf62ob7gnhnPzoz7iHWlCBujkGmezC\\/glNiF1iHoecLBLlztVaW3BdWolif9eE\\/XMZBd9zXecIzcyV6hn8bFw==\"\n}";

    public static Task SignedFixture()
    {
        var o = SignedUpdate.Verify(Encoding.UTF8.GetBytes(UpdateFixture), LanLineVersion.Parse("0.9.0-beta.10")!, SignedUpdate.Platform.Windows);
        H.True(o != null, "fixture verifies with the built-in key");
        H.Eq("0.9.0-beta.99", o!.Version.ToString(), "version");
        H.Eq(5L, o.Asset.Size, "size");
        H.True(o.Asset.Url.EndsWith("-windows-setup.exe"), "windows file");
        return Task.CompletedTask;
    }

    static byte[] SignManifest(ECDsa key, string version, string? url = null, long size = 1234, string? hash = null)
    {
        var dl = "https://github.com/averywrobinson/lan-line/releases/download/";
        var payload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["version"] = version,
            ["windows"] = new Dictionary<string, object> { ["url"] = url ?? $"{dl}v{version}/Lan-Line-{version}-windows-setup.exe", ["size"] = size, ["sha256"] = hash ?? new string('a', 64) },
        });
        var sig = key.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        return JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["payload"] = Convert.ToBase64String(payload), ["sig"] = Convert.ToBase64String(sig) });
    }

    static string Pub(ECDsa k) { var q = k.ExportParameters(false).Q; return Convert.ToBase64String([.. q.X!, .. q.Y!]); }

    public static Task SignedRefusals()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var other = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var cur = LanLineVersion.Parse("0.9.0-beta.10")!;
        var pub = Pub(key);
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.11"), cur, SignedUpdate.Platform.Windows, pub) != null, "good one");
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.11"), cur, SignedUpdate.Platform.Mac, pub) == null, "no mac file");
        H.True(SignedUpdate.Verify(SignManifest(other, "0.9.0-beta.11"), cur, SignedUpdate.Platform.Windows, pub) == null, "wrong key");
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.10"), cur, SignedUpdate.Platform.Windows, pub) == null, "same version");
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.11", url: "https://evil.example/x.exe"), cur, SignedUpdate.Platform.Windows, pub) == null, "foreign url");
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.11", url: "https://github.com/averywrobinson/lan-line/releases/download/v0.9.0-beta.11/../x.exe"), cur, SignedUpdate.Platform.Windows, pub) == null, "dot dot");
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.11", size: 0), cur, SignedUpdate.Platform.Windows, pub) == null, "size");
        H.True(SignedUpdate.Verify(SignManifest(key, "0.9.0-beta.11", hash: "XYZ"), cur, SignedUpdate.Platform.Windows, pub) == null, "hash");
        var tampered = Encoding.UTF8.GetString(SignManifest(key, "0.9.0-beta.11"));
        using (var d = JsonDocument.Parse(tampered))
        {
            var body = Encoding.UTF8.GetString(Convert.FromBase64String(d.RootElement.GetProperty("payload").GetString()!)).Replace("1234", "1235");
            var t = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["payload"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(body)), ["sig"] = d.RootElement.GetProperty("sig").GetString()! });
            H.True(SignedUpdate.Verify(t, cur, SignedUpdate.Platform.Windows, pub) == null, "tampered payload");
        }
        return Task.CompletedTask;
    }

    public static async Task SignedDownload()
    {
        var dir = H.TempDir("upd");
        var content = Encoding.UTF8.GetBytes("pretend installer");
        var listener = new System.Net.HttpListener();
        var port = 47000 + Random.Shared.Next(800);
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        _ = Task.Run(async () =>
        {
            for (var i = 0; i < 2; i++)
            {
                var c = await listener.GetContextAsync();
                var body = c.Request.Url!.AbsolutePath.Contains("bad") ? [.. content, (byte)'!'] : content;
                c.Response.ContentLength64 = body.Length;
                await c.Response.OutputStream.WriteAsync(body);
                c.Response.Close();
            }
        });
        var hash = Convert.ToHexStringLower(SHA256.HashData(content));
        var v = LanLineVersion.Parse("0.9.0-beta.11")!;
        var good = new SignedUpdate.Offer(v, new SignedUpdate.Asset($"http://127.0.0.1:{port}/good/setup.exe", content.Length, hash), null);
        var f = await SignedUpdate.Download(good, "0.9.0-beta.10", dir);
        H.True(SignedUpdate.Matches(f, good.Asset), "good download kept");
        var bad = new SignedUpdate.Offer(v, new SignedUpdate.Asset($"http://127.0.0.1:{port}/bad/other.exe", content.Length, hash), null);
        var refused = false;
        try { await SignedUpdate.Download(bad, "0.9.0-beta.10", dir); } catch (UpdateException e) { refused = e.Message == SignedUpdate.Mismatch; }
        H.True(refused, "too-long download refused");
        H.True(!File.Exists(Path.Combine(dir, "other.exe")) && !File.Exists(Path.Combine(dir, "other.exe.part")), "nothing left behind");
        listener.Stop();
    }

    // beta.10 welcome tour: the same wording and rules as the Mac
    public static Task TourRules()
    {
        foreach (var p in new[] { Tour.Platform.Mac, Tour.Platform.Windows, Tour.Platform.IPhone })
        {
            var cards = Tour.Cards(p);
            H.Eq("send,anywhere,close", string.Join(",", cards.Select(c => c.Id)), $"{p} card ids");
            foreach (var c in cards) H.True(c.Title.Length is > 0 and <= 28 && c.Body.Length is > 40 and <= 190 && c.Body.EndsWith('.'), $"{p} {c.Id}");
            H.Eq("type,drop,share", string.Join(",", Tour.Hints(p).Select(h => h.Id)), $"{p} hint ids");
            H.True(Tour.Hints(p).All(h => h.Text.Length is > 0 and <= 48 && !h.Text.EndsWith('.')), $"{p} hints");
        }
        H.Eq(Tour.Cards(Tour.Platform.Mac)[0].Title, Tour.Cards(Tour.Platform.Windows)[0].Title, "same first title");
        H.True(Tour.Cards(Tour.Platform.Windows)[0].Body.Contains("Enter") && Tour.Cards(Tour.Platform.Windows)[2].Body.Contains("notification area"), "Windows terms");
        H.True(Tour.ShouldShow(null, true, true), "new install, paired, settings saved");
        H.True(!Tour.ShouldShow(null, false, true) && !Tour.ShouldShow(null, true, false) && !Tour.ShouldShow(true, true, true), "not before pairing or settings, and once");
        H.True(Tour.SeenAtLaunch(null, true) == true && Tour.SeenAtLaunch(null, false) == null && Tour.SeenAtLaunch(true, false) == true, "already paired: not owed");
        return Task.CompletedTask;
    }
}
