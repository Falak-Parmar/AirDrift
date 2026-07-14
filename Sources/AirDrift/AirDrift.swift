import Foundation
import CoreGraphics

class WebSocketClient: @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    var onMessageReceived: ((String) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?
    private(set) var isConnected = false
    
    init(ipAddress: String, port: Int = 8080) {
        self.url = URL(string: "ws://\(ipAddress):\(port)")!
    }
    
    func connect() {
        print("Connecting to Android Hub at \(url)...")
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        onConnectionStateChanged?(true)
        
        receiveMessage()
    }
    
    func send(message: String) {
        guard isConnected else { return }
        let msg = URLSessionWebSocketTask.Message.string(message)
        webSocketTask?.send(msg) { [weak self] error in
            if let error = error {
                print("⚠️ WebSocket send error: \(error.localizedDescription)")
                self?.handleDisconnect()
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.onMessageReceived?(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.onMessageReceived?(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage() // Listen for next message
            case .failure(let error):
                print("⚠️ WebSocket connection lost: \(error.localizedDescription)")
                self.handleDisconnect()
            }
        }
    }
    
    private func handleDisconnect() {
        if isConnected {
            isConnected = false
            onConnectionStateChanged?(false)
            
            // Try to reconnect after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.connect()
            }
        }
    }
}

class InputManager {
    private let webSocketClient: WebSocketClient
    private var displayBounds: [CGDirectDisplayID: CGRect] = [:]
    private var rightmostX: CGFloat = 0.0
    private var leftmostX: CGFloat = 0.0
    private var mainDisplayID: CGDirectDisplayID = 0
    
    private(set) var isLocked = false
    private var exitY: CGFloat = 0.0
    private var lastUnlockTime: TimeInterval = 0
    
    init(webSocketClient: WebSocketClient) {
        self.webSocketClient = webSocketClient
        self.mainDisplayID = CGMainDisplayID()
        updateDisplayBounds()
        
        // Register connection change callback to unlock automatically if server goes down
        webSocketClient.onConnectionStateChanged = { [weak self] isConnected in
            if !isConnected {
                self?.unlockCursor()
            }
        }
    }
    
    /// Queries active display boundaries in CG coordinate system (origin top-left).
    func updateDisplayBounds() {
        let maxDisplays: UInt32 = 16
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        let result = CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
        guard result == .success else {
            print("Warning: Could not fetch active display list.")
            return
        }
        
        displayBounds.removeAll()
        var maxVal: CGFloat = -CGFloat.greatestFiniteMagnitude
        var minVal: CGFloat = CGFloat.greatestFiniteMagnitude
        
        for i in 0..<Int(displayCount) {
            let displayID = activeDisplays[i]
            let bounds = CGDisplayBounds(displayID)
            displayBounds[displayID] = bounds
            
            let maxX = bounds.origin.x + bounds.size.width
            if maxX > maxVal {
                maxVal = maxX
            }
            if bounds.origin.x < minVal {
                minVal = bounds.origin.x
            }
        }
        
        self.rightmostX = maxVal
        self.leftmostX = minVal
        print("Display Layout: [Left limit: \(leftmostX)] <--- [Right limit: \(rightmostX)]")
    }
    
    func start() {
        print("Starting AirDrift CGEventTap monitor...")
        
        // We want to capture mouse moves, drags, key presses, scroll events and releases
        let eventMask = (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.leftMouseDragged.rawValue) |
                        (1 << CGEventType.rightMouseDragged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.leftMouseUp.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseUp.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.scrollWheel.rawValue)
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let manager = Unmanaged<InputManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            print("\n❌ ERROR: Failed to create CGEventTap. Please grant Accessibility permissions to Terminal/App.\n")
            exit(1)
        }
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("AirDrift Event Interceptor is running.")
        print("Emergency Unlock: Press the 'Escape' key if your mouse gets stuck.")
        CFRunLoopRun()
    }
    
    func unlockCursor() {
        guard isLocked else { return }
        isLocked = false
        lastUnlockTime = Date().timeIntervalSince1970
        print("🔓 Unlocked. Returning cursor control to macOS.")
        
        // Warp the cursor back slightly from the edge to prevent immediate re-triggering
        let warpPos = CGPoint(x: leftmostX + 30, y: exitY)
        CGWarpMouseCursorPosition(warpPos)
    }
    
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if !isLocked {
            // Local macOS Mode
            if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
                let location = event.location
                let edgeThreshold: CGFloat = 10.0
                
                // If cursor reaches the left edge, transition to Android mode
                if location.x <= leftmostX + edgeThreshold {
                    let now = Date().timeIntervalSince1970
                    if now - lastUnlockTime > 0.5 { // 500ms cooldown to allow cursor to safely move away from edge
                        if webSocketClient.isConnected {
                            isLocked = true
                            exitY = location.y
                            print("🔒 Locked! Entering Android screen space (Exit Y: \(exitY))")
                            
                            let mainBounds = displayBounds[mainDisplayID] ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
                            let yRatio = exitY / mainBounds.height
                            
                            // Send enter command to Android with normalized relative vertical entry position
                            webSocketClient.send(message: "{\"type\": \"enter\", \"y_ratio\": \(yRatio)}")
                            
                            return nil // Swallow the boundary transition event
                        } else {
                            // Throttle warnings if server is not connected
                            if Int.random(in: 0...100) == 0 {
                                print("⚠️ Cursor hit left edge, but Android target is not connected.")
                            }
                        }
                    }
                }
            }
            return Unmanaged.passRetained(event)
        } else {
            // Android Controlling Mode: Swallow event and stream over WebSocket
            
            // EMERGENCY ESCAPE KEY: If the user presses Escape (keycode 53), unlock local cursor.
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 53 {
                    unlockCursor()
                    return Unmanaged.passRetained(event)
                }
            }
            
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                let dx = event.getIntegerValueField(.mouseEventDeltaX)
                let dy = event.getIntegerValueField(.mouseEventDeltaY)
                print("Sending delta: dx=\(dx), dy=\(dy)")
                webSocketClient.send(message: "{\"type\": \"mouse_move\", \"dx\": \(dx), \"dy\": \(dy)}")
                
            case .leftMouseDown:
                webSocketClient.send(message: "{\"type\": \"mouse_button\", \"button\": \"left\", \"state\": \"down\"}")
            case .leftMouseUp:
                webSocketClient.send(message: "{\"type\": \"mouse_button\", \"button\": \"left\", \"state\": \"up\"}")
            case .rightMouseDown:
                webSocketClient.send(message: "{\"type\": \"mouse_button\", \"button\": \"right\", \"state\": \"down\"}")
            case .rightMouseUp:
                webSocketClient.send(message: "{\"type\": \"mouse_button\", \"button\": \"right\", \"state\": \"up\"}")
                
            case .keyDown:
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                webSocketClient.send(message: "{\"type\": \"keyboard_key\", \"keycode\": \(keyCode), \"state\": \"down\"}")
            case .keyUp:
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                webSocketClient.send(message: "{\"type\": \"keyboard_key\", \"keycode\": \(keyCode), \"state\": \"up\"}")
                
            case .scrollWheel:
                let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                webSocketClient.send(message: "{\"type\": \"scroll\", \"dx\": \(dx), \"dy\": \(dy)}")
                
            default:
                break
            }
            
            return nil // Swallow all events so they don't affect local Mac
        }
    }
}

@main
struct AirDrift {
    static func main() {
        print("=== AirDrift macOS Transmitter ===")
        
        let args = CommandLine.arguments
        let ipAddress: String
        if args.count > 1 {
            ipAddress = args[1]
        } else {
            ipAddress = "192.168.1.100" // Fallback IP
            print("No IP address specified. Using default: \(ipAddress)")
            print("Usage: swift run AirDrift <Android_IP_Address>")
        }
        
        let client = WebSocketClient(ipAddress: ipAddress)
        let manager = InputManager(webSocketClient: client)
        
        // Listen to messages from Android (e.g. exit back to Mac)
        client.onMessageReceived = { message in
            if message.contains("\"type\": \"exit\"") || message.contains("\"type\":\"exit\"") {
                manager.unlockCursor()
            }
        }
        
        client.connect()
        manager.start()
    }
}
