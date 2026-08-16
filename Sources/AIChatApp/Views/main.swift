import AppKit

// Programmatic AppKit entry point — the old toolchain's SwiftUI module has no
// @main / App / WindowGroup, so we host SwiftUI views inside a plain window.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()