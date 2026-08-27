import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Network

// MARK: - Input event types (mirror of client-side JSON)

struct InputEvent: Codable {
    let type: String         // click, mousedown, mouseup, mousemove, keydown, keyup, scroll, resize, move
    let x: Double?
    let y: Double?
    let button: Int?         // 0=left,1=middle,2=right
    let clickCount: Int?
    let deltaX: Double?
    let deltaY: Double?
    let keyCode: Int?
    let key: String?
    let modifiers: [String]?
    let width: Double?       // for resize
    let height: Double?
    let windowID: UInt32?
}

// MARK: - AX window controller

final class WindowController {
    private let pid: pid_t
    private let axApp: AXUIElement
    private var axWindow: AXUIElement?

    init(pid: pid_t) {
        self.pid = pid
        self.axApp = AXUIElementCreateApplication(pid)
    }

    func findWindow(id: CGWindowID) {
        // Match AX window to CGWindowID by comparing bounds from CGWindowListCopyWindowInfo
        // against the AX window position/size (public API only — no SPI).
        guard let cgInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = cgInfo.first,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let cgX = boundsDict["X"] as? Double,
              let cgY = boundsDict["Y"] as? Double else { return }
        let cgOrigin = CGPoint(x: cgX, y: cgY)

        var windowList: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        guard let windows = windowList as? [AXUIElement] else { return }
        for w in windows {
            var posVal: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posVal) == .success,
                  let posVal else { continue }
            var pt = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
            // Allow 2pt tolerance for rounding
            if abs(pt.x - cgOrigin.x) < 2 && abs(pt.y - cgOrigin.y) < 2 {
                axWindow = w
                return
            }
        }
        // Fallback: use first window
        axWindow = (windows as [AXUIElement]).first
    }

    func move(to point: CGPoint) {
        guard let win = axWindow else { return }
        var pt = point
        let val = AXValueCreate(.cgPoint, &pt)!
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, val)
    }

    func resize(to size: CGSize) {
        guard let win = axWindow else { return }
        var sz = size
        let val = AXValueCreate(.cgSize, &sz)!
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, val)
    }
}

// MARK: - CGEvent helpers

