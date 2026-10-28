import Foundation
import AVFoundation
import MediaPlayer

/// Manages system-wide Now Playing status and remote command center events
/// for external audio peripherals (AirPods, Bluetooth headphones, AVRCP controllers).
final class RemoteMediaController {
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    
    // Command center targets for cleanup
    private var playPauseTarget: Any?
    private var playTarget: Any?
    private var pauseTarget: Any?
    
    // Callback invoked when a remote play/pause command is received
    var onRemotePlayPause: (() -> Void)?
    
    init() {}
    
    deinit {
        stop()
    }
    
    /// Starts the silent background audio output and registers remote command handlers.
    func start() {
        startSilentAudioEngine()
        setupNowPlayingInfo()
        setupRemoteCommandCenter()
    }
    
    /// Stops the audio engine and releases remote command handlers.
    func stop() {
        stopSilentAudioEngine()
        tearDownRemoteCommandCenter()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // MARK: - Silent Audio Output Engine
    
    private func startSilentAudioEngine() {
        guard audioEngine == nil else { return }
        
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            print("[RemoteMediaController] Failed to create audio format.")
            return
        }
        
        // Zero-overhead silent audio source node that outputs zeroed buffers
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
        
        engine.attach(node)
        
        do {
            try engine.connectNode(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.0 // Completely silent, zero overhead
            try engine.start()
            self.audioEngine = engine
            self.sourceNode = node
            print("[RemoteMediaController] Silent background audio engine active.")
        } catch {
            print("[RemoteMediaController] Failed to start silent audio engine: \(error)")
        }
    }
    
    private func stopSilentAudioEngine() {
        if let engine = audioEngine {
            engine.stop()
            if let node = sourceNode {
                engine.detach(node)
            }
            audioEngine = nil
            sourceNode = nil
            print("[RemoteMediaController] Silent background audio engine stopped.")
        }
    }
    
    // MARK: - Now Playing Info Center
    
    private func setupNowPlayingInfo() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "PsychAudio",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // MARK: - Remote Command Center (MPRemoteCommandCenter)
    
    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        
        // togglePlayPauseCommand (e.g., AirPods stem press, Bluetooth headphone multi-function button)
        center.togglePlayPauseCommand.isEnabled = true
        playPauseTarget = center.togglePlayPauseCommand.addTarget { [weak self] event in
            print("[RemoteMediaController] Received togglePlayPauseCommand from peripheral.")
            DispatchQueue.main.async {
                self?.onRemotePlayPause?()
            }
            return .success
        }
        
        // playCommand
        center.playCommand.isEnabled = true
        playTarget = center.playCommand.addTarget { [weak self] event in
            print("[RemoteMediaController] Received playCommand from peripheral.")
            DispatchQueue.main.async {
                self?.onRemotePlayPause?()
            }
            return .success
        }
        
        // pauseCommand
        center.pauseCommand.isEnabled = true
        pauseTarget = center.pauseCommand.addTarget { [weak self] event in
            print("[RemoteMediaController] Received pauseCommand from peripheral.")
            DispatchQueue.main.async {
                self?.onRemotePlayPause?()
            }
            return .success
        }
        
        print("[RemoteMediaController] Registered MPRemoteCommandCenter handlers.")
    }
    
    private func tearDownRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        if let target = playPauseTarget {
            center.togglePlayPauseCommand.removeTarget(target)
            center.togglePlayPauseCommand.isEnabled = false
            playPauseTarget = nil
        }
        if let target = playTarget {
            center.playCommand.removeTarget(target)
            center.playCommand.isEnabled = false
            playTarget = nil
        }
        if let target = pauseTarget {
            center.pauseCommand.removeTarget(target)
            center.pauseCommand.isEnabled = false
            pauseTarget = nil
        }
    }
}
