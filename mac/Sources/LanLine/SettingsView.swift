import SwiftUI
import ServiceManagement
import LanLineCore

/// Storage settings: how long received files are kept, how much room they may use, and the Trash reminder.
/// Shown first on every launch until the user presses Save once.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var draft = StorageSettings()
    @State private var retentionTag = 0          // a choice in days, or -1 = custom
    @State private var customDays = ""
    @State private var limitTag: Double = 10     // a choice in GB, or -1 = custom
    @State private var customGB = ""
    @State private var error: String?
    @State private var openAtLogin = false
    @State private var confirmClear = false

    @State private var barHeight: CGFloat = 54

    var body: some View {
        let p = Palette.of(scheme)
        // Design refresh (beta.10): titled groups on solid surfaces (readable at any window opacity), in the same
        // order on every platform; Save floats above them on a glass bar.
        ZStack(alignment: .bottom) {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.settingsFirstRun {
                    SettingsGroup("Paired computers") { PairedList(model: model) }
                }
                SettingsGroup("Received files") {
                    if model.settingsFirstRun {
                        Text("Choose how Lan-Line keeps received files before you start. You can change this any time with ⌘,.")
                            .font(.system(size: fs(11.5))).foregroundStyle(p.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ReceiveRows(model: model, draft: $draft)
                    SettingRow(label: "Delete received files after") {
                        Picker("Delete received files after", selection: $retentionTag) {
                            Text("Never").tag(0)
                            Text("1 day").tag(1)
                            ForEach([10, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                            Text("Custom…").tag(-1)
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 130)
                        if retentionTag == -1 { NumberField(text: $customDays, unit: "days") }
                    }

                    SettingRow(label: "Storage limit") {
                        Picker("Storage limit", selection: $limitTag) {
                            Text("No limit").tag(0.0)
                            ForEach([5.0, 10, 25, 50, 100], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                            Text("Custom…").tag(-1.0)
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 130)
                        if limitTag == -1 { NumberField(text: $customGB, unit: "GB") }
                    }

                    if limitTag != 0 {
                        SettingRow(label: "When over the limit") {
                            Picker("When over the limit", selection: $draft.overLimit) {
                                Text("Warn me").tag("warn")
                                Text("Move oldest to Trash").tag("trash")
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                        }
                    }

                    Toggle(isOn: $draft.trashReminder) {
                        Text("Remind me now and then to empty the Trash").font(.system(size: fs(12))).foregroundStyle(p.text)
                    }
                    .toggleStyle(.switch).controlSize(.small)

                    UsageBar(used: model.usageBytes, limit: currentLimitBytes)

                    Text("Only files Lan-Line received are ever moved, and only to the Trash, so you can still get them back.")
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.unmanagedCount > 0 {
                        Text("Also in the folder: \(model.unmanagedCount) file\(model.unmanagedCount == 1 ? "" : "s") (\(Cleanup.formatBytes(model.unmanagedBytes))) from before this version or added by you. Lan-Line leaves these alone.")
                            .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SettingsGroup("When something arrives") { ArrivalRows(model: model, draft: $draft) }
                SettingsGroup("Keyboard shortcuts, from any app") { ShortcutRows(model: model, draft: $draft) }
                SettingsGroup("Clipboard and links") {
                    ClipboardRows(model: model, draft: $draft)
                    Toggle(isOn: Binding(get: { draft.linkPreviewsValue }, set: { draft.linkPreviews = $0 ? true : nil })) {
                        Text("Show link previews").font(.system(size: fs(12))).foregroundStyle(p.text)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    Text(draft.linkPreviewsValue
                         ? "A shared link shows its page's title and picture. Lan-Line fetches them from that website, which can see the visit."
                         : "Off: links show their site and path, and nothing is fetched until you open one.")
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                }
                SettingsGroup("Running") {
                    Toggle(isOn: $openAtLogin) {
                        Text("Open Lan-Line at login").font(.system(size: fs(12))).foregroundStyle(p.text)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    if model.loginNeedsApproval && openAtLogin {
                        HStack(spacing: 8) {
                            Text("macOS is waiting for you to allow Lan-Line in Login Items.")
                                .font(.system(size: fs(11))).foregroundStyle(p.accent)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                        }
                    }
                    Text("At login it waits in the menu bar, still receiving, and opens when something arrives.")
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: Binding(get: { draft.keepRunningWhenClosedValue }, set: { draft.keepRunningWhenClosed = $0 ? nil : false })) {
                        Text("Keep running in the menu bar when closed").font(.system(size: fs(12))).foregroundStyle(p.text)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    Text(draft.keepRunningWhenClosedValue
                         ? "Closing the window leaves Lan-Line in the menu bar, out of the Dock, still receiving. Quit from its menu or with ⌘Q."
                         : "Closing the window keeps Lan-Line in the Dock, still receiving. Quit with ⌘Q.")
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                }
                SettingsGroup("Updates and history") {
                    Toggle(isOn: Binding(get: { draft.autoUpdateCheck ?? false }, set: { draft.autoUpdateCheck = $0 })) {
                        Text("Check for updates automatically once a day").font(.system(size: fs(12))).foregroundStyle(p.text)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    Text("Off unless you turn it on. Lan-Line then reads one small file from averywrobinson.com once a day. It sends no ID and nothing about your files.")
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: Binding(get: { draft.keepHistoryValue }, set: { draft.keepHistory = $0 ? nil : false })) {
                        Text("Keep history on this Mac").font(.system(size: fs(12))).foregroundStyle(p.text)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    HStack(spacing: 8) {
                        Text(draft.keepHistoryValue
                             ? "The last \(History.cap.formatted()) texts and file names stay in the window and in search (⌘F), on this Mac only. Turning it off deletes it."
                             : "Off: the window starts empty each time and search covers only this session.")
                            .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.storage.keepHistoryValue {
                            Button("Clear History…") { confirmClear = true }.controlSize(.small)
                                .confirmationDialog("Clear the history on this Mac?", isPresented: $confirmClear) {
                                    Button("Clear History", role: .destructive) { model.settingsActions.clearHistory() }
                                } message: { Text("Texts and file names are removed from Lan-Line. Received files stay in your Lan-Line folder.") }
                        }
                    }

                }
                SettingsGroup("Appearance") {
                    TextSizeRow(draft: $draft)
                    OpacityRow(model: model, draft: $draft)
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: barHeight) }
        .softEdges(top: 14, bottom: 26, floor: 0.15)
            VStack(alignment: .leading, spacing: 8) {   // floating: Save never scrolls out of view
                if let error { Text(error).font(.system(size: fs(11))).foregroundStyle(p.danger) }
                // beta.11: in a narrow window the folder buttons move up a line instead of being cut short
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { folderButtons; Spacer(minLength: 8); saveButtons }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) { folderButtons }
                        HStack(spacing: 10) { Spacer(minLength: 0); saveButtons }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .chrome(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
            .readHeight($barHeight)
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var folderButtons: some View {
        Button("Open folder") { model.settingsActions.openFolder() }.controlSize(.small).fixedSize()
        Button("Clean up now") { if let s = build() { model.settingsActions.save(s); model.settingsActions.cleanNow() } }
            .controlSize(.small).fixedSize()
            .help("Saves these settings and applies them now")
    }

    @ViewBuilder private var saveButtons: some View {
        if !model.settingsFirstRun {
            Button("Cancel") { model.settingsActions.cancel() }.controlSize(.small).fixedSize().keyboardShortcut(.cancelAction)
        }
        Button {
            if let s = build() {
                if openAtLogin != model.openAtLogin { model.settingsActions.setOpenAtLogin(openAtLogin) }
                model.settingsActions.save(s)
            }
        } label: {
            Text("Save").font(.system(size: fs(12.5), weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.of(scheme).accent))
        }
        .buttonStyle(.plain).keyboardShortcut(.defaultAction).fixedSize()
    }

    private var currentLimitBytes: Int64 {
        let gb = limitTag == -1 ? (Double(customGB) ?? 0) : limitTag
        return gb > 0 ? Int64(gb * 1_000_000_000) : 0
    }

    private func load() {
        draft = model.storage
        openAtLogin = model.openAtLogin
        if StorageSettings.retentionChoices.contains(draft.retentionDays) { retentionTag = draft.retentionDays }
        else { retentionTag = -1; customDays = "\(draft.retentionDays)" }
        if StorageSettings.limitChoices.contains(draft.limitGB) { limitTag = draft.limitGB }
        else { limitTag = -1; customGB = String(format: "%g", draft.limitGB) }
    }

    /// The settings as chosen, or nil (with an error shown) when a custom number is not valid.
    private func build() -> StorageSettings? {
        var s = draft
        if retentionTag == -1 {
            guard let d = Int(customDays.trimmingCharacters(in: .whitespaces)), (1...3650).contains(d) else {
                error = "Days to keep files must be a whole number from 1 to 3650."; return nil
            }
            s.retentionDays = d
        } else { s.retentionDays = retentionTag }
        if limitTag == -1 {
            guard let g = Double(customGB.trimmingCharacters(in: .whitespaces)), g >= 0.1, g <= 100_000 else {
                error = "The storage limit must be a number of GB from 0.1 to 100000."; return nil
            }
            s.limitGB = g
        } else { s.limitGB = limitTag }
        if let a = s.showShortcut, let b = s.sendShortcut, a == b { error = "Pick two different keyboard shortcuts."; return nil }
        if let why = s.showShortcut?.problem(mac: true) ?? s.sendShortcut?.problem(mac: true) { error = why; return nil }
        error = nil
        s.confirmed = true
        return s
    }
}

/// Where received files go and what happens when one arrives (beta.10).
private struct ReceiveRows: View {
    @ObservedObject var model: AppModel
    @Binding var draft: StorageSettings
    @Environment(\.colorScheme) private var scheme

    private var desktop: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
    private var shown: String {
        guard let u = draft.downloadFolderURL else { return "Downloads › Lan-Line" }
        if u.standardizedFileURL == desktop.standardizedFileURL { return "Desktop" }
        return (u.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(label: "Save received files in") {
                Menu(shown) {
                    Button("Downloads › Lan-Line") { draft.downloadFolder = nil }
                    Button("Desktop") { draft.downloadFolder = desktop.path }
                    Divider()
                    Button("Choose a Folder…") { choose() }
                }
                .fixedSize().controlSize(.small)
                .help(draft.downloadFolderURL?.path ?? LanLineConfig.downloadsDir.path)
            }
            Toggle(isOn: Binding(get: { draft.folderPerComputerValue }, set: { draft.folderPerComputer = $0 ? true : nil })) {
                Text("A folder for each computer").font(.system(size: fs(12))).foregroundStyle(p.text)
            }
            .toggleStyle(.switch).controlSize(.small)
            SettingRow(label: "When a file arrives") {
                Picker("When a file arrives", selection: Binding(get: { draft.afterReceiveValue }, set: { draft.afterReceive = $0 == .nothing ? nil : $0.rawValue })) {
                    Text("Do nothing").tag(AfterReceive.nothing)
                    Text("Show in Finder").tag(AfterReceive.reveal)
                    Text("Open it").tag(AfterReceive.open)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 270)
            }
            Text(draft.afterReceiveValue == .open
                 ? "Opens pictures, PDFs, text and media (up to 3 at a time). Apps, scripts, installers and archives are shown in Finder instead."
                 : "Files save as soon as they arrive: pairing is what makes a computer trusted.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"; panel.message = "Received files will be saved here."
        panel.directoryURL = draft.downloadFolderURL ?? LanLineConfig.downloadsDir.deletingLastPathComponent()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        guard FileManager.default.isWritableFile(atPath: u.path) else {
            NSSound.beep(); return
        }
        draft.downloadFolder = u.path
    }
}

/// Clipboard sharing (beta.10): off until turned on; pictures too.
private struct ClipboardRows: View {
    @ObservedObject var model: AppModel
    @Binding var draft: StorageSettings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { draft.shareClipboardValue }, set: { draft.shareClipboard = $0 ? true : nil })) {
                Text("Share the clipboard").font(.system(size: fs(12))).foregroundStyle(p.text)
            }
            .toggleStyle(.switch).controlSize(.small)
            if draft.shareClipboardValue {
                Toggle(isOn: Binding(get: { draft.shareClipboardPicturesValue }, set: { draft.shareClipboardPictures = $0 ? nil : false })) {
                    Text("Include pictures (up to 10 MB)").font(.system(size: fs(12))).foregroundStyle(p.text)
                }
                .toggleStyle(.switch).controlSize(.small).padding(.leading, 18)
            }
            Text(draft.shareClipboardValue
                 ? "Copy on one computer, paste on the other, while they're connected. Passwords from password managers are never shared, and nothing is kept. Pause it any time from the menu bar icon."
                 : "Off: copying stays on this Mac. Turn it on here and on the other computer.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Global shortcuts (beta.10): show/hide (default ⌃⌥L) and send the clipboard (off until chosen).
private struct ShortcutRows: View {
    @ObservedObject var model: AppModel
    @Binding var draft: StorageSettings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        let show = Binding<Shortcut?>(get: { draft.showShortcut }, set: { draft.shortcutShow = $0 == .defaultShow ? nil : ($0?.text ?? "") })
        let send = Binding<Shortcut?>(get: { draft.sendShortcut }, set: { draft.shortcutSend = $0?.text })
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Show or hide Lan-Line").font(.system(size: fs(12))).foregroundStyle(p.text); Spacer(); ShortcutField(value: show) }
            problem(show.wrappedValue, saved: model.hotKeyProblems["show"], p: p)
            HStack { Text("Send the clipboard").font(.system(size: fs(12))).foregroundStyle(p.text); Spacer(); ShortcutField(value: send) }
            problem(send.wrappedValue, saved: model.hotKeyProblems["send"], p: p)
            if show.wrappedValue != nil, show.wrappedValue == send.wrappedValue {
                Text("Pick two different shortcuts.").font(.system(size: fs(11))).foregroundStyle(p.danger)
            }
            Text(send.wrappedValue == nil
                 ? "Send the clipboard is off. Try \(Shortcut.suggestedSend.display(mac: true)): it sends copied text, a picture or files to \(model.targetLabel == "Everyone" && !model.multi ? model.peerLabel : model.targetLabel) without opening the window."
                 : "Sends copied text, a picture or files without opening the window. All shortcuts: ⌘/.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func problem(_ s: Shortcut?, saved: String?, p: Palette) -> some View {
        if let why = s?.problem(mac: true) ?? saved {
            Text(why).font(.system(size: fs(11))).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What happens when something arrives (beta.10): a system notification, and/or the window coming forward.
private struct ArrivalRows: View {
    @ObservedObject var model: AppModel
    @Binding var draft: StorageSettings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { draft.notifyOnArrivalValue }, set: { draft.notifyOnArrival = $0 ? nil : false })) {
                Text("Show a notification").font(.system(size: fs(12))).foregroundStyle(p.text)
            }
            .toggleStyle(.switch).controlSize(.small)
            if draft.notifyOnArrivalValue && !model.notificationsAllowed {
                HStack(spacing: 8) {
                    Text("Notifications are off for Lan-Line in System Settings.")
                        .font(.system(size: fs(11))).foregroundStyle(p.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { model.settingsActions.openNotificationSettings() }.controlSize(.small)
                }
            }
            Toggle(isOn: Binding(get: { draft.popUpOnArrivalValue }, set: { draft.popUpOnArrival = $0 ? nil : false })) {
                Text("Bring the window forward").font(.system(size: fs(12))).foregroundStyle(p.text)
            }
            .toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: Binding(get: { draft.soundsValue }, set: { draft.sounds = $0 ? nil : false })) {
                Text("Play sounds").font(.system(size: fs(12))).foregroundStyle(p.text)
            }
            .toggleStyle(.switch).controlSize(.small)
            .help("A soft chime when something arrives while you're in Lan-Line, and a quiet tick when you send")
            Text("Notifications appear only while you're using another app, with Copy for texts and Open or Show in Finder for files. Banners and sounds follow System Settings → Notifications.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Window opacity: how see-through the smoked glass is. Moves the backdrop live while dragging; Save keeps it,
/// Cancel puts it back. Text, bubbles and chips are not changed.
/// Text size (accessibility pass, beta.10): Lan-Line's own, like Messages'. Applied on Save.
private struct TextSizeRow: View {
    @Binding var draft: StorageSettings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 5) {
            Text("Text size").font(.system(size: fs(11.5), weight: .medium)).foregroundStyle(p.textSecondary)
            Picker("Text size", selection: Binding(get: { draft.textScaleValue }, set: { draft.textScale = $0 == 1 ? nil : $0 })) {
                ForEach(StorageSettings.textScaleChoices, id: \.self) { c in Text("\(Int((c * 100).rounded()))%").tag(c) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 300)
            Text("Changes when you save. Menus and system buttons keep the macOS size.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OpacityRow: View {
    @ObservedObject var model: AppModel
    @Binding var draft: StorageSettings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        let value = Binding<Double>(
            get: { draft.glassOpacityValue },
            set: { v in
                let r = (v * 100).rounded() / 100
                draft.glassOpacity = abs(r - StorageSettings.defaultGlassOpacity) < 0.001 ? nil : r
                model.glassOpacity = draft.glassOpacityValue
            })
        VStack(alignment: .leading, spacing: 5) {
            Text("Window opacity").font(.system(size: fs(11.5), weight: .medium)).foregroundStyle(p.textSecondary)
            HStack(spacing: 10) {
                Slider(value: value, in: StorageSettings.glassOpacityRange) {
                    Text("Window opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: fs(10))).foregroundStyle(p.icon)
                } maximumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: fs(10))).foregroundStyle(p.icon)
                }
                .labelsHidden().controlSize(.small)
                .accessibilityValue("\(Int((draft.glassOpacityValue * 100).rounded())) percent")
                Text("\(Int((draft.glassOpacityValue * 100).rounded()))%")
                    .font(.system(size: fs(12)).monospacedDigit()).foregroundStyle(p.text).frame(width: 38, alignment: .trailing)
                Button("Default") { value.wrappedValue = StorageSettings.defaultGlassOpacity }
                    .controlSize(.small).disabled(draft.glassOpacity == nil)
            }
            Text("Changes only the smoked-glass background; text stays fully readable.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One titled group of settings on a solid surface (design refresh, beta.10).
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: fs(11.5), weight: .semibold)).foregroundStyle(Palette.of(scheme).textSecondary)
                .bodyScrim().padding(.horizontal, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 11) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupSurface()
        }
    }
}

private struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: fs(11.5), weight: .medium)).foregroundStyle(Palette.of(scheme).textSecondary)
            HStack(spacing: 8) { content }
        }
    }
}

private struct NumberField: View {
    @Binding var text: String
    let unit: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: 64).accessibilityLabel(unit)
            Text(unit).font(.system(size: fs(12))).foregroundStyle(Palette.of(scheme).textSecondary)
        }
    }
}

private struct UsageBar: View {
    let used: Int64
    let limit: Int64
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        let frac = limit > 0 ? min(1, Double(used) / Double(limit)) : 0
        let color = frac >= 1 ? p.danger : (frac >= 0.8 ? Color(red: 0.96, green: 0.69, blue: 0.20) : p.accent)
        VStack(alignment: .leading, spacing: 5) {
            Text(limit > 0 ? "Received files use \(Cleanup.formatBytes(used)) of \(Cleanup.formatBytes(limit))"
                           : "Received files use \(Cleanup.formatBytes(used))")
                .font(.system(size: fs(11.5))).foregroundStyle(p.text.opacity(0.85))
            if limit > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.hairline)
                        Capsule().fill(color).frame(width: max(4, g.size.width * frac))
                    }
                }
                .frame(height: 5)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings → Paired computers: rename, forget, pair another (beta.7).
private struct PairedList: View {
    @ObservedObject var model: AppModel
    @State private var editing: String?
    @State private var draftName = ""
    @State private var forgetting: PartnerInfo?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.partners) { partner in
                HStack(spacing: 8) {
                    Circle().fill(partner.up ? p.connected : p.idleDot).frame(width: 7, height: 7)
                        .accessibilityLabel(partner.up ? "connected" : "not connected")
                    if editing == partner.id {
                        TextField("Name", text: $draftName, onCommit: {
                            model.partnerActions.rename(partner.id, draftName); editing = nil
                        })
                        .textFieldStyle(.roundedBorder).font(.system(size: fs(12))).frame(maxWidth: 180)
                    } else {
                        Text(partner.name).font(.system(size: fs(12))).foregroundStyle(p.text).lineLimit(1)
                    }
                    Spacer()
                    Button(editing == partner.id ? "Done" : "Rename") {
                        if editing == partner.id { model.partnerActions.rename(partner.id, draftName); editing = nil }
                        else { draftName = partner.name; editing = partner.id }
                    }
                    .buttonStyle(.link).font(.system(size: fs(11)))
                    Button("Forget") { forgetting = partner }
                        .buttonStyle(.link).font(.system(size: fs(11))).foregroundStyle(p.danger)
                }
            }
            HStack(spacing: 8) {
                if model.partners.isEmpty {
                    Text("None yet.").font(.system(size: fs(12))).foregroundStyle(p.textSecondary)
                    Spacer()
                }
                Button(model.partners.isEmpty ? "Pair a computer…" : "Pair another computer…") { model.partnerActions.pairAnother() }
                    .buttonStyle(.link).font(.system(size: fs(11.5)))
                    .disabled(model.partners.count >= DeviceConfig.maxPartners)
            }
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let f = forgetting { model.partnerActions.forget(f.id) }; forgetting = nil }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("Lan-Line stops connecting to it and deletes its pairing secret. Files you already received stay.")
        }
    }
}
