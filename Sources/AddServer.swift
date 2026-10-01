import Foundation

/// What the Add Server wizard collected.
struct Draft {
    var id = UUID().uuidString
    var name = "", host = "", port = "22", user = ""
    var auth = "key", key = "", sshPassword = ""
    var sudo = "remember", when = "now", sudoPassword = ""
    var touchID = true

    init(_ m: [String: Any]) {
        func s(_ k: String) -> String { (m[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        name = s("name"); host = s("host"); port = s("port").isEmpty ? "22" : s("port"); user = s("user")
        auth = s("auth"); key = s("key").replacingOccurrences(of: "~", with: realHome); sshPassword = m["sshPassword"] as? String ?? ""
        sudo = s("sudo"); when = s("when"); sudoPassword = m["sudoPassword"] as? String ?? ""
        touchID = m["touchID"] as? Bool ?? true
        if let given = m["id"] as? String, !given.isEmpty { id = given }
        if name.isEmpty { name = host }
    }

    var target: String { "\(user)@\(host)" }
    var keyArgs: [String] { key.isEmpty ? [] : ["-i", key, "-o", "IdentitiesOnly=yes"] }

    /// What `ServerConfig.ssh` stores: plain `ssh` arguments.
    var sshString: String {
        ((port == "22" ? [] : ["-p", port]) + (key == SSHKey.defaultPath ? [] : ["-i", key]) + [target]).joined(separator: " ")
    }
}

enum SSHKey {
    static let defaultPath = realHome + "/.ssh/id_ed25519"

    /// The key ssh would use by default, if this Mac has one.
    static var existing: String? {
        ["id_ed25519", "id_ecdsa", "id_rsa"].map { realHome + "/.ssh/" + $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func display(_ path: String) -> String { path.replacingOccurrences(of: realHome, with: "~") }
}

/// Runs the wizard's "Test" step for real, one check at a time. Each check reports
/// running / done / trust (waiting for the user) / fail through `report`.
final class Probe {
    private let d: Draft
    private let report: (_ index: Int, _ state: String, _ note: String, _ fingerprint: String?) -> Void
    private var cancelled = false
    private var scanned = ""
    var stats: Stats?

    init(_ draft: Draft, report: @escaping (Int, String, String, String?) -> Void) {
        d = draft
        self.report = report
    }

    func cancel() { cancelled = true }

    func start() { reach() }

    private func step(_ i: Int, _ state: String, _ note: String = "", _ fp: String? = nil) {
        if !cancelled { report(i, state, note, fp) }
    }

    private func fail(_ i: Int, _ out: String, _ fallback: String) {
        let last = out.split(separator: "\n").last.map(String.init) ?? ""
        step(i, "fail", last.isEmpty ? fallback : last)
    }

    private var ssh: [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-p", d.port] + d.keyArgs + [d.target]
    }

    // 1. Reaching host:port
    private func reach() {
        step(0, "running")
        let start = Date()
        Shell.run("/usr/bin/nc", ["-z", "-G", "5", d.host, d.port]) { [self] status, out in
            guard !cancelled else { return }
            guard status == 0 else { return fail(0, out, "Can't reach \(d.host):\(d.port)") }
            step(0, "done", "\(max(1, Int(-start.timeIntervalSinceNow * 1000))) ms")
            hostKey()
        }
    }

    // 2. Verifying host key: known already, or show the fingerprint and wait for Trust.
    private func hostKey() {
        step(1, "running")
        let spec = d.port == "22" ? d.host : "[\(d.host)]:\(d.port)"
        Shell.run("/usr/bin/ssh-keygen", ["-F", spec]) { [self] status, _ in
            guard !cancelled else { return }
            if status == 0 { step(1, "done", "Trusted"); return signIn() }
            Shell.run("/usr/bin/ssh-keyscan", ["-T", "5", "-p", d.port, d.host]) { [self] _, out in
                scanned = out.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.joined(separator: "\n")
                guard !scanned.isEmpty else { return fail(1, "", "The server didn't send a host key") }
                Shell.run("/usr/bin/ssh-keygen", ["-lf", "-"], input: scanned) { [self] _, fps in
                    // "256 SHA256:abc… host (ED25519)" → "ED25519 SHA256:abc…"
                    let lines = fps.split(separator: "\n").map { $0.split(separator: " ") }.filter { $0.count >= 4 }
                    let pick = lines.first { $0.last == "(ED25519)" } ?? lines.first
                    let fp = pick.map { "\($0.last!.trimmingCharacters(in: CharacterSet(charactersIn: "()"))) \($0[1])" } ?? ""
                    step(1, "trust", "", fp)
                }
            }
        }
    }

    func trust() {
        let file = URL(fileURLWithPath: realHome + "/.ssh/known_hosts")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let joined = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        try? FileManager.default.createDirectory(atPath: realHome + "/.ssh", withIntermediateDirectories: true)
        try? (joined + scanned + "\n").write(to: file, atomically: true, encoding: .utf8)
        step(1, "done", "Trusted")
        signIn()
    }

    // 3. Signing in. With a password, it's used once to add this Mac's key, so the app
    //    and the sandboxed widget can both sign in with the key afterwards.
    private func signIn() {
        step(2, "running")
        guard d.auth == "pw" else {
            Shell.run("/usr/bin/ssh", ssh + ["true"]) { [self] status, out in
                guard !cancelled else { return }
                guard status == 0 else { return fail(2, out, "The server didn't accept the SSH key") }
                step(2, "done", "SSH key")
                sudo()
            }
            return
        }
        let key = d.key.isEmpty ? SSHKey.defaultPath : d.key
        let makeKey: (@escaping () -> Void) -> Void = { next in
            if FileManager.default.fileExists(atPath: key) { return next() }
            Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key]) { _, _ in next() }
        }
        makeKey { [self] in
            guard let pub = try? String(contentsOfFile: key + ".pub", encoding: .utf8) else {
                return fail(2, "", "Couldn't read \(SSHKey.display(key)).pub")
            }
            // ssh asks this app for the password (see main.swift) instead of a terminal.
            let askpass = ["SSH_ASKPASS": Bundle.main.executablePath ?? "", "SSH_ASKPASS_REQUIRE": "force",
                           "ICE_ASKPASS": d.sshPassword]
            let args = ["-T", "-o", "ConnectTimeout=5", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
                        "-o", "PreferredAuthentications=password,keyboard-interactive", "-p", d.port, d.target,
                        "k=$(cat); umask 077; mkdir -p ~/.ssh && { grep -qxF \"$k\" ~/.ssh/authorized_keys 2>/dev/null || echo \"$k\" >> ~/.ssh/authorized_keys; }"]
            Shell.run("/usr/bin/ssh", args, input: pub.trimmingCharacters(in: .whitespacesAndNewlines), env: askpass) { [self] status, out in
                guard !cancelled else { return }
                guard status == 0 else { return fail(2, out, "Wrong username or password") }
                Shell.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-p", d.port, "-i", key, d.target, "true"]) { [self] status, out in
                    guard status == 0 else { return fail(2, out, "Signed in, but the key still isn't accepted") }
                    step(2, "done", "Password")
                    sudo()
                }
            }
        }
    }

    // 4. sudo: check and save the password, or check passwordless sudo.
    private func sudo() {
        step(3, "running")
        switch (d.sudo, d.when) {
        case ("remember", "now"):
            Shell.run("/usr/bin/ssh", ssh + ["sudo -S -p '' -v"], input: d.sudoPassword) { [self] status, out in
                guard !cancelled else { return }
                guard status == 0, !out.contains("try again") else {
                    return step(3, "fail", "Incorrect password. sudo on \(d.name) rejected it. Nothing was saved.")
                }
                Keychain.set(d.id, d.sudoPassword)
                step(3, "done", "Saved")
                read()
            }
        case ("nopass", _):
            Shell.run("/usr/bin/ssh", ssh + ["sudo -n true || sudo -n -l /usr/bin/systemctl"]) { [self] status, out in
                guard !cancelled else { return }
                guard status == 0 else { return step(3, "fail", "sudo on \(d.name) still asks for a password") }
                step(3, "done", "OK")
                read()
            }
        default:
            step(3, "done", "OK")
            read()
        }
    }

    // 5. Reading CPU, memory, disk and temperature
    private func read() {
        step(4, "running")
        var parser = StatsParser(Stats(id: d.id, name: d.name))
        Shell.run("/usr/bin/ssh", ssh + [Remote.snapshot], done: { [self] _, out in
            guard !cancelled else { return }
            guard !parser.stats.cpu.isEmpty else { return fail(4, out, "Couldn't read stats from \(d.name)") }
            stats = parser.stats
            step(4, "done", parser.stats.temp.isEmpty ? "OK · no temperature sensor" : "OK")
        }, line: { _ = parser.feed($0) })
    }
}
