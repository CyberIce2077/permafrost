import SwiftUI
import WidgetKit

@main
struct IceWidgets: WidgetBundle {
    var body: some Widget { ServersWidget() }
}

struct ServersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "IceServers", provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Servers")
        .description("Live stats and controls for your servers. Choose what each size shows in Ice Servers › Widget Settings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct Entry: TimelineEntry {
    var date = Date()
    var size: String
    var style: WidgetStyle
    var servers: [Stats]
}

struct Provider: TimelineProvider {
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

    private func pick(_ config: Config, _ size: String) -> (WidgetStyle, [ServerConfig]) {
        let style = config.widgets[size] ?? WidgetStyle()
        let one = config.servers.filter { $0.id == style.server }
        return (style, one.isEmpty ? config.servers : one)
    }

    private func fetch(_ context: Context) -> Entry {
        let config = Store.load() ?? Config()
        let (style, servers) = pick(config, size(context))
        var results = [Stats](repeating: Stats(), count: servers.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: servers.count) { i in
            let s = Self.stats(servers[i])
            lock.withLock { results[i] = s }
        }
        return Entry(size: size(context), style: style, servers: results)
    }

    /// One short SSH session: ~3 s of samples plus the update count.
    private static func stats(_ server: ServerConfig) -> Stats {
        var parser = StatsParser(Stats(id: server.id, name: server.name))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -F /dev/null: ~/.ssh/config may include files the sandbox can't read; the app resolved it for us.
        p.arguments = ["-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                       "-o", "UserKnownHostsFile=\(realHome)/.ssh/known_hosts"]
            + (server.resolved ?? server.ssh.split(separator: " ").map(String.init)) + [Remote.snapshot]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return parser.stats }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        text.split(separator: "\n").forEach { _ = parser.feed(String($0)) }
        parser.stats.online = parser.stats.online && !parser.stats.cpu.isEmpty
        return parser.stats
    }

    private func sample(_ context: Context) -> Entry {
        let config = Store.load() ?? Config()
        let (style, servers) = pick(config, size(context))
        let names = servers.isEmpty ? ["server"] : servers.map(\.name)
        let demo = names.enumerated().map { i, name in
            let wave = (0..<12).map { 30 + 12 * sin(Double($0) * 0.9 + Double(i)) }
            return Stats(id: "", name: name, online: true, cpu: wave, mem: wave.map { $0 + 25 },
                         down: wave.map { $0 / 2 }, up: wave.map { $0 / 5 }, memUsed: 19.5, memTotal: 32,
                         diskUsed: 580, diskTotal: 1000, diskFree: 420, uptime: 1_036_800, updates: 0)
        }
        return Entry(size: size(context), style: style, servers: demo)
    }
}
