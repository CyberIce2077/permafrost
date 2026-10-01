import AppKit

// ssh runs this app as its SSH_ASKPASS helper while adding a server with a password.
if let password = ProcessInfo.processInfo.environment["ICE_ASKPASS"] {
    print(password)
    exit(0)
}

let ice = AppDelegate()
let app = NSApplication.shared
app.delegate = ice
app.setActivationPolicy(.regular)
app.run()
