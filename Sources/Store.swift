import Foundation
import Security

struct ServerConfig: Codable {
    var id = UUID().uuidString
    var name: String
    var ssh: String
    var mac: String?
}

struct WidgetConfig: Codable {
    var id = UUID().uuidString
    var size = "M"
    var server = "all"
    var metrics = ["cpu": true, "mem": true, "net": true, "disk": true]
    var style = "bars"
    var look = "glass"
    var x = 0.0
    var y = 0.0
}

struct Config: Codable {
    var servers: [ServerConfig] = []
    var widgets: [WidgetConfig] = []
}

enum Store {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ice Servers/config.json")

    static func load() -> Config? {
        try? JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    static func save(_ config: Config) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(config).write(to: url, options: .atomic)
    }

    /// First launch: turn `alias name='ssh user@host'` lines from shell rc files into servers.
    static func shellAliases() -> [ServerConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser
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

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ password: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData] = Data(password.utf8)
        SecItemAdd(q as CFDictionary, nil)
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
