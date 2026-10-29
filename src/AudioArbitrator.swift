import Foundation
import Cocoa

/// Defines the arbitration targets for media playback
enum AudioTarget: Equatable, CustomStringConvertible {
    case appleMusic
    case spotify
    case vlc
    case iina
    case chrome(tabId: Int)
    
    var description: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        case .vlc:
            return "VLC"
        case .iina:
            return "IINA"
        case .chrome(let tabId):
            return "Chrome Tab [\(tabId)]"
        }
    }
    
    var bundleIdentifier: String? {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .vlc: return "org.videolan.vlc"
        case .iina: return "com.colliderli.iina"
        case .chrome: return "com.google.Chrome"
        }
    }
    
    var appName: String? {
        switch self {
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        case .vlc: return "VLC"
        case .iina: return "IINA"
        case .chrome: return nil
        }
    }
}

/// State tracking for native media player applications
struct AppPlaybackState {
    var isPlaying: Bool = false
    var lastActiveTime: Date = Date.distantPast
    var lastPausedTime: Date? = nil
}

/// State tracking for Chrome media tabs
struct ChromeTabAudioState {
    let tabId: Int
    var isPlaying: Bool
    var lastActiveTime: Date
    var lastPausedTime: Date?
}

/// Arbitrates hardware media key Play/Pause presses between Apple Music, Spotify, VLC, IINA, and Google Chrome tabs.
/// Maintains an internal state machine updated via distributed notifications, workspace app activity tracking, and WebSocket IPC.
final class AudioArbitrator {
    private let lock = NSLock()
    
    // Application-specific playback states
    private var appleMusicState = AppPlaybackState()
    private var spotifyState = AppPlaybackState()
    private var vlcState = AppPlaybackState()
    private var iinaState = AppPlaybackState()
    
    // Chrome tabs state tracking: tabId -> ChromeTabAudioState
    private var chromeTabs: [Int: ChromeTabAudioState] = [:]
    
    // Most recent paused target with timestamp
    private var mostRecentPausedTarget: (target: AudioTarget, timestamp: Date)? = nil
    
    // Most recently active source (playing or paused)
    private var lastActiveSource: AudioTarget = .appleMusic
    
    // Weak reference to the local WebSocket server to send outbound commands
    weak var webSocketServer: WebSocketServer?
    
    init() {
        setupDistributedNotificationObservers()
        setupWorkspaceObservers()
    }
    
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    // MARK: - Distributed Notifications (Apple Music & Spotify)
    
    private func setupDistributedNotificationObservers() {
        let center = DistributedNotificationCenter.default()
        
        // Apple Music: com.apple.Music.playerInfo
        center.addObserver(
            self,
            selector: #selector(handleAppleMusicPlayerInfo(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        
        // Spotify: com.spotify.client.PlaybackStateChanged
        center.addObserver(
            self,
            selector: #selector(handleSpotifyPlaybackStateChanged(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }
    
    @objc private func handleAppleMusicPlayerInfo(_ notification: Notification) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let userInfo = notification.userInfo,
              let playerState = userInfo["Player State"] as? String else {
            return
        }
        
        let now = Date()
        if playerState == "Playing" {
            appleMusicState.isPlaying = true
            appleMusicState.lastActiveTime = now
            lastActiveSource = .appleMusic
            print("[AudioArbitrator] Apple Music status: PLAYING at \(now)")
        } else if playerState == "Paused" || playerState == "Stopped" {
            appleMusicState.isPlaying = false
            appleMusicState.lastPausedTime = now
            mostRecentPausedTarget = (.appleMusic, now)
            print("[AudioArbitrator] Apple Music status: PAUSED at \(now). Recorded as last paused target.")
        }
    }
    
    @objc private func handleSpotifyPlaybackStateChanged(_ notification: Notification) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let userInfo = notification.userInfo,
              let playerState = userInfo["Player State"] as? String else {
            return
        }
        
        let now = Date()
        let isPlaying = playerState.caseInsensitiveCompare("Playing") == .orderedSame || playerState.contains("Playing")
        
        if isPlaying {
            spotifyState.isPlaying = true
            spotifyState.lastActiveTime = now
            lastActiveSource = .spotify
            print("[AudioArbitrator] Spotify status: PLAYING at \(now)")
        } else {
            spotifyState.isPlaying = false
            spotifyState.lastPausedTime = now
            mostRecentPausedTarget = (.spotify, now)
            print("[AudioArbitrator] Spotify status: PAUSED at \(now). Recorded as last paused target.")
        }
    }
    
    // MARK: - Workspace Notifications (VLC, IINA, and Process Lifecycle)
    
    private func setupWorkspaceObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        
        wsCenter.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        wsCenter.addObserver(
            self,
            selector: #selector(handleAppDeactivated(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )
        
        wsCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        
        if bundleId == "org.videolan.vlc" {
            vlcState.lastActiveTime = now
            lastActiveSource = .vlc
            print("[AudioArbitrator] VLC activated at \(now)")
        } else if isIINABundle(bundleId) {
            iinaState.lastActiveTime = now
            lastActiveSource = .iina
            print("[AudioArbitrator] IINA activated at \(now)")
        } else if bundleId == "com.spotify.client" {
            spotifyState.lastActiveTime = now
            lastActiveSource = .spotify
        } else if bundleId == "com.apple.Music" {
            appleMusicState.lastActiveTime = now
            lastActiveSource = .appleMusic
        }
    }
    
    @objc private func handleAppDeactivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        
        if bundleId == "org.videolan.vlc" {
            vlcState.lastPausedTime = now
            mostRecentPausedTarget = (.vlc, now)
            print("[AudioArbitrator] VLC deactivated at \(now). Recorded as last paused candidate.")
        } else if isIINABundle(bundleId) {
            iinaState.lastPausedTime = now
            mostRecentPausedTarget = (.iina, now)
            print("[AudioArbitrator] IINA deactivated at \(now). Recorded as last paused candidate.")
        }
    }
    
    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        
        lock.lock()
        defer { lock.unlock() }
        
