import Foundation

/// One Linux box reached over SSH: a long-lived stats stream plus one-off commands.
final class Server {
    var cfg: ServerConfig
    var phase = "connecting" {  // connecting online off stopping starting restarting updating checking
        didSet { if phase != oldValue, phase == "online" || phase == "off" { ice.reloadWidgets() } }
    }
    var parser: StatsParser
    var checkedAt: Date?
    var progress = 0

    private var removed = false
    private var stream: Process?
    private var holdUntil = Date.distantPast
    private var deadline = Date.distantPast

    init(_ cfg: ServerConfig) {
        self.cfg = cfg
        let blank = [Double](repeating: 0, count: 24)
        parser = StatsParser(Stats(cpu: blank, mem: blank, down: blank, up: blank))
    }

    var json: [String: Any] {
        let s = parser.stats
        return [
            "id": cfg.id, "name": cfg.name, "phase": phase, "hasMac": cfg.mac != nil,
            "cpu": s.cpu, "mem": s.mem, "down": s.down, "up": s.up,
            "memUsed": s.memUsed, "memTotal": s.memTotal, "disk": s.disk,
            "diskUsed": s.diskUsed, "diskTotal": s.diskTotal, "diskFree": s.diskFree,
            "uptime": s.uptime, "updates": s.updates ?? NSNull(), "progress": progress,
            "temp": s.temp, "tempDrive": s.tempDrive ?? NSNull(), "tempBoard": s.tempBoard ?? NSNull(),
            "user": sshUser, "saved": hasSavedPassword, "sudo": sudoMode,
            "checkedAgo": checkedAt.map { -$0.timeIntervalSinceNow } ?? NSNull(),
        ]
    }

    // MARK: stats stream

