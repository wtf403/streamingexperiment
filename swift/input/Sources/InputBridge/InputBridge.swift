import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

// MARK: - SkyLight private symbols
// Loaded once at startup via dlsym. If any symbol is missing we fall back to
// a no-op so the process still launches.

private let skyLight: UnsafeMutableRawPointer? = {
    let paths = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
    ]
    for p in paths { if let h = dlopen(p, RTLD_LAZY | RTLD_LOCAL) { return h } }
    fputs("[input] ⚠️  SkyLight not found – virtual clicks disabled\n", stderr)
    return nil
}()

private func sym<T>(_ name: String) -> T? {
    guard let h = skyLight else { return nil }
    guard let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

// CGSConnectionID cgsMainConnectionID()
private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
private let _cgsMain: CGSMainConnectionIDFn? = sym("CGSMainConnectionID")

// CGError CGSGetWindowOwner(CGSConnectionID cid, CGWindowID wid, CGSConnectionID *owner)
private typealias CGSGetWindowOwnerFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
private let _cgsGetWindowOwner: CGSGetWindowOwnerFn? = sym("CGSGetWindowOwner")

// CGError CGSGetConnectionPSN(CGSConnectionID cid, ProcessSerialNumber *psn)
private typealias CGSGetConnectionPSNFn = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
private let _cgsGetConnectionPSN: CGSGetConnectionPSNFn? = sym("CGSGetConnectionPSN")

// void SLEventPostToPid(pid_t pid, CGEventRef event)
private typealias SLEventPostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
private let _slEventPostToPid: SLEventPostToPidFn? = sym("SLEventPostToPid")

// void CGEventSetWindowLocation(CGEventRef, CGPoint)
private typealias CGEventSetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
private let _cgEventSetWindowLocation: CGEventSetWindowLocationFn? = sym("CGEventSetWindowLocation")

// SLPSPostEventRecordTo for target-only focus
private typealias SLPSPostEventRecordToFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>, Int) -> Int32
private let _slpsPostEventRecordTo: SLPSPostEventRecordToFn? = sym("SLPSPostEventRecordTo")

// MARK: - Input event model

struct InputEvent: Codable {
    let type: String
    let x: Double?
    let y: Double?
    let button: Int?
    let clickCount: Int?
    let deltaX: Double?
    let deltaY: Double?
    let keyCode: Int?
    let key: String?
    let modifiers: [String]?
    let width: Double?
    let height: Double?
    let windowID: UInt32?
}

// MARK: - Window routing info

struct WindowTarget {
    let pid: pid_t
    let windowNumber: Int          // CGWindowID as Int
    let ownerConnection: Int32     // CGSConnectionID of the window's connection
    var psn: ProcessSerialNumber
    let boundsTopLeft: CGPoint     // global, top-left origin (flipped)
}

// MARK: - Target-only focus (no raise, no app activation)
// Sends a raw SkyLight focus record to the target pid/window without
// making it the frontmost application. Matches NativeWindowServerPreparation.targetOnlyFocus.

func targetOnlyFocus(pid: pid_t, windowNumber: Int) {
    guard let postFn = _slpsPostEventRecordTo,
          let getPSN = _cgsGetConnectionPSN,
          let getOwner = _cgsGetWindowOwner,
          let cgsMain = _cgsMain else { return }

    // Build the SkyLight event record (0xF8 bytes, type 0x0D).
    // Layout derived from background-computer-use / SkyLight RE:
    //   +0x00  UInt32  record size = 0xF8
    //   +0x04  UInt32  type        = 0x0D  (focus)
    //   +0x3C  UInt32  window id
    //   +0x8A  UInt8   flag        = 1  (target-only, no defocus-previous)
    var record = [UInt8](repeating: 0, count: 0xF8)
    func write32(_ offset: Int, _ value: UInt32) {
        record[offset+0] = UInt8(value & 0xFF)
        record[offset+1] = UInt8((value >> 8) & 0xFF)
        record[offset+2] = UInt8((value >> 16) & 0xFF)
        record[offset+3] = UInt8((value >> 24) & 0xFF)
    }
    write32(0x00, 0xF8)
    write32(0x04, 0x0D)
    write32(0x3C, UInt32(windowNumber))
    record[0x8A] = 1

    // Get PSN via the window's owner connection (avoids deprecated GetProcessForPID)
    let globalCID = cgsMain()
    var ownerCID: Int32 = 0
    guard getOwner(globalCID, UInt32(windowNumber), &ownerCID) == 0 else { return }
    var psn = ProcessSerialNumber()
    _ = getPSN(ownerCID, &psn)
    _ = postFn(&psn, record, record.count)
}

// MARK: - Window target resolution