        if bundleId == "org.videolan.vlc" {
            vlcState = AppPlaybackState()
            invalidatePausedTargetIfMatch(.vlc)
        } else if isIINABundle(bundleId) {
            iinaState = AppPlaybackState()
            invalidatePausedTargetIfMatch(.iina)
        } else if bundleId == "com.spotify.client" {
            spotifyState = AppPlaybackState()
            invalidatePausedTargetIfMatch(.spotify)
        } else if bundleId == "com.apple.Music" {
            appleMusicState = AppPlaybackState()
            invalidatePausedTargetIfMatch(.appleMusic)
        }
    }
    
    private func isIINABundle(_ bundleId: String) -> Bool {
        return bundleId == "com.colliderli.iina" || bundleId.lowercased().contains("iina")
    }
    
    private func invalidatePausedTargetIfMatch(_ target: AudioTarget) {
        if mostRecentPausedTarget?.target == target {
            mostRecentPausedTarget = findNextMostRecentTarget()
        }
        if lastActiveSource == target {
            lastActiveSource = .appleMusic
        }
    }
    
    // MARK: - Chrome Tab Events (Inbound from WebSocket)
    
    func handleChromeTabPlaying(tabId: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        var tabState = chromeTabs[tabId] ?? ChromeTabAudioState(tabId: tabId, isPlaying: false, lastActiveTime: now, lastPausedTime: nil)
        tabState.isPlaying = true
        tabState.lastActiveTime = now
        chromeTabs[tabId] = tabState
        
        lastActiveSource = .chrome(tabId: tabId)
        print("[AudioArbitrator] Chrome tab \(tabId) status: PLAYING at \(now)")
    }
    
    func handleChromeTabPaused(tabId: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        var tabState = chromeTabs[tabId] ?? ChromeTabAudioState(tabId: tabId, isPlaying: false, lastActiveTime: now, lastPausedTime: nil)
        tabState.isPlaying = false
        tabState.lastPausedTime = now
        chromeTabs[tabId] = tabState
        
        mostRecentPausedTarget = (.chrome(tabId: tabId), now)
        print("[AudioArbitrator] Chrome tab \(tabId) status: PAUSED at \(now). Recorded as last paused target.")
    }
    
    func handleChromeTabClosed(tabId: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        chromeTabs.removeValue(forKey: tabId)
        print("[AudioArbitrator] Chrome tab \(tabId) closed.")
        
        if case .chrome(let id) = mostRecentPausedTarget?.target, id == tabId {
            mostRecentPausedTarget = findNextMostRecentTarget()
        }
    }
    
    // MARK: - Arbitration and Playback Routing
    
    /// Evaluates the target and executes the play/pause toggle when the hardware key is pressed.
    func handleHardwarePlayPausePressed() {
        let target = evaluateTarget()
        print("[AudioArbitrator] Arbitrated Play/Pause target: \(target)")
        executeToggle(for: target)
    }
    
    private func isAppRunning(_ bundleId: String) -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }
    
    private func evaluateTarget() -> AudioTarget {
        lock.lock()
        defer { lock.unlock() }
        
        // 1. If any source is actively playing, route to that active source to pause it
        var activePlayingTargets: [(target: AudioTarget, lastActive: Date)] = []
        
        // Active Chrome tabs
        for tab in chromeTabs.values where tab.isPlaying {
            activePlayingTargets.append((.chrome(tabId: tab.tabId), tab.lastActiveTime))
        }
        
        // Active Spotify
        if spotifyState.isPlaying && isAppRunning("com.spotify.client") {
            activePlayingTargets.append((.spotify, spotifyState.lastActiveTime))
        }
        
        // Active Apple Music
        if appleMusicState.isPlaying && isAppRunning("com.apple.Music") {
            activePlayingTargets.append((.appleMusic, appleMusicState.lastActiveTime))
        }
        
        // Pick the actively playing source that started playing / was active most recently
        if let mostRecentActive = activePlayingTargets.max(by: { $0.lastActive < $1.lastActive }) {
            return mostRecentActive.target
        }
        
        // 2. No source is actively playing: Check which source was most recently paused
        if let paused = mostRecentPausedTarget, isTargetAvailable(paused.target) {
            return paused.target
        }
        
        // 3. Fallback: Check last active source if still running
        if isTargetAvailable(lastActiveSource) {
            return lastActiveSource
        }
        
        // 4. Fallback: Find any currently running media application
        if isAppRunning("com.spotify.client") { return .spotify }
        if isAppRunning("org.videolan.vlc") { return .vlc }
        if isAppRunning("com.colliderli.iina") { return .iina }
        if isAppRunning("com.apple.Music") { return .appleMusic }
        
        return .appleMusic
    }
    
    private func isTargetAvailable(_ target: AudioTarget) -> Bool {
        switch target {
        case .chrome:
            return webSocketServer?.hasActiveConnections == true
        case .appleMusic:
            return isAppRunning("com.apple.Music")
        case .spotify:
            return isAppRunning("com.spotify.client")
        case .vlc:
            return isAppRunning("org.videolan.vlc")
        case .iina:
            return isAppRunning("com.colliderli.iina")
        }
    }
    
    private func findNextMostRecentTarget() -> (target: AudioTarget, timestamp: Date)? {
        var candidates: [(target: AudioTarget, timestamp: Date)] = []
        
        if let time = appleMusicState.lastPausedTime, isAppRunning("com.apple.Music") {
            candidates.append((.appleMusic, time))
        }
        if let time = spotifyState.lastPausedTime, isAppRunning("com.spotify.client") {
            candidates.append((.spotify, time))
        }
        if let time = vlcState.lastPausedTime, isAppRunning("org.videolan.vlc") {
            candidates.append((.vlc, time))
        }
        if let time = iinaState.lastPausedTime, isAppRunning("com.colliderli.iina") {
            candidates.append((.iina, time))
        }
        
        for tab in chromeTabs.values {
            if let time = tab.lastPausedTime, webSocketServer?.hasActiveConnections == true {
                candidates.append((.chrome(tabId: tab.tabId), time))
            }
        }
        
        return candidates.max(by: { $0.timestamp < $1.timestamp })
    }
    
    // MARK: - Playback Execution
    
    private func executeToggle(for target: AudioTarget) {
        switch target {
        case .appleMusic:
            runAppleScript("tell application \"Music\" to playpause", appName: "Music")
        case .spotify:
            runAppleScript("tell application \"Spotify\" to playpause", appName: "Spotify")
        case .vlc:
            runAppleScript("tell application \"VLC\" to play", appName: "VLC")
        case .iina:
            runAppleScript("tell application \"IINA\" to playpause", appName: "IINA")
        case .chrome(let tabId):
            triggerChromePlayback(tabId: tabId)
        }
    }
    
    private func runAppleScript(_ scriptSource: String, appName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&errorInfo)
                if let error = errorInfo {
                    print("[AudioArbitrator] AppleScript error for \(appName): \(error)")
                } else {
                    print("[AudioArbitrator] Executed \(appName) toggle successfully.")
                }
            } else {
                print("[AudioArbitrator] Failed to compile AppleScript for \(appName).")
            }
        }
    }
    
    private func triggerChromePlayback(tabId: Int) {
        guard let server = webSocketServer, server.hasActiveConnections else {
            print("[AudioArbitrator] Cannot route to Chrome tab \(tabId): no active WebSocket connections. Falling back to Apple Music.")
            runAppleScript("tell application \"Music\" to playpause", appName: "Music")
            return
        }
        
        print("[AudioArbitrator] Dispatching toggle_playback for tab \(tabId) to Chrome extension...")
        server.sendTogglePlayback(tabId: tabId)
    }
}
