import Foundation

/// One Linux box reached over SSH: a long-lived stats stream plus one-off commands.
final class Server {
    var cfg: ServerConfig
    var phase = "connecting" {  // connecting online off stopping starting restarting updating checking timedout
        didSet {
            guard phase != oldValue else { return }
            ice.reloadWidgets()  // widgets show checking, installing, restart required…
            // A sudo action runs while the phase is busy; its clock starts and stops with it.
            if let kind = Self.ops[phase] {
                if op == nil { op = Op(action: kind.action, label: kind.label, limit: kind.limit(ice.prefs) * 60, prev: kind.prev) }
            } else {
                op = nil
            }
        }
    }

    /// A running sudo action and how long it may take (design: Main › lock banner).
    struct Op {
        let action, label: String
        let limit: TimeInterval
        let prev: String
        var start = Date()
    }
    private static let ops: [String: (action: String, label: String, limit: (Prefs) -> Double, prev: String)] = [
        "restarting": ("restart", "Restart", { $0.limRestart }, "online"),
        "stopping": ("stop", "Shut down", { $0.limPower }, "online"),
        "starting": ("start", "Start", { $0.limPower }, "off"),
        "updating": ("update", "Software update", { $0.limUpdate }, "online"),
        "checking": ("check", "Update check", { $0.limCheck }, "online"),
    ]
    private(set) var op: Op?
    /// The action that ran out of time, until Dismiss or Retry.
    private(set) var failed: Op?
    var parser: StatsParser
    var checkedAt: Date?
    var progress = 0