func cgFlags(from modifiers: [String]?) -> CGEventFlags {
    var flags: CGEventFlags = []
    for mod in modifiers ?? [] {
        switch mod.lowercased() {
        case "shift":   flags.insert(.maskShift)
        case "meta", "cmd", "command": flags.insert(.maskCommand)
        case "alt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

func cgButton(from button: Int?) -> CGMouseButton {
    switch button {
    case 1: return .center
    case 2: return .right
    default: return .left
    }
}

func eventType(for button: CGMouseButton, down: Bool) -> CGEventType {
    switch button {
    case .left:   return down ? .leftMouseDown  : .leftMouseUp
    case .right:  return down ? .rightMouseDown : .rightMouseUp
    default:      return down ? .otherMouseDown : .otherMouseUp
    }
}

// MARK: - Input dispatcher

final class InputDispatcher {
    // windowID → (pid, WindowController)
    private var controllers: [UInt32: (pid_t, WindowController)] = [:]

    /// Resolve pid for a CGWindowID using CGWindowList
    func resolvePid(for windowID: UInt32) -> pid_t? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]]
        if let entry = list?.first, let pid = entry[kCGWindowOwnerPID as String] as? Int32 {
            return pid_t(pid)
        }
        return nil
    }

    func ensureController(windowID: UInt32) -> WindowController? {
        if let (_, ctrl) = controllers[windowID] { return ctrl }
        guard let pid = resolvePid(for: windowID) else { return nil }
        let ctrl = WindowController(pid: pid)
        ctrl.findWindow(id: CGWindowID(windowID))
        controllers[windowID] = (pid, ctrl)
        return ctrl
    }

    func dispatch(_ event: InputEvent) {
        switch event.type {
        case "click":
            guard let x = event.x, let y = event.y else { return }
            let pt = CGPoint(x: x, y: y)
            let btn = cgButton(from: event.button)
            let count = event.clickCount ?? 1
            let mods = cgFlags(from: event.modifiers)

            for _ in 0..<count {
                if let e = CGEvent(mouseEventSource: nil, mouseType: eventType(for: btn, down: true), mouseCursorPosition: pt, mouseButton: btn) {
                    e.flags = mods
                    e.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.02)
                if let e = CGEvent(mouseEventSource: nil, mouseType: eventType(for: btn, down: false), mouseCursorPosition: pt, mouseButton: btn) {
                    e.flags = mods
                    e.post(tap: .cghidEventTap)
                }
            }

        case "mousedown":
            guard let x = event.x, let y = event.y else { return }
            let pt = CGPoint(x: x, y: y)
            let btn = cgButton(from: event.button)
            if let e = CGEvent(mouseEventSource: nil, mouseType: eventType(for: btn, down: true), mouseCursorPosition: pt, mouseButton: btn) {
                e.flags = cgFlags(from: event.modifiers)
                e.post(tap: .cghidEventTap)
            }

        case "mouseup":
            guard let x = event.x, let y = event.y else { return }
            let pt = CGPoint(x: x, y: y)
            let btn = cgButton(from: event.button)
            if let e = CGEvent(mouseEventSource: nil, mouseType: eventType(for: btn, down: false), mouseCursorPosition: pt, mouseButton: btn) {
                e.flags = cgFlags(from: event.modifiers)
                e.post(tap: .cghidEventTap)
            }

        case "mousemove":
            guard let x = event.x, let y = event.y else { return }
            let pt = CGPoint(x: x, y: y)
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }

        case "scroll":
            guard let x = event.x, let y = event.y else { return }
            let pt = CGPoint(x: x, y: y)
            let dy = Int32(event.deltaY ?? 0)
            let dx = Int32(event.deltaX ?? 0)
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) {
                e.location = pt
                e.post(tap: CGEventTapLocation.cghidEventTap)
            }

        case "keydown":
            if let keyCode = event.keyCode {
                if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) {
                    e.flags = cgFlags(from: event.modifiers)
                    e.post(tap: .cghidEventTap)
                }
            }

        case "keyup":
            if let keyCode = event.keyCode {
                if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) {
                    e.flags = cgFlags(from: event.modifiers)
                    e.post(tap: .cghidEventTap)
                }
            }

        case "move":
            guard let wid = event.windowID,
                  let x = event.x, let y = event.y,
                  let ctrl = ensureController(windowID: wid) else { return }
            ctrl.move(to: CGPoint(x: x, y: y))

        case "resize":
            guard let wid = event.windowID,
                  let w = event.width, let h = event.height,
                  let ctrl = ensureController(windowID: wid) else { return }
            ctrl.resize(to: CGSize(width: w, height: h))

        default:
            fputs("[input] unknown event type: \(event.type)\n", stderr)
        }
    }
}

// MARK: - WebSocket client (connects to server port 8767)

final class InputBridgeClient {
    private var connection: NWConnection?
    private let dispatcher = InputDispatcher()
    private let queue = DispatchQueue(label: "input-bridge")
    private let serverPort: UInt16
    private var reconnectTimer: DispatchSourceTimer?

    init(serverPort: UInt16 = 8767) {
        self.serverPort = serverPort
    }

    func connect() {
        let params = NWParameters.tcp
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        let conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: serverPort)!,
            using: params
        )
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                fputs("[input] connected to server\n", stderr)
                self?.receive()
            case .failed(let err):
                fputs("[input] connection failed: \(err) — retrying in 2s\n", stderr)
                self?.scheduleReconnect()
            case .cancelled:
                fputs("[input] connection cancelled\n", stderr)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, ctx, isComplete, error in
            if let error {
                fputs("[input] receive error: \(error)\n", stderr)
                self?.scheduleReconnect()
                return
            }
            if let data, !data.isEmpty {
                self?.handleMessage(data)
            }
            self?.receive() // loop
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            let event = try JSONDecoder().decode(InputEvent.self, from: data)
            dispatcher.dispatch(event)
        } catch {
            fputs("[input] decode error: \(error) — \(String(data: data, encoding: .utf8) ?? "?")\n", stderr)
        }
    }

    private func scheduleReconnect() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2)
        timer.setEventHandler { [weak self] in self?.connect() }
        timer.resume()
        reconnectTimer = timer
    }
}

// MARK: - Entry point

@main
struct InputBridge {
    static func main() {
        fputs("[input] starting\n", stderr)
        let serverPort: UInt16 = {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--port"), i + 1 < args.count {
                return UInt16(args[i + 1]) ?? 8767
            }
            return 8767
        }()

        let client = InputBridgeClient(serverPort: serverPort)
        client.connect()
        RunLoop.main.run()
    }
}
