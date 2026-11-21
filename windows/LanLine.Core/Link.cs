using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;

namespace LanLine.Core;

enum LinkEventKind { Ready, Text, Data, Closed }

readonly record struct LinkEvent(LinkEventKind Kind, string? Text = null, byte[]? Data = null, string? Reason = null);

/// <summary>
/// One WebSocket (dialed with ClientWebSocket, or accepted by <see cref="Listener"/>).
/// Its callbacks are posted to the Session queue; IsClosed and the handler are only touched there.
/// Sends go through one channel, so at most one SendAsync is ever in flight.
/// </summary>
sealed class Link
{
    const int MaxMessage = 2 << 20;
    readonly SerialQueue _q;
    readonly Action<Link, LinkEvent> _onEvent;
    readonly CancellationTokenSource _cts = new();
    readonly Channel<(byte[] Data, WebSocketMessageType Type, Action<bool>? Done)> _sendQ =
        Channel.CreateUnbounded<(byte[], WebSocketMessageType, Action<bool>?)>(new UnboundedChannelOptions { SingleReader = true });
    WebSocket? _ws;

    public DateTime OpenedAt { get; }
    public string Peer { get; }
    public bool IsClosed { get; private set; }

    Link(SerialQueue q, Action<Link, LinkEvent> onEvent, DateTime openedAt, string peer)
    {
        _q = q; _onEvent = onEvent; OpenedAt = openedAt; Peer = peer;
    }

    public static Link Dial(string host, int port, TimeSpan timeout, SerialQueue q, DateTime openedAt, Action<Link, LinkEvent> onEvent)
    {
        var l = new Link(q, onEvent, openedAt, host);
        _ = l.DialAsync(host, port, timeout);
        return l;
    }

    /// <summary>Wrap an accepted server-side socket. Call on the queue; starts reading at once.</summary>
    public static Link Accepted(WebSocket ws, string peer, SerialQueue q, DateTime openedAt, Action<Link, LinkEvent> onEvent)
    {
        var l = new Link(q, onEvent, openedAt, peer) { _ws = ws };
        l.StartLoops(ws);
        return l;
    }

    async Task DialAsync(string host, int port, TimeSpan timeout)
    {
        var ws = new ClientWebSocket();
        ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
        using var to = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
        to.CancelAfter(timeout);
        try
        {
            await ws.ConnectAsync(new Uri($"ws://{host}:{port}/lan-line"), to.Token).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            ws.Dispose();
            var why = to.IsCancellationRequested && !_cts.IsCancellationRequested ? "dial timeout" : Short(e);
            _q.Post(() => Finish($"unreachable {host}: {why}"));
            return;
        }
        _q.Post(() =>
        {
            if (IsClosed) { ws.Abort(); ws.Dispose(); return; }
            _ws = ws;
            StartLoops(ws);
            _onEvent(this, new LinkEvent(LinkEventKind.Ready));
        });
    }

    void StartLoops(WebSocket ws)
    {
        _ = Task.Run(() => ReceiveLoop(ws));
        _ = Task.Run(() => SendLoop(ws));
    }

    async Task ReceiveLoop(WebSocket ws)
    {
        var buf = new byte[64 * 1024];
        var ms = new MemoryStream();
        try
        {
            while (true)
            {
                var r = await ws.ReceiveAsync(buf, _cts.Token).ConfigureAwait(false);
                if (r.MessageType == WebSocketMessageType.Close) { _q.Post(() => Finish("closed by peer")); return; }
                ms.Write(buf, 0, r.Count);
                if (ms.Length > MaxMessage) { _q.Post(() => Finish("message too big")); return; }
                if (!r.EndOfMessage) continue;
                var data = ms.ToArray();
                ms.SetLength(0);
                var ev = r.MessageType == WebSocketMessageType.Text
                    ? new LinkEvent(LinkEventKind.Text, Text: Encoding.UTF8.GetString(data))
                    : new LinkEvent(LinkEventKind.Data, Data: data);
                _q.Post(() => { if (!IsClosed) _onEvent(this, ev); });
            }
        }
        catch (Exception e)
        {
            _q.Post(() => Finish($"receive: {Short(e)}"));
        }
    }

