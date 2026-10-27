import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

/// Handles low-level interception of the hardware Play/Pause media key using a CGEventTap.
/// Consumes the event by returning `nil` to prevent macOS system daemons (mediaremoted)
/// from guessing the playback target.
final class MediaKeyInterceptor {
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    
    // Callback invoked when hardware Play/Pause key is pressed (key down)
    var onPlayPausePressed: (() -> Void)?
    
    // NX_KEYTYPE_PLAY is defined as 16 in <IOKit/hidsystem/ev_keymap.h>
    private static let NX_KEYTYPE_PLAY: Int = 16
    // NX_SUBTYPE_AUX_CONTROL_BUTTONS is defined as 8
    private static let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
    // System-defined event type raw value in CoreGraphics / IOKit
    private static let NX_SYSDEFINED_TYPE: UInt32 = 14
    
    init() {}
    
    deinit {
        stop()
    }
    
    /// Starts the media key interceptor. If Accessibility permissions are not yet granted,
    /// prompts the user and sets up an auto-retry timer.
    func start() {
        guard checkAccessibility(prompt: true) else {
            print("[MediaKeyInterceptor] Accessibility permission not granted. Waiting for permission...")
            startAccessibilityPolling()
            return
        }
        
        setupEventTap()
    }
    
    /// Cleanly tears down the event tap, removes its run loop source, and invalidates mach port.
    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        
        if let machPort = machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(machPort)
            self.machPort = nil
            self.runLoopSource = nil
            print("[MediaKeyInterceptor] Event tap destroyed and system hooks released.")
        }
    }
    
    /// Checks whether the application has Accessibility permissions.
    private func checkAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Polls periodically for Accessibility permission after prompting the user.
    private func startAccessibilityPolling() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            if self.checkAccessibility(prompt: false) {
                print("[MediaKeyInterceptor] Accessibility permission granted by user!")
                timer.invalidate()
                self.retryTimer = nil
                self.setupEventTap()
            }
        }
    }
    
    /// Sets up the event tap targeting kCGHIDEventTap at kCGHeadInsertEventTap.
    private func setupEventTap() {
        guard machPort == nil else { return }
        
        // Listen for NX_SYSDEFINED events (event type 14)
        let eventMask: CGEventMask = (1 << MediaKeyInterceptor.NX_SYSDEFINED_TYPE)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return interceptor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            print("[MediaKeyInterceptor] Failed to create event tap. Check Accessibility permissions.")
            startAccessibilityPolling()
            return
        }
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        self.machPort = tap
        self.runLoopSource = source
        print("[MediaKeyInterceptor] Low-level HID media key tap successfully active at head insert.")
    }
    
    /// Callback handler for the event tap.
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS can disable event taps if they timeout or during system input switches.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort = self.machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
                print("[MediaKeyInterceptor] Re-enabled tap after system timeout/pause.")
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Check for NX_SYSDEFINED events
        if type.rawValue == MediaKeyInterceptor.NX_SYSDEFINED_TYPE {
            if let nsEvent = NSEvent(cgEvent: event),
               nsEvent.subtype.rawValue == MediaKeyInterceptor.NX_SUBTYPE_AUX_CONTROL_BUTTONS {
                
                let data1 = nsEvent.data1
                let keyCode = Int((data1 & 0xFFFF0000) >> 16)
                let keyFlags = data1 & 0x0000FFFF
                let keyState = (keyFlags & 0xFF00) >> 8
                let isRepeat = (keyFlags & 0x1) != 0
                
                // Intercept Play/Pause media key
                if keyCode == MediaKeyInterceptor.NX_KEYTYPE_PLAY {
                    // keyState 0xA corresponds to key down (NX_KEYDOWN)
                    if keyState == 0xA && !isRepeat {
                        // Dispatch handling asynchronously to avoid blocking the event tap
                        DispatchQueue.main.async { [weak self] in
                            self?.onPlayPausePressed?()
                        }
                    }
                    
                    // Consume both key down and key up events by returning nil.
                    // This prevents mediaremoted and default system daemons from guessing the playback target.
                    return nil
                }
            }
        }
        
        // Let all other events (volume, brightness, next/prev tracks) pass through untouched
        return Unmanaged.passUnretained(event)
    }
}
