import AppKit
import LocalAuthentication
import ServiceManagement
import WebKit
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config()
    var servers: [Server] = []
    var main: Panel!
    var settings: Panel?
    var widgetEditor: Panel?
    let alerts = Alerts()
    let menuBar = MenuBar()
    private var undo: (server: Server, index: Int, forget: Bool, timer: Timer)?

    var prefs: Prefs {
        get { config.prefs ?? Prefs() }
        set { config.prefs = newValue }
    }
    private var renderQueued = false
    private var reloadQueued = false
    private var selectID: String?
    private var settingsPane: String?
    private var pendingURLs: [URL] = []
    private var probe: Probe?

    static let busyPhases = ["restarting", "stopping", "starting", "updating", "checking"]

    func applicationDidFinishLaunching(_ note: Notification) {
        if let saved = Store.load() {
            config = saved
        } else {
            config.servers = Store.shellAliases()
        }
        servers = config.servers.map(Server.init)
        buildMenu()

        main = Panel(page: "app", size: NSSize(width: 1160, height: 720), radius: 28, resizable: true)
        main.window.minSize = NSSize(width: 960, height: 640)
        main.window.makeKeyAndOrderFront(nil)
        apply(prefs, was: nil)

        servers.forEach { $0.connect() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            self.servers.filter { $0.phase == "online" }.forEach { $0.countUpdates() }
        }
        save()
        NSApp.activate()
        application(NSApp, open: pendingURLs)
    }

    /// With the menu bar item on, closing the window keeps the app (and its alerts) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !prefs.menubar }

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
            var state: [String: Any] = ["servers": list, "touchID": self.config.touchID == true, "prefs": self.prefs.json,
                                        "key": SSHKey.display(SSHKey.existing ?? SSHKey.defaultPath)]
            if let id = self.selectID {
                state["select"] = id
                self.selectID = nil
            }
            self.main.render(state)
            if let pane = self.settingsPane, self.settings?.loaded == true {
                state["pane"] = pane
                self.settingsPane = nil
            }
            self.settings?.render(state)
            self.menuBar.update()
            self.widgetEditor?.render(["servers": list, "prefs": self.prefs.json, "widgets": ["S", "M", "L", "XL"].reduce(into: [String: Any]()) {
                $0[$1] = self.config.widgets[$1, default: WidgetStyle()].json
            }])
        }
    }

    /// While one server runs a sudo action, power, restart and update controls are locked everywhere.
    var lockedBy: Server? { servers.first { Self.busyPhases.contains($0.phase) } }

    func toast(_ text: String) {
        guard !text.isEmpty else { return }
        for p in [main, settings].compactMap({ $0 }) { p.call("toast", ["text": text]) }
    }

    /// Touch ID, or the Mac's password where there's no sensor.
    func authenticate(_ reason: String, done: @escaping (Bool) -> Void) {
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
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
        let cmd = m["cmd"] as? String ?? ""
        if ["power", "restart", "install", "check"].contains(cmd), let busy = lockedBy {
            return toast("Running sudo on \(busy.cfg.name). Try again when it finishes.")
        }
        switch cmd {
        case "ready":
            p.loaded = true
            changed()
            p.window.invalidateShadow()
            showPasswordSheet()
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
            else if s.phase == "online", !prefs.confirmOff || confirm("Turn off \(s.cfg.name)?", "You'll be able to turn it back on with Wake-on-LAN.", "Turn Off") { s.powerOff() }
        case "restart":
            if let s = server, s.phase == "online", confirm("Restart \(s.cfg.name)?", "It will be unavailable for a minute or two.", "Restart") { s.restart() }
        case "install": server?.installUpdates()
        case "check": server?.checkUpdates()
        case "menu": if p === main { serverMenu(server, in: p) }
        case "set": setWidgetStyle(m["size"] as? String ?? "", m["patch"] as? [String: Any] ?? [:])
        case "addWidget":
            let size = m["size"] as? String ?? "M"
            setWidgetStyle(size, ["server": m["server"] as? String ?? "all"])
            let names = ["S": "Small", "M": "Medium", "L": "Large", "XL": "Extra large"]
            toast("\(names[size] ?? "Medium") widget ready · Right-click the desktop › Edit Widgets to place it")
        // Add Server wizard
        case "addTest":
            probe?.cancel()
            let draft = Draft(m["draft"] as? [String: Any] ?? [:])
            probe = Probe(draft) { [weak p] i, state, note, fp in
                p?.call("addCheck", ["i": i, "state": state, "note": note, "fp": fp ?? NSNull()])
            }
            probe?.start()
        case "addTrust": probe?.trust()
        case "addCancel":
            probe?.cancel()
            probe = nil
        case "addSave": addServer(Draft(m["draft"] as? [String: Any] ?? [:]))
        case "checkNopass":
            Passwordless.check(Draft(m["draft"] as? [String: Any] ?? [:])) { [weak p] allowed, error in
                p?.call("nopassResult", ["allowed": allowed ?? NSNull(), "error": error])
            }
        case "chooseKey": chooseKey(in: p)
        // Settings › Passwords
        case "savePassword": server?.savePassword()
        case "forget":
            server?.forgetPassword()
            toast("Password for \(server?.cfg.name ?? "") removed from Keychain")
            changed()
        case "forgetAll":
            servers.forEach { $0.forgetPassword() }
            toast("All saved passwords removed")
            changed()
        case "touchID":
            config.touchID = m["on"] as? Bool ?? false
            save()
            changed()
        case "showSettings":
            settingsPane = m["pane"] as? String
            showSettings()
            changed()
        case "showWidgets": showWidgetEditor()
        case "showAdd":
            showMain()
            main.call("showAdd")
        // Settings
        case "pref":
            guard let key = m["key"] as? String, let value = m["value"] else { return }
            setPrefs([key: value])
        case "resetLook":
            let d = Prefs()
            setPrefs(["glass": d.glass, "blur": d.blur, "theme": d.theme, "tint": d.tint, "accent": d.accent, "reduce": d.reduce])
        case "editServer":
            guard let s = server else { return }
            func f(_ k: String) -> String { (m[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !f("name").isEmpty, !f("host").isEmpty else { return }
            s.edit(name: f("name"), user: f("user"), host: f("host"), port: f("port"))
            s.cfg.color = f("color")
            s.cfg.widgets = m["widgets"] as? Bool ?? true
            s.cfg.menu = m["menu"] as? Bool ?? true
            save()
            changed()
        case "removeServer":
            if let s = server { remove(s, forget: m["forget"] as? Bool ?? true) }
        case "undoRemove": undoRemove()
        default: break
        }
    }

    // MARK: servers

    private func addServer(_ d: Draft) {
        guard !d.host.isEmpty, !d.user.isEmpty else { return }
        let s = Server(ServerConfig(id: d.id, name: d.name, ssh: d.sshString, sudo: d.sudo))
        if d.sudo == "remember" { config.touchID = d.touchID }
        servers.append(s)
        probe = nil
        s.connect()
        save()
        changed()
    }

    private func chooseKey(in p: Panel) {
        let open = NSOpenPanel()
        open.directoryURL = URL(fileURLWithPath: realHome + "/.ssh")
        open.showsHiddenFiles = true
        open.message = "Choose the private key Ice Servers should sign in with."
        open.beginSheetModal(for: p.window) { response in
            guard response == .OK, let url = open.url else { return }
            p.call("keyChosen", ["path": url.path, "display": SSHKey.display(url.path)])
        }
    }

    private func serverMenu(_ s: Server?, in p: Panel) {
        guard let s else { return }
        p.popUp([MenuAction("Remove “\(s.cfg.name)”…") { [self] in
            guard confirm("Remove \(s.cfg.name)?", "It disappears from the app and its widgets. Nothing changes on the server.", "Remove") else { return }
            remove(s, forget: true)
        }])
    }

    /// Removes a server; it can be brought back with Undo for 5 seconds, until then its password stays.
    private func remove(_ s: Server, forget: Bool) {
        finishRemoval()
        guard let i = servers.firstIndex(where: { $0 === s }) else { return }
        s.disconnect()
        servers.remove(at: i)
        undo = (s, i, forget, Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in self.finishRemoval() })
        save()
        changed()
        for p in [main, settings].compactMap({ $0 }) { p.call("toast", ["text": "\(s.cfg.name) removed", "undo": true]) }
    }

    private func finishRemoval() {
        guard let u = undo else { return }
        u.timer.invalidate()
        undo = nil
        if u.forget { Keychain.delete(u.server.cfg.id) }
        for (size, w) in config.widgets where w.server == u.server.cfg.id { config.widgets[size]?.server = "all" }
        save()
    }

    private func undoRemove() {
        guard let u = undo else { return }
        u.timer.invalidate()
        undo = nil
        let s = Server(u.server.cfg)
        servers.insert(s, at: min(u.index, servers.count))
        s.connect()
        save()
        changed()
        toast("\(s.cfg.name) is back")
    }

    // MARK: settings

    private func setPrefs(_ patch: [String: Any]) {
        let old = prefs
        var dict = old.json
        patch.forEach { dict[$0] = $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let new = try? JSONDecoder().decode(Prefs.self, from: data) else { return }
        prefs = new
        apply(new, was: old)
        save()
        changed()
    }

    /// Makes the app match its settings. `was` is nil at launch.
    private func apply(_ p: Prefs, was old: Prefs?) {
        menuBar.show(p.menubar)
        if let old, old.login != p.login {
            do { try p.login ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { toast("Couldn't change Open at login: \(error.localizedDescription)") }
        }
        if let old, old.refresh != p.refresh { servers.forEach { $0.reconnect() } }
        if p.nOffline || p.nCpu || p.nTemp || p.nDisk || p.nUpd { alerts.requestPermission() }
        for panel in [main, settings].compactMap({ $0 }) { panel.look(p) }
    }

    // MARK: windows

    @objc func showSettings() {
        if settings == nil {
            settings = Panel(page: "settings", size: NSSize(width: 1000, height: 680), radius: 28)
            settings?.look(prefs)
        }
        settings?.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showWidgetEditor() {
        if widgetEditor == nil { widgetEditor = Panel(page: "widgets", size: NSSize(width: 1280, height: 820), radius: 16, glass: false) }
        widgetEditor?.window.makeKeyAndOrderFront(nil)
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

    // MARK: sudo password sheet (one server at a time, in the window that asked)

    private var passwordRequests: [(server: Server, action: String?, remember: Bool, error: String?, reply: ((String, Bool)?) -> Void)] = []
    private var sheetPanel: Panel?

    /// Shows the sheet for `server`, or updates it with `error` if it's already showing.
    /// `reply` gets the password and whether to remember it, or nil when cancelled.
    func askPassword(for server: Server, action: String?, remember: Bool, error: String?, reply: @escaping ((String, Bool)?) -> Void) {
        if let i = passwordRequests.firstIndex(where: { $0.server === server }) {
            passwordRequests[i] = (server, action, remember, error, reply)
        } else {
            passwordRequests.append((server, action, remember, error, reply))
        }
        showPasswordSheet()
    }

    func passwordAccepted(for server: Server) {
        passwordRequests.removeAll { $0.server === server }
        showPasswordSheet()
    }

    private func showPasswordSheet() {
        guard let r = passwordRequests.first else {
            sheetPanel?.call("hidePassword")
            sheetPanel = nil
            return
        }
        // Saving from Settings asks in Settings; actions ask in the main window.
        let panel = r.action == nil && settings?.window.isVisible == true ? settings! : main!
        if sheetPanel !== panel { sheetPanel?.call("hidePassword") }
        sheetPanel = panel
        panel.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        panel.call("askPassword", ["id": r.server.cfg.id, "name": r.server.cfg.name, "user": r.server.sshUser,
                                   "action": r.action ?? NSNull(), "remember": r.remember, "error": r.error ?? NSNull()])
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
            item("Settings…", #selector(showSettings), ",", self),
            item("Widget Settings…", #selector(showWidgetEditor), "", self),
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

extension Encodable {
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

/// A borderless window with one transparent web page on top of native glass:
/// Liquid Glass on macOS 26 and later, a behind-window blur before that.
final class Panel: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    let window: NSWindow
    let web: Web
    var loaded = false

    init(page: String, size: NSSize, radius: CGFloat, resizable: Bool = false, glass: Bool = true) {
        var style: NSWindow.StyleMask = [.borderless, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        let conf = WKWebViewConfiguration()
        web = Web(frame: NSRect(origin: .zero, size: size), configuration: conf)
        self.radius = radius
        super.init()
        conf.userContentController.add(self, name: "ice")

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        window.setContentSize(size)
        window.center()

        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        setGlass(glass)

        let res = Bundle.main.resourceURL!
        web.loadFileURL(res.appendingPathComponent("\(page).html"), allowingReadAccessTo: res)
    }

    private let radius: CGFloat

    /// Native glass behind the page, or nothing (Settings › Appearance: no blur / reduce transparency).
    private func setGlass(_ on: Bool) {
        web.removeFromSuperview()
        web.frame = NSRect(origin: .zero, size: window.frame.size)
        if !on {
            let plain = NSView(frame: web.frame)
            plain.addSubview(web)
            window.contentView = plain
        } else if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.style = .clear
            g.cornerRadius = radius
            g.contentView = web
            window.contentView = g
        } else {
            let blur = NSVisualEffectView()
            blur.blendingMode = .behindWindow
            blur.material = .fullScreenUI
            blur.state = .active
            blur.maskImage = Self.mask(radius)
            blur.frame = web.frame
            blur.addSubview(web)
            window.contentView = blur
        }
        window.invalidateShadow()
    }

    /// Settings › Appearance: theme for the native parts, glass on or off. The page styles itself.
    func look(_ p: Prefs) {
        window.appearance = p.theme == "dark" ? NSAppearance(named: .darkAqua) : p.theme == "light" ? NSAppearance(named: .aqua) : nil
        let glass = p.blur > 0 && !p.reduce
        if glass != (window.contentView is NSVisualEffectView || window.contentView?.className == "NSGlassEffectView") { setGlass(glass) }
    }

    private static func mask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        return mask
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
        guard self !== ice.main else { return }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ice")
        if self === ice.settings { ice.settings = nil }
        if self === ice.widgetEditor { ice.widgetEditor = nil }
    }
}
