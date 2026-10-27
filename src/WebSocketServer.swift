import Foundation
import Network

/// Embedded local WebSocket server using Network.framework (NWListener) bound strictly
/// to 127.0.0.1:49281. Provides bidirectional JSON IPC with the local Chrome Extension.
final class WebSocketServer {
    private let port: UInt16 = 49281
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.psychaudio.websocketserver", qos: .userInitiated)
    
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsLock = NSLock()
    
    // Callbacks for inbound tab events
    var onTabPlaying: ((Int) -> Void)?
    var onTabPaused: ((Int) -> Void)?
    var onTabClosed: ((Int) -> Void)?
    
    var hasActiveConnections: Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return !connections.isEmpty
    }
    
    init() {}
    
    deinit {
        stop()
    }
    
    /// Starts the WebSocket listener bound exclusively to loopback IPv4 (127.0.0.1) on port 49281.
    func start() {
        guard listener == nil else { return }
        
        do {
            let tcpOptions = NWProtocolTCP.Options()
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            
            // Bind strictly to 127.0.0.1
            guard let portEndpoint = NWEndpoint.Port(rawValue: self.port) else {
                print("[WebSocketServer] Invalid port: \(self.port)")
                return
            }
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: portEndpoint)
            
            let nwListener = try NWListener(using: parameters)
            
            nwListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[WebSocketServer] Listening on ws://127.0.0.1:\(self?.port ?? 0)")
                case .failed(let error):
                    print("[WebSocketServer] Listener failed with error: \(error)")
                case .cancelled:
                    print("[WebSocketServer] Listener cancelled.")
                default:
                    break
                }
            }
            
            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            nwListener.start(queue: serverQueue)
            self.listener = nwListener
        } catch {
            print("[WebSocketServer] Failed to create listener: \(error)")
        }
    }
    
    /// Cleanly stops the listener and closes all active client connections.
    func stop() {
        listener?.cancel()
        listener = nil
        
        connectionsLock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        connectionsLock.unlock()
        
        for conn in active {
            conn.cancel()
        }
        print("[WebSocketServer] WebSocket server stopped and all client connections terminated.")
    }
    
    /// Sends a toggle_playback command for a specific tab ID to the connected Chrome extension.
    func sendTogglePlayback(tabId: Int) {
        let payload: [String: Any] = [
            "action": "toggle_playback",
            "tabId": tabId
        ]
        
        broadcast(payload: payload)
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        // Enforce strict 127.0.0.1 loopback connection security check
        if case .hostPort(let host, _) = connection.endpoint {
            if host != .ipv4(.loopback) {
                print("[WebSocketServer] Rejected non-127.0.0.1 connection from: \(connection.endpoint)")
                connection.cancel()
                return
            }
        }
        
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            let id = ObjectIdentifier(conn)
            
            switch state {
            case .ready:
                print("[WebSocketServer] Client connected: \(conn.endpoint)")
                self.connectionsLock.lock()
                self.connections[id] = conn
                self.connectionsLock.unlock()
                
                self.receiveNextMessage(on: conn)
                
            case .failed(let error):
                print("[WebSocketServer] Connection failed (\(conn.endpoint)): \(error)")
                self.removeConnection(id: id, connection: conn)
                
            case .cancelled:
                self.removeConnection(id: id, connection: conn)
                
            default:
                break
            }
        }
        
        connection.start(queue: serverQueue)
    }
    
    private func removeConnection(id: ObjectIdentifier, connection: NWConnection) {
        connectionsLock.lock()
        connections.removeValue(forKey: id)
        connectionsLock.unlock()
        connection.cancel()
        print("[WebSocketServer] Client disconnected: \(connection.endpoint)")
    }
    
    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, context, isComplete, error in
            guard let self = self, let conn = connection else { return }
            let id = ObjectIdentifier(conn)
            
            if let error = error {
                print("[WebSocketServer] Receive error: \(error)")
                self.removeConnection(id: id, connection: conn)
                return
            }
            
            if let metadata = context?.protocolMetadata.compactMap({ $0 as? NWProtocolWebSocket.Metadata }).first {
                switch metadata.opcode {
                case .text:
                    if let data = content, let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingJSON(text)
                    }
                case .close:
                    self.removeConnection(id: id, connection: conn)
                    return
                default:
                    break
                }
            }
            
            // Continue listening for the next message
            self.receiveNextMessage(on: conn)
        }
    }
    
    private func handleIncomingJSON(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }
        
        let tabId = json["tabId"] as? Int
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch event {
            case "tab_playing":
                if let tabId = tabId {
                    self.onTabPlaying?(tabId)
                }
            case "tab_paused":
                if let tabId = tabId {
                    self.onTabPaused?(tabId)
                }
            case "tab_closed":
                if let tabId = tabId {
                    self.onTabClosed?(tabId)
                }
            case "ping":
                // Inbound keepalive ping; responder can acknowledge
                break
            default:
                print("[WebSocketServer] Unknown event: \(event)")
            }
        }
    }
    
    private func broadcast(payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "wsText", metadata: [metadata])
        
        connectionsLock.lock()
        let active = Array(connections.values)
        connectionsLock.unlock()
        
        for conn in active {
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
                if let error = error {
                    print("[WebSocketServer] Failed to send to client: \(error)")
                }
            }))
        }
    }
}
