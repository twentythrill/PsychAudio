import Cocoa

// Entry point for the PsychAudio daemon menu bar utility
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
