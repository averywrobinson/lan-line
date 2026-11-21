# Lan-Line encryption (protocol v2)

Status: shipped in 0.9.0-beta.5 (2026-11-21).

## Threat model
**Protects against:**
- **Anyone on the same network:** Wi-Fi neighbours, a compromised device, a café or office LAN. They can read and change packets between the two computers.
  - **Passive** (sniffing): must learn nothing about content, file names or sizes beyond traffic volume and timing. The long-term secret never crosses the wire.
  - **Active** (injecting, replaying, man-in-the-middle): cannot impersonate either computer, cannot change or replay messages without detection, and cannot downgrade to plaintext.
- **A stolen past capture:** later theft of the long-term secret must not decrypt old sessions (forward secrecy).

**Not covered:**
- A compromised computer at either end (it has the files anyway).
- Traffic analysis: how much is sent, and when.
- Denial of service on the LAN.
- The secret stored in the user's config file. It keeps today's protection: 0600 on the Mac, %APPDATA% on Windows.

## Why not TLS
The Mac app speaks WebSocket over BSD sockets with its own framing, chosen because Network.framework managed about 0.5 MB/s against 300+ MB/s here. TLS from the standard libraries would mean Network.framework or the deprecated SecureTransport. Instead: a small authenticated key exchange using standard library primitives only.
- **Mac:** CryptoKit (P256.KeyAgreement, HKDF, HMAC, AES.GCM).
- **Windows:** System.Security.Cryptography (ECDiffieHellman P-256, HKDF, HMACSHA256, AesGcm).

It's the same shape as TLS 1.3 PSK with (EC)DHE: a pre-shared key (the pairing secret) authenticates fresh ephemeral keys.

## Handshake (replaces v1 `hello` / `hello_ok`, still JSON text frames)
`S` = UTF-8 bytes of the shared secret: the 64-hex long-term secret, or the 10-character code while pairing.

1. **Derive the MAC key:** `K_mac = HKDF-SHA256(ikm: S, salt: "lan-line/v2", info: "mac", 32)`.
2. **Dialer → listener:** `{"type":"hello","v":2,"name":…,"nonce":b64(32 random),"epk":b64(P-256 public, X9.63 uncompressed),"mac":b64(HMAC(K_mac, T1))}`.
   - `T1 = "LL2-HELLO" ‖ lp(name) ‖ nonce ‖ epk`, where `lp` is a 4-byte big-endian length prefix.
   - The secret itself is never sent. v1 sent it in the clear.
3. **Listener checks** `mac` in constant time against its secret. While pairing, or after a rekey, it also tries the previous secret until restart, then uses whichever matched as `S`. On failure it closes with "bad hello" and records nothing.
4. **Listener → dialer:** `{"type":"hello_ok","v":2,"name":…,"nonce":…,"epk":…,"mac":b64(HMAC(K_mac, T2))}`.
   - `T2 = "LL2-OK" ‖ T1 ‖ lp(name) ‖ nonce_s ‖ epk_s`. The dialer checks it, so a fake listener without `S` is refused.
5. **Both derive the session keys:**
   - `Z = ECDH(own ephemeral, peer epk)`.
   - `keys = HKDF-SHA256(ikm: Z, salt: SHA256(S), info: "LL2-KEYS" ‖ SHA256(T2), 64)`.
   - The first 32 bytes are the dialer→listener key; the last 32 are listener→dialer.
6. **From then on, every WebSocket message is a binary frame:** `AES-256-GCM(key_dir, nonce = 4 zero bytes ‖ counter as u64 big-endian, plaintext)`, with ciphertext and 16-byte tag.
   - `plaintext = kind (1 byte) ‖ payload`: kind 1 = a JSON control frame (text, file_begin, file_end, ack, beat, rekey, addrs); kind 2 = a file chunk.
   - Each direction counts from 0. A failed tag or a skipped or replayed counter closes the link.
   - A link closes itself after 2³¹ messages; a reconnect makes fresh keys.

## Keys and rotation
- **Per connection:** fresh ephemeral P-256 keys, so every connection has new AES keys (forward secrecy).
- **Long-term secret:** 32 random bytes, made at pairing.
  - The listener sends it as an encrypted `{"type":"rekey","token":…}` right after the first pairing handshake. v1 sent it in plaintext `hello_ok`.
  - A listener still holding a 10-character beta code also sends one, so old pairings upgrade.
  - "Pair again" makes a new one. Later possibility: an automatic rotation interval.
- **Fallback addresses:** sent as encrypted `{"type":"addrs"}`, no longer in plaintext `hello_ok`.
- **The 10-character pairing code** (50 bits) is only a key for the first connection. A passive capture of the pairing hello could be brute-forced offline in time. That still can't decrypt the session (ephemeral ECDH) or reveal the real secret (sent encrypted). An active attacker would need the code within the 8-second pairing window. A real PAKE (SPAKE2/OPAQUE) would be stronger, but neither platform's standard library has one.

## Compatibility
- **Version:** protocol v2 ships as 0.9.0-beta.5. Both computers must be on beta.5 or later; there is no plaintext fallback, so a downgrade attack is impossible.
- **A beta.5 listener getting a v1 hello** replies with a plaintext `{"type":"error","err":"upgrade","v":2}`, then closes. The window shows: "The other computer runs an older Lan-Line. Update it to connect."
- **A beta.5 dialer refused by a v1 listener** (which closes on `v:2`) shows: "Can't connect: update Lan-Line on the other computer too."
- **Configs, pairing codes and the stored secret format** are unchanged, so updating both keeps the pairing.
- **Discovery** (`LANLINE?1`) is unchanged.

## Tests (tests first, both platforms)
- **Primitives:** fixed test vectors, identical in Swift and C#, for `K_mac`, T1/T2 MACs, key derivation from a fixed `Z`, and one sealed message. This proves the two implementations match byte for byte.
- **Handshake:**
  - The right secret connects.
  - A wrong secret, or an old secret after a rotation and restart, is refused on both sides; neither side reports connected.
  - A tampered `epk` or `nonce` is refused.
  - A v1 hello gets the "upgrade" error.
- **Channel:**
  - A flipped bit in a frame closes the link.
  - A replayed frame closes it.
  - Counters run per direction.
- **On the wire:** a test TCP proxy records every byte between the two sessions while a text marker, a file with a known pattern and the secret pass through. None of those bytes appear in the capture. (The same test without encryption would find them.)
- **Existing behaviour:** the suites (files, 50 MB, dead link, queue, rekey, addrs) run over the encrypted channel.
- **Cross-machine:**
  - selftests Mac ↔ PC in all four directions (50 MB, SHA-256);
  - a pairing round trip with the secret swap;
  - throughput stays within 10 % of beta.4.
