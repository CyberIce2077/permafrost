import SwiftUI
import WidgetKit

// A SwiftUI port of the widget in Resources/widget.js (the design's Settings › Widgets renderer).

private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

private func hex(_ v: Int) -> Color {
    rgba(Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
}

private let orange = hex(0xFF9F0A)

struct Look {
    var bg, border, text, sub, tile, track, ok, btnBg: Color
    var shadow = false

    static func named(_ name: String) -> Look {
        switch name {
        case "tinted":
            Look(bg: rgba(16, 52, 104, 0.66), border: rgba(255, 255, 255, 0.28), text: .white, sub: rgba(255, 255, 255, 0.82),
                 tile: rgba(255, 255, 255, 0.12), track: rgba(255, 255, 255, 0.22), ok: hex(0x8CF5AE), btnBg: rgba(255, 255, 255, 0.16))
        case "clear":
            Look(bg: rgba(255, 255, 255, 0.14), border: rgba(255, 255, 255, 0.55), text: .white, sub: rgba(255, 255, 255, 0.92),
                 tile: rgba(255, 255, 255, 0.14), track: rgba(255, 255, 255, 0.3), ok: hex(0xA6FFC2), btnBg: rgba(255, 255, 255, 0.18), shadow: true)
        default:
            Look(bg: rgba(255, 255, 255, 0.64), border: rgba(255, 255, 255, 0.8), text: hex(0x1D1D1F), sub: hex(0x4A4A4F),
                 tile: rgba(255, 255, 255, 0.6), track: rgba(120, 120, 128, 0.2), ok: hex(0x1E7A34), btnBg: rgba(255, 255, 255, 0.8))
        }
    }
}

private struct Metric {
    let key, label, short: String
    let color: Color
}

private let metrics: [String: Metric] = [
    "cpu": Metric(key: "cpu", label: "CPU", short: "CPU", color: hex(0x0A84FF)),
    "mem": Metric(key: "mem", label: "Memory", short: "RAM", color: hex(0x5E5CE6)),
    "net": Metric(key: "net", label: "Network", short: "Net", color: hex(0xFF9F0A)),
    "disk": Metric(key: "disk", label: "Disk", short: "Disk", color: hex(0x34C759)),
    "temp": Metric(key: "temp", label: "Temperature", short: "Temp", color: hex(0xFF453A)),
]

struct WidgetView: View {
    let entry: Entry

    private var d: Design { entry.design }
    private var L: Look { Look.named(d.look) }
    private var size: String { entry.size }
    private var small: Bool { size == "S" }
    private var big: Bool { size == "L" || size == "XL" }
    private var ctl: Bool { d.controls && big }
    private var multi: Bool { entry.total > 1 }
    private var stats: [Metric] {
        let cap = Design.caps(size: size, style: d.style, controls: d.controls, multi: multi).stats
        return Array(d.stats.compactMap { metrics[$0] }.prefix(cap))
    }

    var body: some View {
        content
            .padding(small ? 14 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                ZStack {
                    L.bg
                    ContainerRelativeShape().strokeBorder(L.border, lineWidth: 1)
                }
            }
            .widgetURL(URL(string: "iceservers://open?id=\(entry.servers.first?.id ?? "")"))
    }

    @ViewBuilder private var content: some View {
        if entry.servers.isEmpty || stats.isEmpty {
            Text(entry.servers.isEmpty ? "Add a server in Ice Servers" : "Pick at least one stat")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(L.sub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if multi {
            table
        } else {
            single(entry.servers[0])
        }
    }

    private var titleFont: Font { .system(size: size == "XL" ? 17 : small ? 13 : 15, weight: .bold) }

    // MARK: One server

    private func single(_ s: Stats) -> some View {
        let n = stats.count, bars = d.style == "bars"
        let cols = small ? (bars ? 1 : min(2, n)) : size == "M" ? (bars ? min(2, n) : min(4, n)) : size == "L" ? min(2, n) : min(3, n)
        let rows = stride(from: 0, to: n, by: max(1, cols)).map { Array(stats[$0..<min($0 + max(1, cols), n)]) }
        return VStack(alignment: .leading, spacing: small ? 8 : 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(titleFont).foregroundStyle(L.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(s.online ? hex(0x30D158) : hex(0x8E8E93)).frame(width: 6, height: 6)
                        Text(!s.online ? "Offline" : small ? "Online" : "Online · up " + uptime(s.uptime))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(s.online ? L.ok : L.sub)
                    .lineLimit(1)
                }
                .textShadow(L)
                Spacer(minLength: 0)
                if ctl { power(s, 40) }
            }
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(rows[r], id: \.key) { tile($0, s) }
                        ForEach(0..<(cols - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if ctl {
                HStack(spacing: 10) {
                    Link(destination: link("restart", s)) {
                        Text("Restart")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(L.text)
                            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                            .background(Capsule().fill(L.btnBg))
                            .overlay(Capsule().strokeBorder(L.border, lineWidth: 1))
                    }
                    Link(destination: link((s.updates ?? 0) > 0 ? "install" : "check", s)) {
                        Text((s.updates ?? 0) > 0 ? "\(s.updates!) Update\(s.updates == 1 ? "" : "s")" : "Check Updates")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                            .background(Capsule().fill(hex(0x0066CC)))
                    }
                }
                .opacity(s.online ? 1 : 0.45)
            }
        }
    }

    private func tile(_ m: Metric, _ s: Stats) -> some View {
        let (v, text, history) = reading(m, s)
        let label = Text(small ? m.short : m.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(L.sub).lineLimit(1).textShadow(L)
        let value = Text(text).font(.system(size: d.style == "rings" || small ? 13 : 16, weight: .bold)).monospacedDigit()
            .foregroundStyle(L.text).lineLimit(1).minimumScaleFactor(0.6).textShadow(L)
        return Group {
            switch d.style {
            case "rings":
                VStack(spacing: 3) {
                    Ring(value: v, track: L.track, color: m.color, box: 44, radius: 38, width: 13, round: true)
                    value
                    label
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case "graph":
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { label; Spacer(minLength: 0); value }
                    Sparkline(values: history).stroke(m.color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .frame(minHeight: 18)
                }
                .frame(maxHeight: .infinity)
            case "numbers":
                VStack(alignment: .leading, spacing: 2) {
                    label
                    Text(text).font(.system(size: small ? 22 : 28, weight: .bold)).kerning(small ? -0.44 : -0.56).monospacedDigit()
                        .foregroundStyle(warn(m, v) && s.online ? orange : L.text).lineLimit(1).minimumScaleFactor(0.5).textShadow(L)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            default:
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { label; Spacer(minLength: 0); value }
                    Bar(value: v, height: 6, track: L.track, color: warn(m, v) ? orange : m.color)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, small ? 8 : 10)
        .padding(.vertical, small ? 5 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(L.tile))
    }

    // MARK: Several servers

    private var table: some View {
        let more = entry.total - entry.servers.count
        return VStack(alignment: .leading, spacing: small ? 8 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(d.name.isEmpty ? "Servers" : d.name).font(titleFont).foregroundStyle(L.text).lineLimit(1)
                Spacer(minLength: 0)
                Text(small ? "\(entry.online)/\(entry.total) online" : "\(entry.online) of \(entry.total) online")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(L.sub).lineLimit(1)
            }
            .textShadow(L)
            // Large and Extra Large rows share the height, up to 66 pt each.
            VStack(spacing: big ? 6 : 4) {
                ForEach(entry.servers.indices, id: \.self) { row(entry.servers[$0]) }
            }
            .frame(maxHeight: big ? .infinity : nil, alignment: .top)
            if more > 0 {
                Text("+\(more) more").font(.system(size: 11, weight: .semibold)).foregroundStyle(L.sub).textShadow(L)
            }
        }
    }

    private func row(_ s: Stats) -> some View {
        let height: CGFloat = size == "XL" ? 52 : big ? 50 : 22
        return GeometryReader { g in
            let pad: CGFloat = big ? 12 : 0
            let gaps = CGFloat(stats.count + (ctl ? 1 : 0)) * 10
            let unit = (g.size.width - 2 * pad - gaps - (ctl ? 40 : 0)) / (1.3 + CGFloat(stats.count))
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(s.online ? hex(0x30D158) : hex(0x8E8E93)).frame(width: 7, height: 7)
                    Text(s.name).font(.system(size: big ? 13 : 12, weight: .bold)).foregroundStyle(L.text).lineLimit(1).textShadow(L)
                }
                .frame(width: unit * 1.3, alignment: .leading)
                ForEach(stats, id: \.key) { cell(s, $0).frame(width: unit, alignment: .leading) }
                if ctl { power(s, 36).frame(width: 40) }
            }
            .padding(.horizontal, pad)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(big ? L.tile : .clear))
        }
        .frame(minHeight: height, maxHeight: big ? 66 : height)
    }

    @ViewBuilder private func cell(_ s: Stats, _ m: Metric) -> some View {
        let (v, text, history) = reading(m, s)
        let live = s.online || m.key == "disk"
        let value = Text(text).font(.system(size: big ? 12 : 11, weight: .bold)).monospacedDigit()
            .foregroundStyle(live ? (warn(m, v) && d.style == "numbers" ? orange : L.text) : L.sub)
            .lineLimit(1).minimumScaleFactor(0.7).textShadow(L)
        if d.style == "rings" && !small && live {
            HStack(spacing: 5) {
                Ring(value: v, track: L.track, color: m.color, box: 18, radius: 36, width: 18, round: false)
                value
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                value
                if d.style == "bars" && !small && live {
                    Bar(value: v, height: 5, track: L.track, color: warn(m, v) ? orange : m.color)
                }
                if d.style == "graph" && !small && s.online {
                    Sparkline(values: history).stroke(m.color, lineWidth: 2).frame(height: 14)
                }
            }
        }
    }

    // MARK: Pieces

    private func power(_ s: Stats, _ px: CGFloat) -> some View {
        Link(destination: link("power", s)) {
            Icon.power.view(16, .white, 2.2)
                .frame(width: px, height: px)
                .background(Circle().fill(s.online ? hex(0x248A3D) : rgba(120, 120, 128, 0.45)))
        }
        .accessibilityLabel("Turn \(s.name) \(s.online ? "off" : "on")")
    }

    private func warn(_ m: Metric, _ value: Double) -> Bool {
        (m.key == "disk" && value > 80) || (m.key == "temp" && value >= 70)
    }

    /// One stat: its 0–100 value for bars and rings, its text, and its history for graphs.
    private func reading(_ m: Metric, _ s: Stats) -> (Double, String, [Double]) {
        if !s.online {
            let disk = s.diskTotal > 0
            return m.key == "disk" && disk ? (s.disk, "\(Int(s.disk.rounded()))%", []) : (0, "—", [])
        }
        let netMax = max(1, (s.down + s.up).max() ?? 1)
        let temp = s.temp.last
        switch m.key {
        case "cpu": return (s.cpu.last ?? 0, "\(Int((s.cpu.last ?? 0).rounded()))%", s.cpu)
        case "mem": return (s.mem.last ?? 0, "\(Int((s.mem.last ?? 0).rounded()))%", s.mem)
        case "net": return ((s.down.last ?? 0) / netMax * 100, rate(s.down.last ?? 0), s.down.map { $0 / netMax * 100 })
        case "temp": return (temp ?? 0, temp.map(degrees) ?? "—", s.temp.count > 1 ? s.temp : s.cpu.map { _ in temp ?? 0 })
        default: return (s.disk, "\(Int(s.disk.rounded()))%", s.cpu.map { _ in s.disk })
        }
    }

    private func degrees(_ c: Double) -> String {
        entry.prefs.unit == "F" ? "\(Int((c * 9 / 5 + 32).rounded()))°F" : "\(Int(c.rounded()))°C"
    }

    private func link(_ action: String, _ s: Stats) -> URL {
        URL(string: "iceservers://\(action)?id=\(s.id)")!
    }

    private func uptime(_ sec: Double) -> String {
        sec < 60 ? "<1m" : sec < 3600 ? "\(Int(sec / 60))m" : sec < 86400 ? "\(Int(sec / 3600))h" : "\(Int(sec / 86400))d"
    }

    private func rate(_ mb: Double) -> String {
        let v = entry.prefs.net == "Mbit" ? mb * 8 : mb
        return (v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))) + (entry.prefs.net == "Mbit" ? " Mbit/s" : " MB/s")
    }
}

private extension View {
    func textShadow(_ L: Look) -> some View {
        shadow(color: L.shadow ? .black.opacity(0.45) : .clear, radius: 1.5, y: 1)
    }
}

private struct Bar: View {
    let value: Double, height: CGFloat
    let track, color: Color

    var body: some View {
        Capsule().fill(track).frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(color).frame(width: g.size.width * min(max(value, 0), 100) / 100) }
            }
    }
}

