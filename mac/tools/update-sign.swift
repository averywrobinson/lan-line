// Lan-Line release signing for one-click updates (beta.10).
//   swift tools/update-sign.swift keygen        create the key once (Keychain item lan-line-update-signing), print the public key
//   swift tools/update-sign.swift pubkey        print the public key (for SignedUpdate.publicKeyBase64 / SignedUpdate.cs)
//   swift tools/update-sign.swift sign VERSION MAC_DMG WIN_EXE OUT.json
//        hashes both files, names their GitHub release download URLs, signs, writes update.json (site/update.json).
//   swift tools/update-sign.swift verify UPDATE.json [MAC_DMG WIN_EXE]
//        checks the signature against the Keychain key's public half, prints what it says, and (given the files)
//        checks their size and SHA-256 against it.
// The private key never leaves the Keychain except into this process. Back it up (see release/CHECKLIST.md): without
// it, installed copies can't take one-click updates and need one manual install of a build with a new key.
import Foundation
import CryptoKit
import Security

let service = "lan-line-update-signing", account = "lan-line"

func sh(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Read through the Security framework (the way keygen stores it); the `security` tool is the fall-back for an
/// item made some other way. Either way the key only ever travels from the Keychain into this process.
func loadKey() -> P256.Signing.PrivateKey? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let raw = out as? Data,
       let d = Data(base64Encoded: String(decoding: raw, as: UTF8.self)), let k = try? P256.Signing.PrivateKey(rawRepresentation: d) { return k }
    let (rc, text) = sh(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard rc == 0, let d = Data(base64Encoded: text) else { return nil }
    return try? P256.Signing.PrivateKey(rawRepresentation: d)
}

func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func sha256(_ u: URL) -> (Int64, String) {
    guard let h = try? FileHandle(forReadingFrom: u) else { die("can't read \(u.path)") }
    var hasher = SHA256(), n: Int64 = 0
    while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d); n += Int64(d.count) }
    return (n, hasher.finalize().map { String(format: "%02x", $0) }.joined())
}

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "keygen":
    if loadKey() != nil { die("a key already exists in the Keychain; refusing to replace it") }
    let k = P256.Signing.PrivateKey()
    // Straight into the Keychain through the Security framework: never as a command-line argument, where any
    // process on this Mac could read it from the process list while the command ran.
    let add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "Lan-Line update signing key",
        kSecValueData as String: Data(k.rawRepresentation.base64EncodedString().utf8),
    ]
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { die("couldn't save to the Keychain") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    guard let k = loadKey() else { die("no key in the Keychain (run keygen)") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign" where a.count == 6:
    guard let k = loadKey() else { die("no key in the Keychain") }
    let version = a[2]
    func asset(_ path: String) -> [String: Any] {
        let u = URL(fileURLWithPath: path)
        let (size, hash) = sha256(u)
        return ["url": "https://github.com/averywrobinson/lan-line/releases/download/v\(version)/\(u.lastPathComponent)", "size": size, "sha256": hash]
    }
    let payload: [String: Any] = ["version": version, "mac": asset(a[3]), "windows": asset(a[4]),
                                  "notes_url": "https://github.com/averywrobinson/lan-line/releases/tag/v\(version)"]
    let body = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let sig = try! k.signature(for: body).rawRepresentation
    let env = try! JSONSerialization.data(withJSONObject: ["payload": body.base64EncodedString(), "sig": sig.base64EncodedString()], options: [.sortedKeys, .prettyPrinted])
    try! env.write(to: URL(fileURLWithPath: a[5]))
    guard k.publicKey.isValidSignature(try! P256.Signing.ECDSASignature(rawRepresentation: sig), for: body) else { die("self-check failed") }
    print("wrote \(a[5]) for \(version)")
case "verify" where a.count == 3 || a.count == 5:
    guard let k = loadKey() else { die("no key in the Keychain") }
    guard let env = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2]))) as? [String: String],
          let body = env["payload"].flatMap({ Data(base64Encoded: $0) }), let sig = env["sig"].flatMap({ Data(base64Encoded: $0) }),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else { die("\(a[2]) isn't an update.json") }
    guard k.publicKey.isValidSignature(signature, for: body) else { die("BAD SIGNATURE: not signed with this Mac's key") }
    guard let p = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { die("the payload isn't JSON") }
    print("signature OK (public key \(k.publicKey.rawRepresentation.base64EncodedString().prefix(12))…)")
    print("version: \(p["version"] ?? "?")")
    for (name, path) in [("mac", a.count == 5 ? a[3] : nil), ("windows", a.count == 5 ? a[4] : nil)] {
        guard let m = p[name] as? [String: Any] else { print("\(name): none"); continue }
        print("\(name): \(m["url"] ?? "?")  \(m["size"] ?? "?") bytes  sha256 \(m["sha256"] ?? "?")")
        if let path {
            let (size, hash) = sha256(URL(fileURLWithPath: path))
            guard (m["size"] as? NSNumber)?.int64Value == size, m["sha256"] as? String == hash else { die("\(name): \(path) does NOT match the signed size and hash") }
            print("\(name): \(path) matches")
        }
    }
default:
    die("usage: update-sign.swift keygen | pubkey | sign VERSION MAC_DMG WIN_EXE OUT.json | verify UPDATE.json [MAC_DMG WIN_EXE]")
}
