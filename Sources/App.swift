import AppKit
import WebKit
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config()
    var servers: [Server] = []
    var main: Panel!
    var settings: Panel?
    private var renderQueued = false
    private var reloadQueued = false
    private var selectID: String?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        if let saved = Store.load() {
            config = saved
        } else {
            config.servers = Store.shellAliases()
        }
        servers = config.servers.map(Server.init)
        buildMenu()

        let win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
                            styleMask: [.borderless, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.minSize = NSSize(width: 960, height: 640)
        win.center()
        main = Panel(page: "app", window: win, radius: 28)
        win.makeKeyAndOrderFront(nil)

        servers.forEach { $0.connect() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            self.servers.filter { $0.phase == "online" }.forEach { $0.countUpdates() }
        }
        save()
        NSApp.activate()
        application(NSApp, open: pendingURLs)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        reloadWidgets()
    }

    /// Asks WidgetKit to refresh the desktop widgets, at most once a second.
    func reloadWidgets() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.reloadQueued = false
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Coalesces state pushes to the web views into one per run loop turn.
    func changed() {
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async {
            self.renderQueued = false
            let list = self.servers.map(\.json)
            var state: [String: Any] = ["servers": list]
            if let id = self.selectID {
                state["select"] = id
                self.selectID = nil
            }
            self.main.render(state)
            self.settings?.render(["servers": list, "widgets": ["S", "M", "L", "XL"].reduce(into: [String: Any]()) {
                $0[$1] = self.config.widgets[$1, default: WidgetStyle()].json
            }])
        }
    }

    // MARK: widget links: iceservers://<open|power|restart|install|check>?id=<server>

    func application(_ application: NSApplication, open urls: [URL]) {
        guard main != nil else { return pendingURLs += urls }
        for url in urls where url.scheme == "iceservers" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            selectID = id
            showMain()
            changed()
            if let action = url.host, action != "open", let id { run(action, on: id) }
        }
    }

    /// Runs a widget's action once the app knows whether the server is up (it may have just launched).
    private func run(_ action: String, on id: String, tries: Int = 40) {
        guard let s = servers.first(where: { $0.cfg.id == id }) else { return }
        if s.phase == "connecting", tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.run(action, on: id, tries: tries - 1) }
            return
        }
        handle(["cmd": action, "id": id], from: main)
    }

    // MARK: messages from the pages

    func handle(_ m: [String: Any], from p: Panel) {
        let server = servers.first { $0.cfg.id == m["id"] as? String }
        switch m["cmd"] as? String {
        case "ready":
            changed()
            p.window.invalidateShadow()
            if p === main { showPasswordSheet() }
        case "password":
            guard let r = passwordRequests.first, r.server === server else { return }
            r.reply((m["value"] as? String ?? "", m["remember"] as? Bool ?? true))
        case "passwordCancel":
            guard !passwordRequests.isEmpty else { return }
            passwordRequests.removeFirst().reply(nil)
            showPasswordSheet()
        case "drag": p.drag()
        case "close", "done": p.window.close()
        case "minimize": p.window.miniaturize(nil)
        case "zoom": p.window.zoom(nil)
        case "power":
            guard let s = server else { return }
            if s.phase == "off" { s.powerOn() }
            else if s.phase == "online", confirm("Turn off \(s.cfg.name)?", "You'll be able to turn it back on with Wake-on-LAN.", "Turn Off") { s.powerOff() }
        case "restart":
            if let s = server, s.phase == "online", confirm("Restart \(s.cfg.name)?", "It will be unavailable for a minute or two.", "Restart") { s.restart() }
        case "install": server?.installUpdates()
        case "check": server?.checkUpdates()
        case "add": addServer(m)
        case "menu": if p === main { serverMenu(server, in: p) }
        case "set": setWidgetStyle(m["size"] as? String ?? "", m["patch"] as? [String: Any] ?? [:])
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
            for (size, w) in config.widgets where w.server == s.cfg.id { config.widgets[size]?.server = "all" }
            save()
            changed()
        }])
    }

    // MARK: widget settings

    @objc func showSettings() {
        if settings == nil {
            let win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                styleMask: [.borderless, .closable, .miniaturizable], backing: .buffered, defer: false)
            win.center()
            settings = Panel(page: "settings", window: win, radius: 16)
        }
        settings?.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func setWidgetStyle(_ size: String, _ patch: [String: Any]) {
        guard ["S", "M", "L", "XL"].contains(size) else { return }
        var dict = config.widgets[size, default: WidgetStyle()].json
        patch.forEach { dict[$0] = $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let style = try? JSONDecoder().decode(WidgetStyle.self, from: data) else { return }
        config.widgets[size] = style
        save()
        changed()
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

    // MARK: sudo password sheet (in the main window, one server at a time)

    private var passwordRequests: [(server: Server, error: String?, reply: ((String, Bool)?) -> Void)] = []

    /// Shows the sheet for `server`, or updates it with `error` if it's already showing.
    /// `reply` gets the password and whether to remember it, or nil when cancelled.
    func askPassword(for server: Server, error: String?, reply: @escaping ((String, Bool)?) -> Void) {
        if let i = passwordRequests.firstIndex(where: { $0.server === server }) {
            passwordRequests[i] = (server, error, reply)
        } else {
            passwordRequests.append((server, error, reply))
        }
        showPasswordSheet()
    }

    func passwordAccepted(for server: Server) {
        passwordRequests.removeAll { $0.server === server }
        showPasswordSheet()
    }

    private func showPasswordSheet() {
        guard let r = passwordRequests.first else { return main.call("hidePassword") }
        showMain()
        main.call("askPassword", ["id": r.server.cfg.id, "name": r.server.cfg.name, "user": r.server.sshUser, "error": r.error ?? NSNull()])
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
            item("Widget Settings…", #selector(showSettings), ",", self),
            .separator(),
            item("Hide Ice Servers", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Ice Servers", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            MenuAction("Add Server…", key: "n") { [self] in showMain(); main.web.evaluateJavaScript("showAdd()") },
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

extension WidgetStyle {
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
    private let blur = NSVisualEffectView()

    init(page: String, window: NSWindow, radius: CGFloat) {
        self.window = window
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

    func call(_ function: String, _ arg: [String: Any] = [:]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arg) else { return }
        web.evaluateJavaScript("window.\(function) && \(function)(\(String(decoding: data, as: UTF8.self)))")
    }

    func drag() {
        if let e = web.lastMouseDown { window.performDrag(with: e) }
    }

    func popUp(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        items.forEach(menu.addItem)
        menu.popUp(positioning: nil, at: web.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: web)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        ice.handle(message.body as? [String: Any] ?? [:], from: self)
    }

    func windowWillClose(_ notification: Notification) {
        if self === ice.settings {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "ice")
            ice.settings = nil
        }
    }
}
