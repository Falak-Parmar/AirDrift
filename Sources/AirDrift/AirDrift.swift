import Foundation
import CoreGraphics
import AppKit
import SwiftUI

class WebSocketClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    
    var onMessageReceived: (@Sendable (String) -> Void)?
    var onConnectionStateChanged: (@Sendable (Bool) -> Void)?
    private(set) var isConnected = false
    
    init(ipAddress: String, port: Int = 8080) {
        self.url = URL(string: "ws://\(ipAddress):\(port)")!
        super.init()
    }
    
    func connect() {
        print("Connecting to Android Hub at \(url)...")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
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
    
    func disconnect() {
        guard isConnected || webSocketTask != nil else { return }
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        notifyConnectionState(false)
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("WebSocket connected successfully to \(url)!")
        isConnected = true
        notifyConnectionState(true)
        receiveMessage()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("⚠️ WebSocket task complete with error: \(error.localizedDescription)")
        }
        handleDisconnect()
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isConnected else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.notifyMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.notifyMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                print("⚠️ WebSocket receive failed: \(error.localizedDescription)")
                self.handleDisconnect()
            }
        }
    }
    
    private func handleDisconnect() {
        if isConnected || webSocketTask != nil {
            isConnected = false
            webSocketTask = nil
            notifyConnectionState(false)
            
            // Try to reconnect after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.connect()
            }
        }
    }

    private func notifyConnectionState(_ state: Bool) {
        self.onConnectionStateChanged?(state)
    }

    private func notifyMessage(_ message: String) {
        self.onMessageReceived?(message)
    }
}

class InputManager: @unchecked Sendable {
    private let webSocketClient: WebSocketClient
    private var displayBounds: [CGDirectDisplayID: CGRect] = [:]
    private var rightmostX: CGFloat = 0.0
    private var leftmostX: CGFloat = 0.0
    private var mainDisplayID: CGDirectDisplayID = 0
    
    private(set) var isLocked = false
    private var exitY: CGFloat = 0.0
    private var lastUnlockTime: TimeInterval = 0
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // UI tweaks populated by AirDriftService config
    var scrollSensitivity: Double = 0.4
    var edgeThreshold: CGFloat = 10.0
    var lockCooldown: Double = 0.5
    
    var onLockStateChanged: (@Sendable (Bool) -> Void)?
    
    init(webSocketClient: WebSocketClient) {
        self.webSocketClient = webSocketClient
        self.mainDisplayID = CGMainDisplayID()
        updateDisplayBounds()
        
        webSocketClient.onConnectionStateChanged = { [weak self] isConnected in
            if !isConnected {
                self?.unlockCursor()
            }
        }
    }
    
