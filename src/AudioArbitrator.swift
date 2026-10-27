import Foundation
import Cocoa

/// Defines the arbitration targets for media playback
enum AudioTarget: Equatable, CustomStringConvertible {
    case appleMusic
    case chrome(tabId: Int)
    
    var description: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .chrome(let tabId):
            return "Chrome Tab [\(tabId)]"
        }
    }
}

/// State tracking for Chrome media tabs
struct ChromeTabAudioState {
    let tabId: Int
    var isPlaying: Bool
    var lastActiveTime: Date
    var lastPausedTime: Date?
}

/// Arbitrates hardware media key Play/Pause presses between Apple Music and Google Chrome tabs.
/// Maintains an internal state machine updated via distributed notifications and local WebSocket IPC.
final class AudioArbitrator {
    private let lock = NSLock()
    
    // Apple Music state tracking
    private var isAppleMusicPlaying: Bool = false
    private var appleMusicLastActiveTime: Date = Date.distantPast
    private var appleMusicLastPausedTime: Date? = nil
    
    // Chrome tabs state tracking: tabId -> ChromeTabAudioState
    private var chromeTabs: [Int: ChromeTabAudioState] = [:]
    
    // Most recent paused target with timestamp
    private var mostRecentPausedTarget: (target: AudioTarget, timestamp: Date)? = nil
    
    // Most recently active source (playing or paused)
    private var lastActiveSource: AudioTarget = .appleMusic
    
    // Weak reference to the local WebSocket server to send outbound commands
    weak var webSocketServer: WebSocketServer?
    
    init() {
        setupAppleMusicObserver()
    }
    
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    // MARK: - Distributed Notifications (Apple Music)
    
    private func setupAppleMusicObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppleMusicPlayerInfo(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
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
            isAppleMusicPlaying = true
            appleMusicLastActiveTime = now
            lastActiveSource = .appleMusic
            print("[AudioArbitrator] Apple Music status: PLAYING at \(now)")
        } else if playerState == "Paused" || playerState == "Stopped" {
            isAppleMusicPlaying = false
            appleMusicLastPausedTime = now
            mostRecentPausedTarget = (.appleMusic, now)
            print("[AudioArbitrator] Apple Music status: PAUSED at \(now). Recorded as last paused target.")
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
        
        // If the closed tab was our recorded most recent paused target, find next best fallback
        if case .chrome(let id) = mostRecentPausedTarget?.target, id == tabId {
            let nextRecentTab = chromeTabs.values
                .filter { !$0.isPlaying && $0.lastPausedTime != nil }
                .max(by: { ($0.lastPausedTime ?? .distantPast) < ($1.lastPausedTime ?? .distantPast) })
            
            if let nextTab = nextRecentTab, let pauseTime = nextTab.lastPausedTime {
                if let musicPauseTime = appleMusicLastPausedTime, musicPauseTime > pauseTime {
                    mostRecentPausedTarget = (.appleMusic, musicPauseTime)
                } else {
                    mostRecentPausedTarget = (.chrome(tabId: nextTab.tabId), pauseTime)
                }
            } else if let musicPauseTime = appleMusicLastPausedTime {
                mostRecentPausedTarget = (.appleMusic, musicPauseTime)
            } else {
                mostRecentPausedTarget = nil
            }
        }
    }
    
    // MARK: - Arbitration and Playback Routing
    
    /// Evaluates the target and executes the play/pause toggle when the hardware key is pressed.
    func handleHardwarePlayPausePressed() {
        let target = evaluateTarget()
        print("[AudioArbitrator] Arbitrated Play/Pause target: \(target)")
        executeToggle(for: target)
    }
    
    /// Evaluates whether Apple Music or a Chrome tab is the correct playback target.
    private func evaluateTarget() -> AudioTarget {
        lock.lock()
        defer { lock.unlock() }
        
        // 1. If any source is actively playing, route to that active source to pause it.
        let activePlayingTabs = chromeTabs.values.filter { $0.isPlaying }
        let mostRecentPlayingTab = activePlayingTabs.max(by: { $0.lastActiveTime < $1.lastActiveTime })
        
        if isAppleMusicPlaying && mostRecentPlayingTab != nil {
            // Both are playing: pick the one that started playing most recently
            if let tab = mostRecentPlayingTab, tab.lastActiveTime > appleMusicLastActiveTime {
                return .chrome(tabId: tab.tabId)
            } else {
                return .appleMusic
            }
        } else if let tab = mostRecentPlayingTab {
            return .chrome(tabId: tab.tabId)
        } else if isAppleMusicPlaying {
            return .appleMusic
        }
        
        // 2. Neither is actively playing: Check which source was the most recent paused target
        if let paused = mostRecentPausedTarget {
            // Verify if it's a Chrome tab that Chrome is still connected
            if case .chrome = paused.target, webSocketServer?.hasActiveConnections != true {
                // If extension is not currently connected, fallback to Apple Music
                print("[AudioArbitrator] Chrome extension not connected, falling back to Apple Music")
                return .appleMusic
            }
            return paused.target
        }
        
        // 3. Fallback: Check last active source or default to Apple Music
        if case .chrome(let tabId) = lastActiveSource {
            if chromeTabs[tabId] != nil && webSocketServer?.hasActiveConnections == true {
                return .chrome(tabId: tabId)
            }
        }
        
        return .appleMusic
    }
    
    /// Executes the playback toggle for the arbitrated target.
    private func executeToggle(for target: AudioTarget) {
        switch target {
        case .appleMusic:
            triggerAppleMusicPlayback()
        case .chrome(let tabId):
            triggerChromePlayback(tabId: tabId)
        }
    }
    
    /// Triggers Apple Music play/pause via NSAppleScript executing `tell application "Music" to playpause`.
    private func triggerAppleMusicPlayback() {
        DispatchQueue.global(qos: .userInitiated).async {
            let scriptSource = "tell application \"Music\" to playpause"
            var errorInfo: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&errorInfo)
                if let error = errorInfo {
                    print("[AudioArbitrator] AppleScript execution error: \(error)")
                } else {
                    print("[AudioArbitrator] Executed Apple Music playpause successfully.")
                }
            } else {
                print("[AudioArbitrator] Failed to instantiate NSAppleScript for Apple Music.")
            }
        }
    }
    
    /// Sends `{ "action": "toggle_playback", "tabId": tabId }` over the local WebSocket bridge.
    private func triggerChromePlayback(tabId: Int) {
        guard let server = webSocketServer, server.hasActiveConnections else {
            print("[AudioArbitrator] Cannot route to Chrome tab \(tabId): no active WebSocket connections. Falling back to Apple Music.")
            triggerAppleMusicPlayback()
            return
        }
        
        print("[AudioArbitrator] Dispatching toggle_playback for tab \(tabId) to Chrome extension...")
        server.sendTogglePlayback(tabId: tabId)
    }
}
