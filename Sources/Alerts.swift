import Foundation
import UserNotifications

/// Settings › Notifications. Checked on every stats sample while the app runs.
/// Each alert fires once, then re-arms when the value drops back below its limit.
final class Alerts {
    private var cpuSince: [String: Date] = [:]
    private var fired: Set<String> = []
    private var lastUpdates: [String: Date] = [:]

    private var prefs: Prefs { ice.prefs }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(_ s: Server) {
        let id = s.cfg.id, name = s.cfg.name, st = s.parser.stats
        if prefs.nCpu, let cpu = st.cpu.last, cpu >= prefs.cpuAt {
            let since = cpuSince[id] ?? Date()
            cpuSince[id] = since
            if -since.timeIntervalSinceNow >= 300 {
                once("cpu" + id, "High CPU on \(name)", "CPU has been above \(Int(prefs.cpuAt))% for 5 minutes.")
            }
        } else {
            cpuSince[id] = nil
            fired.remove("cpu" + id)
        }
        if let t = st.temp.last {
            if prefs.nTemp, t >= prefs.tempAt { once("temp" + id, "\(name) is running hot", "CPU temperature is \(degrees(t)).") }
            else if t < prefs.tempAt - 5 { fired.remove("temp" + id) }
        }
        if st.diskTotal > 0 {
            if prefs.nDisk, st.disk >= prefs.diskAt { once("disk" + id, "\(name) disk is almost full", "\(Int(st.disk))% of the disk is used.") }
            else if st.disk < prefs.diskAt - 2 { fired.remove("disk" + id) }
        }
    }

    func offline(_ s: Server) {
        if prefs.nOffline { post("\(s.cfg.name) went offline", "It stopped responding.") }
    }

    /// Once each time a server starts needing a restart (a new /var/run/reboot-required).
    func reboot(_ s: Server) {
        let st = s.parser.stats
        guard prefs.nReboot, let since = st.rebootSince, !fired.contains("reboot" + s.cfg.id + "\(since)") else { return }
        fired.insert("reboot" + s.cfg.id + "\(since)")
        let pkgs = st.rebootPkgs ?? []
        post("\(s.cfg.name) needs a restart", pkgs.isEmpty ? "Updates finish after a restart." : "Updates to \(pkgs.prefix(2).joined(separator: " and "))\(pkgs.count > 2 ? " and \(pkgs.count - 2) more" : "") finish after a restart.")
    }

    /// At most once a day per server.
    func updates(_ s: Server) {
        guard prefs.nUpd, let n = s.parser.stats.updates, n > 0,
              (lastUpdates[s.cfg.id].map { -$0.timeIntervalSinceNow > 86400 } ?? true) else { return }
        lastUpdates[s.cfg.id] = Date()
        post("Updates for \(s.cfg.name)", "\(n) update\(n == 1 ? " is" : "s are") available.")
    }

    private func degrees(_ c: Double) -> String {
        prefs.unit == "F" ? "\(Int((c * 9 / 5 + 32).rounded()))°F" : "\(Int(c.rounded()))°C"
    }

    private func once(_ key: String, _ title: String, _ body: String) {
        guard !fired.contains(key) else { return }
        fired.insert(key)
        post(title, body)
    }

    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
