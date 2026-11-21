# Lan-Line wire protocol, v2 (0.9.0-beta.5, capabilities from beta.6)

Transport: one WebSocket per paired computers. The computer that showed the pairing code listens on `ws://0.0.0.0:47830/lan-line`; the other dials it at the addresses saved when they paired. The path is informational: the listener accepts any path. Plain RFC 6455 WebSockets with no extensions or subprotocols; the Mac app implements the framing itself on BSD sockets (`mac/Sources/LanLineCore/WebSocket.swift`), the Windows app uses .NET's `System.Net.WebSockets`.

**Encrypted (v2):** the handshake (`hello`, `hello_ok`, `error`) is JSON text frames in the clear, but it never carries the secret: the pairing secret authenticates a fresh P-256 ECDH, and from `hello_ok` on every message is one **binary frame** sealed with AES-256-GCM (kind byte 1 = a JSON control frame below, 2 = a file chunk). Full spec, keys and threat model: `ENCRYPTION.md`. Plaintext after the handshake, a bad tag or a skipped counter closes the link. There is no plaintext fallback; v1 (beta.1–beta.4) and v2 can't talk to each other.

Control messages are UTF-8 JSON objects with a `type` field. File bytes travel as chunks (at most 256 KiB each) between `file_begin` and `file_end`.

| type | Fields | Direction | Meaning |
|---|---|---|---|
| `hello` (clear) | `v` (2), `name`, `nonce`, `epk`, `mac` | dialer → listener, first frame | Authenticate (ENCRYPTION.md). No hello within 10 s closes the socket. |
| `hello_ok` (clear) | `v`, `name`, `nonce`, `epk`, `mac` | listener → dialer | Accepted; the dialer checks `mac`, then both sides are connected and encrypted. |
| `error` (clear) | `v`, `err` | listener → dialer, then close | `upgrade`: the hello was protocol v1 (the window says to update the older computer). `auth`: the `mac` matches no secret (pair again). |
| `rekey` | `token` | listener → dialer (encrypted) | Right after pairing, or when the dialer still used the pairing code: the 64-hex long-term secret. |
| `addrs` | `addrs` | listener → dialer (encrypted) | The listener's IPv4 addresses; the dialer keeps them as fallback hosts. |
| `text` | `id`, `text` | either | A text item. |
| `file_begin` | `id`, `name`, `size`, `sha256` (hex; omitted when the peer has `sha_end`), `folder`?, `path`? | either | A file follows. `size` ≤ 1 TiB (a sanity bound); the receiver refuses a file that would leave under 64 MiB free, and answers that refusal (`ack ok:false`) at once, so the sender stops. |
| (chunk) | raw bytes | either | The next chunk of the current file. |
| `file_end` | `id`, `sha256`? | either | The current file is complete. With `sha_end`, the SHA-256 comes here: the sender hashes while it streams. |
| `folder_begin` | `id`, `name`, `count`, `size` | either | A folder follows (`folders` cap): `count` files, `size` bytes in all. Space is checked here, and a refusal is answered at once. |
| `mkdir` | `folder`, `path` | either | A folder inside it (so empty folders arrive too). |
| `folder_end` | `id` | either | The folder is complete; the receiver acks the folder's `id` once. |
| `ack` | `id`, `ok`, `err?` | either | Receipt of an item. `ok:false` means it was rejected (`err` says why). |
| `beat` | | either | Liveness, every 15 s. |

## Rules
- `id` is a sender-chosen unique string (a UUID). Receivers remember finished ids and ack a repeat without delivering it again, so resends after a reconnect are safe.
- One item at a time per direction, in order: a sender never starts a `text` or `file_begin` while its current file is still streaming. `ack` and `beat` frames may appear anywhere, including between a file's binary frames.
- Received names are reduced to their base name: path separators (`/`, `\`), `..`, leading dots, control characters and Windows-reserved characters are removed; an empty result becomes `file`. Clashes are saved as `name (2).ext`, `name (3).ext`, …
- Receivers stream to `<name>.<id>.part`, hash incrementally, and check the byte count and SHA-256 at `file_end`. On a mismatch the part file is deleted and `ack{ok:false, err:"sha256 mismatch"}` (or `"size mismatch"`) is sent. Partial files are deleted when the link drops.
- Any frame counts as proof of life. A side that hears nothing for 45 s closes the link. WebSocket protocol pings are answered automatically too.
- Items sent while disconnected stay queued and go out after the next `hello_ok`. An item counts as delivered only when its `ack` arrives; un-acked items are resent after a reconnect.

## Capabilities (beta.6+)
`hello` and `hello_ok` carry `caps`, what that side can do. A side without `caps` is beta.5 and gets the beta.5 behaviour (hash first, SHA-256 in `file_begin`, no folders).
- `sha_end`: the SHA-256 may come in `file_end`, so `file_begin` goes out without hashing first. A file too big for the receiver is refused in milliseconds instead of after hashing it.
- `folders`: `folder_begin` / `mkdir` / `file_begin` with `folder` and `path` / `folder_end`. Paths are `/`-separated and relative. The receiver refuses the whole folder on an absolute path, an empty, `.` or `..` part, a backslash, or more than 64 levels, and sanitises each name like a file name. It builds the folder in a hidden `.<name>.<random>.part` folder and moves it into place (`name (2)` on a clash) only when every file arrived and checked out. Senders never follow symlinks or junctions; they are left out.
- `caps` sits outside the handshake MAC: removing it only falls back to beta.5 behaviour, and adding one a side can't handle breaks the link, which an attacker on the LAN can do anyway.

## Pairing and discovery

- **Rekey:** when the listener is pairing (or still holds a 10-character code from 0.9.0-beta.1), it sends an encrypted `rekey` right after `hello_ok`: a new random 32-byte secret, hex. Both sides save it and use it from then on, so the short on-screen code is never the long-term secret. The listener keeps accepting the code until it restarts and sends `rekey` again to a dialer that still uses it (the first one may have been lost).
- **Pairing code:** 10 characters of Crockford base32 (`0-9 A-Z` without `I L O U`), shown as `XXXXX-XXXXX`. When typed, case and dashes are ignored and `O`→`0`, `I`/`L`→`1`. The code is the first shared secret: the dialer proves it knows it in `hello` (it is never sent). Nothing is saved until the first connection succeeds; then both sides keep `{port, token, role, hosts, peer}` in their config.
- **Discovery (UDP, same port 47830):** the dialer broadcasts the ASCII datagram `LANLINE?1` (to 255.255.255.255 and each interface's broadcast address). A listening computer answers with JSON `{"lanline":1,"name":…,"port":…,"pair":…}`, where `pair` is the first 8 hex characters of SHA-256 of `"lan-line-pair:" + token`. The pair id reveals nothing about the code; a paired dialer that can't reach its partner searches again every 20 s and follows a matching `pair` to a new address.
