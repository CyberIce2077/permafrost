import AppIntents
import AppKit

/// A widget button (Restart, Update, Power) that acts without opening the app: it hands the action
/// to Ice Servers, launching it hidden if it isn't running. The app does the SSH and sudo work, with
/// its usual confirmations, locks and password handling.
struct ServerAction: AppIntent {
    static let title: LocalizedStringResource = "Server action"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "Action") var action: String
    @Parameter(title: "Server") var server: String

    init() {}

    init(_ action: String, _ server: String) {
        self.action = action
        self.server = server
    }

    func perform() async throws -> some IntentResult {
        let app = "app.iceservers.IceServers"
        if NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            let launch = NSWorkspace.OpenConfiguration()
            launch.activates = false
            launch.arguments = ["--action", action, server]
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: launch)
        } else {
            // The sandbox drops userInfo from distributed notifications, so the action rides in `object`.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("app.iceservers.action"), object: "\(action) \(server)", userInfo: nil, deliverImmediately: true)
        }
        return .result()
    }
}
