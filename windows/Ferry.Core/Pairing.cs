using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Ferry.Core;

/// <summary>
/// The code one computer shows and the other types to pair; it doubles as the shared token.
/// 10 characters of Crockford base32 (50 bits), shown as XXXXX-XXXXX. Same rules as the Mac.
/// </summary>
public static class PairCode
{
    const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    public static string Generate() =>
        string.Concat(Enumerable.Range(0, 10).Select(_ => Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)]));

    /// <summary>Canonical form of what the user typed (upper case, separators dropped, O→0, I/L→1), or null.</summary>
    public static string? Normalize(string typed)
    {
        var sb = new StringBuilder();
        foreach (var c in typed.ToUpperInvariant())
        {
            switch (c)
            {
                case '-' or ' ' or '–' or '—' or '\t': continue;
                case 'O': sb.Append('0'); break;
                case 'I' or 'L': sb.Append('1'); break;
                default:
                    if (Alphabet.IndexOf(c) < 0) return null;
                    sb.Append(c); break;
            }
        }
        return sb.Length == 10 ? sb.ToString() : null;
    }

    public static string Display(string code) => code.Length == 10 ? $"{code[..5]}-{code[5..]}" : code;

    /// <summary>A public tag for a pairing, so a computer can find its partner after an address change.</summary>
    public static string PairId(string token) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("lan-line-pair:" + token)))[..8];
}

public sealed record DiscoveredPeer(string Name, string Host, int Port, string PairId);

/// <summary>
/// UDP discovery on the Lan-Line port: a waiting computer answers "LANLINE?1" with its name, TCP port and pair id.
/// Nothing secret is revealed; the code is still needed to connect.
/// </summary>
public static class Discovery
{
    public const string Probe = "LANLINE?1";

    public static byte[] Reply(string name, int port, string pairId) =>
        Encoding.UTF8.GetBytes(new JsonObject { ["lanline"] = 1, ["name"] = name.Length > 64 ? name[..64] : name, ["pair"] = pairId, ["port"] = port }.ToJsonString());

    public static DiscoveredPeer? Parse(byte[] data, string host)
    {
        if (data.Length >= 1024) return null;
        try
        {
            var o = JsonNode.Parse(data)?.AsObject();
            if (o == null || (int?)o["lanline"] != 1) return null;
            var name = (string?)o["name"]; var port = (int?)o["port"]; var pair = (string?)o["pair"];
            if (name == null || pair == null || port is not (>= 1 and <= 65535)) return null;
            return new DiscoveredPeer(name.Length > 64 ? name[..64] : name, host, port.Value, pair.Length > 16 ? pair[..16] : pair);
        }
        catch (Exception) { return null; }
    }

    /// <summary>This computer's IPv4 addresses worth showing (up, not loopback, not link-local), LAN ones first.</summary>
    public static List<string> LocalAddresses() =>
        Interfaces().Select(i => i.Addr.ToString()).OrderBy(Rank).ToList();

    static int Rank(string a) =>
        a.StartsWith("192.168.") || a.StartsWith("10.") ? 0 : a.StartsWith("172.") ? 1 : a.StartsWith("100.") ? 3 : 2;

    static IEnumerable<(IPAddress Addr, IPAddress? Broadcast)> Interfaces()
    {
        NetworkInterface[] nics;
        try { nics = NetworkInterface.GetAllNetworkInterfaces(); } catch (Exception) { yield break; }
        foreach (var n in nics)
        {
            if (n.OperationalStatus != OperationalStatus.Up || n.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var u in n.GetIPProperties().UnicastAddresses)
            {
                if (u.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var b = u.Address.GetAddressBytes();
                if (b[0] == 169 && b[1] == 254) continue;
                IPAddress? bc = null;
                if (u.IPv4Mask is { } m)
                {
                    var mb = m.GetAddressBytes();
                    bc = new IPAddress(b.Select((x, i) => (byte)(x | ~mb[i])).ToArray());
                }
                yield return (u.Address, bc);
            }
        }
    }

    /// <summary>Broadcast a probe and collect answers for the timeout. Targets override the broadcast addresses (tests).</summary>
    public static async Task<List<DiscoveredPeer>> SearchAsync(int port = 47830, TimeSpan? timeout = null, IEnumerable<string>? targets = null)
    {
        var found = new List<DiscoveredPeer>();
        using var udp = new UdpClient(new IPEndPoint(IPAddress.Any, 0)) { EnableBroadcast = true };
        IgnoreConnReset(udp);
        var dests = targets?.Select(IPAddress.Parse).ToList()
            ?? [IPAddress.Broadcast, .. Interfaces().Select(i => i.Broadcast).OfType<IPAddress>()];
        var probe = Encoding.ASCII.GetBytes(Probe);
        foreach (var d in dests.Distinct())
            try { await udp.SendAsync(probe, new IPEndPoint(d, port)); } catch (SocketException) { }
        using var cts = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(1.2));
        try
        {
            while (true)
            {
                try
                {
                    var r = await udp.ReceiveAsync(cts.Token);
                    if (Parse(r.Buffer, r.RemoteEndPoint.Address.ToString()) is { } p && !found.Contains(p)) found.Add(p);
                }
                catch (SocketException e) when (e.SocketErrorCode == SocketError.ConnectionReset) { }   // ICMP unreachable from one target
            }
        }
        catch (OperationCanceledException) { }
        catch (SocketException) { }
        return found;
    }

    /// <summary>
    /// Windows reports an ICMP "port unreachable" (from any target of an earlier send) as a failed receive
    /// on a UDP socket. Turn that off so one silent target can't end a search.
    /// </summary>
    internal static void IgnoreConnReset(UdpClient u)
    {
        if (!OperatingSystem.IsWindows()) return;
        const int SIO_UDP_CONNRESET = unchecked((int)0x9800000C);
        try { u.Client.IOControl(SIO_UDP_CONNRESET, [0, 0, 0, 0], null); } catch (Exception) { }
    }
}

/// <summary>Answers discovery probes while this computer waits for its partner.</summary>
public sealed class DiscoveryResponder : IDisposable
{
    readonly UdpClient _udp;
    readonly CancellationTokenSource _cts = new();

    public DiscoveryResponder(int port, string name, string pairId)
    {
        _udp = new UdpClient();
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, port));
        Discovery.IgnoreConnReset(_udp);
        var answer = Discovery.Reply(name, port, pairId);
        _ = Task.Run(async () =>
        {
            while (!_cts.IsCancellationRequested)
            {
                try
                {
                    var r = await _udp.ReceiveAsync(_cts.Token);
                    if (Encoding.ASCII.GetString(r.Buffer) == Discovery.Probe) await _udp.SendAsync(answer, r.RemoteEndPoint);
                }
                catch (OperationCanceledException) { return; }
                catch (ObjectDisposedException) { return; }
                catch (SocketException) { }   // e.g. ICMP port-unreachable from an old prober: keep answering
            }
        });
    }

    public void Dispose() { _cts.Cancel(); _udp.Dispose(); }
}
