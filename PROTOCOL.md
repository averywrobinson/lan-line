# Lan-Line wire protocol, v1

Transport: one WebSocket per paired computers. The computer that showed the pairing code listens on `ws://0.0.0.0:47830/lan-line`; the other dials it at the addresses saved when they paired. The path is informational: the listener accepts any path. Plain RFC 6455 WebSockets with no extensions or subprotocols; the Mac app implements the framing itself on BSD sockets (`mac/Sources/LanLineCore/WebSocket.swift`), the Windows app uses .NET's `System.Net.WebSockets`.

Control messages are UTF-8 JSON **text frames** with a `type` field. File bytes travel as **binary frames** (at most 256 KiB each) between `file_begin` and `file_end`.

| type | Fields | Direction | Meaning |
|---|---|---|---|
| `hello` | `v` (1), `token` (the pairing code, 10 characters; older configs: 64 hex chars), `name` | dialer → listener, first frame | Authenticate. The listener compares the token in constant time; on a mismatch, a wrong `v`, or no hello within 10 s it closes the socket. |
| `hello_ok` | `name` | listener → dialer | Accepted; both sides are now connected. |
| `text` | `id`, `text` | either | A text item. |
| `file_begin` | `id`, `name`, `size`, `sha256` (hex) | either | A file follows. `size` ≤ 1 TiB (a sanity bound); the receiver refuses a file that would leave under 64 MiB free. |
| (binary) | raw bytes | either | The next chunk of the current file. |
| `file_end` | `id` | either | The current file is complete. |
| `ack` | `id`, `ok`, `err?` | either | Receipt of an item. `ok:false` means it was rejected (`err` says why). |
| `beat` | | either | Liveness, every 15 s. |

## Rules
- `id` is a sender-chosen unique string (a UUID). Receivers remember finished ids and ack a repeat without delivering it again, so resends after a reconnect are safe.
- One item at a time per direction, in order: a sender never starts a `text` or `file_begin` while its current file is still streaming. `ack` and `beat` frames may appear anywhere, including between a file's binary frames.
- Received names are reduced to their base name: path separators (`/`, `\`), `..`, leading dots, control characters and Windows-reserved characters are removed; an empty result becomes `file`. Clashes are saved as `name (2).ext`, `name (3).ext`, …
- Receivers stream to `<name>.<id>.part`, hash incrementally, and check the byte count and SHA-256 at `file_end`. On a mismatch the part file is deleted and `ack{ok:false, err:"sha256 mismatch"}` (or `"size mismatch"`) is sent. Partial files are deleted when the link drops.
- Any frame counts as proof of life. A side that hears nothing for 45 s closes the link. WebSocket protocol pings are answered automatically too.
- Items sent while disconnected stay queued and go out after the next `hello_ok`. An item counts as delivered only when its `ack` arrives; un-acked items are resent after a reconnect.

## Pairing and discovery

- **Pairing code:** 10 characters of Crockford base32 (`0-9 A-Z` without `I L O U`), shown as `XXXXX-XXXXX`. When typed, case and dashes are ignored and `O`→`0`, `I`/`L`→`1`. The code is the shared token: the dialer sends it in `hello`. Nothing is saved until the first connection succeeds; then both sides keep `{port, token, role, hosts, peer}` in their config.
- **Discovery (UDP, same port 47830):** the dialer broadcasts the ASCII datagram `LANLINE?1` (to 255.255.255.255 and each interface's broadcast address). A listening computer answers with JSON `{"lanline":1,"name":…,"port":…,"pair":…}`, where `pair` is the first 8 hex characters of SHA-256 of `"lan-line-pair:" + token`. The pair id reveals nothing about the code; a paired dialer that can't reach its partner searches again every 20 s and follows a matching `pair` to a new address.
