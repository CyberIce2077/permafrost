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
    private var mediumOne: Bool { size == "M" && !multi && entry.ask == nil && !entry.servers.isEmpty }
    private var stats: [Metric] {
        let cap = Design.caps(size: size, style: d.style, controls: d.controls, multi: multi).stats
        return Array(d.stats.compactMap { metrics[$0] }.prefix(cap))
    }

    var body: some View {
        content
            .padding(mediumOne ? EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 14) : EdgeInsets(top: small ? 14 : 16, leading: small ? 14 : 16, bottom: small ? 14 : 16, trailing: small ? 14 : 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                ZStack {
                    L.bg
                    ContainerRelativeShape().strokeBorder(L.border, lineWidth: 1)
                }
            }
            .widgetURL(URL(string: entry.ask != nil ? "permafrost://widgets" : "permafrost://open?id=\(entry.servers.first?.id ?? "")"))
    }

    @ViewBuilder private var content: some View {
        if let why = entry.ask {
            ask(why)
        } else if entry.servers.isEmpty || stats.isEmpty {
            Text(entry.servers.isEmpty ? "Add a server in Permafrost" : "Pick at least one stat")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(L.sub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if multi {
            table
        } else if size == "M" {
            medium(entry.servers[0])
        } else {
            single(entry.servers[0])
        }
    }

    /// No design to show: none picked yet, its design was deleted, or there are none. Clicking opens Custom Widgets.
    private func ask(_ why: String) -> some View {
        let box: CGFloat = small ? 36 : 44
        let (title, body, short) = switch why {
        case "create": ("Create a design", "Make a \(sizeName) design in Permafrost › Custom Widgets, then pick it with right‑click › Edit Widget.", "Open Permafrost")
        case "gone": ("Design deleted", "This widget's design was deleted. Right‑click › Edit Widget to pick another.", "Right‑click › Edit Widget")
        case "resized": ("Design resized", "This widget's design is now another size. Right‑click › Edit Widget to pick a \(sizeName) one.", "Right‑click › Edit Widget")
        default: ("Choose a design", "Right‑click this widget › Edit Widget and pick one of your designs from Permafrost.", "Right‑click › Edit Widget")
        }
        return VStack(spacing: small ? 6 : 8) {
            RoundedRectangle(cornerRadius: box * 11 / 36)
                .fill(LinearGradient(colors: [hex(0xFFC46B), hex(0xFF9500)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(DesignsGlyph().stroke(.white, style: StrokeStyle(lineWidth: 2 * box / 36, lineJoin: .round)).frame(width: box / 2, height: box / 2))
                .frame(width: box, height: box)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: small ? 14 : 16, weight: .bold))
                .foregroundStyle(L.text)
            Text(small ? short : body)
                .font(.system(size: small ? 11 : 12, weight: .medium))
                .foregroundStyle(L.sub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .textShadow(L)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sizeName: String { ["S": "Small", "M": "Medium", "L": "Large", "XL": "Extra Large"][size] ?? "" }

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
                        Circle().fill(dot(s)).frame(width: 6, height: 6)
                        Text(pendingText(s) ?? (!s.online ? "Offline" : reboot(s) ? "Restart required" : small ? "Online" : "Online · up " + uptime(s.uptime)))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(s))
                    .lineLimit(1)
                }
                .textShadow(L)
                Spacer(minLength: 0)
                if ctl { controls(s, 40) }
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

    // MARK: Medium, one server (design: Widgets › iceserver medium widget)

    private func medium(_ s: Stats) -> some View {
        let n = stats.count
        let cols = d.style == "rings" || d.style == "numbers" ? min(4, n) : min(2, n)
        let rows = stride(from: 0, to: n, by: max(1, cols)).map { Array(stats[$0..<min($0 + max(1, cols), n)]) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // The app's server icon (sidebar), at 32 pt.
                RoundedRectangle(cornerRadius: 10)
                    .fill(serverColor(s.color))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 0.5).mask(alignment: .top) { Rectangle().frame(height: 1) })
                    .overlay(ServerGlyph().stroke(.white, style: StrokeStyle(lineWidth: 1.8 * 18 / 24, lineCap: .round, lineJoin: .round)).frame(width: 18, height: 18))
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 14, weight: .bold)).foregroundStyle(L.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(dot(s)).frame(width: 6, height: 6)
                        Text(pendingText(s) ?? (!s.online ? "Offline" : reboot(s) ? "Restart required" : "Online · up " + uptime(s.uptime)))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(s))
                    .lineLimit(1)
                }
                .textShadow(L)
                Spacer(minLength: 0)
                if d.controls { controls(s, 34) }
            }
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(rows[r], id: \.key) { m in
                            if d.style == "bars" { mediumTile(m, s) } else { tile(m, s) }
                        }
                        ForEach(0..<(cols - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Restart, Update and Power as round buttons next to the name (design: Widgets › update button states).
    private func controls(_ s: Stats, _ px: CGFloat) -> some View {
        let updates = s.updates ?? 0
        let glow = { (c: Color, on: Bool) in Circle().fill(c).shadow(color: on ? c.opacity(0.35) : .clear, radius: 5, y: 3) }
        return HStack(spacing: 6) {
            act("restart", s) {
                let hot = reboot(s) || pending("restart", s)
                Icon.restart.view(15, hot ? .white : L.text, 2.3)
                    .frame(width: px, height: px)
                    .background(glow(hot ? restartOrange : L.btnBg, hot))
                    .overlay(Circle().strokeBorder(pending("restart", s) ? .white : hot ? .clear : L.border, lineWidth: pending("restart", s) ? 2 : 1))
            }
            .accessibilityLabel(reboot(s) ? "Restart \(s.name), restart required" : "Restart \(s.name)")
            .opacity(s.online ? 1 : 0.45)

            switch s.phase {
            case "updating":
                ZStack {
                    Circle().fill(hex(0x5E5CE6))
                    Circle().stroke(.white.opacity(0.3), lineWidth: 2.5).padding(3)
                    Circle().trim(from: 0, to: Double(s.progress ?? 0) / 100)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90)).padding(3)
                    Icon.download.view(12, .white, 2.3)
                }
                .frame(width: px, height: px)
                .accessibilityLabel("Installing updates, \(s.progress ?? 0)%")
            case "checking":
                Spinner().stroke(hex(0x0066CC), style: StrokeStyle(lineWidth: 2.8 * 15 / 24, lineCap: .round))
                    .frame(width: 15, height: 15)
                    .frame(width: px, height: px)
                    .background(Circle().fill(rgba(0, 102, 204, 0.12)))
                    .overlay(Circle().strokeBorder(rgba(0, 102, 204, 0.25), lineWidth: 1))
                    .accessibilityLabel("Checking for updates")
            default:
                if !s.online || entry.locked {
                    Icon.download.view(15, .white, 2.3)
                        .frame(width: px, height: px)
                        .background(Circle().fill(rgba(120, 120, 128, 0.45)))
                        .opacity(0.6)
                        .accessibilityLabel("Updates unavailable")
                } else if updates > 0 {
                    act("install", s) {
                        Icon.download.view(15, .white, 2.3)
                            .frame(width: px, height: px)
                            .background(glow(hex(0x0066CC), true))
                            .overlay(ring(pending("install", s)))
                            .overlay(alignment: .topTrailing) {
                                Text("\(updates)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(hex(0xFF3B30)))
                                    .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
                                    .offset(x: 5, y: -4)
                            }
                    }
                    .accessibilityLabel("\(updates) updates available")
                } else {
                    act("check", s) {
                        CheckMark().stroke(hex(0x248A3D), style: StrokeStyle(lineWidth: 2.8 * 15 / 24, lineCap: .round, lineJoin: .round))
                            .frame(width: 15, height: 15)
                            .frame(width: px, height: px)
                            .background(Circle().fill(pending("check", s) ? hex(0x0066CC).opacity(0.18) : L.btnBg))
                            .overlay(Circle().strokeBorder(pending("check", s) ? hex(0x0066CC) : L.border, lineWidth: pending("check", s) ? 2 : 1))
                    }
                    .accessibilityLabel("Up to date, check again")
                }
            }

            power(s, px)
        }
    }

    /// The Medium widget's compact bar tile.
    private func mediumTile(_ m: Metric, _ s: Stats) -> some View {
        let (v, text, _) = reading(m, s)
        return VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(m.key == "temp" ? m.short : m.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(L.sub).lineLimit(1)
                Spacer(minLength: 0)
                Text(text).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(L.text).lineLimit(1).minimumScaleFactor(0.6)
            }
            .textShadow(L)
            Bar(value: v, height: 5, track: L.track, color: warn(m, v) ? orange : m.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(L.tile))
    }

    /// The app's server icon colors (Resources/common.js › SERVER_COLORS).
    private func serverColor(_ name: String?) -> LinearGradient {
        let (a, b) = switch name {
        case "teal": (0x6EE0D0, 0x0A7C86)
        case "purple": (0xB9A6FF, 0x5E5CE6)
        case "orange": (0xFFC46B, 0xE06A00)
        case "pink": (0xFF9EC0, 0xC2185B)
        case "graphite": (0xC7C7CC, 0x636366)
        default: (0x5AC8FA, 0x0A64D6)
        }
        return LinearGradient(colors: [hex(a), hex(b)], startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
    }

    // MARK: Several servers

    private var table: some View {
        let more = entry.total - entry.servers.count
        return VStack(alignment: .leading, spacing: small ? 8 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(d.name.isEmpty ? "Servers" : d.name).font(titleFont).foregroundStyle(L.text).lineLimit(1)
                Spacer(minLength: 0)
                let n = entry.restarts
                let asking = entry.servers.first { pendingText($0) != nil }
                Text(asking.map { "\(pendingText($0)!) \($0.name)" }
                     ?? (small ? (n > 0 ? "\(n) to restart" : "\(entry.online)/\(entry.total) online")
                         : "\(entry.online) of \(entry.total) online" + (n > 0 ? " · \(n) need\(n == 1 ? "s" : "") restart" : "")))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(asking != nil || (small && n > 0) ? (d.look == "glass" ? hex(0xA34700) : hex(0xFFC46B)) : L.sub).lineLimit(1)
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
                    Circle().fill(dot(s)).frame(width: 7, height: 7)
                    Text(s.name).font(.system(size: big ? 13 : 12, weight: .bold)).foregroundStyle(L.text).lineLimit(1).textShadow(L)
                    if reboot(s) && !small {
                        Icon.restart.view(12, d.look == "glass" ? hex(0xC25A00) : hex(0xFFC46B), 2.8)
                            .accessibilityLabel("Restart required")
                    }
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
        act("power", s) {
            Icon.power.view(16, .white, 2.2)
                .frame(width: px, height: px)
                .background(Circle().fill(pending("power", s) ? (s.online ? hex(0xFF3B30) : hex(0x248A3D)) : s.online ? hex(0x248A3D) : rgba(120, 120, 128, 0.45)))
                .overlay(Circle().strokeBorder(pending("power", s) ? .white : .clear, lineWidth: 2))
        }
        .accessibilityLabel("Turn \(s.name) \(s.online ? "off" : "on")")
    }

    /// Waiting for a restart to finish installing updates (/var/run/reboot-required on the server).
    private func reboot(_ s: Stats) -> Bool { s.online && s.rebootSince != nil }
    private var restartOrange: Color { hex(0xE07800) }
    private func dot(_ s: Stats) -> Color { pendingText(s) != nil || reboot(s) ? hex(0xFF9500) : !s.online ? hex(0x8E8E93) : hex(0x30D158) }
    private func statusColor(_ s: Stats) -> Color {
        pendingText(s) != nil || (s.online && reboot(s)) ? (d.look == "glass" ? hex(0xA34700) : hex(0xFFC46B)) : !s.online ? L.sub : L.ok
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

    /// A button that runs `action` on `s` in the background (Actions.swift), without opening the app.
    /// Every button waits for a second click (Actions.swift).
    private func act<Label: View>(_ action: String, _ s: Stats, @ViewBuilder _ label: () -> Label) -> some View {
        Button(intent: ServerAction(action, s.id, confirm: true), label: label).buttonStyle(.plain)
    }

    private func pending(_ action: String, _ s: Stats) -> Bool { entry.pending?.matches(action, s.id) == true }

    private func pendingText(_ s: Stats) -> String? {
        guard let p = entry.pending, p.server == s.id else { return nil }
        switch p.action {
        case "restart": return "Click again to restart"
        case "power": return s.online ? "Click again to turn off" : "Click again to turn on"
        case "install": return "Click again to update"
        default: return "Click again to check"
        }
    }

    /// The white ring on a button waiting for its second click.
    private func ring(_ on: Bool) -> some View { Circle().strokeBorder(on ? .white : .clear, lineWidth: 2) }

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

/// M5 12l5 5 9-10
private struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 5 * k, y: 12 * k)); p.addLine(to: CGPoint(x: 10 * k, y: 17 * k)); p.addLine(to: CGPoint(x: 19 * k, y: 7 * k))
        return p
    }
}

