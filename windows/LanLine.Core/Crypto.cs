using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace LanLine.Core;

/// <summary>
/// Protocol v2 encryption (ENCRYPTION.md): the shared secret authenticates a fresh P-256 ECDH per connection,
/// HKDF-SHA256 gives one AES-256-GCM key per direction, and every message after the handshake is sealed.
/// Byte for byte the same as mac/Sources/LanLineCore/Crypto.swift (shared test vectors).
/// </summary>
public static class LL2
{
    public const int Version = 2;
    static readonly byte[] MacSalt = "lan-line/v2"u8.ToArray();

    static byte[] Cat(params byte[][] parts)
    {
        var o = new byte[parts.Sum(p => p.Length)];
        var i = 0;
        foreach (var p in parts) { p.CopyTo(o, i); i += p.Length; }
        return o;
    }

    /// <summary>4-byte big-endian length, then the bytes.</summary>
    static byte[] Lp(byte[] d)
    {
        var o = new byte[4 + d.Length];
        BinaryPrimitives.WriteUInt32BigEndian(o, (uint)d.Length);
        d.CopyTo(o, 4);
        return o;
    }

    public static byte[] MacKey(string secret) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(secret), 32, MacSalt, "mac"u8.ToArray());

    public static byte[] T1(string name, byte[] nonce, byte[] epk) => Cat("LL2-HELLO"u8.ToArray(), Lp(Encoding.UTF8.GetBytes(name)), nonce, epk);

    public static byte[] T2(byte[] t1, string name, byte[] nonce, byte[] epk) => Cat("LL2-OK"u8.ToArray(), t1, Lp(Encoding.UTF8.GetBytes(name)), nonce, epk);

    public static byte[] Mac(byte[] key, byte[] t) => HMACSHA256.HashData(key, t);

    public static bool Verify(byte[] key, byte[] t, byte[] mac) => mac.Length == 32 && CryptographicOperations.FixedTimeEquals(Mac(key, t), mac);

    /// <summary>64 bytes: dialer→listener key, then listener→dialer key.</summary>
    public static (byte[] D2L, byte[] L2D) SessionKeys(byte[] z, string secret, byte[] t2)
    {
        var okm = HKDF.DeriveKey(HashAlgorithmName.SHA256, z, 64, SHA256.HashData(Encoding.UTF8.GetBytes(secret)),
                                 Cat("LL2-KEYS"u8.ToArray(), SHA256.HashData(t2)));
        return (okm[..32], okm[32..]);
    }

    /// <summary>The public key as X9.63 uncompressed (04 ‖ X ‖ Y), 65 bytes.</summary>
    public static byte[] Epk(ECDiffieHellman k)
    {
        var p = k.ExportParameters(false);
        return Cat([4], p.Q.X!, p.Q.Y!);
    }

    public static ECDiffieHellman NewKey() => ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    /// <summary>Tests: a fixed private key (with its public point).</summary>
    public static ECDiffieHellman KeyFrom(byte[] d, byte[] epk) => ECDiffieHellman.Create(new ECParameters
    {
        Curve = ECCurve.NamedCurves.nistP256, D = d, Q = new ECPoint { X = epk[1..33], Y = epk[33..] },
    });

    /// <summary>The raw shared x-coordinate, or null if the peer key is not a valid P-256 point.</summary>
    public static byte[]? Z(ECDiffieHellman own, byte[] peer)
    {
        if (peer.Length != 65 || peer[0] != 4) return null;
        try
        {
            using var p = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = peer[1..33], Y = peer[33..] },
            });
            return own.DeriveRawSecretAgreement(p.PublicKey);
        }
        catch (CryptographicException) { return null; }
    }

    public static byte[]? B64(string? s)
    {
        if (s == null) return null;
        try { return Convert.FromBase64String(s); } catch (FormatException) { return null; }
    }
}

/// <summary>The dialer's half of the handshake: make the hello, then check the listener's hello_ok.</summary>
public sealed class DialerHandshake
{
    readonly ECDiffieHellman _priv;
    readonly byte[] _t1;
    readonly string _secret;
    public Frame Hello { get; }

    public DialerHandshake(string secret, string name, ECDiffieHellman? priv = null, byte[]? nonce = null)
    {
        _priv = priv ?? LL2.NewKey();
        _secret = secret;
        nonce ??= RandomNumberGenerator.GetBytes(32);
        var epk = LL2.Epk(_priv);
        _t1 = LL2.T1(name, nonce, epk);
        Hello = new Frame
        {
            Type = "hello", V = LL2.Version, Name = name, Nonce = Convert.ToBase64String(nonce),
            Epk = Convert.ToBase64String(epk), Mac = Convert.ToBase64String(LL2.Mac(LL2.MacKey(secret), _t1)),
        };
    }