    deinit {
        stop()
    }
    
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
            print("\n❌ ERROR: Failed to create CGEventTap. Please grant Accessibility permissions in System Settings.\n")
            return
        }
        
        self.eventTap = eventTap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("AirDrift Event Interceptor is running.")
    }
    
    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        eventTap = nil
        runLoopSource = nil
        if isLocked {
            isLocked = false
            notifyLockState(false)
        }
    }
    
    func unlockCursor() {
        guard isLocked else { return }
        isLocked = false
        lastUnlockTime = Date().timeIntervalSince1970
        notifyLockState(false)
        print("🔓 Unlocked. Returning cursor control to macOS.")
        
        let warpPos = CGPoint(x: leftmostX + 30, y: exitY)
        CGWarpMouseCursorPosition(warpPos)
    }
    
    private func notifyLockState(_ locked: Bool) {
        self.onLockStateChanged?(locked)
    }
    
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if !isLocked {
            if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
                let location = event.location
                
                if location.x <= leftmostX + edgeThreshold {
                    let now = Date().timeIntervalSince1970
                    if now - lastUnlockTime > lockCooldown {
                        if webSocketClient.isConnected {
                            isLocked = true
                            exitY = location.y
                            notifyLockState(true)
                            print("🔒 Locked! Entering Android screen space (Exit Y: \(exitY))")
                            
                            let mainBounds = displayBounds[mainDisplayID] ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
                            let yRatio = exitY / mainBounds.height
                            
                            webSocketClient.send(message: "{\"type\": \"enter\", \"y_ratio\": \(yRatio)}")
                            return nil
                        }
                    }
                }
            }
            return Unmanaged.passRetained(event)
        } else {
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 53 { // ESC
                    unlockCursor()
                    return Unmanaged.passRetained(event)
                }
            }
            
            if event.flags.contains(.maskCommand) {
                if type == .keyDown || type == .keyUp {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let state = (type == .keyDown) ? "down" : "up"
                    
                    var targetCode: Int? = nil
                    switch keyCode {
                    case 4: targetCode = 10001 // Cmd + H (Home)
                    case 11, 51: targetCode = 10002 // Cmd + B / Cmd + Backspace (Back)
                    case 15, 48: targetCode = 10003 // Cmd + R / Cmd + Tab (Recents)
                    case 45: targetCode = 10004 // Cmd + N (Notifications)
                    default: break
                    }
                    
                    if let code = targetCode {
                        webSocketClient.send(message: "{\"type\": \"keyboard_key\", \"keycode\": \(code), \"state\": \"\(state)\"}")
                        return nil
                    }
                }
            }
            
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                let dx = event.getIntegerValueField(.mouseEventDeltaX)
                let dy = event.getIntegerValueField(.mouseEventDeltaY)
                
                if dx != 0 || dy != 0 {
                    webSocketClient.send(message: "{\"type\": \"mouse_move\", \"dx\": \(dx), \"dy\": \(dy)}")
                }
                
                let location = event.location
                if location.x > leftmostX + 5.0 {
                    CGWarpMouseCursorPosition(CGPoint(x: leftmostX, y: exitY))
                }
                
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
                
                // Adjust scroll multiplier relative to base speed of 1.0 (internal 0.4 scaling is handled phone-side)
                let scaledDy = Double(dy) * scrollSensitivity
                let scaledDx = Double(dx) * scrollSensitivity
                
                webSocketClient.send(message: "{\"type\": \"scroll\", \"dx\": \(Int(scaledDx)), \"dy\": \(Int(scaledDy))}")
                
            default:
                break
            }
            
            return nil
        }
    }
}

@MainActor
class AirDriftService: ObservableObject {
    @Published var isConnected = false
    @Published var isLocked = false
    @Published var isDeviceConnected = false
    @Published var adbStatusMessage = "Checking ADB connection..."
    
