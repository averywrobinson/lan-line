using System.Security.Cryptography;
using System.Text.Json;

namespace Ferry.Core;

/// <summary>
/// --headless [--echo] / --selftest / --send-text T / --send-file P, shared by Ferry.exe and Ferry.Tests.
/// Options: --listen | --connect HOST[,HOST]  --port N  --bind HOST  --config PATH  --downloads DIR  --name NAME
///          --size MB (selftest, default 50)  --timeout S (selftest, default 180)  --duration S (headless)
/// Prints one JSON object per line. Returns the process exit code.
/// </summary>
public static class Headless
{
    public static bool Wants(string[] args) => args.Contains("--headless") || args.Contains("--selftest") || args.Contains("--discover") || args.Contains("--respond");

    static string? Val(string[] a, string f) { var i = Array.IndexOf(a, f); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }

    public static int Run(string[] args)
    {
        if (args.Contains("--discover") || args.Contains("--respond")) return Discover(args);
        FerryConfig cfg;
        try { cfg = FerryConfig.Load(Val(args, "--config")); }
        catch (Exception e) { Console.Error.WriteLine($"ferry: cannot read config: {e.Message}"); return 2; }
        var port = int.TryParse(Val(args, "--port"), out var p) ? p : cfg.Port;
        Role role = args.Contains("--listen") ? new Role.Listen(port, Val(args, "--bind"))
            : new Role.Dial(Val(args, "--connect")?.Split(',') ?? cfg.Hosts, port);
        var downloads = Val(args, "--downloads") ?? Path.Combine(Path.GetTempPath(), $"ferry-headless-{Environment.ProcessId}");
        var selftest = args.Contains("--selftest");
        var echo = args.Contains("--echo");
        var sizeMb = int.TryParse(Val(args, "--size"), out var mb) ? mb : 50;
        var t0 = DateTime.UtcNow;
        var outLock = new object();
        var exit = new TaskCompletionSource<int>();

        void Log(string ev, Dictionary<string, object?>? fields = null)
        {
            var d = new SortedDictionary<string, object?>(fields ?? []) { ["event"] = ev, ["t"] = $"{(DateTime.UtcNow - t0).TotalSeconds:0.0}" };
            lock (outLock) { Console.Out.WriteLine(JsonSerializer.Serialize(d)); Console.Out.Flush(); }
        }

        string? testFile = null, testSha = null;
        var testText = $"ferry selftest {Guid.NewGuid()}\nline two ✓";
        if (selftest)
        {
            var dir = Path.Combine(Path.GetTempPath(), $"ferry-selftest-{Environment.ProcessId}");
            Directory.CreateDirectory(dir);
            testFile = Path.Combine(dir, $"selftest-{sizeMb}MB.bin");
            using (var fs = File.Create(testFile))
            {
                var buf = new byte[1 << 20];
                for (var i = 0; i < sizeMb; i++) { RandomNumberGenerator.Fill(buf); fs.Write(buf); }
            }
            testSha = Hashing.Sha256File(testFile);
        }

        Session? session = null;
        bool started = false, gotText = false, gotFile = false;
        int connects = 0, disconnects = 0;
        var oneShot = new HashSet<string>();
        var sendText = Val(args, "--send-text");
        var sendFile = Val(args, "--send-file");

        void Finish(bool ok, string why)
        {
            Log(ok ? "SELFTEST PASS" : "SELFTEST FAIL", new() { ["detail"] = why });
            exit.TrySetResult(ok ? 0 : 1);
        }

        void Handle(SessionEvent e)   // runs on the session queue
        {
            switch (e)
            {
                case SessionEvent.Listening l: Log("listening", new() { ["port"] = l.Port }); break;
                case SessionEvent.Connected c:
                    connects++;
                    Log("connected", new() { ["peer"] = c.Peer });
                    if (!started && (sendText != null || sendFile != null))
                    {
                        started = true;
                        if (sendText != null) oneShot.Add(session!.SendText(sendText).Id);
                        if (sendFile != null) oneShot.Add(session!.SendFile(sendFile).Id);
                    }
                    if (selftest && !started)
                    {
                        started = true;
                        session!.SendText(testText);
                        session!.SendFile(testFile!);
                    }
                    break;
                case SessionEvent.Disconnected d: disconnects++; Log("disconnected", new() { ["reason"] = d.Reason }); break;
                case SessionEvent.Received r when !r.Item.IsFile:
                    Log("received_text", new() { ["chars"] = r.Item.Text!.Length });
                    if (echo) session!.SendText(r.Item.Text!);
                    if (selftest && r.Item.Text == testText) { gotText = true; Log("selftest_text_ok"); }
                    if (selftest && gotText && gotFile) Finish(true, $"text and {sizeMb} MB file came back intact");
                    break;
                case SessionEvent.Received r:
                    var sha = Hashing.Sha256File(r.Item.Path!);
                    Log("received_file", new() { ["name"] = r.Item.FileName, ["size"] = r.Item.Size, ["sha256"] = sha });
                    if (echo) session!.SendFile(r.Item.Path!);
                    if (selftest && sha == testSha && r.Item.Size == (long)sizeMb << 20) { gotFile = true; Log("selftest_file_ok", new() { ["sha256"] = sha }); }
                    if (selftest && gotText && gotFile) Finish(true, $"text and {sizeMb} MB file came back intact");
                    break;
                case SessionEvent.Outgoing o when o.Item.State.Kind == ItemStateKind.Delivered:
                    Log("delivered", new() { ["id"] = o.Item.Id });
                    if (oneShot.Remove(o.Item.Id) && oneShot.Count == 0) { Log("sent_all"); exit.TrySetResult(0); }
                    break;
                case SessionEvent.Outgoing o when o.Item.State.Kind == ItemStateKind.Failed:
                    Log("send_failed", new() { ["id"] = o.Item.Id, ["why"] = o.Item.State.Error });
                    if (selftest) Finish(false, o.Item.State.Error ?? "send failed");
                    break;
                case SessionEvent.ReceiveFailed f:
                    Log("receive_failed", new() { ["name"] = f.Name, ["reason"] = f.Reason });
                    if (selftest) Finish(false, f.Reason);
                    break;
                case SessionEvent.Error err: Log("error", new() { ["message"] = err.Message }); break;
                case SessionEvent.Status st: Log("status", new() { ["text"] = st.Text }); break;
            }
        }

        var name = Val(args, "--name") ?? Environment.MachineName;
        session = new Session(role, new SessionConfig { Token = cfg.Token, Name = name, DownloadDir = downloads }, Handle);
        Log("start", new() { ["mode"] = selftest ? "selftest" : echo ? "echo" : "headless", ["downloads"] = downloads });
        if (selftest)
        {
            var timeout = double.TryParse(Val(args, "--timeout"), out var ts) ? ts : 180;
            _ = Task.Delay(TimeSpan.FromSeconds(timeout)).ContinueWith(_ => Finish(false, $"timeout after {timeout:0} s"));
        }
        if (double.TryParse(Val(args, "--duration"), out var dur))
            _ = Task.Delay(TimeSpan.FromSeconds(dur)).ContinueWith(_ =>
            {
                Log("summary", new() { ["connects"] = connects, ["disconnects"] = disconnects });
                exit.TrySetResult(disconnects == 0 ? 0 : 1);
            });
        Console.CancelKeyPress += (_, ev) => { ev.Cancel = true; exit.TrySetResult(130); };
        session.Start();
        var code = exit.Task.GetAwaiter().GetResult();
        try { session.Stop(); } catch (Exception) { }
        if (testFile != null) try { File.Delete(testFile); } catch (Exception) { }
        return code;
    }