/// The design's SVG ring: a `box` px square with a 100-unit viewBox, circle radius and stroke in those units.
private struct Ring: View {
    let value: Double
    let track, color: Color
    let box, radius, width: CGFloat
    let round: Bool

    var body: some View {
        let k = box / 100
        ZStack {
            Circle().stroke(track, lineWidth: width * k)
            Circle().trim(from: 0, to: min(max(value, 0), 100) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: width * k, lineCap: round ? .round : .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 2 * radius * k, height: 2 * radius * k)
        .frame(width: box, height: box)
    }
}

/// The design's polyline: a 240×56 box with values 0–100 drawn between y 54 and 4.
private struct Sparkline: Shape {
    let values: [Double]

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: r.width * Double(i) / Double(values.count - 1),
                             y: r.height * (54 - min(max(v, 0), 100) / 100 * 50) / 56)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

/// The design's 24×24 stroke power icon.
private enum Icon {
    case power

    func view(_ px: CGFloat, _ color: Color, _ width: CGFloat) -> some View {
        IconShape()
            .stroke(color, style: StrokeStyle(lineWidth: width * px / 24, lineCap: .round, lineJoin: .round))
            .frame(width: px, height: px)
    }
}

/// M12 3v8 and the arc M6.4 6.6a8 8 0 1 0 11.2 0.
private struct IconShape: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        var p = Path()
        p.move(to: pt(12, 3)); p.addLine(to: pt(12, 11))
        for i in 0...48 {
            let a = (-134.43 - 271.15 * Double(i) / 48) * .pi / 180
            let q = pt(12 + 8 * cos(a), 12.313 + 8 * sin(a))
            i == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        return p
    }
}
