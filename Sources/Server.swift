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

    func powerOff() { systemctl("poweroff", busy: "stopping") }
    func restart() { systemctl("reboot", busy: "restarting") }

    private func systemctl(_ verb: String, busy: String) {
        guard phase == "online" else { return }
        phase = busy
        ice.changed()
        sudo("systemctl \(verb)") { [self] status, out in
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
        phase = "checking"
        ice.changed()
        sudo("apt-get update -qq") { [self] _, _ in
            countUpdates { if self.phase == "checking" { self.phase = "online" } }
        }
    }

    func installUpdates() {
        guard phase == "online" else { return }
        phase = "updating"
        progress = 0
        ice.changed()
        let cmd = "env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o APT::Status-Fd=1"
            + " -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs"
        sudo(cmd, line: { [self] line in
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

    /// Runs `cmd` under sudo. Asks for the password (kept in the Keychain) when sudo needs one.
    /// `done` gets nil when the user cancels the password prompt.
    func sudo(_ cmd: String, line: ((String) -> Void)? = nil, done: @escaping (Int32?, String) -> Void) {
        let password = Keychain.get(cfg.id)
        ssh(password == nil ? "sudo -n \(cmd)" : "sudo -S -p '' \(cmd)", input: password, line: line) { [self] status, out in
            let wrong = out.contains("try again") || out.contains("incorrect password")
            guard wrong || out.contains("password is required") || out.contains("interactive authentication") else {
                return done(status, out)
            }
            if wrong { Keychain.delete(cfg.id) }
            guard let pw = ice.askPassword(cfg.name, wrong: wrong) else { return done(nil, out) }
            Keychain.set(cfg.id, pw)
            sudo(cmd, line: line, done: done)
        }
    }

    /// Runs `command` on the server. Output lines (stdout + stderr) arrive on the main queue.
    @discardableResult
    func ssh(_ command: String, input: String? = nil, line: ((String) -> Void)? = nil,
             done: ((Int32, String) -> Void)? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                       "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2"]
            + cfg.ssh.split(separator: " ").map(String.init) + [command]
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