    /// <summary>--discover: list Lan-Lines waiting on the network. --respond CODE: answer probes as that code until killed.</summary>
    static int Discover(string[] args)
    {
        var i = Array.IndexOf(args, "--port");
        var port = i >= 0 && i + 1 < args.Length ? int.Parse(args[i + 1]) : 47830;
        var r = Array.IndexOf(args, "--respond");
        if (r >= 0 && r + 1 < args.Length)
        {
            using var resp = new DiscoveryResponder(port, Environment.MachineName, PairCode.PairId(args[r + 1]));
            Console.WriteLine($"{{\"event\":\"responding\",\"pair\":\"{PairCode.PairId(args[r + 1])}\"}}");
            var d = Array.IndexOf(args, "--duration");
            Thread.Sleep(d >= 0 && d + 1 < args.Length ? (int)(double.Parse(args[d + 1]) * 1000) : Timeout.Infinite);
            return 0;
        }
        var peers = Discovery.SearchAsync(port, TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();
        foreach (var p in peers) Console.WriteLine($"{{\"found\":\"{p.Name}\",\"host\":\"{p.Host}\",\"port\":{p.Port},\"pair\":\"{p.PairId}\"}}");
        Console.WriteLine($"{{\"event\":\"discover_done\",\"count\":{peers.Count}}}");
        return 0;
    }
}
