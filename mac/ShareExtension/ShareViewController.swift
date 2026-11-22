import Cocoa

/// Finder / app "Share → Lan-Line". Collects what was shared (files, folders, images, text, links), hands it to the
/// Lan-Line app as a `lanline://stage?...` link, and closes at once. It never sends anything itself: the app stages
/// the items above the message box and the user picks who gets them and presses Send.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let lock = NSLock()
    private var paths: [String] = []
    private var texts: [String] = []

    override var nibName: NSNib.Name? { nil }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { self.add(path: u.path) }
                    else if let u = item as? URL, u.isFileURL { self.add(path: u.path) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier("public.url") {
                group.enter()
                p.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                    if let u = item as? URL { self.add(text: u.absoluteString) }
                    else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { self.add(text: u.absoluteString) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier("public.plain-text") {
                group.enter()
                p.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
                    if let s = item as? String { self.add(text: s) } else if let d = item as? Data { self.add(text: String(decoding: d, as: UTF8.self)) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { self.handOff() }
    }

    private func add(path: String) { lock.lock(); paths.append(path); lock.unlock() }
    private func add(text: String) { lock.lock(); texts.append(text); lock.unlock() }

    private func handOff() {
        var c = URLComponents()
        c.scheme = "lanline"; c.host = "stage"
        lock.lock()
        c.queryItems = paths.prefix(200).map { URLQueryItem(name: "p", value: $0) } + texts.prefix(20).map { URLQueryItem(name: "t", value: String($0.prefix(100_000))) }
        lock.unlock()
        if let u = c.url, !(c.queryItems ?? []).isEmpty { NSWorkspace.shared.open(u) }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
