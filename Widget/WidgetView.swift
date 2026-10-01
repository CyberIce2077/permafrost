import SwiftUI
import WidgetKit

// A SwiftUI port of the widget in Resources/widget.js (which draws the preview in Widget Settings).

private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

private func hex(_ v: Int) -> Color {
    rgba(Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
}

private let blue = hex(0x0066CC)

struct Look {
    var bg, border, text, sub, tile, track, ok, btnBg: Color
    var shadow = false

    static func named(_ name: String) -> Look {
        switch name {
        case "tinted":
            Look(bg: rgba(16, 52, 104, 0.62), border: rgba(255, 255, 255, 0.28), text: .white, sub: rgba(255, 255, 255, 0.8),
                 tile: rgba(255, 255, 255, 0.12), track: rgba(255, 255, 255, 0.22), ok: hex(0x8CF5AE), btnBg: rgba(255, 255, 255, 0.16))
        case "clear":
            Look(bg: rgba(255, 255, 255, 0.14), border: rgba(255, 255, 255, 0.55), text: .white, sub: rgba(255, 255, 255, 0.9),
                 tile: rgba(255, 255, 255, 0.14), track: rgba(255, 255, 255, 0.3), ok: hex(0xA6FFC2), btnBg: rgba(255, 255, 255, 0.18), shadow: true)
        default:
            Look(bg: rgba(255, 255, 255, 0.64), border: rgba(255, 255, 255, 0.8), text: hex(0x1D1D1F), sub: hex(0x4A4A4F),
                 tile: rgba(255, 255, 255, 0.6), track: rgba(120, 120, 128, 0.2), ok: hex(0x1E7A34), btnBg: rgba(255, 255, 255, 0.75))
        }
    }
}

private struct Metric {
    let key, label: String
    let color: Color
}

private let allMetrics = [
    Metric(key: "cpu", label: "CPU", color: hex(0x0A84FF)),
    Metric(key: "mem", label: "Memory", color: hex(0x5E5CE6)),
    Metric(key: "net", label: "Network", color: hex(0xFF9F0A)),
    Metric(key: "disk", label: "Disk", color: hex(0x34C759)),
]

struct WidgetView: View {
    let entry: Entry

    private var L: Look { Look.named(entry.style.look) }
    private var size: String { entry.size }
    private var small: Bool { size == "S" }
    private var many: Bool { entry.servers.count > 1 }
    private var row: Bool { many && (size == "M" || size == "XL") }

    private var shown: [Metric] {
        let cap = ["S": many ? 1 : 2, "M": many ? 2 : 4, "L": many ? 2 : 4, "XL": 4][size] ?? 2
        return Array(allMetrics.filter { entry.style.metrics[$0.key] ?? true }.prefix(cap))
    }

    private var cols: Int {
        let n = shown.count, bars = entry.style.style == "bars"
        switch size {
        case "S": return bars ? 1 : min(2, n)
        case "M": return many ? (bars ? 1 : min(2, n)) : min(bars ? 2 : 4, n)
        default: return min(2, n)
        }
    }

    var body: some View {
        content
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
        if entry.servers.isEmpty {
            Text("Add a server in Ice Servers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(L.sub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let layout = row ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                ForEach(entry.servers.indices, id: \.self) { i in
                    column(entry.servers[i])
                        .padding(.leading, row && i > 0 ? 16 : 0)
                        .overlay(alignment: .leading) {
                            if row && i > 0 {
                                Rectangle().fill(entry.style.look == "glass" ? rgba(60, 60, 67, 0.14) : rgba(255, 255, 255, 0.25)).frame(width: 1)
                            }
                        }
                }
            }
            .padding(small ? 14 : 16)
        }
    }

    private func column(_ s: Stats) -> some View {
        VStack(alignment: .leading, spacing: small ? 8 : 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                        .font(.system(size: small ? 14 : 15, weight: .bold))
                        .foregroundStyle(L.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(s.online ? hex(0x30D158) : hex(0x8E8E93)).frame(width: 6, height: 6)
                        Text(s.online ? "Online · up " + uptime(s.uptime) : "Offline")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(s.online ? L.ok : entry.style.look == "glass" ? hex(0x56565B) : L.sub)
                    .lineLimit(1)
                }
                .textShadow(L)
                Spacer(minLength: 0)
                if size == "L" || size == "XL" {
                    Link(destination: link("power", s)) {
                        Icon.power.view(18, .white, 2.2)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(s.online ? hex(0x248A3D) : rgba(120, 120, 128, 0.5)))
                            .shadow(color: s.online ? rgba(36, 138, 61, 0.35) : .clear, radius: 6, y: 4)
                    }
                    .accessibilityLabel("Turn \(s.name) \(s.online ? "off" : "on")")
                }
            }
            grid(s)
            if size == "XL" || (size == "L" && !many) {
                HStack(spacing: 10) {
                    Link(destination: link("restart", s)) {
                        HStack(spacing: 7) { Icon.restart.view(15, L.text, 2.2); Text("Restart") }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(L.text)
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                            .background(Capsule().fill(L.btnBg))
                            .overlay(Capsule().strokeBorder(L.border, lineWidth: 1))
                    }
                    Link(destination: link((s.updates ?? 0) > 0 ? "install" : "check", s)) {
                        HStack(spacing: 7) {
                            Icon.download.view(15, .white, 2.2)
                            Text((s.updates ?? 0) > 0 ? "\(s.updates!) Update\(s.updates == 1 ? "" : "s")" : "Check")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .background(Capsule().fill(blue))
                        .shadow(color: rgba(0, 102, 204, 0.3), radius: 6, y: 4)
                    }
                }
                .opacity(s.online ? 1 : 0.45)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func grid(_ s: Stats) -> some View {
        let n = max(1, cols)
        let rows = stride(from: 0, to: shown.count, by: n).map { Array(shown[$0..<min($0 + n, shown.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r], id: \.key) { tile($0, s) }
                    ForEach(0..<(n - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tile(_ m: Metric, _ s: Stats) -> some View {
        let netMax = max(1, (s.down + s.up).max() ?? 1)
        let history: [Double] = switch m.key {
        case "cpu": s.cpu
        case "mem": s.mem
        case "net": s.down.map { $0 / netMax * 100 }
        default: s.cpu.map { _ in s.disk }
        }
        let value = s.online ? history.last ?? 0 : 0
        let reading: String = switch m.key {
        case "cpu": "\(Int((s.cpu.last ?? 0).rounded()))%"
        case "mem": String(format: "%.1f GB", s.memUsed)
        case "net": rate(s.down.last ?? 0)
        default: "\(Int(s.disk.rounded()))%"
        }
        let text = s.online ? reading : "—"
        let label = Text(m.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(L.sub).lineLimit(1).textShadow(L)
        let valueText = Text(text)
            .font(.system(size: entry.style.style == "rings" || small ? 13 : 16, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(L.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .textShadow(L)

        return Group {
            switch entry.style.style {
            case "rings":
                VStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(L.track, lineWidth: 5.98)
                        Circle().trim(from: 0, to: min(value, 100) / 100)
                            .stroke(m.color, style: StrokeStyle(lineWidth: 5.98, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 34.96, height: 34.96)
                    .frame(width: 46, height: 46)
                    valueText
                    label
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case "graph":
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { label; Spacer(minLength: 0); valueText }
                    Sparkline(values: s.online ? history : history.map { _ in 0 })
                        .stroke(m.color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .frame(minHeight: 20)
                }
                .frame(maxHeight: .infinity)
            default:
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { label; Spacer(minLength: 0); valueText }
                    Capsule().fill(L.track).frame(height: 6)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in
                                Capsule()
                                    .fill(m.key == "disk" && value > 80 ? hex(0xFF9F0A) : m.color)
                                    .frame(width: g.size.width * min(value, 100) / 100)
                            }
                        }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, small ? 8 : 10)
        .padding(.vertical, small ? 6 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(L.tile))
    }

    private func link(_ action: String, _ s: Stats) -> URL {
        URL(string: "iceservers://\(action)?id=\(s.id)")!
    }

    private func uptime(_ sec: Double) -> String {
        sec < 60 ? "<1m" : sec < 3600 ? "\(Int(sec / 60))m" : sec < 86400 ? "\(Int(sec / 3600))h" : "\(Int(sec / 86400))d"
    }

    private func rate(_ v: Double) -> String {
        (v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))) + " MB/s"
    }
}

private extension View {
    func textShadow(_ L: Look) -> some View {
        shadow(color: L.shadow ? .black.opacity(0.4) : .clear, radius: 1.5, y: 1)
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

/// The design's 24×24 stroke icons.
private enum Icon {
    case power, restart, download

    func view(_ px: CGFloat, _ color: Color, _ width: CGFloat) -> some View {
        IconShape(icon: self)
            .stroke(color, style: StrokeStyle(lineWidth: width * px / 24, lineCap: .round, lineJoin: .round))
            .frame(width: px, height: px)
    }
}

private struct IconShape: Shape {
    let icon: Icon

    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        func arc(_ p: inout Path, cx: Double, cy: Double, from start: Double, by delta: Double) {
            for i in 0...48 {
                let a = (start + delta * Double(i) / 48) * .pi / 180
                let q = pt(cx + 8 * cos(a), cy + 8 * sin(a))
                i == 0 ? p.move(to: q) : p.addLine(to: q)
            }
        }
        var p = Path()
        switch icon {
        case .power:
            p.move(to: pt(12, 3)); p.addLine(to: pt(12, 11))
            arc(&p, cx: 12, cy: 12.313, from: -134.43, by: -271.15)
        case .restart:
            arc(&p, cx: 12, cy: 11.086, from: -0.62, by: -314.82)
            p.move(to: pt(20, 4)); p.addLine(to: pt(20, 11)); p.addLine(to: pt(13, 11))
        case .download:
            p.move(to: pt(12, 4)); p.addLine(to: pt(12, 15))
            p.move(to: pt(7, 10)); p.addLine(to: pt(12, 15)); p.addLine(to: pt(17, 10))
            p.move(to: pt(5, 20)); p.addLine(to: pt(19, 20))
        }
        return p
    }
}
