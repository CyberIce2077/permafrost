import AppIntents
import AppKit

/// A widget button (Restart, Update, Power) that acts without opening the app: it hands the action
/// to Permafrost, launching it in the background if it isn't running. The app does the SSH and sudo
/// work, with its usual locks and password handling.
///
/// Restart and power off need a second click within `Pending.window` seconds: the first only marks
/// the button (the widget redraws to say "Click again…"), so a stray click can't take a server down.
struct ServerAction: AppIntent {
    static let title: LocalizedStringResource = "Server action"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "Action") var action: String
    @Parameter(title: "Server") var server: String
    @Parameter(title: "Confirm") var confirm: Bool

    init() {}

    init(_ action: String, _ server: String, confirm: Bool = false) {
        self.action = action
        self.server = server
        self.confirm = confirm
    }

    func perform() async throws -> some IntentResult {
        if confirm, Pending.current()?.matches(action, server) != true {
            Pending.set(action, server)  // first click
            return .result()
        }
        Pending.clear()

        let app = "app.permafrost.Permafrost"
        if NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            let launch = NSWorkspace.OpenConfiguration()
            launch.activates = false
            launch.arguments = ["--action", action, server] + (confirm ? ["--confirmed"] : [])
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: launch)
        } else {
            // The sandbox drops userInfo from distributed notifications, so the action rides in `object`.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("app.permafrost.action"), object: "\(action) \(server)\(confirm ? " confirmed" : "")",
                userInfo: nil, deliverImmediately: true)
        }
        return .result()
    }
}

/// The click waiting for its second click, kept by the widget extension.
struct Pending {
    static let window: TimeInterval = 5
    let action, server: String
    let until: Date

    func matches(_ action: String, _ server: String) -> Bool { self.action == action && self.server == server }

    static func current() -> Pending? {
        let f = (UserDefaults.standard.string(forKey: "pending") ?? "").split(separator: " ").map(String.init)
        guard f.count == 3, let t = Double(f[2]), Date(timeIntervalSince1970: t) > Date() else { return nil }
        return Pending(action: f[0], server: f[1], until: Date(timeIntervalSince1970: t))
    }

    static func set(_ action: String, _ server: String) {
        UserDefaults.standard.set("\(action) \(server) \(Date().timeIntervalSince1970 + window)", forKey: "pending")
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: "pending") }
}
