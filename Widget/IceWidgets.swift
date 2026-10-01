import OSLog
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "app.iceservers.IceServers.Widgets", category: "fetch")

@main
struct IceWidgets: WidgetBundle {
    var body: some Widget {
        ServersWidget()
        Custom1()
        Custom2()
        Custom3()
        Custom4()
    }
}

struct ServersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "IceServers", provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Servers")
        .description("Live stats and controls for your servers. Choose them in Ice Servers › Settings › Widgets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

/// Widget kinds are fixed when the app is built (and a Widget must be creatable with no arguments),
/// so custom widgets live in four numbered slots.
private func customSlot(_ slot: Int) -> some WidgetConfiguration {
    // Plain Strings: WidgetKit traps on interpolated (formatted) text in the display name.
    let name: String = "Custom \(slot)"
    return StaticConfiguration(kind: "IceCustom\(slot)", provider: Provider(slot: slot)) { entry in
        WidgetView(entry: entry)
    }
    .configurationDisplayName(name)
    .description("A widget you set up in Ice Servers › Settings › Widgets: its own name, servers and stats.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    .contentMarginsDisabled()
}

struct Custom1: Widget { var body: some WidgetConfiguration { customSlot(1) } }
struct Custom2: Widget { var body: some WidgetConfiguration { customSlot(2) } }
struct Custom3: Widget { var body: some WidgetConfiguration { customSlot(3) } }
struct Custom4: Widget { var body: some WidgetConfiguration { customSlot(4) } }

struct Entry: TimelineEntry {
    var date = Date()
    var size: String
    var style: WidgetStyle
    var servers: [Stats]
    /// "All servers" (a compact row each) rather than one server.
    var all = false
    var prefs = Prefs()
    /// A custom widget's name, shown as its title.
    var title: String?
    /// Shown instead of stats, e.g. for a custom slot that hasn't been set up.
    var message: String?
}

struct Provider: TimelineProvider {
    var slot: Int?

    func placeholder(in context: Context) -> Entry { sample(context) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { return completion(sample(context)) }
        DispatchQueue.global().async { completion(fetch(context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        DispatchQueue.global().async {
            // WidgetKit decides the real refresh rate; the app also asks for a refresh whenever something changes.
            completion(Timeline(entries: [fetch(context)], policy: .after(Date() + 300)))
        }
    }

    private func size(_ context: Context) -> String {
        switch context.family {
        case .systemSmall: "S"
        case .systemLarge: "L"
        case .systemExtraLarge: "XL"
        default: "M"
        }
    }

    /// What this widget shows: its style, its servers (at most `maxServersPerWidget`), whether it's
    /// the multi-server table, a custom title, and a message when there's nothing to show.
    private func pick(_ config: Config, _ size: String) -> (WidgetStyle, [ServerConfig], Bool, String?, String?) {
        if let slot {
            guard let custom = config.custom?.first(where: { $0.slot == slot }) else {
                return (WidgetStyle(), [], false, nil, "Set up Custom \(slot) in Ice Servers › Settings › Widgets")
            }
            let servers = custom.servers.compactMap { id in config.servers.first { $0.id == id } }.prefix(maxServersPerWidget)
            return (custom.style, Array(servers), servers.count > 1, custom.name, servers.isEmpty ? "Choose servers for \(custom.name)" : nil)
        }
        let style = config.widgets[size] ?? WidgetStyle()
        let one = config.servers.filter { $0.id == style.server }
        if !one.isEmpty { return (style, one, false, nil, nil) }
        return (style, Array(config.servers.filter { $0.widgets ?? true }.prefix(maxServersPerWidget)), true, nil, nil)
    }

    private func fetch(_ context: Context) -> Entry {
        let config = Store.load() ?? Config()
        let (style, servers, all, title, message) = pick(config, size(context))
        var results = [Stats](repeating: Stats(), count: servers.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: servers.count) { i in
            let s = Self.stats(servers[i])
            lock.withLock { results[i] = s }
        }
        return Entry(size: size(context), style: style, servers: results, all: all, prefs: config.prefs ?? Prefs(), title: title, message: message)
    }

    /// One short SSH session: ~3 s of samples plus the update count.
    private static func stats(_ server: ServerConfig) -> Stats {
        var parser = StatsParser(Stats(id: server.id, name: server.name))
        // -F /dev/null: ~/.ssh/config may include files the sandbox can't read; the app resolved it for us.
        let args = ["-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                    "-o", "UserKnownHostsFile=\(realHome)/.ssh/known_hosts"]
            + (server.resolved ?? server.ssh.split(separator: " ").map(String.init)) + [Remote.snapshot]
        let (status, text, errors) = Spawn.run("/usr/bin/ssh", args, timeout: 15)
        if status != 0 {
            log.error("\(server.name, privacy: .public): ssh exited \(status): \(errors, privacy: .public)")
        }
        text.split(separator: "\n").forEach { _ = parser.feed(String($0)) }
        parser.stats.online = parser.stats.online && !parser.stats.cpu.isEmpty
        log.info("\(server.name, privacy: .public): online=\(parser.stats.online) samples=\(parser.stats.cpu.count) bytes=\(text.utf8.count)")
        return parser.stats
    }

    private func sample(_ context: Context) -> Entry {
        let config = Store.load() ?? Config()
        let (style, servers, all, title, message) = pick(config, size(context))
        let names = servers.isEmpty ? ["server"] : servers.map(\.name)
        let demo = names.enumerated().map { i, name in
            let wave = (0..<12).map { 30 + 12 * sin(Double($0) * 0.9 + Double(i)) }
            return Stats(id: "", name: name, online: true, cpu: wave, mem: wave.map { $0 + 25 },
                         down: wave.map { $0 / 2 }, up: wave.map { $0 / 5 }, temp: wave.map { $0 + 18 }, memUsed: 19.5, memTotal: 32,
                         diskUsed: 580, diskTotal: 1000, diskFree: 420, uptime: 1_036_800, updates: 0)
        }
        return Entry(size: size(context), style: style, servers: message == nil ? demo : [], all: all, prefs: config.prefs ?? Prefs(), title: title, message: message)
    }
}

/// Runs a program as its own "responsible" process, like Terminal does for the commands it runs.
/// Otherwise macOS's Local Network privacy judges ssh as part of this widget, can't match an
/// ad-hoc signed widget to the app the user allowed, and fails every connection with "No route to host".
enum Spawn {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (Int32, String, String) {
        let out = Pipe(), err = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = disclaim?(&attr, 1)

        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        guard rc == 0 else { return (-1, "", String(cString: strerror(rc))) }

        var finished = false
        let lock = NSLock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            lock.withLock { if !finished { kill(pid, SIGTERM) } }
        }
        var errText = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errText = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let text = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        lock.withLock { finished = true }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        return (code, String(decoding: text, as: UTF8.self), String(decoding: errText, as: UTF8.self))
    }
}
