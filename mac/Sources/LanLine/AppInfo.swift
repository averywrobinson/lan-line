import Foundation

enum AppInfo {
    /// "0.9.0-beta.6" from the bundle's Info.plist (build-app.sh writes it). Empty when run outside the .app,
    /// e.g. `swift run` (then update notices are off unless --app-version is given).
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "LanLineVersion") as? String ?? "" }
}
