// LanLine.Tests: a plain console test runner (no NuGet). `dotnet run --project LanLine.Tests` runs every test;
// `... -- headless|selftest <options>` runs the shared headless modes instead (same as Lan-Line.exe --headless).
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using LanLine.Core;

if (args.Length > 0 && (args[0] == "headless" || args[0] == "selftest"))
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
    ("config save round trip", T.ConfigSave), ("not enough disk space", T.DiskSpace), ("pairing code swapped for long secret", T.Rekey),
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

sealed class RawClient : IDisposable
{
    readonly ClientWebSocket _ws = new();
    public static async Task<RawClient> Connect(int port)
    {
        var c = new RawClient();
        await c._ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/lan-line"), CancellationToken.None);
        return c;
    }
    public Task Send(Frame f) => _ws.SendAsync(Encoding.UTF8.GetBytes(f.Json), WebSocketMessageType.Text, true, CancellationToken.None);
    public Task Send(byte[] d) => _ws.SendAsync(d, WebSocketMessageType.Binary, true, CancellationToken.None);
    /// <summary>Next control frame; null if the socket closed or nothing came within the timeout.</summary>
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
                return r.MessageType == WebSocketMessageType.Text ? Frame.Decode(Encoding.UTF8.GetString(ms.ToArray())) : new Frame { Type = "binary" };
            }
        }
        catch (OperationCanceledException) { return new Frame { Type = "timeout" }; }
        catch (Exception) { return null; }
    }
    public async Task<Frame?> NextNonBeat(double timeout = 5)
    {
        while (true) { var f = await Next(timeout); if (f?.Type != "beat") return f; }
    }
    public async Task<Frame?> Hello(string? token = null)
    {
        await Send(Frame.Hello(token ?? H.Token, "raw"));
        return await NextNonBeat();
    }
    public void Dispose() { try { _ws.Abort(); } catch (Exception) { } _ws.Dispose(); }
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
            await c.Send(Frame.Hello(bad, "evil"));
            H.True(await c.Next() == null, $"socket should close for token '{bad}'");
        }
        using (var c = await RawClient.Connect(port))
        {
            await c.Send(Frame.TextItem("x", "hi"));
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
        using (var c = await RawClient.Connect(port)) { var ok = await c.Hello(newTok); H.True(ok is { Type: "hello_ok", Rekey: null }, $"new secret accepted, got {ok}"); }
        using (var c = await RawClient.Connect(port)) { var ok = await c.Hello("ABCDE12345"); H.True(ok is { Type: "hello_ok" }, $"code still accepted, got {ok}"); }
        using (var c = await RawClient.Connect(port)) { var bad = await c.Hello("ZZZZZ99999"); H.True(bad is not { Type: "hello_ok" }, $"wrong code refused, got {bad}"); }
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
}
