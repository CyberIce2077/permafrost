import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config()
    var servers: [Server] = []
    var main: Panel!
    var widgets: [String: Panel] = [:]
    var editor: Panel?
    private var renderQueued = false

    static let widgetSizes: [String: (w: CGFloat, h: CGFloat, r: CGFloat)] = [
        "S": (172, 172, 26), "M": (364, 172, 26), "L": (364, 384, 28), "XL": (748, 384, 30),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        if let saved = Store.load() {
            config = saved
        } else {
            config.servers = Store.shellAliases()
            config.widgets = [newWidget()]
        }
        servers = config.servers.map(Server.init)
        buildMenu()

        let win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
                            styleMask: [.borderless, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.minSize = NSSize(width: 960, height: 640)
        win.center()
        main = Panel(page: "app", window: win, radius: 28)
        win.makeKeyAndOrderFront(nil)

        config.widgets.forEach(openWidget)
        servers.forEach { $0.connect() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            self.servers.filter { $0.phase == "online" }.forEach { $0.countUpdates() }
        }
        save()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMain()
        return true
    }

    @objc func showMain() {
        main.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func save() {
        config.servers = servers.map(\.cfg)
        Store.save(config)
    }

    /// Coalesces state pushes to the web views into one per run loop turn.
    func changed() {
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async {
            self.renderQueued = false
            let list = self.servers.map(\.json)
            self.main.render(["servers": list])
            for p in Array(self.widgets.values) + [self.editor].compactMap({ $0 }) {
                if let w = self.config.widgets.first(where: { $0.id == p.widgetID }) {
                    p.render(["servers": list, "widget": w.json])
                }
            }
        }
    }

    // MARK: messages from the pages

    func handle(_ m: [String: Any], from p: Panel) {
        let server = servers.first { $0.cfg.id == m["id"] as? String }
        switch m["cmd"] as? String {
        case "ready": changed(); p.window.invalidateShadow()
        case "drag": p.drag()
        case "close": p.window.close()
        case "minimize": p.window.miniaturize(nil)
        case "zoom": p.window.zoom(nil)
        case "power":
            guard let s = server else { return }
            if s.phase == "off" { s.powerOn() }
            else if confirm("Turn off \(s.cfg.name)?", "You'll be able to turn it back on with Wake-on-LAN.", "Turn Off") { s.powerOff() }
        case "restart":
            if let s = server, confirm("Restart \(s.cfg.name)?", "It will be unavailable for a minute or two.", "Restart") { s.restart() }
        case "install": server?.installUpdates()
        case "check": server?.checkUpdates()
        case "add": addServer(m)
        case "menu": p === main ? serverMenu(server, in: p) : widgetMenu(p)
        case "set": updateWidget(p.widgetID, m["patch"] as? [String: Any] ?? [:])
        case "done": closeEditor()
        default: break
        }
    }

    // MARK: servers

    private func addServer(_ m: [String: Any]) {
        func field(_ k: String) -> String { (m[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = field("name"), ssh = field("ssh"), mac = field("mac").lowercased().replacingOccurrences(of: "-", with: ":")
        guard !name.isEmpty, !ssh.isEmpty else { return }
        let s = Server(ServerConfig(name: name, ssh: ssh, mac: mac.isEmpty ? nil : mac))
        servers.append(s)
        s.connect()
        save()
        changed()
    }

    private func serverMenu(_ s: Server?, in p: Panel) {
        guard let s else { return }
        p.popUp([MenuAction("Remove “\(s.cfg.name)”…") { [self] in
            guard confirm("Remove \(s.cfg.name)?", "It disappears from the app and its widgets. Nothing changes on the server.", "Remove") else { return }
            s.disconnect()
            Keychain.delete(s.cfg.id)
            servers.removeAll { $0 === s }
            for i in config.widgets.indices where config.widgets[i].server == s.cfg.id { config.widgets[i].server = "all" }
            save()
            changed()
        }])
    }

    // MARK: widgets

    private func newWidget() -> WidgetConfig {
        let vf = NSScreen.screens.first?.visibleFrame ?? .zero
        let offset = CGFloat(config.widgets.count) * 24
        return WidgetConfig(x: vf.minX + 24 + offset, y: vf.maxY - 24 - 172 - offset)
    }

    private func openWidget(_ w: WidgetConfig) {
        let d = Self.widgetSizes[w.size] ?? Self.widgetSizes["M"]!
        let win = NSPanel(contentRect: NSRect(x: w.x, y: w.y, width: d.w, height: d.h),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hidesOnDeactivate = false
        widgets[w.id] = Panel(page: "widget", window: win, radius: d.r, widgetID: w.id)
        win.orderFront(nil)
    }

    @objc func addWidget() {
        let w = newWidget()
        config.widgets.append(w)
        openWidget(w)
        save()
        openEditor(w.id)
    }

    private func widgetMenu(_ p: Panel) {
        guard let id = p.widgetID, p !== editor else { return }
        p.popUp([
            MenuAction("Edit Widget…") { [self] in openEditor(id) },
            MenuAction("Remove Widget") { [self] in
                if editor?.widgetID == id { closeEditor() }
                widgets.removeValue(forKey: id)?.close()
                config.widgets.removeAll { $0.id == id }
                save()
            },
        ])
    }

    func widgetMoved(_ p: Panel) {
        guard let i = config.widgets.firstIndex(where: { $0.id == p.widgetID }), p !== editor else { return }
        config.widgets[i].x = p.window.frame.minX
        config.widgets[i].y = p.window.frame.minY
        save()
    }

    private func updateWidget(_ id: String?, _ patch: [String: Any]) {
        guard let i = config.widgets.firstIndex(where: { $0.id == id }) else { return }
        var dict = config.widgets[i].json
        patch.forEach { dict[$0] = $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let w = try? JSONDecoder().decode(WidgetConfig.self, from: data) else { return }
        config.widgets[i] = w
        if let p = widgets[w.id], let d = Self.widgetSizes[w.size] {
            let f = p.window.frame
            p.window.setFrame(NSRect(x: f.minX, y: f.maxY - d.h, width: d.w, height: d.h), display: true, animate: true)
            p.setRadius(d.r)
        }
        save()
        changed()
    }

    private func openEditor(_ id: String) {
        closeEditor()
        guard let widget = widgets[id]?.window else { return }
        let wf = widget.frame, vf = (widget.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = NSSize(width: 400, height: 724)
        var x = wf.minX - size.width - 24
        if x < vf.minX { x = wf.maxX + 24 }
        let y = min(max(wf.maxY - size.height, vf.minY), vf.maxY - size.height)
        let win = KeyWindow(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = .floating
        editor = Panel(page: "editor", window: win, radius: 28, widgetID: id)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func closeEditor() {
        editor?.close()
        editor = nil
    }

    // MARK: dialogs

    func confirm(_ title: String, _ info: String, _ button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }

    func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        NSApp.activate()
        a.runModal()
    }

    func askPassword(_ name: String, wrong: Bool) -> String? {
        let a = NSAlert()
        a.messageText = wrong ? "Wrong password for \(name)" : "sudo password for \(name)"
        a.informativeText = "Needed to restart, shut down or update the server. It's kept in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    // MARK: menu bar

    private func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let item = NSMenuItem()
            item.submenu = m
            bar.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        menu("Ice Servers", [
            item("About Ice Servers", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Ice Servers", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Ice Servers", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            MenuAction("Add Server…", key: "n") { [self] in showMain(); main.web.evaluateJavaScript("showAdd()") },
            item("Add Widget", #selector(addWidget), "N", self),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Show Ice Servers", #selector(showMain), "0", self),
        ])
        NSApp.mainMenu = bar
    }
}

extension WidgetConfig {
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
}

final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, key: String = "", _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Web: WKWebView {
    var lastMouseDown: NSEvent?

    override func mouseDown(with event: NSEvent) {
        lastMouseDown = event
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless window: native behind-window blur, rounded by a mask, with one transparent web page on top.
final class Panel: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    let window: NSWindow
    let web: Web
    let widgetID: String?
    private let blur = NSVisualEffectView()

    init(page: String, window: NSWindow, radius: CGFloat, widgetID: String? = nil) {
        self.window = window
        self.widgetID = widgetID
        let conf = WKWebViewConfiguration()
        web = Web(frame: window.contentLayoutRect, configuration: conf)
        super.init()
        conf.userContentController.add(self, name: "ice")

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self

        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        setRadius(radius)
        window.contentView = blur

        web.setValue(false, forKey: "drawsBackground")
        web.frame = blur.bounds
        web.autoresizingMask = [.width, .height]
        blur.addSubview(web)

        let res = Bundle.main.resourceURL!
        web.loadFileURL(res.appendingPathComponent("\(page).html"), allowingReadAccessTo: res)
    }

    func setRadius(_ r: CGFloat) {
        let side = r * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        blur.maskImage = mask
        window.invalidateShadow()
    }

    func render(_ state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        web.evaluateJavaScript("window.render && render(\(String(decoding: data, as: UTF8.self)))")
    }

    func drag() {
        if let e = web.lastMouseDown { window.performDrag(with: e) }
    }

    func popUp(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        items.forEach(menu.addItem)
        menu.popUp(positioning: nil, at: web.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: web)
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ice")
        window.close()
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        ice.handle(message.body as? [String: Any] ?? [:], from: self)
    }

    func windowDidMove(_ notification: Notification) { ice.widgetMoved(self) }
}
