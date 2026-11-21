import SwiftUI
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

    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage for received files").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                    if model.settingsFirstRun {
                        Text("Choose how Lan-Line keeps received files before you start. You can change this any time with ⌘,.")
                            .font(.system(size: 11.5)).foregroundStyle(p.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingRow(label: "Delete received files after") {
                    Picker("", selection: $retentionTag) {
                        Text("Never").tag(0)
                        Text("1 day").tag(1)
                        ForEach([10, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                        Text("Custom…").tag(-1)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 130)
                    if retentionTag == -1 { NumberField(text: $customDays, unit: "days") }
                }

                SettingRow(label: "Storage limit") {
                    Picker("", selection: $limitTag) {
                        Text("No limit").tag(0.0)
                        ForEach([5.0, 10, 25, 50, 100], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                        Text("Custom…").tag(-1.0)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 130)
                    if limitTag == -1 { NumberField(text: $customGB, unit: "GB") }
                }

                if limitTag != 0 {
                    SettingRow(label: "When over the limit") {
                        Picker("", selection: $draft.overLimit) {
                            Text("Warn me").tag("warn")
                            Text("Move oldest to Trash").tag("trash")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    }
                }

                Toggle(isOn: $draft.trashReminder) {
                    Text("Remind me now and then to empty the Trash").font(.system(size: 12)).foregroundStyle(p.text)
                }
                .toggleStyle(.switch).controlSize(.small)

                UsageBar(used: model.usageBytes, limit: currentLimitBytes)

                Text("Only files Lan-Line received are ever moved, and only to the Trash, so you can still get them back.")
                    .font(.system(size: 11)).foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(get: { draft.autoUpdateCheck ?? false }, set: { draft.autoUpdateCheck = $0 })) {
                    Text("Check for updates automatically once a day").font(.system(size: 12)).foregroundStyle(p.text)
                }
                .toggleStyle(.switch).controlSize(.small)
                Text("Off unless you turn it on. Lan-Line then reads one small file from averywrobinson.com once a day. It sends no ID and nothing about your files.")
                    .font(.system(size: 11)).foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.unmanagedCount > 0 {
                    Text("Also in the folder: \(model.unmanagedCount) file\(model.unmanagedCount == 1 ? "" : "s") (\(Cleanup.formatBytes(model.unmanagedBytes))) from before this version or added by you. Lan-Line leaves these alone.")
                        .font(.system(size: 11)).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
        }
            Rectangle().fill(p.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {   // pinned: Save never scrolls out of view
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(p.danger) }
                HStack(spacing: 10) {
                    Button("Open folder") { model.settingsActions.openFolder() }.controlSize(.small)
                    Button("Clean up now") { if let s = build() { model.settingsActions.save(s); model.settingsActions.cleanNow() } }
                        .controlSize(.small)
                        .help("Saves these settings and applies them now")
                    Spacer()
                    if !model.settingsFirstRun {
                        Button("Cancel") { model.settingsActions.cancel() }.controlSize(.small).keyboardShortcut(.cancelAction)
                    }
                    Button { if let s = build() { model.settingsActions.save(s) } } label: {
                        Text("Save").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.accent))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear(perform: load)
    }

    private var currentLimitBytes: Int64 {
        let gb = limitTag == -1 ? (Double(customGB) ?? 0) : limitTag
        return gb > 0 ? Int64(gb * 1_000_000_000) : 0
    }

    private func load() {
        draft = model.storage
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
        error = nil
        s.confirmed = true
        return s
    }
}

private struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.of(scheme).textSecondary)
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
            Text(unit).font(.system(size: 12)).foregroundStyle(Palette.of(scheme).textSecondary)
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
                .font(.system(size: 11.5)).foregroundStyle(p.text.opacity(0.85))
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
