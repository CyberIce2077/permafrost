import Foundation
import Security

struct ServerConfig: Codable {
    var id = UUID().uuidString
    var name: String
    var ssh: String
    var mac: String?
    /// `ssh` arguments with ~/.ssh/config already applied, for the sandboxed widget.
    var resolved: [String]?
    /// How sudo gets its password: "remember" (Keychain), "every" (ask each time) or "nopass".
    var sudo: String?
    /// Icon color in the app ("blue", "teal", "purple", "orange", "pink", "graphite").
    var color: String?
    /// Shown in "All servers" widgets and in the menu bar (both default to yes).
    var widgets: Bool?
    var menu: Bool?
}

/// A widget design from Settings › Widgets. Each desktop widget picks one in Edit Widget.
struct Design: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// The size it's designed (and previewed) at: "S", "M", "L" or "XL". On the desktop it fills whatever size the widget is.
    var size = "M"
    /// Every server shown in widgets (`ServerConfig.widgets`), including ones added later.
    var all = true
    var servers: [String] = []
    /// In the order they're shown: "cpu", "mem", "net", "disk", "temp".
    var stats = ["cpu", "temp"]
    var style = "bars"  // bars rings graph numbers
    var look = "glass"  // glass tinted clear
    /// Power, Restart and Updates buttons (Large and Extra Large only).
    var controls = false

    /// The servers it shows, in order.
    func servers(in config: Config) -> [ServerConfig] {
        all ? config.servers.filter { $0.widgets ?? true } : servers.compactMap { id in config.servers.first { $0.id == id } }
    }

    /// How much fits at a size: server rows and stats (per server when there are several).
    static func caps(size: String, style: String, controls: Bool, multi: Bool) -> (rows: Int, stats: Int) {
        let ctl = controls && (size == "L" || size == "XL")
        if multi { return (["S": 4, "M": 4, "L": 5, "XL": 5][size] ?? 4, ["S": 1, "M": 2, "L": ctl ? 2 : 3, "XL": 5][size] ?? 2) }
        return (1, ["S": style == "bars" ? 3 : 2, "M": 4, "L": 6, "XL": 6][size] ?? 4)
    }
}

struct Config: Codable {
    var servers: [ServerConfig] = []
    /// Widget designs; the first is the default for widgets that haven't picked one.
    var designs: [Design]?
    /// Ask for Touch ID (or the Mac's password) before a saved sudo password is used.
    var touchID: Bool?
    var prefs: Prefs?
}

/// Settings › General, Notifications and Appearance. Missing keys fall back to the defaults,
/// so new settings can be added without breaking older config files.
struct Prefs: Codable {
    var login = false, menubar = true, refresh = 2.0, unit = "C", net = "MBs", confirmOff = true
    var nOffline = true, nCpu = true, cpuAt = 90.0, nTemp = true, tempAt = 80.0, nDisk = true, diskAt = 85.0, nUpd = false
    var glass = 60.0, blur = 40.0, theme = "light", tint = "ice", accent = "blue", reduce = false
    /// Sudo command time limits, in minutes (Settings › Sudo & Passwords).
    var limRestart = 3.0, limPower = 5.0, limUpdate = 30.0, limCheck = 1.0

    init() {}

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? all.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        login = v(.login, login); menubar = v(.menubar, menubar); refresh = v(.refresh, refresh)
        unit = v(.unit, unit); net = v(.net, net); confirmOff = v(.confirmOff, confirmOff)
        nOffline = v(.nOffline, nOffline); nCpu = v(.nCpu, nCpu); cpuAt = v(.cpuAt, cpuAt)
        nTemp = v(.nTemp, nTemp); tempAt = v(.tempAt, tempAt); nDisk = v(.nDisk, nDisk)
        diskAt = v(.diskAt, diskAt); nUpd = v(.nUpd, nUpd)
        glass = v(.glass, glass); blur = v(.blur, blur); theme = v(.theme, theme)
        tint = v(.tint, tint); accent = v(.accent, accent); reduce = v(.reduce, reduce)
        limRestart = v(.limRestart, limRestart); limPower = v(.limPower, limPower)
        limUpdate = v(.limUpdate, limUpdate); limCheck = v(.limCheck, limCheck)
    }
}

/// The real home folder, also from inside the widget's sandbox (where $HOME is its container).
let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)

enum Store {
    static let url = URL(fileURLWithPath: realHome + "/Library/Application Support/Ice Servers/config.json")

    static func load() -> Config? {
        try? JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    /// The running app's latest stats, so widgets redraw instantly instead of opening their own SSH session.
    struct Live: Codable {
        var at: Date
        var stats: [Stats]
    }

    private static let liveURL = url.deletingLastPathComponent().appendingPathComponent("live.json")

    static func saveLive(_ stats: [Stats]) {
        try? JSONEncoder().encode(Live(at: Date(), stats: stats)).write(to: liveURL, options: .atomic)
    }

    /// nil when the app isn't running (or hasn't written for a while).
    static func loadLive() -> [Stats]? {
        guard let live = try? JSONDecoder().decode(Live.self, from: Data(contentsOf: liveURL)),
              -live.at.timeIntervalSinceNow < 30 else { return nil }
        return live.stats
    }

    static func save(_ config: Config) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(config).write(to: url, options: .atomic)
    }

    /// First launch: turn `alias name='ssh user@host'` lines from shell rc files into servers.
    static func shellAliases() -> [ServerConfig] {
        let home = URL(fileURLWithPath: realHome)
        let re = try! NSRegularExpression(pattern: #"^\s*alias\s+([\w.-]+)=(['"])ssh\s+([^'"]+)\2"#, options: .anchorsMatchLines)
        var found: [ServerConfig] = []
        for file in [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".aliases"] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(m.range(at: 1), in: text)!])
                let ssh = String(text[Range(m.range(at: 3), in: text)!]).trimmingCharacters(in: .whitespaces)
                if !found.contains(where: { $0.name == name }) { found.append(ServerConfig(name: name, ssh: ssh)) }
            }
        }
        return found
    }
}

/// sudo passwords, one Keychain item per server.
enum Keychain {
    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "Ice Servers sudo", kSecAttrAccount: account]
    }

    static func get(_ account: String) -> String? { read(account).password }

    /// The status tells "not saved" apart from "the user clicked Deny in macOS's Keychain prompt".
    static func read(_ account: String) -> (password: String?, status: OSStatus) {
        var q = query(account)
        q[kSecReturnData] = true
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return ((out as? Data).flatMap { String(data: $0, encoding: .utf8) }, status)
    }

    static func denied(_ status: OSStatus) -> Bool { status == errSecAuthFailed || status == errSecUserCanceled }

    static func set(_ account: String, _ password: String) {
        let data = Data(password.utf8)
        if SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// Checks for a saved password without reading it (reading can make macOS ask for permission).
    static func has(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

enum WakeOnLAN {
    /// Sends the magic packet to the global broadcast and, for an IPv4 host, its /24 broadcast.
    static func send(mac: String, host: String) -> Bool {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }
        let packet = [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var targets = ["255.255.255.255"]
        let octets = host.split(separator: ".")
        // ponytail: assumes a /24 LAN, read the real netmask if someone runs a bigger subnet
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            targets.append(octets.prefix(3).joined(separator: ".") + ".255")
        }
        var sent = false
        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9).bigEndian
            inet_pton(AF_INET, target, &addr.sin_addr)
            let n = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if n == packet.count { sent = true }
        }
        return sent
    }
}