    // UI tweaks saved in UserDefaults
    @Published var scrollSensitivity: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(scrollSensitivity, forKey: "AirDriftScrollSensitivity")
            inputManager?.scrollSensitivity = scrollSensitivity
        }
    }
    
    @Published var edgeThreshold: Double = 10.0 {
        didSet {
            UserDefaults.standard.set(edgeThreshold, forKey: "AirDriftEdgeThreshold")
            inputManager?.edgeThreshold = CGFloat(edgeThreshold)
        }
    }
    
    @Published var lockCooldown: Double = 0.5 {
        didSet {
            UserDefaults.standard.set(lockCooldown, forKey: "AirDriftLockCooldown")
            inputManager?.lockCooldown = lockCooldown
        }
    }
    
    private var webSocketClient: WebSocketClient?
    private var inputManager: InputManager?
    private var adbDaemonProcess: Process?
    
    init() {
        self.scrollSensitivity = UserDefaults.standard.double(forKey: "AirDriftScrollSensitivity") == 0 ? 1.0 : UserDefaults.standard.double(forKey: "AirDriftScrollSensitivity")
        self.edgeThreshold = UserDefaults.standard.double(forKey: "AirDriftEdgeThreshold") == 0 ? 10.0 : UserDefaults.standard.double(forKey: "AirDriftEdgeThreshold")
        self.lockCooldown = UserDefaults.standard.double(forKey: "AirDriftLockCooldown") == 0 ? 0.5 : UserDefaults.standard.double(forKey: "AirDriftLockCooldown")
        
        checkDeviceConnection()
    }
    
    func checkDeviceConnection() {
        Task.detached {
            let adbPath = self.findADBPath()
            let process = Process()
            
            if adbPath == "/usr/bin/env" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["adb", "devices"]
            } else {
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = ["devices"]
            }
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines)
                    var deviceCount = 0
                    for line in lines {
                        let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanLine.isEmpty && !cleanLine.contains("List of devices attached") && !cleanLine.contains("daemon not running") && !cleanLine.contains("daemon started successfully") {
                            deviceCount += 1
                        }
                    }
                    
                    let connected = deviceCount > 0
                    let message = connected ? "📱 Device detected via ADB" : "⚠️ No ADB Device. Connect your phone."
                    
                    await MainActor.run {
                        self.isDeviceConnected = connected
                        self.adbStatusMessage = message
                    }
                }
            } catch {
                await MainActor.run {
                    self.isDeviceConnected = false
                    self.adbStatusMessage = "⚠️ ADB Command not found."
                }
            }
        }
    }
    
    nonisolated private func findADBPath() -> String {
        let fileManager = FileManager.default
        let homeDir = NSHomeDirectory()
        let commonPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(homeDir)/Library/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]
        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/env"
    }
    
    private func runADBCommand(arguments: [String]) -> String? {
        let adbPath = findADBPath()
        let process = Process()
        
        if adbPath == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["adb"] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = arguments
        }
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    
    private func getAndroidDisplaySize() -> (width: Int, height: Int) {
        if let output = runADBCommand(arguments: ["shell", "wm", "size"]) {
            let pattern = #"\d+x\d+"#
            if let range = output.range(of: pattern, options: .regularExpression) {
                let sizeStr = String(output[range])
                let parts = sizeStr.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    return (w, h)
                }
            }
        }
        return (1080, 2320)
    }
    
    func connect() {
        guard webSocketClient == nil else { return }
        
        _ = runADBCommand(arguments: ["forward", "tcp:8080", "tcp:8080"])
        
        let (width, height) = getAndroidDisplaySize()
        print("Resolved display boundaries: \(width)x\(height)")
        
        print("Launching Android injector daemon...")
        let adbPath = findADBPath()
        let process = Process()
        if adbPath == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["adb", "shell", "export CLASSPATH=/data/local/tmp/app-debug.apk; exec app_process /data/local/tmp com.drift.droiddrift.AdbMain \(width) \(height)"]
        } else {
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["shell", "export CLASSPATH=/data/local/tmp/app-debug.apk; exec app_process /data/local/tmp com.drift.droiddrift.AdbMain \(width) \(height)"]
        }
        
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            self.adbDaemonProcess = process
        } catch {
            print("Failed to run ADB daemon: \(error.localizedDescription)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            
            let client = WebSocketClient(ipAddress: "127.0.0.1")
            self.webSocketClient = client
            
            let manager = InputManager(webSocketClient: client)
            manager.scrollSensitivity = self.scrollSensitivity
            manager.edgeThreshold = CGFloat(self.edgeThreshold)
            manager.lockCooldown = self.lockCooldown
            self.inputManager = manager
            
            client.onConnectionStateChanged = { [weak self] isConnected in
                Task { @MainActor in
                    self?.isConnected = isConnected
                }
            }
            
            manager.onLockStateChanged = { [weak self] isLocked in
                Task { @MainActor in
                    self?.isLocked = isLocked
                }
            }
            
            client.onMessageReceived = { [weak manager] message in
                if message.contains("\"type\": \"exit\"") || message.contains("\"type\":\"exit\"") {
                    manager?.unlockCursor()
                }
            }
            
            client.connect()
            manager.start()
        }
    }
    
    func disconnect() {
        webSocketClient?.disconnect()
        inputManager?.stop()
        webSocketClient = nil
        inputManager = nil
        
        adbDaemonProcess?.terminate()
        adbDaemonProcess = nil
        
        _ = runADBCommand(arguments: ["forward", "--remove", "tcp:8080"])
        _ = runADBCommand(arguments: ["shell", "pkill -f com.drift.droiddrift.AdbMain"])
        
        isConnected = false
        isLocked = false
        
        checkDeviceConnection()
    }
}