/// The app's spinner arc, M12 3a9 9 0 1 0 9 9 (widgets can't animate, so it stands still).
private struct Spinner: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        var p = Path()
        p.addArc(center: CGPoint(x: 12 * k, y: 12 * k), radius: 9 * k, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: true)
        return p
    }
}

/// The app's server symbol (common.js › ICON.server): two racks with a light each, 24×24.
private struct ServerGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        var p = Path()
        for y in [4.0, 13.0] {
            p.addRoundedRect(in: CGRect(x: 3 * k, y: y * k, width: 18 * k, height: 7 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k))
            p.move(to: CGPoint(x: 7 * k, y: (y + 3.5) * k))
            p.addLine(to: CGPoint(x: 7.01 * k, y: (y + 3.5) * k))
        }
        return p
    }
}

/// The Custom Widgets glyph from the main window's sidebar card (24×24: two squares over a bar).
private struct DesignsGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        var p = Path()
        for (x, y, w) in [(3.0, 3.0, 8.0), (13, 3, 8), (3, 13, 18)] {
            p.addRoundedRect(in: CGRect(x: x * k, y: y * k, width: w * k, height: 8 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k))
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
        case .power:  // M12 3v8 · M6.4 6.6a8 8 0 1 0 11.2 0
            p.move(to: pt(12, 3)); p.addLine(to: pt(12, 11))
            arc(&p, cx: 12, cy: 12.313, from: -134.43, by: -271.15)
        case .restart:  // M20 11a8 8 0 1 0-2.3 5.7 · M20 4v7h-7
            arc(&p, cx: 12, cy: 11.086, from: -0.62, by: -314.82)
            p.move(to: pt(20, 4)); p.addLine(to: pt(20, 11)); p.addLine(to: pt(13, 11))
        case .download:  // M12 4v11 · M7 10l5 5 5-5 · M5 20h14
            p.move(to: pt(12, 4)); p.addLine(to: pt(12, 15))
            p.move(to: pt(7, 10)); p.addLine(to: pt(12, 15)); p.addLine(to: pt(17, 10))
            p.move(to: pt(5, 20)); p.addLine(to: pt(19, 20))
        }
        return p
    }
}
