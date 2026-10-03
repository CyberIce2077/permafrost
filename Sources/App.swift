import AppKit
import LocalAuthentication
import ServiceManagement
import WebKit
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config()
    var servers: [Server] = []
    var main: Panel!
    /// Settings shows in the main window, in place of the servers.
    var settings: Panel? { main?.page == "settings" ? main : nil }
    let alerts = Alerts()
    let menuBar = MenuBar()
    private var undo: (server: Server, index: Int, forget: Bool, timer: Timer)?
    private var deletedDesign: (design: Design, index: Int)?
    /// How many desktop widgets use each design, by id.
    private var placed: [String: Int] = [:]

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
        Store.moveOldFolder()
        if let saved = Store.load() {
            config = saved
        } else {
            config.servers = Store.shellAliases()
        }
        servers = config.servers.map(Server.init)
        buildMenu()

        // Launched by a widget button (Widget/Actions.swift): run its action, don't show the window.
        let args = CommandLine.arguments
        let launchAction = args.firstIndex(of: "--action").flatMap { i in i + 2 < args.count ? (args[i + 1], args[i + 2]) : nil }

        main = Panel(pages: ["app", "settings"], size: NSSize(width: 1160, height: 790), radius: 28, resizable: true)
        main.window.minSize = NSSize(width: 960, height: 640)
        if launchAction == nil { main.window.makeKeyAndOrderFront(nil) }
        apply(prefs, was: nil)

        servers.forEach { $0.connect() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.servers.forEach { $0.tick() } }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            self.servers.filter { $0.phase == "online" }.forEach { $0.countUpdates() }
        }
        save()
        countPlaced()
        // Widget buttons while the app runs (Widget/Actions.swift): "action serverID".
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.permafrost.action"), object: nil, queue: .main) { n in
            guard let parts = (n.object as? String)?.split(separator: " "), parts.count == 2 else { return }
            self.run(String(parts[0]), on: String(parts[1]), quiet: true)
        }
        if let (action, id) = launchAction {
            run(action, on: id, quiet: true)
        } else {
            NSApp.activate()
        }
        application(NSApp, open: pendingURLs)
    }

    /// Desktop widgets may have been added or changed in Edit Widget while the app was in the back.
    func applicationDidBecomeActive(_ note: Notification) { countPlaced() }

    /// With the menu bar item on, closing the window keeps the app (and its alerts) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !prefs.menubar }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        main.window.makeKeyAndOrderFront(nil)
        return true
    }

    /// The servers, in the main window (leaving Settings if it's showing). `then` runs once they're on screen.
    @objc func showMain() { showServers() }

    func showServers(then: (() -> Void)? = nil) {
        main.show("app", then: then)
        showPasswordSheet()
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
            var state: [String: Any] = ["servers": list, "touchID": self.config.touchID.map { $0 as Any } ?? NSNull(), "prefs": self.prefs.json,
                                        "key": SSHKey.display(SSHKey.existing ?? SSHKey.defaultPath)]
            if let id = self.selectID {
                state["select"] = id
                self.selectID = nil
            }
            state["designs"] = (self.config.designs ?? []).map(\.json)
            state["placed"] = self.placed
            Store.saveLive(self.servers.map { s in
                var st = s.parser.stats
                st.id = s.cfg.id
                st.name = s.cfg.name
                st.online = s.phase == "online"
                st.phase = s.phase
                st.progress = s.progress
                return st
            })
            if let pane = self.settingsPane, self.settings?.loaded == true {
                state["pane"] = pane
                self.settingsPane = nil
            }
            self.main.render(state)
            self.menuBar.update()
        }
    }

    /// While one server runs a sudo action, power, restart and update controls are locked everywhere.
    var lockedBy: Server? { servers.first { Self.busyPhases.contains($0.phase) } }

    func toast(_ text: String) {
        guard !text.isEmpty else { return }
        main.call("toast", ["text": text])
    }

    /// Touch ID, or the Mac's password where there's no sensor.
    func authenticate(_ reason: String, done: @escaping (Bool) -> Void) {
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: widget links: permafrost://<open|power|restart|install|check>?id=<server>

    func application(_ application: NSApplication, open urls: [URL]) {
        guard main != nil else { return pendingURLs += urls }
        for url in urls where url.scheme == "permafrost" {
            // permafrost://widgets: from a widget that hasn't picked a design yet.
            if url.host == "widgets" {
                showCustomWidgets()
                continue
            }
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            selectID = id
            showMain()
            changed()
            if let action = url.host, action != "open", let id { run(action, on: id) }
        }
    }

    /// Runs a widget's action once the app knows whether the server is up (it may have just launched).
    /// An action from a widget button or an permafrost:// link. Only these four: anything on this Mac
    /// can open a link or post the widget's notification. `quiet`: from a widget, so the main window
    /// stays put; a confirmation is all that shows.
    private func run(_ action: String, on id: String, quiet: Bool = false, tries: Int = 40) {
        guard ["power", "restart", "install", "check"].contains(action),
              let s = servers.first(where: { $0.cfg.id == id }) else { return }
        if s.phase == "connecting", tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.run(action, on: id, quiet: quiet, tries: tries - 1) }
            return
        }
        quietConfirm = quiet && !NSApp.isActive
        handle(["cmd": action, "id": id], from: main)
        quietConfirm = false
    }

    /// Set while running a widget's action with the app in the background.
    private var quietConfirm = false

    /// The host key the passwordless check is waiting for the user to trust.
    private var nopassKey: HostKey.Scan?

    // MARK: messages from the pages

    func handle(_ m: [String: Any], from p: Panel) {
        let server = servers.first { $0.cfg.id == m["id"] as? String }
        let cmd = m["cmd"] as? String ?? ""
        if ["power", "restart", "install", "check", "retryTimeout"].contains(cmd), let busy = lockedBy {
            return toast("Running sudo on \(busy.cfg.name). Try again when it finishes.")
        }
        switch cmd {
        case "ready":
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
        case "dismissTimeout": server?.dismissTimeout()
        case "retryTimeout": server?.retryTimeout()
        case "check": server?.checkUpdates()
        case "menu": if p === main { serverMenu(server, in: p) }
        // Settings › Widgets
        case "saveDesign":
            guard let data = try? JSONSerialization.data(withJSONObject: m["design"] ?? [:]),
                  let d = try? JSONDecoder().decode(Design.self, from: data) else { return }
            var list = config.designs ?? []
            if let i = list.firstIndex(where: { $0.id == d.id }) { list[i] = d } else { list.append(d) }
            config.designs = list
            save()
            changed()
        case "dupDesign":
            guard var list = config.designs, let i = list.firstIndex(where: { $0.id == m["id"] as? String }) else { return }
            var copy = list[i]
            copy.id = UUID().uuidString
            copy.name += " copy"
            list.insert(copy, at: i + 1)
            config.designs = list
            save()
            changed()
        case "deleteDesign":
            // Widgets using it fall back to the default (first) design until Undo.
            guard var list = config.designs, let i = list.firstIndex(where: { $0.id == m["id"] as? String }) else { return }
            deletedDesign = (list.remove(at: i), i)
            config.designs = list
            save()
            changed()
        case "undoDesign":
            guard let (d, i) = deletedDesign else { return }
            deletedDesign = nil
            var list = config.designs ?? []
            list.insert(d, at: min(i, list.count))
            config.designs = list
            save()
            changed()
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
            nopassKey = nil
            Passwordless.check(Draft(m["draft"] as? [String: Any] ?? [:])) { [weak p] allowed, error, scan in
                self.nopassKey = scan
                p?.call("nopassResult", ["allowed": allowed ?? NSNull(), "error": error, "fp": scan?.fingerprint ?? NSNull()])
            }
        case "nopassTrust":
            // Trusted here, the Test step finds the host key already known.
            guard let scan = nopassKey else { return }
            nopassKey = nil
            HostKey.trust(scan)
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
        case "showAdd":
            showServers { self.main.call("showAdd") }
        case "showServers": showServers()
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
        // The Test step checked it; it's kept only now, so Cancel or Back leaves nothing behind.
        if d.when == "now", !d.sudoPassword.isEmpty {
            if d.sudo == "always" { LocalSecrets.set(d.id, d.sudoPassword) }
            else if d.sudo == "remember" { Keychain.set(d.id, d.sudoPassword) }
        }
        // One setting for every server: the wizard's switch starts at its current value and says so.
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
        open.message = "Choose the private key Permafrost should sign in with."
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
        main.call("toast", ["text": "\(s.cfg.name) removed", "undo": true])
    }

    private func finishRemoval() {
        guard let u = undo else { return }
        u.timer.invalidate()
        undo = nil
        if u.forget { u.server.forgetPassword() }
        for i in (config.designs ?? []).indices { config.designs?[i].servers.removeAll { $0 == u.server.cfg.id } }
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
        main.look(p)
    }

    // MARK: windows

    @objc func showSettings() {
        main.show("settings")
        showPasswordSheet()
        main.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        countPlaced()
    }

    @objc func showCustomWidgets() {
        settingsPane = "widgets"
        showSettings()
        changed()
    }

    /// Counts the desktop widgets using each design. Widgets with no design (or a deleted one) ask for one instead.
    func countPlaced() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let widgets) = result else {
                if case .failure(let e) = result { NSLog("Permafrost: can't read desktop widgets: %@", e.localizedDescription) }
                return
            }
            var counts: [String: Int] = [:]
            for w in widgets {
                // Only widgets of the design's size show it ("PermafrostM" is the Medium widget).
                let size = String(w.kind.dropFirst("Permafrost".count))
                guard let id = pickedDesign(w),
                      self.config.designs?.contains(where: { $0.id == id && $0.size == size }) == true else { continue }
                counts[id, default: 0] += 1
            }
            DispatchQueue.main.async {
                guard counts != self.placed else { return }
                self.placed = counts
                self.changed()
            }
        }
    }

    // MARK: dialogs

    func confirm(_ title: String, _ info: String, _ button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        let hide = quietConfirm
        NSApp.activate()
        let ok = a.runModal() == .alertFirstButtonReturn
        // From a widget: back to the background, as if only the dialog had appeared.
        if hide { NSApp.hide(nil) }
        return ok
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
        let panel = main!
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
        menu("Permafrost", [
            item("About Permafrost", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(showSettings), ",", self),
            item("Custom Widgets…", #selector(showCustomWidgets), "", self),
            .separator(),
            item("Hide Permafrost", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Permafrost", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            MenuAction("Add Server…", key: "n") { [self] in showServers { self.main.call("showAdd") } },
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
            item("Show Permafrost", #selector(showMain), "0", self),
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

/// A borderless window on top of native glass (Liquid Glass on macOS 26 and later, a behind-window
/// blur before that) holding transparent web pages: the servers ("app") and Settings. Both stay loaded
/// and up to date; switching crossfades between them instead of loading a page, so nothing flickers.
final class Panel: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    let window: NSWindow
    private let container: NSView
    private var webs: [String: Web] = [:]
    /// The page showing.
    private(set) var page: String
    private var ready: Set<String> = []
    private var onReady: [String: [() -> Void]] = [:]

    /// The page showing, for drags, menus and focus.
    var web: Web { webs[page]! }
    var loaded: Bool { ready.contains(page) }

    init(pages: [String], size: NSSize, radius: CGFloat, resizable: Bool = false) {
        var style: NSWindow.StyleMask = [.borderless, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        page = pages[0]
        self.radius = radius
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        window.setContentSize(size)
        window.center()

        let res = Bundle.main.resourceURL!
        for name in pages {
            let conf = WKWebViewConfiguration()
            conf.userContentController.add(self, name: "ice")
            let web = Web(frame: container.bounds, configuration: conf)
            web.setValue(false, forKey: "drawsBackground")
            web.autoresizingMask = [.width, .height]
            web.isHidden = name != page
            container.addSubview(web)
            webs[name] = web
            web.loadFileURL(res.appendingPathComponent("\(name).html"), allowingReadAccessTo: res)
        }
        setGlass(true)
    }

    private let radius: CGFloat

    /// Switches to another page with a short crossfade (none with Reduce Motion); `then` runs once
    /// it's ready, right away if it already is.
    func show(_ name: String, then: (() -> Void)? = nil) {
        guard let next = webs[name] else { return }
        if name != page {
            webs[page]?.evaluateJavaScript("window.hidePassword && hidePassword()")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                container.layer?.add(fade, forKey: "page")
            }
            webs[page]?.isHidden = true
            next.isHidden = false
            page = name
            window.makeFirstResponder(next)
        }
        guard let then else { return }
        if ready.contains(name) { then() } else { onReady[name, default: []].append(then) }
    }

    /// Native glass behind the pages, or nothing (Settings › Appearance: no blur / reduce transparency).
    private func setGlass(_ on: Bool) {
        container.removeFromSuperview()
        container.frame = NSRect(origin: .zero, size: window.frame.size)
        if !on {
            let plain = NSView(frame: container.frame)
            plain.addSubview(container)
            window.contentView = plain
        } else if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.style = .clear
            g.cornerRadius = radius
            g.contentView = container
            window.contentView = g
        } else {
            let blur = NSVisualEffectView()
            blur.blendingMode = .behindWindow
            blur.material = .fullScreenUI
            blur.state = .active
            blur.maskImage = Self.mask(radius)
            blur.frame = container.frame
            blur.addSubview(container)
            window.contentView = blur
        }
        window.invalidateShadow()
    }

    /// Settings › Appearance: theme for the native parts, glass on or off. The pages style themselves.
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

    /// The state goes to every page, so a hidden one is current when it's shown.
    func render(_ state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        let js = "window.render && render(\(String(decoding: data, as: UTF8.self)))"
        webs.values.forEach { $0.evaluateJavaScript(js) }
    }

    /// Calls a function on the page showing.
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
        let body = message.body as? [String: Any] ?? [:]
        if body["cmd"] as? String == "ready", let name = webs.first(where: { $0.value === message.webView })?.key {
            ready.insert(name)
            onReady.removeValue(forKey: name)?.forEach { $0() }
        }
        // Only the page showing can be clicked; a hidden one only reports that it's ready.
        guard message.webView === web || body["cmd"] as? String == "ready" else { return }
        ice.handle(body, from: self)
    }

    func windowWillClose(_ notification: Notification) {}
}