// Sidebar Button component for macOS Preferences styling
struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(width: 20, alignment: .center)
                
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// Preferences view modeled in Stats app design paradigm
struct MainPreferencesView: View {
    @ObservedObject var service: AirDriftService
    @State private var selectedTab = "dashboard"
    @Environment(\.colorScheme) var colorScheme
    
    var sidebarColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.12, green: 0.12, blue: 0.14) // Deep sidebar charcoal
        } else {
            return Color(red: 0.94, green: 0.94, blue: 0.96) // Softer gray sidebar
        }
    }
    
    var contentColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.07, green: 0.07, blue: 0.08) // Pitch black/charcoal content area
        } else {
            return Color(red: 1.0, green: 1.0, blue: 1.0) // Pure white content area
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            VStack(spacing: 4) {
                SidebarButton(title: "Dashboard", icon: "laptopcomputer", isSelected: selectedTab == "dashboard") {
                    selectedTab = "dashboard"
                }
                SidebarButton(title: "Settings", icon: "slider.horizontal.3", isSelected: selectedTab == "settings") {
                    selectedTab = "settings"
                }
                SidebarButton(title: "About", icon: "info.circle", isSelected: selectedTab == "about") {
                    selectedTab = "about"
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(width: 145)
            .background(sidebarColor)
            
            Divider()
            
            // Content panel
            VStack(alignment: .leading, spacing: 0) {
                if selectedTab == "dashboard" {
                    DashboardSettingsView(service: service)
                } else if selectedTab == "settings" {
                    PreferencesSettingsView(service: service)
                } else {
                    AboutSettingsView()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(contentColor)
        }
        .frame(width: 550, height: 340)
    }
}

struct DashboardSettingsView: View {
    @ObservedObject var service: AirDriftService
    @State private var isHoveringConnect = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dashboard")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)
            
            // Connection Status Panel
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Connection")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(service.isConnected ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(service.isConnected ? "Active" : "Idle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(service.isConnected ? Color.green : .secondary)
                    }
                }
                
                Text(service.adbStatusMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            // Main Action Button
            Button(action: {
                if service.isConnected {
                    service.disconnect()
                } else {
                    service.connect()
                }
            }) {
                Text(service.isConnected ? "Disconnect" : "Connect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(
                        !service.isDeviceConnected && !service.isConnected ?
                        Color.secondary :
                        (service.isConnected ? .red : Color(NSColor.windowBackgroundColor))
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        !service.isDeviceConnected && !service.isConnected ?
                        Color.primary.opacity(0.05) :
                        (service.isConnected ? Color.red.opacity(0.15) : Color.primary)
                    )
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!service.isDeviceConnected && !service.isConnected)
            .scaleEffect(isHoveringConnect && (service.isDeviceConnected || service.isConnected) ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHoveringConnect)
            .onHover { hovering in
                isHoveringConnect = hovering
            }
            
            Spacer()
        }
    }
}

