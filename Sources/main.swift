import AppKit

let ice = AppDelegate()
let app = NSApplication.shared
app.delegate = ice
app.setActivationPolicy(.regular)
app.run()
