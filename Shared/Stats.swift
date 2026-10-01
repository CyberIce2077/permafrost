import Foundation

/// One server's numbers, as shown by the app and the widgets.
struct Stats {
    var id = "", name = ""
    var online = false
    var cpu: [Double] = [], mem: [Double] = [], down: [Double] = [], up: [Double] = []
    /// CPU temperature history in °C; empty when the server has no readable sensor.
    var temp: [Double] = []
    var tempDrive: Double?, tempBoard: Double?
    var memUsed = 0.0, memTotal = 0.0, diskUsed = 0.0, diskTotal = 0.0, diskFree = 0.0, uptime = 0.0
    var updates: Int?
    var mac: String?

    var disk: Double { diskUsed + diskFree > 0 ? diskUsed / (diskUsed + diskFree) * 100 : 0 }
}

/// Shell snippets run on the server. They print one `key values…` line per fact; `StatsParser` reads them.
enum Remote {
    private static let iface = #"i=$(ip route show default 2>/dev/null | awk '{print $5; exit}'); [ -n "$i" ] || i=lo"#
    private static let sample = """
        echo t $(date +%s.%N)
        head -1 /proc/stat
        grep -E '^Mem(Total|Available):' /proc/meminfo
        echo net $(cat /sys/class/net/$i/statistics/rx_bytes /sys/class/net/$i/statistics/tx_bytes)
        echo disk $(df -B1 --output=size,used,avail / | tail -1)
        echo up $(cut -d' ' -f1 /proc/uptime)
        for f in /sys/class/hwmon/hwmon*/temp1_input; do [ -r "$f" ] && echo temp $(cat ${f%/*}/name) $(cat $f); done 2>/dev/null
        echo end
        """
    static let updates = """
        if [ -x /usr/lib/update-notifier/apt-check ]; then echo upd $(/usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f1)
        else echo upd $(apt list --upgradable 2>/dev/null | grep -c upgradable); fi
        """

    /// Endless: a sample every 2 seconds, for the app.
    static let stream = iface + "\necho mac $(cat /sys/class/net/$i/address)\nwhile :; do\n" + sample + "\nsleep 2\ndone"

    /// About 3 seconds of samples plus the update count, for a widget refresh.
    static let snapshot = iface + "\nfor n in 1 2 3 4 5 6 7 8 9 10 11 12; do\n" + sample + "\nsleep 0.25\ndone\n" + updates
}

struct StatsParser {
    var stats: Stats
    var keep = 24
    private var prevCPU: (total: Double, idle: Double)?
    private var prevNet: (rx: Double, tx: Double, at: Double)?
    private var time: Double?
    private var cpuNow: Double?
    private var net = (down: 0.0, up: 0.0)
    private var temps: [(chip: String, celsius: Double)] = []

    init(_ stats: Stats) { self.stats = stats }

    /// Reads one output line. Returns true when it completed a sample.
    mutating func feed(_ line: String) -> Bool {
        let f = line.split(separator: " ").map(String.init)
        guard let key = f.first else { return false }
        let n = f.dropFirst().compactMap(Double.init)
        switch key {
        case "t": time = n.first
        case "mac": if f.count > 1, f[1] != "00:00:00:00:00:00" { stats.mac = f[1] }
        case "cpu" where n.count >= 5:
            let total = n.prefix(8).reduce(0, +), idle = n[3] + n[4]
            if let p = prevCPU, total > p.total { cpuNow = 100 * (1 - (idle - p.idle) / (total - p.total)) }
            prevCPU = (total, idle)
        case "MemTotal:": stats.memTotal = (n.first ?? 0) / 1_048_576
        case "MemAvailable:": stats.memUsed = stats.memTotal - (n.first ?? 0) / 1_048_576
        case "net" where n.count == 2:
            let at = time ?? Date().timeIntervalSince1970
            if let p = prevNet {
                let dt = max(at - p.at, 0.05)
                net = (max(0, n[0] - p.rx) / dt / 1e6, max(0, n[1] - p.tx) / dt / 1e6)
            }
            prevNet = (n[0], n[1], at)
        case "disk" where n.count == 3:
            (stats.diskTotal, stats.diskUsed, stats.diskFree) = (n[0] / 1e9, n[1] / 1e9, n[2] / 1e9)
        case "up": stats.uptime = n.first ?? 0
        case "upd": stats.updates = n.first.map { Int($0) }
        case "temp" where f.count == 3: if let milli = Double(f[2]) { temps.append((f[1], milli / 1000)) }
        case "end":
            stats.online = true
            readTemps()
            guard let c = cpuNow else { return true }
            push(&stats.cpu, c)
            push(&stats.mem, stats.memTotal > 0 ? stats.memUsed / stats.memTotal * 100 : 0)
            push(&stats.down, net.down)
            push(&stats.up, net.up)
            cpuNow = nil
            return true
        default: break
        }
        return false
    }

    /// Sorts hwmon chips into CPU, drives and board by driver name.
    private mutating func readTemps() {
        func first(_ prefixes: [String]) -> Double? {
            for p in prefixes { if let t = temps.first(where: { $0.chip.hasPrefix(p) }) { return t.celsius } }
            return nil
        }
        if let cpu = first(["coretemp", "k10temp", "zenpower", "cpu_thermal", "cpu"]) { push(&stats.temp, cpu) }
        stats.tempDrive = temps.filter { $0.chip == "nvme" || $0.chip == "drivetemp" }.map(\.celsius).max()
        stats.tempBoard = first(["nct", "it8", "gigabyte", "asus", "dell", "acpitz", "pch"])
        temps = []
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > keep { a.removeFirst(a.count - keep) }
    }
}
