import Cocoa
import ServiceManagement

/// Application delegate managing the menu bar status item and application lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var launchAtLoginMenuItem: NSMenuItem!
    
    private let interceptor = MediaKeyInterceptor()
    private let webSocketServer = WebSocketServer()
    private let arbitrator = AudioArbitrator()
    private let remoteMediaController = RemoteMediaController()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce accessory activation policy so app never shows in Dock
        NSApplication.shared.setActivationPolicy(.accessory)
        
        setupWiring()
        setupStatusBarItem()
        
        // Start background components
        webSocketServer.start()
        interceptor.start()
        remoteMediaController.start()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    // MARK: - Wiring Components
    
    private func setupWiring() {
        // Connect arbitrator to WebSocket server
        arbitrator.webSocketServer = webSocketServer
        
        // Wire interceptor callback to arbitrator (hardware keyboard media keys)
        interceptor.onPlayPausePressed = { [weak self] in
            self?.arbitrator.handleHardwarePlayPausePressed()
        }
        
        // Wire remote media controller (Bluetooth headphones, AirPods, AVRCP controllers)
        remoteMediaController.onRemotePlayPause = { [weak self] in
            self?.arbitrator.handleHardwarePlayPausePressed()
        }
        
        // Wire WebSocket server inbound events to arbitrator
        webSocketServer.onTabPlaying = { [weak self] tabId in
            self?.arbitrator.handleChromeTabPlaying(tabId: tabId)
        }
        
        webSocketServer.onTabPaused = { [weak self] tabId in
            self?.arbitrator.handleChromeTabPaused(tabId: tabId)
        }
        
        webSocketServer.onTabClosed = { [weak self] tabId in
            self?.arbitrator.handleChromeTabClosed(tabId: tabId)
        }
    }
    
    // MARK: - Status Bar UI
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let earSymbol = NSImage(systemSymbolName: "ear", accessibilityDescription: "PsychAudio") {
                earSymbol.isTemplate = true
                button.image = earSymbol
            } else {
                // Fallback clean template vector ear representation
                button.image = createFallbackEarImage()
            }
        }
        
        setupMenu()
    }
    
    private func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false
        
        // Control 1: Launch at Login toggle item
        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginMenuItem)
        
        // Control 2: Quit item
        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
        
        statusItem.menu = menu
    }
    
    // MARK: - Launch at Login (SMAppService.mainApp)
    
    private func updateLaunchAtLoginState() {
        let isEnabled = (SMAppService.mainApp.status == .enabled)
        launchAtLoginMenuItem.state = isEnabled ? .on : .off
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                print("[AppDelegate] Launch at Login unregistered.")
            } else {
                try SMAppService.mainApp.register()
                print("[AppDelegate] Launch at Login registered.")
            }
        } catch {
            print("[AppDelegate] Failed to update SMAppService status: \(error)")
        }
        updateLaunchAtLoginState()
    }
    
    // MARK: - App Termination & Clean Shutdown
    
    @objc private func quitApp(_ sender: NSMenuItem) {
        cleanup()
        NSApplication.shared.terminate(nil)
    }
    
    private func cleanup() {
        print("[AppDelegate] Performing clean shutdown...")
        // 1. Destroy event tap and release low-level system hooks
        interceptor.stop()
        
        // 2. Shut down local WebSocket listener and terminate connections
        webSocketServer.stop()
        
        // 3. Stop remote media controller and release MediaPlayer hooks
        remoteMediaController.stop()
    }
    
    // MARK: - Fallback Template Vector Icon
    
    private func createFallbackEarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            
            // Stylized ear curve
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 7, y: 3))
            path.addCurve(to: CGPoint(x: 13, y: 11), control1: CGPoint(x: 14, y: 3), control2: CGPoint(x: 15, y: 8))
            path.addCurve(to: CGPoint(x: 9, y: 15), control1: CGPoint(x: 11, y: 14), control2: CGPoint(x: 10, y: 15))
            path.addCurve(to: CGPoint(x: 6, y: 13), control1: CGPoint(x: 7, y: 15), control2: CGPoint(x: 6, y: 14))
            
            // Inner tragus curve
            path.move(to: CGPoint(x: 8, y: 7))
            path.addQuadCurve(to: CGPoint(x: 8, y: 11), control: CGPoint(x: 11, y: 9))
            
            context.setLineWidth(1.6)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
            
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
