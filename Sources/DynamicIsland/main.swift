import AppKit

// Entry point. `.accessory` keeps the app out of the Dock and the ⌘-Tab switcher —
// it exists only as the floating island panel plus a status-bar item.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
