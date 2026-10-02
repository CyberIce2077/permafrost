import OSLog
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "app.iceservers.IceServers.Widgets", category: "fetch")

@main
struct IceWidgets: WidgetBundle {
    var body: some Widget {
        ServersWidget()
    }
}

struct ServersWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "IceServers", intent: ConfigureWidget.self, provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Ice Servers")
        .description("Live stats and controls for your servers. Right-click › Edit Widget to pick a design.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct Entry: TimelineEntry {
    var date = Date()
    /// The widget's real size on the desktop ("S", "M", "L", "XL"); the design is laid out at it.
    var size: String
    var design: Design
    /// The servers that fit, in order.
    var servers: [Stats]
    /// All the design's servers, and how many of them are online.
    var total = 0
    var online = 0
    var prefs = Prefs()
    /// No design picked yet: the widget asks for one instead.
    var choose = false
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { sample(ConfigureWidget(), context) }

    func snapshot(for intent: ConfigureWidget, in context: Context) async -> Entry {
        context.isPreview ? sample(intent, context) : fetch(intent, context)
    }

    func timeline(for intent: ConfigureWidget, in context: Context) async -> Timeline<Entry> {
        // WidgetKit decides the real refresh rate; the app also asks for a refresh whenever something changes.
        Timeline(entries: [fetch(intent, context)], policy: .after(Date() + 300))
    }

    private func size(_ context: Context) -> String {
        switch context.family {
        case .systemSmall: "S"
        case .systemLarge: "L"
        case .systemExtraLarge: "XL"
        default: "M"
        }
    }

    /// The picked design, or the first one when it was deleted (or for the gallery preview, before one is picked).
    private func design(_ intent: ConfigureWidget, _ config: Config) -> Design {
        let all = config.designs ?? [.overview]
        return all.first { $0.id == intent.design?.id } ?? all.first ?? .overview
    }

    /// The design's servers, and the ones that fit at this size.
    private func pick(_ d: Design, _ config: Config, _ size: String) -> ([ServerConfig], [ServerConfig]) {
        let all = d.servers(in: config)
        let caps = Design.caps(size: size, style: d.style, controls: d.controls, multi: all.count > 1)
        return (all, Array(all.prefix(caps.rows)))
    }

    private func fetch(_ intent: ConfigureWidget, _ context: Context) -> Entry {
        let config = Store.load() ?? Config()
        if intent.design == nil { return Entry(size: size(context), design: .overview, servers: [], prefs: config.prefs ?? Prefs(), choose: true) }
        let d = design(intent, config)
        let (all, servers) = pick(d, config, size(context))
        let live = Store.loadLive()
        var results = [Stats](repeating: Stats(), count: servers.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: servers.count) { i in
            // The app's live stats when it's running; otherwise a short SSH session of our own.
            let s = live?.first { $0.id == servers[i].id } ?? Self.stats(servers[i])
            lock.withLock { results[i] = s }
        }
        // Rows that don't fit only count as online when the app's live stats say so.
        let hidden = all.dropFirst(servers.count).filter { c in live?.first { $0.id == c.id }?.online == true }.count
        return Entry(size: size(context), design: d, servers: results, total: all.count,
                     online: results.filter(\.online).count + hidden, prefs: config.prefs ?? Prefs())
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

    private func sample(_ intent: ConfigureWidget, _ context: Context) -> Entry {
        let config = Store.load() ?? Config()
        let d = design(intent, config)
        let (all, servers) = pick(d, config, size(context))
        let demo = (servers.isEmpty ? [ServerConfig(name: "server", ssh: "")] : servers).enumerated().map { i, c in
            let wave = (0..<12).map { 30 + 12 * sin(Double($0) * 0.9 + Double(i)) }
            return Stats(id: c.id, name: c.name, online: true, cpu: wave, mem: wave.map { $0 + 25 },
                         down: wave.map { $0 / 2 }, up: wave.map { $0 / 5 }, temp: wave.map { $0 + 18 }, memUsed: 19.5, memTotal: 32,
                         diskUsed: 580, diskTotal: 1000, diskFree: 420, uptime: 1_036_800, updates: 0)
        }
        return Entry(size: size(context), design: d, servers: demo, total: max(all.count, demo.count), online: max(all.count, demo.count), prefs: config.prefs ?? Prefs())
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