    private var removed = false
    private var quietDrop = false
    private var stream: Process?
    private var holdUntil = Date.distantPast

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
            "rebootSince": s.rebootSince ?? NSNull(), "rebootPkgs": s.rebootPkgs ?? [],
            "temp": s.temp, "tempDrive": s.tempDrive ?? NSNull(), "tempBoard": s.tempBoard ?? NSNull(),
            "user": sshUser, "saved": hasSavedPassword, "sudo": sudoMode,
            "host": address.host, "port": address.port, "color": cfg.color ?? "blue",
            "widgets": cfg.widgets ?? true, "menu": cfg.menu ?? true,
            "checkedAgo": checkedAt.map { -$0.timeIntervalSinceNow } ?? NSNull(),
            "op": op.map { ["label": $0.label, "limit": $0.limit, "elapsed": -$0.start.timeIntervalSinceNow] } ?? NSNull(),
            "failed": failed.map { ["label": $0.label, "limit": $0.limit] } ?? NSNull(),
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
        stream = ssh(Remote.stream(every: ice.prefs.refresh), line: { [weak self] in self?.parse($0) }) { [weak self] _, _ in self?.dropped() }
    }

    func disconnect() {
        removed = true
        stream?.terminate()
    }

    /// Restarts the stats stream (new refresh rate or new address) without showing the server as offline.
    func reconnect() {
        guard let stream else { return connect() }
        quietDrop = true
        stream.terminate()
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
        if quietDrop {
            quietDrop = false
            return connect()
        }
        // Booting, or given up on and waiting for the server to answer again.
        let waiting = ["starting", "restarting", "timedout"].contains(phase)
        if !waiting {
            if ["online", "updating", "checking"].contains(phase) { ice.alerts.offline(self) }
            phase = "off"
        }
        ice.changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
    }

    private func parse(_ line: String) {
        guard parser.feed(line) else { return }
        if let mac = parser.stats.mac, mac != cfg.mac {
            cfg.mac = mac
            ice.save()
        }
        if ["connecting", "off", "starting", "restarting", "timedout"].contains(phase) {
            phase = "online"
            countUpdates()
        }
        ice.alerts.check(self)
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
        ice.changed()
    }

    /// Called every second: past its limit, the app stops waiting for the action and unlocks the controls.
    /// Nothing is stopped on the server (an interrupted upgrade could leave packages half installed).
    func tick() {
        guard let op, -op.start.timeIntervalSinceNow >= op.limit else { return }
        failed = op
        phase = "timedout"
        progress = 0
        ice.changed()
    }

    func dismissTimeout() {
        guard let f = failed else { return }
        failed = nil
        if phase == "timedout" { phase = f.prev }
        ice.changed()
    }

    func retryTimeout() {
        guard let f = failed else { return }
        dismissTimeout()
        switch f.action {
        case "restart": restart()
        case "stop": powerOff()
        case "start": powerOn()
        case "update": installUpdates()
        default: checkUpdates()
        }
    }

    func powerOff() { systemctl("poweroff", action: "Shutting down", busy: "stopping") }
    func restart() { systemctl("reboot", action: "Restart", busy: "restarting") }

    /// Scheduled 3 s out, so the command returns and SSH closes cleanly before systemd shuts the
    /// server down in order. The server decides before sudo runs: `--when` needs systemd 254+,
    /// and a passwordless rule may only allow the plain command. Otherwise the plain command runs.
    private func systemctl(_ verb: String, action: String, busy: String) {
        guard phase == "online" else { return }
        let when = "--when=+3s"
        let ok = sudoMode == "nopass" ? "sudo -n -l systemctl \(verb) \(when) >/dev/null 2>&1"
            : "[ \"$(systemctl --version | awk 'NR==1{print $2}')\" -ge 254 ] 2>/dev/null"
        sudo("systemctl \(verb) $(\(ok) && echo \(when))", action: action, busy: busy) { [self] status, out in
            // 255 = ssh lost the connection, which is what a shutdown looks like.
            if status == 0 || status == 255 {
                holdUntil = Date() + 15
            } else {
                if status != nil { ice.alert("Couldn't \(verb) \(cfg.name)", tail(out)) }
                if phase == busy { phase = "online" }
            }
            ice.changed()
        }
    }

    func countUpdates(then: (() -> Void)? = nil) {
        ssh(Remote.updates, line: { [self] in _ = parser.feed($0) }, done: { [self] _, out in
            if out.hasPrefix("upd") {
                checkedAt = Date()
                ice.alerts.updates(self)
                ice.alerts.reboot(self)
            }
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
        // Run apt-get itself under sudo (not `env apt-get`), so passwordless sudo rules for apt-get apply.
        // Without a terminal, debconf already answers questions with their defaults.
        let cmd = "apt-get -y -q -o APT::Status-Fd=1"
            + " -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs"
        sudo(cmd, action: "Installing updates", busy: "updating", line: { [self] line in
            let f = line.split(separator: ":")
            guard f.count >= 3, let pct = Double(f[2]) else { return }
            if f[0] == "dlstatus" { progress = Int(pct * 0.3) }
            else if f[0] == "pmstatus" { progress = 30 + Int(pct * 0.7) }
            else { return }
            ice.changed()
        }) { [self] status, out in
            if let status, status != 0, phase == "updating" { ice.alert("Updating \(cfg.name) failed", tail(out)) }
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

    /// Host and port from the `ssh` arguments (for Settings › Servers › Edit).
    var address: (host: String, port: String) {
        let args = cfg.ssh.split(separator: " ").map(String.init)
        let target = args.last ?? ""
        let port = args.firstIndex(of: "-p").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "22"
        return (target.split(separator: "@").last.map(String.init) ?? target, port)
    }

    /// Settings › Servers › Edit: rewrites the address and reconnects; other ssh options are kept.
    func edit(name: String, user: String, host: String, port: String) {
        var args = cfg.ssh.split(separator: " ").map(String.init)
        if !args.isEmpty { args.removeLast() }
        if let i = args.firstIndex(of: "-p"), i + 1 < args.count { args.removeSubrange(i...(i + 1)) }
        let new = ((port == "22" || port.isEmpty) ? [] : ["-p", port]) + args + ["\(user)@\(host)"]
        let oldHost = address.host
        cfg.name = name
        guard new.joined(separator: " ") != cfg.ssh else { return }
        cfg.ssh = new.joined(separator: " ")
        cfg.resolved = nil
        if host != oldHost { cfg.mac = nil }
        reconnect()
    }

    /// "Remember, never ask" keeps its password in `LocalSecrets` and never touches the Keychain,
    /// so macOS never asks before it's used.
    private var neverAsk: Bool { sudoMode == "always" }

    var hasSavedPassword: Bool {
        password != nil && sudoMode != "every" || (neverAsk ? LocalSecrets.has(cfg.id) : Keychain.has(cfg.id))
    }

    func forgetPassword() {
        password = nil
        triedKeychain = true
        if neverAsk { LocalSecrets.delete(cfg.id) } else { Keychain.delete(cfg.id) }
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
            if password == nil, neverAsk {
                password = LocalSecrets.get(cfg.id)
            } else if password == nil, !triedKeychain {
                if Keychain.has(cfg.id) {
                    // macOS may ask whether this app may read it. Deny means "don't", so nothing runs
                    // (no fallback to asking for the password), and macOS asks again next time.
                    let (saved, status) = Keychain.read(cfg.id)
                    if Keychain.denied(status) {
                        ice.toast("Keychain access denied · Nothing ran on \(cfg.name)")
                        return done(nil, "")
                    }
                    password = saved
                }
                triedKeychain = true
            }
            guard let pw = password else { return run(nil) }
            // "always" means remembered and never confirmed on this Mac.
            guard ice.config.touchID == true, sudoMode != "always" else { return run(pw) }
            let what = ["Restart": "restart", "Shutting down": "shut down", "Installing updates": "install updates on",
                        "Checking for updates": "check for updates on"][action] ?? "run sudo on"
            ice.authenticate("use your saved sudo password to \(what) \(cfg.name)") { ok in
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
                    if neverAsk { LocalSecrets.set(cfg.id, pw) } else { Keychain.set(cfg.id, pw) }
                    if sudoMode == "every" || sudoMode == "nopass" {
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