func resolveTarget(windowID: UInt32) -> WindowTarget? {
    guard let cgsMain = _cgsMain,
          let getOwner = _cgsGetWindowOwner,
          let getPSN   = _cgsGetConnectionPSN else { return nil }

    // pid from CGWindowList
    let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]]
    guard let entry = list?.first,
          let pidRaw = entry[kCGWindowOwnerPID as String] as? Int32,
          let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
          let bx = boundsDict["X"] as? Double,
          let by = boundsDict["Y"] as? Double else { return nil }

    let pid = pid_t(pidRaw)
    let globalCID = cgsMain()

    var ownerCID: Int32 = 0
    guard getOwner(globalCID, windowID, &ownerCID) == 0 else { return nil }

    var psn = ProcessSerialNumber()
    _ = getPSN(ownerCID, &psn)

    return WindowTarget(
        pid: pid,
        windowNumber: Int(windowID),
        ownerConnection: ownerCID,
        psn: psn,
        boundsTopLeft: CGPoint(x: bx, y: by)
    )
}

// MARK: - Virtual click via SLEventPostToPid
// Does NOT move the hardware cursor. Does NOT post to the HID tap.

func postVirtualMouseEvent(
    type: CGEventType,
    globalTopLeft: CGPoint,   // screen coords, top-left origin
    windowLocal: CGPoint,     // coords relative to window top-left
    button: CGMouseButton,
    clickState: Int,
    target: WindowTarget,
    flags: CGEventFlags = []
) {
    guard let postFn = _slEventPostToPid,
          let setLoc = _cgEventSetWindowLocation else { return }

    // Build from NSEvent so the event has a proper windowNumber baked in.
    let nsEvent = NSEvent.mouseEvent(
        with: nsEventType(type),
        location: windowLocal,
        modifierFlags: nsModFlags(flags),
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: target.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: max(1, clickState),
        pressure: type == .leftMouseDown ? 1.0 : 0.0
    )
    guard let cgEvent = nsEvent?.cgEvent else { return }

    // Stamp all the SkyLight routing fields
    cgEvent.location = globalTopLeft
    cgEvent.flags    = flags
    setLoc(cgEvent, windowLocal)

    cgEvent.setIntegerValueField(.eventTargetUnixProcessID,
                                 value: Int64(target.pid))
    cgEvent.setIntegerValueField(.mouseEventSubtype, value: 3)
    cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer,
                                 value: Int64(target.windowNumber))
    cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                 value: Int64(target.windowNumber))

    // Pack PSN into a single Int64 (hi32 << 32 | lo32)
    let psnPacked = (Int64(target.psn.highLongOfPSN) << 32) | Int64(target.psn.lowLongOfPSN)
    cgEvent.setIntegerValueField(.eventTargetProcessSerialNumber, value: psnPacked)

    postFn(target.pid, cgEvent)
}

private func nsEventType(_ cg: CGEventType) -> NSEvent.EventType {
    switch cg {
    case .leftMouseDown:   return .leftMouseDown
    case .leftMouseUp:     return .leftMouseUp
    case .rightMouseDown:  return .rightMouseDown
    case .rightMouseUp:    return .rightMouseUp
    case .mouseMoved:      return .mouseMoved
    case .leftMouseDragged: return .leftMouseDragged
    default:               return .mouseMoved
    }
}

private func nsModFlags(_ cg: CGEventFlags) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if cg.contains(.maskShift)     { f.insert(.shift) }
    if cg.contains(.maskCommand)   { f.insert(.command) }
    if cg.contains(.maskAlternate) { f.insert(.option) }
    if cg.contains(.maskControl)   { f.insert(.control) }
    return f
}

// MARK: - AX window controller (for move/resize)

final class WindowController {
    private let axApp: AXUIElement
    private var axWindow: AXUIElement?

    init(pid: pid_t) { axApp = AXUIElementCreateApplication(pid) }

    func findWindow(id: CGWindowID) {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bd = info.first?[kCGWindowBounds as String] as? [String: Any],
              let cx = bd["X"] as? Double, let cy = bd["Y"] as? Double else { return }
        var list: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list)
        guard let wins = list as? [AXUIElement] else { return }
        for w in wins {
            var pv: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
                  let pv else { continue }
            var pt = CGPoint.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
            if abs(pt.x - cx) < 2 && abs(pt.y - cy) < 2 { axWindow = w; return }
        }
        axWindow = wins.first
    }

    func move(to p: CGPoint) {
        guard let w = axWindow else { return }
        var pt = p; let v = AXValueCreate(.cgPoint, &pt)!
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
    }

    func resize(to s: CGSize) {
        guard let w = axWindow else { return }
        var sz = s; let v = AXValueCreate(.cgSize, &sz)!
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
    }
}

