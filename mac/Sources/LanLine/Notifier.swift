import AppKit
import UserNotifications
import LanLineCore

/// System notifications for arrived items (beta.10): a text with Copy, a file or folder with Open and Show in
/// Finder, a picture with its thumbnail. A burst of arrivals becomes one "Sent you 3 files" notification.
/// Posted only while Lan-Line isn't the window in use; clicking one shows Lan-Line at that item.
/// Wording comes from `ArrivalNotices` (shared with Windows); this class only posts and answers.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    struct Handlers {
        var show: (String?) -> Void = { _ in }
        var copy: (String, String?) -> Void = { _, _ in }   // item id, the text as posted (fallback)
        var open: (String) -> Void = { _ in }
        var reveal: (String) -> Void = { _ in }
        /// Whether notifications are allowed by the system (false = the user turned them off for Lan-Line).
        var authorization: (Bool) -> Void = { _ in }
    }

    var handlers = Handlers()
    private var pending: [(from: String, item: Item)] = []
    private var flush: DispatchWorkItem?
    private var burstStarted: Date?
    private var asked = false
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (swift run, tests); stay quiet there.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        guard let c = center else { return }
        c.delegate = self
        let copy = UNNotificationAction(identifier: ArrivalNotice.Action.copy.rawValue, title: "Copy", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        let open = UNNotificationAction(identifier: ArrivalNotice.Action.open.rawValue, title: "Open", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        let reveal = UNNotificationAction(identifier: ArrivalNotice.Action.reveal.rawValue, title: "Show in Finder", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "folder"))
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "text", actions: [copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: "file", actions: [open, reveal], intentIdentifiers: []),
        ])
    }

    /// Ask once for permission (the system prompt appears only the first time), and report the answer.
    func requestPermission() {
        guard let c = center else { return }
        asked = true
        c.requestAuthorization(options: [.alert, .sound]) { ok, err in
            DebugLog.write("notifications allowed: \(ok)\(err.map { " (\($0.localizedDescription))" } ?? "")")
            UNUserNotificationCenter.current().getNotificationSettings { st in
                DebugLog.write("notification settings: auth=\(st.authorizationStatus.rawValue) alert=\(st.alertSetting.rawValue) style=\(st.alertStyle.rawValue) center=\(st.notificationCenterSetting.rawValue)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.handlers.authorization(ok) } }
        }
    }

    /// Re-read the system setting (the user may have changed it in System Settings while we ran).
    func refreshAuthorization() {
        guard let c = center else { return }
        c.getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            let undecided = s.authorizationStatus == .notDetermined
            DispatchQueue.main.async { MainActor.assumeIsolated { self.handlers.authorization(ok || undecided) } }
        }
    }

    /// Something arrived. Collected for a moment so a burst becomes one notification.
    func arrived(from: String, _ item: Item) {
        pending.append((from, item))
        let now = Date()
        if burstStarted == nil { burstStarted = now }
        flush?.cancel()
        // Wait for the burst to settle, but never hold the first item back more than 3 s.
        let wait = min(ArrivalNotices.coalesceSeconds, max(0, 3 - now.timeIntervalSince(burstStarted ?? now)))
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.post() } }
        flush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    /// A short confirmation for something sent from the background (the send-the-clipboard shortcut).
    func confirm(title: String, body: String) {
        guard let c = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.threadIdentifier = "sent"
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }

    func failed(from: String, name: String, reason: String) {
        deliver(ArrivalNotices.failed(from: from, name: name, reason: reason), text: nil)
    }

    private func post() {
        let batch = pending
        pending = []; burstStarted = nil; flush = nil
        guard let n = ArrivalNotices.make(batch) else { return }
        var text: String?
        if batch.count == 1, case .text(let t) = batch[0].item.kind { text = t }
        deliver(n, text: text)
    }

    private func deliver(_ n: ArrivalNotice, text: String?) {
        guard let c = center else { return }
        if !asked { requestPermission() }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.threadIdentifier = "arrivals"
        if n.actions.contains(.copy) { content.categoryIdentifier = "text" }
        else if n.actions.contains(.open) { content.categoryIdentifier = "file" }
        var info: [String: String] = [:]
        if let id = n.itemID { info["id"] = id }
        if let t = text, t.utf8.count <= 100_000 { info["text"] = t }
        content.userInfo = info
        if let path = n.imagePath, let a = Self.thumbnail(path) { content.attachments = [a] }
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
            DebugLog.write(err.map { "notification not posted: \($0.localizedDescription)" } ?? "notification posted: \(n.title)")
            if DebugLog.path != nil {
                UNUserNotificationCenter.current().getDeliveredNotifications { list in
                    DebugLog.write("in Notification Center: \(list.map { "\($0.request.content.title): \($0.request.content.body) [\($0.request.content.categoryIdentifier), \($0.request.content.attachments.count) pic]" }.joined(separator: " | "))")
                }
            }
        }
    }

    /// The system moves an attachment into its own store, so hand it a copy (pictures up to 10 MB).
    private static func thumbnail(_ path: String) -> UNNotificationAttachment? {
        let src = URL(fileURLWithPath: path)
        guard let size = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 10_000_000 else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-notify", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(UUID().uuidString + "." + src.pathExtension)
        do {
            try FileManager.default.copyItem(at: src, to: copy)
            return try UNNotificationAttachment(identifier: "picture", url: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])   // posted only while another app is in use, so always show it
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String
        let text = info["text"] as? String
        let action = response.actionIdentifier
        done()   // nothing below needs the system to wait
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch action {
                case ArrivalNotice.Action.copy.rawValue: if let id { self.handlers.copy(id, text) }
                case ArrivalNotice.Action.open.rawValue: if let id { self.handlers.open(id) }
                case ArrivalNotice.Action.reveal.rawValue: if let id { self.handlers.reveal(id) }
                case UNNotificationDismissActionIdentifier: break
                default: self.handlers.show(id)
                }
            }
        }
    }
}
