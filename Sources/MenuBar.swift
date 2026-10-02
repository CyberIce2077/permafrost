import AppKit

/// Settings › General › Show in menu bar: a status dot per server, and quick actions in its menu.
final class MenuBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?

    func show(_ on: Bool) {
        if on, item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.image = Self.glyph
            item?.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item?.menu = menu
        } else if !on, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        update()
    }

    private var servers: [Server] { ice.servers.filter { $0.cfg.menu ?? true } }

    private static func color(_ phase: String) -> NSColor {
        phase == "online" ? .systemGreen : phase == "off" ? .systemGray : .systemOrange
    }

    /// The dots next to the icon: one per server, colored by status.
    func update() {
        guard let button = item?.button else { return }
        let dots = NSMutableAttributedString()
        for s in servers {
            dots.append(NSAttributedString(string: "●", attributes: [.foregroundColor: Self.color(s.phase), .font: NSFont.systemFont(ofSize: 9)]))
        }
        button.attributedTitle = dots
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let locked = ice.lockedBy != nil
        for s in servers {
            let status = s.phase == "online" ? "Online" : s.phase == "off" ? "Offline" : s.phase == "timedout" ? "Not responding" : s.phase.capitalized + "…"
            let head = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: Self.color(s.phase)])
            head.append(NSAttributedString(string: s.cfg.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            head.append(NSAttributedString(string: "  \(status)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let title = NSMenuItem()
            title.attributedTitle = head
            title.isEnabled = false
            menu.addItem(title)

            func action(_ label: String, _ cmd: String, _ enabled: Bool) {
                let i = MenuAction(label) { ice.handle(["cmd": cmd, "id": s.cfg.id], from: ice.main) }
                i.indentationLevel = 1
                i.isEnabled = enabled && !locked
                menu.addItem(i)
            }
            let online = s.phase == "online", updates = s.parser.stats.updates ?? 0
            action("Restart", "restart", online)
            action(s.phase == "off" ? "Turn On" : "Turn Off", "power", online || (s.phase == "off" && s.cfg.mac != nil))
            action(updates > 0 ? "Install \(updates) Update\(updates == 1 ? "" : "s")" : "Check for Updates", updates > 0 ? "install" : "check", online)
            menu.addItem(.separator())
        }
        menu.autoenablesItems = false
        menu.addItem(MenuAction("Open Permafrost") { ice.showMain() })
        menu.addItem(MenuAction("Settings…") { ice.showSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Quit Permafrost") { NSApp.terminate(nil) })
    }

    /// The icon's menu bar version (design: Icons › 6 · Icicle Server): a server with icicles, as a template image.
    private static let glyph: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            let k = r.width / 24
            NSColor.black.set()
            let p = NSBezierPath(roundedRect: NSRect(x: 3 * k, y: 7 * k, width: 18 * k, height: 7 * k), xRadius: 2 * k, yRadius: 2 * k)
            p.move(to: NSPoint(x: 6 * k, y: 10.5 * k)); p.line(to: NSPoint(x: 13 * k, y: 10.5 * k))
            // Icicles: M7 14l1 4 1-4 · M12 14l1 6 1-6 · M17 14l.8 3 .8-3
            for (x, w, h) in [(7.0, 1.0, 4.0), (12, 1, 6), (17, 0.8, 3)] {
                p.move(to: NSPoint(x: x * k, y: 14 * k))
                p.line(to: NSPoint(x: (x + w) * k, y: (14 + h) * k))
                p.line(to: NSPoint(x: (x + 2 * w) * k, y: 14 * k))
            }
            p.lineWidth = 1.7 * k
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
            NSBezierPath(ovalIn: NSRect(x: 16.1 * k, y: 9.6 * k, width: 1.8 * k, height: 1.8 * k)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