// MARK: - CGEvent helpers

func cgFlags(from modifiers: [String]?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in modifiers ?? [] {
        switch m.lowercased() {
        case "shift":                    f.insert(.maskShift)
        case "meta","cmd","command":     f.insert(.maskCommand)
        case "alt","option":             f.insert(.maskAlternate)
        case "ctrl","control":           f.insert(.maskControl)
        default: break
        }
    }
    return f
}

func cgButton(from b: Int?) -> CGMouseButton {
    switch b { case 1: return .center; case 2: return .right; default: return .left }
}

func mouseEventType(button: CGMouseButton, down: Bool) -> CGEventType {
    switch button {
    case .left:   return down ? .leftMouseDown  : .leftMouseUp
    case .right:  return down ? .rightMouseDown : .rightMouseUp
    default:      return down ? .otherMouseDown : .otherMouseUp
    }
}

// MARK: - Input dispatcher

final class InputDispatcher {
    private var targetCache: [UInt32: WindowTarget] = [:]
    private var axControllers: [UInt32: WindowController] = [:]
    private var lastTarget: WindowTarget?

    private func target(for windowID: UInt32) -> WindowTarget? {
        if let t = targetCache[windowID] { return t }
        guard let t = resolveTarget(windowID: windowID) else { return nil }
        targetCache[windowID] = t
        return t
    }

    private func axController(for windowID: UInt32) -> WindowController? {
        if let c = axControllers[windowID] { return c }
        guard let t = target(for: windowID) else { return nil }
        let c = WindowController(pid: t.pid)
        c.findWindow(id: CGWindowID(windowID))
        axControllers[windowID] = c
        return c
    }

    // Convert global top-left screen point → window-local point
    private func toWindowLocal(_ pt: CGPoint, target: WindowTarget) -> CGPoint {
        CGPoint(x: pt.x - target.boundsTopLeft.x,
                y: pt.y - target.boundsTopLeft.y)
    }

    // Full virtual mouse click sequence (down + up, no cursor warp)
    private func virtualClick(at globalPt: CGPoint, button: CGMouseButton,
                              clickCount: Int, flags: CGEventFlags,
                              target: WindowTarget) {
        let wLocal = toWindowLocal(globalPt, target: target)
        let downType = mouseEventType(button: button, down: true)
        let upType   = mouseEventType(button: button, down: false)

        // Primer at (-1,-1) clears any stale button state in Chrome
        let primer = CGPoint(x: -1, y: -1)
        postVirtualMouseEvent(type: downType, globalTopLeft: globalPt,
                               windowLocal: primer, button: button,
                               clickState: 1, target: target, flags: flags)
        usleep(10_000)
        postVirtualMouseEvent(type: upType, globalTopLeft: globalPt,
                               windowLocal: primer, button: button,
                               clickState: 1, target: target, flags: flags)
        usleep(20_000)

        for i in 0..<clickCount {
            postVirtualMouseEvent(type: downType, globalTopLeft: globalPt,
                                   windowLocal: wLocal, button: button,
                                   clickState: i + 1, target: target, flags: flags)
            usleep(20_000)
            postVirtualMouseEvent(type: upType, globalTopLeft: globalPt,
                                   windowLocal: wLocal, button: button,
                                   clickState: i + 1, target: target, flags: flags)
            if clickCount > 1 { usleep(50_000) }
        }
    }