    func connect() {
        guard !removed, stream == nil else { return }
        let wait = holdUntil.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
            return
        }
        if cfg.resolved == nil { resolve() }
        parser = StatsParser(parser.stats)
        stream = ssh(Remote.stream, line: { [weak self] in self?.parse($0) }) { [weak self] _, _ in self?.dropped() }
    }

    func disconnect() {
        removed = true
        stream?.terminate()
    }

    /// Bakes ~/.ssh/config into plain arguments, because the sandboxed widget can't read everything it includes.
    private func resolve() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G"] + cfg.ssh.split(separator: " ").map(String.init)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var opts: [String: String] = [:], keys: [String] = []
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "identityfile" {
                let path = kv[1].replacingOccurrences(of: "~", with: realHome)
                if FileManager.default.fileExists(atPath: path) { keys += ["-i", path] }
            } else if opts[kv[0]] == nil {
                opts[kv[0]] = kv[1]
            }
        }
        guard let host = opts["hostname"], let user = opts["user"] else { return }
        cfg.resolved = ["-p", opts["port"] ?? "22"] + keys + ["\(user)@\(host)"]
        ice.save()
    }

    private func dropped() {
        stream = nil
        guard !removed else { return }
        let waiting = (phase == "starting" || phase == "restarting") && Date() < deadline
        if !waiting { phase = "off" }
        ice.changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
    }

    private func parse(_ line: String) {
        guard parser.feed(line) else { return }
        if let mac = parser.stats.mac, mac != cfg.mac {
            cfg.mac = mac
            ice.save()
        }
        if ["connecting", "off", "starting", "restarting"].contains(phase) {
            phase = "online"
            countUpdates()
        }
        ice.changed()
    }

    // MARK: actions

    func powerOn() {
        guard phase == "off" else { return }
        let host = cfg.ssh.split(separator: " ").last?.split(separator: "@").last.map(String.init) ?? ""
        guard let mac = cfg.mac, WakeOnLAN.send(mac: mac, host: host) else {
            return ice.alert("Can't wake \(cfg.name)", "Wake-on-LAN needs the server's MAC address. It is learned the first time the server is online.")
        }
        phase = "starting"
        deadline = Date() + 180
        ice.changed()
    }

    func powerOff() { systemctl("poweroff", action: "Shutting down", busy: "stopping") }
    func restart() { systemctl("reboot", action: "Restart", busy: "restarting") }

    private func systemctl(_ verb: String, action: String, busy: String) {
        guard phase == "online" else { return }
        sudo("systemctl \(verb)", action: action, busy: busy) { [self] status, out in
            // 255 = ssh lost the connection, which is what a shutdown looks like.
            if status == 0 || status == 255 {
                holdUntil = Date() + 15
                deadline = Date() + 300
            } else {
                if status != nil { ice.alert("Couldn't \(verb) \(cfg.name)", tail(out)) }
                if phase == busy { phase = "online" }
            }
            ice.changed()
        }
    }

    func countUpdates(then: (() -> Void)? = nil) {
        ssh(Remote.updates, line: { [self] in _ = parser.feed($0) }, done: { [self] _, out in
            if out.hasPrefix("upd") { checkedAt = Date() }
            then?()
            ice.changed()
        })
    }

    func checkUpdates() {
        guard phase == "online" else { return }
        sudo("apt-get update -qq", action: "Checking for updates", busy: "checking") { [self] _, _ in
            countUpdates { if self.phase == "checking" { self.phase = "online" } }
        }
    }

    func installUpdates() {
        guard phase == "online" else { return }
        progress = 0
        let cmd = "env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o APT::Status-Fd=1"
            + " -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs"
        sudo(cmd, action: "Installing updates", busy: "updating", line: { [self] line in
            let f = line.split(separator: ":")
            guard f.count >= 3, let pct = Double(f[2]) else { return }
            if f[0] == "dlstatus" { progress = Int(pct * 0.3) }
            else if f[0] == "pmstatus" { progress = 30 + Int(pct * 0.7) }
            else { return }
            ice.changed()
        }) { [self] status, out in
            if let status, status != 0 { ice.alert("Updating \(cfg.name) failed", tail(out)) }
            progress = 0
            countUpdates { if self.phase == "updating" { self.phase = "online" } }
        }
    }

    // MARK: ssh

    private func tail(_ out: String) -> String {
        out.split(separator: "\n").suffix(6).joined(separator: "\n")
    }

    /// The sudo password, once known. Read from the Keychain at most once per launch: with an
    /// ad-hoc signed build each read can make macOS ask the user for permission.
    private var password: String?
    private var triedKeychain = false
    private var sudoMode: String { cfg.sudo ?? "remember" }

    /// The account sudo asks about, for the password sheet.
    var sshUser: String {
        let target = (cfg.resolved ?? cfg.ssh.split(separator: " ").map(String.init)).last ?? ""
        return target.contains("@") ? String(target.split(separator: "@")[0]) : "your user"
    }

    var hasSavedPassword: Bool { password != nil && sudoMode == "remember" || Keychain.has(cfg.id) }

    func forgetPassword() {
        password = nil
        triedKeychain = true
        Keychain.delete(cfg.id)
    }

    private static func needsPassword(_ out: String) -> Bool {
        out.contains("password is required") || out.contains("interactive authentication") || wrongPassword(out)
    }

    private static func wrongPassword(_ out: String) -> Bool {
        out.contains("try again") || out.contains("incorrect password") || out.contains("Authentication failed")
    }

    /// Runs `cmd` under sudo, showing the server as `busy` while it runs. `action` names it in the
    /// password sheet ("Restart needs sudo as ice"). `done` gets nil when the user cancels.
    func sudo(_ cmd: String, action: String, busy: String? = nil, line: ((String) -> Void)? = nil,
              done: @escaping (Int32?, String) -> Void) {
        func run(_ pw: String?) {
            let before = phase
            if let busy {
                phase = busy
                ice.changed()
            }
            ssh(pw == nil ? "sudo -n \(cmd)" : "sudo -S -p '' \(cmd)", input: pw, line: line) { [self] status, out in
                guard Self.needsPassword(out) else { return done(status, out) }
                if busy != nil, phase == busy {
                    phase = before
                    ice.changed()
                }
                let saved = pw != nil && pw == password
                if saved { forgetPassword() }
                askPassword(action: action, error: saved ? "The saved password no longer works. Enter it again." : nil,
                            then: run, cancelled: { done(nil, out) })
            }
        }

        switch sudoMode {
        case "every":
            askPassword(action: action, error: nil, then: run, cancelled: { done(nil, "") })
        case "nopass":
            run(nil)
        default:
            if password == nil, !triedKeychain {
                triedKeychain = true
                if Keychain.has(cfg.id) { password = Keychain.get(cfg.id) }
            }
            guard let pw = password else { return run(nil) }
            guard ice.config.touchID == true else { return run(pw) }
            ice.authenticate("use your saved sudo password for \(cfg.name)") { ok in
                ok ? run(pw) : done(nil, "")
            }
        }
    }

    /// Asks for the password just to keep it (Settings › Passwords › Save Password…).
    func savePassword() {
        askPassword(action: nil, error: nil, then: { _ in }, cancelled: {})
    }

    /// Shows the password sheet until sudo accepts the password (checked with `sudo -v`) or the user cancels.
    private func askPassword(action: String?, error: String?, then: @escaping (String) -> Void, cancelled: @escaping () -> Void) {
        let remember = action == nil || sudoMode != "every"
        ice.askPassword(for: self, action: action, remember: remember, error: error) { [self] answer in
            guard let (pw, keep) = answer else { return cancelled() }
            ssh("sudo -S -p '' -v", input: pw, done: { [self] status, out in
                guard status == 0, !Self.wrongPassword(out) else {
                    let reason = Self.wrongPassword(out) ? "Incorrect password. sudo on \(cfg.name) rejected it. Nothing was saved."
                        : out.split(separator: "\n").last.map(String.init) ?? "sudo didn't accept the password."
                    return askPassword(action: action, error: reason, then: then, cancelled: cancelled)
                }
                if keep {
                    password = pw
                    Keychain.set(cfg.id, pw)
                    if sudoMode != "remember" {
                        cfg.sudo = "remember"
                        ice.save()
                    }
                }
                ice.passwordAccepted(for: self)
                let doing = action.map { a -> String in
                    let verb = ["Restart": "Restarting", "Shutting down": "Shutting down", "Installing updates": "Updating"][a]
                    return verb.map { "\($0) \(cfg.name)…" } ?? "Checking \(cfg.name) for updates…"
                }
                ice.toast(keep ? (doing.map { "Saved to Keychain · \($0)" } ?? "Password for \(cfg.name) saved to Keychain") : doing ?? "")
                then(pw)
            })
        }
    }

    /// Runs `command` on the server. Output lines (stdout + stderr) arrive on the main queue.
    @discardableResult
    func ssh(_ command: String, input: String? = nil, line: ((String) -> Void)? = nil,
             done: ((Int32, String) -> Void)? = nil) -> Process {
        Shell.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                                   "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2"]
                  + cfg.ssh.split(separator: " ").map(String.init) + [command],
                  input: input, done: done, line: line)
    }
}

enum Shell {
    /// Runs a program. Output lines (stdout + stderr) and `done` arrive on the main queue.
    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil, env: [String: String] = [:],
                    done: ((Int32, String) -> Void)? = nil, line: ((String) -> Void)? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        if let input {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data((input + "\n").utf8))
            try? pipe.fileHandleForWriting.close()
            p.standardInput = pipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        var buffer = Data()
        var all = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                p.waitUntilExit()
                let rest = String(decoding: buffer, as: UTF8.self)
                DispatchQueue.main.async {
                    if !rest.isEmpty { all += rest; line?(rest) }
                    done?(p.terminationStatus, all)
                }
                return
            }
            buffer.append(data)
            while let i = buffer.firstIndex(of: 10) {
                let l = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...i)
                DispatchQueue.main.async {
                    all += l + "\n"
                    line?(l)
                }
            }
        }
        do {
            try p.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { done?(-1, error.localizedDescription) }
        }
        return p
    }
}