    async Task SendLoop(WebSocket ws)
    {
        try
        {
            await foreach (var m in _sendQ.Reader.ReadAllAsync(_cts.Token).ConfigureAwait(false))
            {
                var ok = true;
                try { await ws.SendAsync(m.Data, m.Type, true, _cts.Token).ConfigureAwait(false); }
                catch (Exception) { ok = false; }
                if (m.Done is { } done) _q.Post(() => done(ok));
                if (!ok) { _q.Post(() => Finish("send failed")); return; }
            }
        }
        catch (OperationCanceledException) { }
    }

    public void SendText(string s, Action<bool>? done = null) => Enqueue(Encoding.UTF8.GetBytes(s), WebSocketMessageType.Text, done);
    public void SendData(byte[] d, Action<bool>? done = null) => Enqueue(d, WebSocketMessageType.Binary, done);

    void Enqueue(byte[] d, WebSocketMessageType t, Action<bool>? done)
    {
        if (IsClosed || !_sendQ.Writer.TryWrite((d, t, done)))
            if (done != null) _q.Post(() => done(false));
    }

    /// <summary>Tear the connection down; reports Closed(reason) once. Call on the queue.</summary>
    public void Close(string reason) => Finish(reason);

    void Finish(string reason)
    {
        if (IsClosed) return;
        IsClosed = true;
        _cts.Cancel();
        _sendQ.Writer.TryComplete();
        try { _ws?.Abort(); _ws?.Dispose(); } catch (Exception) { }
        _onEvent(this, new LinkEvent(LinkEventKind.Closed, Reason: reason));
    }

    static string Short(Exception e) => (e.InnerException ?? e).Message;
}

/// <summary>
/// The listener role: a TCP listener that answers the HTTP upgrade and hands the stream to the standard
/// library's WebSocket (framing is never hand-written). The Mac uses Network.framework instead; this exists
/// so the PC can run tests and the "Mac selftest dials the PC" direction.
/// </summary>
sealed class Listener
{
    readonly TcpListener _tcp;
    readonly Action<WebSocket, string> _accepted;   // called on a pool thread
    public int Port { get; }

    public Listener(string? bindHost, int port, Action<WebSocket, string> accepted)
    {
        _tcp = new TcpListener(bindHost == null ? IPAddress.Any : IPAddress.Parse(bindHost), port);
        _tcp.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _tcp.Start();
        Port = ((IPEndPoint)_tcp.LocalEndpoint).Port;
        _accepted = accepted;
        _ = Task.Run(AcceptLoop);
    }

    public void Stop() { try { _tcp.Stop(); } catch (Exception) { } }

    async Task AcceptLoop()
    {
        while (true)
        {
            TcpClient c;
            try { c = await _tcp.AcceptTcpClientAsync().ConfigureAwait(false); } catch (Exception) { return; }
            _ = Task.Run(() => Upgrade(c));
        }
    }

    async Task Upgrade(TcpClient c)
    {
        try
        {
            c.NoDelay = true;
            var s = c.GetStream();
            using var to = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var head = new StringBuilder();
            var one = new byte[1];
            while (head.Length < 8192 && !head.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
            {
                if (await s.ReadAsync(one, to.Token).ConfigureAwait(false) == 0) { c.Dispose(); return; }
                head.Append((char)one[0]);
            }
            string? key = null;
            foreach (var line in head.ToString().Split("\r\n"))
                if (line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)) key = line[18..].Trim();
            if (key == null) { c.Dispose(); return; }
            var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            var resp = Encoding.ASCII.GetBytes($"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n");
            await s.WriteAsync(resp, to.Token).ConfigureAwait(false);
            var ws = WebSocket.CreateFromStream(s, new WebSocketCreationOptions { IsServer = true, KeepAliveInterval = TimeSpan.FromSeconds(15) });
            _accepted(ws, c.Client.RemoteEndPoint?.ToString() ?? "?");
        }
        catch (Exception) { c.Dispose(); }
    }
}