    func dispatch(_ event: InputEvent) {
        // Resolve target window (required for virtual events)
        let tgt: WindowTarget? = event.windowID.flatMap { wid in
            let t = target(for: wid)
            if let t { lastTarget = t }
            return t
        } ?? lastTarget

        switch event.type {

        case "click":
            guard let x = event.x, let y = event.y, let t = tgt else { return }
            let pt = CGPoint(x: x, y: y)
            targetOnlyFocus(pid: t.pid, windowNumber: t.windowNumber)
            usleep(30_000)
            virtualClick(at: pt, button: cgButton(from: event.button),
                         clickCount: event.clickCount ?? 1,
                         flags: cgFlags(from: event.modifiers), target: t)

        case "mousedown":
            guard let x = event.x, let y = event.y, let t = tgt else { return }
            let pt = CGPoint(x: x, y: y)
            let btn = cgButton(from: event.button)
            let wl  = toWindowLocal(pt, target: t)
            postVirtualMouseEvent(type: mouseEventType(button: btn, down: true),
                                   globalTopLeft: pt, windowLocal: wl,
                                   button: btn, clickState: 1, target: t,
                                   flags: cgFlags(from: event.modifiers))

        case "mouseup":
            guard let x = event.x, let y = event.y, let t = tgt else { return }
            let pt = CGPoint(x: x, y: y)
            let btn = cgButton(from: event.button)
            let wl  = toWindowLocal(pt, target: t)
            postVirtualMouseEvent(type: mouseEventType(button: btn, down: false),
                                   globalTopLeft: pt, windowLocal: wl,
                                   button: btn, clickState: 1, target: t,
                                   flags: cgFlags(from: event.modifiers))

        case "mousemove":
            guard let x = event.x, let y = event.y, let t = tgt else { return }
            let pt = CGPoint(x: x, y: y)
            let wl = toWindowLocal(pt, target: t)
            postVirtualMouseEvent(type: .mouseMoved, globalTopLeft: pt,
                                   windowLocal: wl, button: .left,
                                   clickState: 0, target: t)

        case "scroll":
            guard let x = event.x, let y = event.y, let t = tgt else { return }
            let pt  = CGPoint(x: x, y: y)
            let dy  = Int32((event.deltaY ?? 0).rounded())
            let dx  = Int32((event.deltaX ?? 0).rounded())
            // Scroll wheels don't need window-local stamping — post to pid directly
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { return }
            e.location = pt
            e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(t.pid))
            if let postFn = _slEventPostToPid { postFn(t.pid, e) }
            else { e.postToPid(t.pid) }

        case "keydown":
            guard let kc = event.keyCode, let t = tgt else { return }
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kc), keyDown: true) else { return }
            e.flags = cgFlags(from: event.modifiers)
            e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(t.pid))
            if let postFn = _slEventPostToPid { postFn(t.pid, e) }
            else { e.postToPid(t.pid) }

        case "keyup":
            guard let kc = event.keyCode, let t = tgt else { return }
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kc), keyDown: false) else { return }
            e.flags = cgFlags(from: event.modifiers)
            e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(t.pid))
            if let postFn = _slEventPostToPid { postFn(t.pid, e) }
            else { e.postToPid(t.pid) }

        case "move":
            guard let wid = event.windowID, let x = event.x, let y = event.y,
                  let ctrl = axController(for: wid) else { return }
            ctrl.move(to: CGPoint(x: x, y: y))
            // Invalidate cached bounds after move
            targetCache.removeValue(forKey: wid)

        case "resize":
            guard let wid = event.windowID, let w = event.width, let h = event.height,
                  let ctrl = axController(for: wid) else { return }
            ctrl.resize(to: CGSize(width: w, height: h))

        default:
            fputs("[input] unknown event: \(event.type)\n", stderr)
        }
    }
}

// MARK: - WebSocket client

final class InputBridgeClient: NSObject, URLSessionDelegate {
    private let dispatcher = InputDispatcher()
    private let serverPort: UInt16
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    init(serverPort: UInt16 = 8767) {
        self.serverPort = serverPort
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        task?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://127.0.0.1:\(serverPort)") else { return }
        let t = session!.webSocketTask(with: url)
        task = t
        t.resume()
        fputs("[input] connecting to ws://127.0.0.1:\(serverPort)\n", stderr)
        receive()
        t.sendPing { [weak self] error in
            if let error {
                fputs("[input] ping failed: \(error) — retrying in 2s\n", stderr)
                self?.scheduleReconnect()
            } else {
                fputs("[input] connected to broker\n", stderr)
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s):
                    if let d = s.data(using: .utf8) { handleMessage(d) }
                case .data(let d):
                    handleMessage(d)
                @unknown default: break
                }
                receive()
            case .failure(let err):
                fputs("[input] receive error: \(err) — retrying\n", stderr)
                scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            let event = try JSONDecoder().decode(InputEvent.self, from: data)
            dispatcher.dispatch(event)
        } catch {
            fputs("[input] decode: \(error)\n", stderr)
        }
    }

    private func scheduleReconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }
}

// MARK: - Entry point

@main
struct InputBridge {
    static func main() {
        fputs("[input] starting\n", stderr)

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        fputs("[input] accessibility: \(trusted ? "✓ granted" : "⚠️  not granted")\n", stderr)

        // Verify SkyLight loaded
        if _slEventPostToPid != nil {
            fputs("[input] ✓ SkyLight SLEventPostToPid loaded — virtual clicks active\n", stderr)
        } else {
            fputs("[input] ⚠️  SLEventPostToPid not found — will fall back to postToPid\n", stderr)
        }

        let serverPort: UInt16 = {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--port"), i+1 < args.count {
                return UInt16(args[i+1]) ?? 8767
            }
            return 8767
        }()

        let client = InputBridgeClient(serverPort: serverPort)
        client.connect()
        RunLoop.main.run()
    }
}