    /// <summary>null = the listener does not know our secret (or the reply was tampered with).</summary>
    public SecureChannel? Finish(Frame ok)
    {
        if (ok is not { Type: "hello_ok", V: LL2.Version }) return null;
        if (LL2.B64(ok.Nonce) is not { Length: 32 } n || LL2.B64(ok.Epk) is not { } e || LL2.B64(ok.Mac) is not { } m) return null;
        var t2 = LL2.T2(_t1, ok.Name ?? "", n, e);
        if (!LL2.Verify(LL2.MacKey(_secret), t2, m) || LL2.Z(_priv, e) is not { } z) return null;
        var (d2l, l2d) = LL2.SessionKeys(z, _secret, t2);
        return new SecureChannel(d2l, l2d);
    }
}

/// <summary>The listener's half: check a hello against the secrets it accepts and answer it.</summary>
public static class ListenerHandshake
{
    /// <param name="SecretIndex">Which offered secret matched (0 = current, 1 = the previous one).</param>
    public sealed record Answer(Frame Ok, SecureChannel Channel, int SecretIndex);

    public static Answer? Respond(Frame hello, IReadOnlyList<string> secrets, string name, ECDiffieHellman? priv = null, byte[]? nonce = null)
    {
        if (hello is not { Type: "hello", V: LL2.Version }) return null;
        if (LL2.B64(hello.Nonce) is not { Length: 32 } n || LL2.B64(hello.Epk) is not { Length: 65 } e || LL2.B64(hello.Mac) is not { } m) return null;
        var t1 = LL2.T1(hello.Name ?? "", n, e);
        var idx = -1;
        for (var i = 0; i < secrets.Count; i++)
            if (LL2.Verify(LL2.MacKey(secrets[i]), t1, m) && idx < 0) idx = i;
        if (idx < 0) return null;
        priv ??= LL2.NewKey();
        if (LL2.Z(priv, e) is not { } z) return null;
        nonce ??= RandomNumberGenerator.GetBytes(32);
        var secret = secrets[idx];
        var epk = LL2.Epk(priv);
        var t2 = LL2.T2(t1, name, nonce, epk);
        var ok = new Frame
        {
            Type = "hello_ok", V = LL2.Version, Name = name, Nonce = Convert.ToBase64String(nonce),
            Epk = Convert.ToBase64String(epk), Mac = Convert.ToBase64String(LL2.Mac(LL2.MacKey(secret), t2)),
        };
        var (d2l, l2d) = LL2.SessionKeys(z, secret, t2);
        return new Answer(ok, new SecureChannel(l2d, d2l), idx);
    }
}

public enum ChannelKind : byte { Control = 1, Chunk = 2 }

/// <summary>AES-256-GCM both ways with message counters. Used only on the Session queue.</summary>
public sealed class SecureChannel : IDisposable
{
    const ulong Limit = 1UL << 31;
    readonly AesGcm _send, _recv;
    ulong _sent, _received;

    public SecureChannel(byte[] sendKey, byte[] recvKey) { _send = new AesGcm(sendKey, 16); _recv = new AesGcm(recvKey, 16); }

    static byte[] Nonce(ulong n)
    {
        var b = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(b.AsSpan(4), n);
        return b;
    }

    /// <summary>ciphertext ‖ 16-byte tag. null once the counter limit is reached (the link must reconnect).</summary>
    public byte[]? Seal(ChannelKind kind, ReadOnlySpan<byte> payload)
    {
        if (_sent >= Limit) return null;
        var pt = new byte[payload.Length + 1];
        pt[0] = (byte)kind;
        payload.CopyTo(pt.AsSpan(1));
        var o = new byte[pt.Length + 16];
        _send.Encrypt(Nonce(_sent), pt, o.AsSpan(0, pt.Length), o.AsSpan(pt.Length));
        _sent++;
        return o;
    }

    /// <summary>null = tampered, replayed, reordered or past the limit: close the link.</summary>
    public (ChannelKind Kind, byte[] Payload)? Open(byte[] d)
    {
        if (_received >= Limit || d.Length < 17) return null;
        var pt = new byte[d.Length - 16];
        try { _recv.Decrypt(Nonce(_received), d.AsSpan(0, pt.Length), d.AsSpan(pt.Length), pt); }
        catch (CryptographicException) { return null; }
        if (pt[0] is not (1 or 2)) return null;
        _received++;
        return ((ChannelKind)pt[0], pt[1..]);
    }

    public void Dispose() { _send.Dispose(); _recv.Dispose(); }
}