struct PreferencesSettingsView: View {
    @ObservedObject var service: AirDriftService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(spacing: 12) {
                // Scroll multiplier
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Scroll Speed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "%.1fx", service.scrollSensitivity))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $service.scrollSensitivity, in: 0.2...2.0, step: 0.1)
                }
                
                // Edge Width
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Border Locking Width")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "%.0f px", service.edgeThreshold))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $service.edgeThreshold, in: 2...25, step: 1)
                }
                
                // Cooldown
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Screen Re-entry Cooldown")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "%.1f s", service.lockCooldown))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $service.lockCooldown, in: 0.1...1.5, step: 0.1)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            Spacer()
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(spacing: 8) {
                if let path = Bundle.main.path(forResource: "my-notion-face-transparent", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .padding(.bottom, 2)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                        .frame(width: 54, height: 54)
                        .padding(.bottom, 2)
                }
                
                Link("Falak Parmar", destination: URL(string: "https://github.com/Falak-Parmar")!)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                
                Link("https://github.com/Falak-Parmar", destination: URL(string: "https://github.com/Falak-Parmar")!)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text("AirDrift v1.0.0")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                
                Text("An automated monochrome system controller linking macOS mouse, keyboard, and scroll inputs to Android virtual device nodes.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.primary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 6)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            Spacer()
        }
    }
}

struct PopoverView: View {
    @ObservedObject var service: AirDriftService
    @State private var isHoveringConnect = false
    @State private var isHoveringQuit = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 18))
                    .foregroundColor(.primary)
                
                Text("AirDrift")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Settings button to open the dashboard app window
                Button(action: {
                    AppDelegate.shared?.showPreferencesWindow()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                
                // Status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(service.isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(service.isConnected ? "Active" : "Idle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(service.isConnected ? Color.green : .secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
            }
            
            Divider()
            
            // Connection Box
            VStack(alignment: .leading, spacing: 4) {
                Text("ADB Tunnel")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(service.adbStatusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            
            // Connect Toggle
            Button(action: {
                if service.isConnected {
                    service.disconnect()
                } else {
                    service.connect()
                }
            }) {
                Text(service.isConnected ? "Disconnect" : "Connect")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(
                        !service.isDeviceConnected && !service.isConnected ?
                        Color.secondary :
                        (service.isConnected ? .red : Color(NSColor.windowBackgroundColor))
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        !service.isDeviceConnected && !service.isConnected ?
                        Color.primary.opacity(0.05) :
                        (service.isConnected ? Color.red.opacity(0.15) : Color.primary)
                    )
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!service.isDeviceConnected && !service.isConnected)
            .scaleEffect(isHoveringConnect && (service.isDeviceConnected || service.isConnected) ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHoveringConnect)
            .onHover { hovering in
                isHoveringConnect = hovering
            }
            
            Divider()
            
            // Footer Panel
            HStack {
                if service.isLocked {
                    Text("🔒 Active Link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)
                } else {
                    Text("🔓 Local Control")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    service.disconnect()
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isHoveringQuit ? Color.primary.opacity(0.08) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringQuit = hovering
                }
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            service.checkDeviceConnection()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var window: NSWindow?
    let service = AirDriftService()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 250, height: 210)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(service: service))
        self.popover = popover
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "AirDrift")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Listen globally for Cmd+Q when this app has active key windows
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
                NSApplication.shared.terminate(nil)
                return nil
            }
            return event
        }
        
        // Show preferences/dashboard window automatically when launched
        showPreferencesWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferencesWindow()
        return true
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(sender)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                if let window = popover?.contentViewController?.view.window {
                    window.makeKey()
                }
            }
        }
    }
    
    @objc func showPreferencesWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 340),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AirDrift Settings"
            window.contentViewController = NSHostingController(rootView: MainPreferencesView(service: service))
            self.window = window
        }
        popover?.performClose(nil)
        window?.makeKeyAndOrderFront(nil)
        
        // Manual centering calculation to bypass system accessory policy notch anchoring
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowWidth: CGFloat = 550
            let windowHeight: CGFloat = 340
            let newX = screenRect.origin.x + (screenRect.width - windowWidth) / 2
            let newY = screenRect.origin.y + (screenRect.height - windowHeight) / 2
            window?.setFrame(NSRect(x: newX, y: newY, width: windowWidth, height: windowHeight), display: true, animate: false)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AirDrift {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
