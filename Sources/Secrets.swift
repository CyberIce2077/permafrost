import CryptoKit
import Foundation
import IOKit

/// Sudo passwords for "Remember, never ask" servers, kept outside the Keychain so macOS never
/// asks before they're used. They're encrypted (a hash can't be turned back into the password
/// sudo needs) with a key derived from this Mac's hardware UUID, in a file only your user can read.
/// So a copy of the file is useless elsewhere (backups, synced folders, another Mac), but a program
/// running as you on this Mac could decrypt it. That's the trade-off "never ask" makes.
enum LocalSecrets {
    private static let url = Store.url.deletingLastPathComponent().appendingPathComponent("sudo-passwords")

    private static let key: SymmetricKey = {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(device) }
        let uuid = IORegistryEntryCreateCFProperty(device, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ""
        // The salt keeps the app's first name: changing it would make saved passwords unreadable.
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(uuid.utf8)),
                                      salt: Data("Ice Servers".utf8), info: Data("sudo passwords".utf8), outputByteCount: 32)
    }()

    private static func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private static func write(_ all: [String: String]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func has(_ id: String) -> Bool { load()[id] != nil }

    static func get(_ id: String) -> String? {
        guard let sealed = load()[id].flatMap({ Data(base64Encoded: $0) }),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func set(_ id: String, _ password: String) {
        guard let combined = try? AES.GCM.seal(Data(password.utf8), using: key).combined else { return }
        var all = load()
        all[id] = combined.base64EncodedString()
        write(all)
    }

    static func delete(_ id: String) {
        var all = load()
        guard all.removeValue(forKey: id) != nil else { return }
        write(all)
    }
}
