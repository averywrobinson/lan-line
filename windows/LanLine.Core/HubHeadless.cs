using System.Security.Cryptography;
using System.Text.Json;

namespace LanLine.Core;

/// <summary>
/// --headless --hub / --selftest --hub: the Hub (all partners in config.json's "peers") without a window. Echo sends each
/// received item back to the partner it came from. Selftest waits for --expect N partners (default: all), sends a text and
/// a file (and with --with-folder a folder) to everyone, and passes when every partner has sent each one back intact.
/// </summary>
public static class HubHeadless
{
    static string? Val(string[] a, string f) { var i = Array.IndexOf(a, f); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }

    public static int Run(string[] args)
    {
        DeviceConfig dev;
        try { dev = DeviceConfig.Load(Val(args, "--config"), "connect"); }
        catch (Exception e) { Console.Error.WriteLine($"lan-line: cannot read config: {e.Message}"); return 2; }
        var selftest = args.Contains("--selftest");
        var echo = args.Contains("--echo");
        var expect = int.TryParse(Val(args, "--expect"), out var x) ? x : dev.Peers.Count;
        var names = dev.Peers.ToDictionary(p => p.Id, p => p.Name);
        var t0 = DateTime.UtcNow;
        var outLock = new object();
        var exit = new TaskCompletionSource<int>();
        void Log(string ev, Dictionary<string, object?>? f = null)
        {
            var d = new SortedDictionary<string, object?>(f ?? []) { ["event"] = ev, ["t"] = $"{(DateTime.UtcNow - t0).TotalSeconds:0.0}" };
            lock (outLock) { Console.Out.WriteLine(JsonSerializer.Serialize(d)); Console.Out.Flush(); }
        }
        string Who(string p) => names.TryGetValue(p, out var n) ? n : p;

        string? testFile = null, testSha = null, testFolder = null;
        Dictionary<string, string> testTree = [];
        var testText = $"lan-line selftest {Guid.NewGuid()}\nline two ✓";
        var dir = Path.Combine(Path.GetTempPath(), $"lan-line-hub-selftest-{Environment.ProcessId}");
        if (selftest)
        {
            Directory.CreateDirectory(dir);
            testFile = Path.Combine(dir, "selftest.bin");
            File.WriteAllBytes(testFile, RandomNumberGenerator.GetBytes((int.TryParse(Val(args, "--size"), out var mb) ? mb : 20) << 20));
            testSha = Hashing.Sha256File(testFile);
            if (args.Contains("--with-folder"))
            {
                testFolder = Path.Combine(dir, "Selftest Ünïcødé 📁");
                void Put(string rel, byte[] d) { var u = Path.Combine(testFolder, rel); Directory.CreateDirectory(Path.GetDirectoryName(u)!); File.WriteAllBytes(u, d); }
                Put("readme.txt", "top"u8.ToArray());
                Put("日本/ファイル.txt", System.Text.Encoding.UTF8.GetBytes("日本語"));
                for (var i = 0; i < 200; i++) Put($"d{i % 7}/sub{i % 3}/f{i}.txt", System.Text.Encoding.UTF8.GetBytes($"file {i}"));
                Put("a/b/c/big.bin", RandomNumberGenerator.GetBytes(8 << 20));
                Directory.CreateDirectory(Path.Combine(testFolder, "empty", "inner"));
                testTree = Manifest(testFolder);
            }
        }
        string[] wants = testFolder != null ? ["file", "folder", "text"] : ["file", "text"];
        var back = new Dictionary<string, HashSet<string>>();
        var up = new HashSet<string>();
        var started = false;
        Hub? hub = null;

        void Finish(bool ok, string why) { Log(ok ? "SELFTEST PASS" : "SELFTEST FAIL", new() { ["detail"] = why }); exit.TrySetResult(ok ? 0 : 1); }
        void Mark(string p, string what)
        {
            if (!back.TryGetValue(p, out var s)) back[p] = s = [];
            s.Add(what);
            Log("selftest_back", new() { ["from"] = Who(p), ["what"] = what });
            var done = back.Count(b => wants.All(b.Value.Contains));
            if (done >= expect) Finish(true, $"{string.Join(", ", wants)} came back intact from {done} computer{(done == 1 ? "" : "s")}");
        }
        void Echo(Action<Hub> f) { var h = hub; if (h != null) _ = Task.Run(() => f(h)); }   // Send* waits on the hub queue

        void Handle(HubEvent e)   // on the hub queue
        {
            switch (e)
            {
                case HubEvent.Listening l: Log("listening", new() { ["port"] = l.Port }); break;
                case HubEvent.Connected c:
                    up.Add(c.Partner);
                    Log("connected", new() { ["partner"] = Who(c.Partner), ["name"] = c.Name });
                    if (selftest && !started && up.Count >= expect && hub is { } h)
                    {
                        started = true;
                        _ = Task.Run(() => { h.SendText(testText, null); h.SendFile(testFile!, null); if (testFolder != null) h.SendFolder(testFolder, null); });
                    }
                    break;
                case HubEvent.Disconnected d: up.Remove(d.Partner); Log("disconnected", new() { ["partner"] = Who(d.Partner), ["reason"] = d.Reason }); break;
                case HubEvent.Received r when r.Item.IsFolder:
                    var same = testFolder != null && Manifest(r.Item.Path!).OrderBy(k => k.Key).SequenceEqual(testTree.OrderBy(k => k.Key));
                    Log("received_folder", new() { ["from"] = Who(r.Partner), ["name"] = r.Item.FileName, ["count"] = r.Item.Count, ["identical"] = same });
                    if (echo) { var p = r.Partner; var path = r.Item.Path!; Echo(h => h.SendFolder(path, p)); }
                    if (selftest && same) Mark(r.Partner, "folder");
                    break;
                case HubEvent.Received r when r.Item.IsFile:
                    var sha = Hashing.Sha256File(r.Item.Path!);
                    Log("received_file", new() { ["from"] = Who(r.Partner), ["name"] = r.Item.FileName, ["size"] = r.Item.Size, ["sha256"] = sha });
                    if (echo) { var p = r.Partner; var path = r.Item.Path!; Echo(h => h.SendFile(path, p)); }
                    if (selftest && sha == testSha) Mark(r.Partner, "file");
                    break;
                case HubEvent.Received r:
                    Log("received_text", new() { ["from"] = Who(r.Partner), ["chars"] = r.Item.Text!.Length });
                    if (echo) { var p = r.Partner; var t = r.Item.Text!; Echo(h => h.SendText(t, p)); }
                    if (selftest && r.Item.Text == testText) Mark(r.Partner, "text");
                    break;
                case HubEvent.Outgoing o when o.Item.Summary.Kind == ItemStateKind.Failed:
                    Log("send_failed", new() { ["why"] = o.Item.Summary.Error });
                    if (selftest) Finish(false, o.Item.Summary.Error ?? "send failed");
                    break;
                case HubEvent.ReceiveFailed f: Log("receive_failed", new() { ["from"] = Who(f.Partner), ["name"] = f.Name, ["reason"] = f.Reason }); if (selftest) Finish(false, f.Reason); break;
                case HubEvent.Status s: Log("status", new() { ["partner"] = Who(s.Partner), ["text"] = s.Text }); break;
                case HubEvent.Error err: Log("error", new() { ["message"] = err.Message }); break;
                case HubEvent.PeerDevice pd: Log("peer_device", new() { ["partner"] = Who(pd.Partner), ["device"] = pd.Device }); break;
            }
        }

        var hc = new HubConfig
        {
            Name = Val(args, "--name") ?? Environment.MachineName, DeviceId = dev.DeviceId, Port = int.TryParse(Val(args, "--port"), out var port) ? port : dev.Port,
            BindHost = Val(args, "--bind"), DownloadDir = Val(args, "--downloads") ?? Path.Combine(Path.GetTempPath(), $"lan-line-hub-{Environment.ProcessId}"),
            AppVersion = Val(args, "--app-version") ?? AppInfo.Version,
        };
        hub = new Hub(hc, dev.Peers, Handle);
        Log("start", new() { ["mode"] = selftest ? "hub-selftest" : "hub-echo", ["partners"] = dev.Peers.Count });
        hub.Start();
        if (selftest)
        {
            var timeout = double.TryParse(Val(args, "--timeout"), out var ts) ? ts : 120;
            _ = Task.Delay(TimeSpan.FromSeconds(timeout)).ContinueWith(_ => Finish(false, $"timeout after {timeout:0} s"));
        }
        if (double.TryParse(Val(args, "--duration"), out var dur)) _ = Task.Delay(TimeSpan.FromSeconds(dur)).ContinueWith(_ => exit.TrySetResult(0));
        var code = exit.Task.GetAwaiter().GetResult();
        hub.Stop();
        try { Directory.Delete(dir, true); } catch (Exception) { }
        return code;
    }

    static Dictionary<string, string> Manifest(string root) =>
        new DirectoryInfo(root).EnumerateFileSystemInfos("*", SearchOption.AllDirectories)
            .ToDictionary(e => Path.GetRelativePath(root, e.FullName).Replace('\\', '/'), e => e is DirectoryInfo ? "dir" : Hashing.Sha256File(e.FullName));
}
