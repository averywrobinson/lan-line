// LanLine.Tests: a plain console test runner (no NuGet). `dotnet run --project LanLine.Tests` runs every test;
// `... -- headless|selftest <options>` runs the shared headless modes instead (same as Lan-Line.exe --headless).
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
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
    ("new peer replaces old", T.NewPeerReplaces), ("pair codes", T.PairCodes),
    ("discovery reply round trip", T.DiscoveryReply), ("discovery over loopback", T.DiscoveryLoopback),
    ("config save round trip", T.ConfigSave), ("not enough disk space", T.DiskSpace), ("pairing code swapped for long secret", T.Rekey), ("storage cleanup rules", T.StorageRules), ("listener addresses reach dialer", T.PeerAddrs),
    ("v2 shared test vectors", T.CryptoVectors), ("v2 handshake refusals", T.HandshakeRefusals),
    ("v2 channel tamper, replay, reorder", T.ChannelTamper), ("v2 nothing readable on the wire", T.WireCapture),
    ("v2 live link closes on tamper or plaintext", T.LiveTamper), ("v2 dialer with wrong secret refused", T.WrongSecretDialer),
    ("too big refused before hashing", T.TooBigEarly), ("over sanity bound refused", T.OverBound), ("beta.5 peers still get files", T.OldPeers),
    ("folder both ways and clash", T.FolderBothWays), ("large folder tree", T.LargeTree), ("folder links skipped", T.FolderLinks),
    ("folder too big refused up front", T.FolderTooBig), ("folder to beta.5 peer says update", T.FolderOldPeer), ("folder path escape refused", T.FolderEscape),
    ("version parse and order", T.VersionOrder), ("update url allowlist", T.UrlAllowlist), ("version.json parse", T.VersionJson),
    ("failed update checks are quiet", T.ChecksQuiet), ("auto update check off by default", T.AutoOff),
    ("peer relays newer version", T.PeerRelay), ("peer version alone links release page", T.PeerVersionOnly), ("peer can't push bad links", T.PeerBadLinks),
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

    public static (Session S, Recorder R) Dialer(string tag, int port)
    {
        var r = new Recorder();
        var s = new Session(new Role.Dial(["127.0.0.1"], port), Cfg(tag), r.Add);
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
}
