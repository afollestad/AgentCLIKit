import AppKit

let app = NSApplication.shared
let delegate = DemoAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
