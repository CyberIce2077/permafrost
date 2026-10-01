import Foundation

/// One Linux box reached over SSH: a long-lived stats stream plus one-off commands.
final class Server {
    var cfg: ServerConfig
    var phase = "connecting"  // connecting online off stopping starting restarting updating checking
    var cpu = history(), mem = history(), down = history(), up = history()
    var memUsed = 0.0, memTotal = 0.0, diskUsed = 0.0, diskTotal = 0.0, diskFree = 0.0, uptime = 0.0
    var updates: Int?
    var checkedAt: Date?
    var progress = 0

    private var removed = false
    private var stream: Process?
    private var prevCPU: (total: Double, idle: Double)?
    private var prevNet: (rx: Double, tx: Double, at: Date)?
    private var cpuSample: Double?
    private var netSample = (down: 0.0, up: 0.0)
    private var holdUntil = Date.distantPast
    private var deadline = Date.distantPast

    init(_ cfg: ServerConfig) { self.cfg = cfg }

    private static func history() -> [Double] { Array(repeating: 0, count: 24) }

    var json: [String: Any] {
        [
            "id": cfg.id, "name": cfg.name, "phase": phase, "hasMac": cfg.mac != nil,
            "cpu": cpu, "mem": mem, "down": down, "up": up,
            "memUsed": memUsed, "memTotal": memTotal,
            "disk": diskUsed + diskFree > 0 ? diskUsed / (diskUsed + diskFree) * 100 : 0,
            "diskUsed": diskUsed, "diskTotal": diskTotal, "diskFree": diskFree,
            "uptime": uptime, "updates": updates ?? NSNull(), "progress": progress,
            "checkedAgo": checkedAt.map { -$0.timeIntervalSinceNow } ?? NSNull(),
        ]
    }

    // MARK: stats stream

    static let statsScript = """
        i=$(ip route show default 2>/dev/null | awk '{print $5; exit}'); [ -n "$i" ] || i=lo
        echo mac $(cat /sys/class/net/$i/address)
        while :; do
          head -1 /proc/stat
          grep -E '^Mem(Total|Available):' /proc/meminfo
          echo net $(cat /sys/class/net/$i/statistics/rx_bytes /sys/class/net/$i/statistics/tx_bytes)
          echo disk $(df -B1 --output=size,used,avail / | tail -1)
          echo up $(cut -d' ' -f1 /proc/uptime)
          echo end
          sleep 2
        done
        """

    func connect() {
        guard !removed, stream == nil else { return }
        let wait = holdUntil.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
            return
        }
        prevCPU = nil
        prevNet = nil
        stream = ssh(Self.statsScript, line: { [weak self] in self?.parse($0) }) { [weak self] _, _ in self?.dropped() }
    }

    func disconnect() {
        removed = true
        stream?.terminate()
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
        let f = line.split(separator: " ").map(String.init)
        guard let key = f.first else { return }
        let n = f.dropFirst().compactMap(Double.init)
        switch key {
        case "mac":
            if f.count > 1, f[1] != cfg.mac, f[1] != "00:00:00:00:00:00" {
                cfg.mac = f[1]
                ice.save()
            }
        case "cpu" where n.count >= 5:
            let total = n.prefix(8).reduce(0, +), idle = n[3] + n[4]
            if let p = prevCPU, total > p.total { cpuSample = 100 * (1 - (idle - p.idle) / (total - p.total)) }
            prevCPU = (total, idle)
        case "MemTotal:":
            memTotal = (n.first ?? 0) / 1_048_576
        case "MemAvailable:":
            memUsed = memTotal - (n.first ?? 0) / 1_048_576
        case "net" where n.count == 2:
            let now = Date()
            if let p = prevNet {
                let dt = max(now.timeIntervalSince(p.at), 0.1)
                netSample = (max(0, n[0] - p.rx) / dt / 1e6, max(0, n[1] - p.tx) / dt / 1e6)
            }
            prevNet = (n[0], n[1], now)
        case "disk" where n.count == 3:
            (diskTotal, diskUsed, diskFree) = (n[0] / 1e9, n[1] / 1e9, n[2] / 1e9)
        case "up":
            uptime = n.first ?? 0
        case "end":
            commit()
        default:
            break
        }
    }

    private func commit() {
        if ["connecting", "off", "starting", "restarting"].contains(phase) {
            phase = "online"
            countUpdates()
        }
        if let c = cpuSample {
            func push(_ a: inout [Double], _ v: Double) { a = Array(a.dropFirst()) + [v] }
            push(&cpu, c)
            push(&mem, memTotal > 0 ? memUsed / memTotal * 100 : 0)
            push(&down, netSample.down)
            push(&up, netSample.up)
            cpuSample = nil
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

    static let countScript = """
        if [ -x /usr/lib/update-notifier/apt-check ]; then /usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f1
        else apt list --upgradable 2>/dev/null | grep -c upgradable; fi
        """

    func countUpdates(then: (() -> Void)? = nil) {
        ssh(Self.countScript, done: { [self] _, out in
            if let n = Int(out.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                updates = n
                checkedAt = Date()
            }
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
