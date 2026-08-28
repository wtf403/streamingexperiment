import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

// MARK: - SkyLight symbols

private let skyLight: UnsafeMutableRawPointer? = {
    let paths = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
    ]
    for p in paths { if let h = dlopen(p, RTLD_LAZY | RTLD_LOCAL) { return h } }
    fputs("[input] ⚠️  SkyLight not found\n", stderr); return nil
}()

private func sym<T>(_ name: String) -> T? {
    guard let h = skyLight, let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

// CGSConnectionID CGSMainConnectionID()
private typealias CGSMainFn           = @convention(c) () -> Int32
private let _cgsMain: CGSMainFn?      = sym("CGSMainConnectionID")

// CGError CGSGetWindowOwner(cid, wid, *owner)
private typealias CGSGetOwnerFn       = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
private let _cgsGetOwner: CGSGetOwnerFn? = sym("CGSGetWindowOwner")

// CGError CGSGetConnectionPSN(cid, *psn)
private typealias CGSGetPSNFn         = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
private let _cgsGetPSN: CGSGetPSNFn?  = sym("CGSGetConnectionPSN")

// void SLEventPostToPid(pid_t, CGEventRef)
private typealias SLPostFn            = @convention(c) (pid_t, CGEvent) -> Void
private let _slPost: SLPostFn?        = sym("SLEventPostToPid")

// void CGEventSetWindowLocation(CGEventRef, CGPoint)
private typealias CGSetWinLocFn       = @convention(c) (CGEvent, CGPoint) -> Void
private let _cgSetWinLoc: CGSetWinLocFn? = sym("CGEventSetWindowLocation")

// OSStatus SLPSPostEventRecordTo(ProcessSerialNumber*, UInt8*)  — 2 args, no length
private typealias SLPSPostFn          = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32
private let _slpsPost: SLPSPostFn?    = sym("SLPSPostEventRecordTo")

// MARK: - Input event model

struct InputEvent: Codable {
    let type: String
    let x: Double?
    let y: Double?
    let button: Int?
    let deltaX: Double?
    let deltaY: Double?
    let keyCode: Int?
    let key: String?
    let modifiers: [String]?
    let width: Double?
    let height: Double?
    let windowID: UInt32?
    // clickCount removed — we synthesise down+up only; browser handles click
}

// MARK: - Window routing

struct WindowTarget {
    let pid: pid_t
    let windowNumber: Int
    var psn: ProcessSerialNumber
    let boundsTopLeft: CGPoint   // global, top-left origin
}

func resolveTarget(_ wid: UInt32) -> WindowTarget? {
    guard let cgsMain  = _cgsMain,
          let getOwner = _cgsGetOwner,
          let getPSN   = _cgsGetPSN else { return nil }

    let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]]
    guard let entry = list?.first,
          let pidRaw = entry[kCGWindowOwnerPID as String] as? Int32,
          let bd     = entry[kCGWindowBounds as String] as? [String: Any],
          let bx     = bd["X"] as? Double, let by = bd["Y"] as? Double else { return nil }

    let globalCID = cgsMain()
    var ownerCID: Int32 = 0
    guard getOwner(globalCID, wid, &ownerCID) == 0 else { return nil }
    var psn = ProcessSerialNumber()
    _ = getPSN(ownerCID, &psn)

    return WindowTarget(pid: pid_t(pidRaw), windowNumber: Int(wid),
                        psn: psn, boundsTopLeft: CGPoint(x: bx, y: by))
}

// MARK: - Target-only focus (no raise)
// Called once when passthrough begins. 2-arg SLPSPostEventRecordTo.
// Record layout from background-computer-use RE:
//   +0x04  UInt32  size  = 0xF8
//   +0x08  UInt32  type  = 0x0D
//   +0x3C  UInt32  windowNumber
//   +0x8A  UInt8   flag  = 1

func targetOnlyFocus(_ target: WindowTarget) {
    guard let postFn = _slpsPost else { return }
    var record = [UInt8](repeating: 0, count: 0xF8)
    func w32(_ o: Int, _ v: UInt32) {
        record[o]=UInt8(v&0xFF); record[o+1]=UInt8((v>>8)&0xFF)
        record[o+2]=UInt8((v>>16)&0xFF); record[o+3]=UInt8((v>>24)&0xFF)
    }
    w32(0x04, 0xF8)
    w32(0x08, 0x0D)
    w32(0x3C, UInt32(target.windowNumber))
    record[0x8A] = 1
    var psn = target.psn
    _ = postFn(&psn, record)
}

// MARK: - Virtual event posting

func postMouseEvent(type: CGEventType, globalPt: CGPoint,
                    button: CGMouseButton, clickState: Int,
                    flags: CGEventFlags, target: WindowTarget) {
    let winLocal = CGPoint(x: globalPt.x - target.boundsTopLeft.x,
                           y: globalPt.y - target.boundsTopLeft.y)
    let nsEvent = NSEvent.mouseEvent(
        with: nsEventType(type), location: winLocal,
        modifierFlags: nsMods(flags),
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: target.windowNumber, context: nil,
        eventNumber: 0, clickCount: max(1, clickState),
        pressure: (type == .leftMouseDown || type == .rightMouseDown) ? 1.0 : 0.0
    )
    guard let cge = nsEvent?.cgEvent else { return }
    cge.location = globalPt
    cge.flags    = flags
    _cgSetWinLoc?(cge, winLocal)
    cge.setIntegerValueField(.eventTargetUnixProcessID,   value: Int64(target.pid))
    cge.setIntegerValueField(.mouseEventSubtype,           value: 3)
    cge.setIntegerValueField(.mouseEventClickState,        value: Int64(max(1, clickState)))
    cge.setIntegerValueField(.mouseEventWindowUnderMousePointer,
                             value: Int64(target.windowNumber))
    cge.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                             value: Int64(target.windowNumber))
    let psnPacked = (Int64(target.psn.highLongOfPSN) << 32) | Int64(target.psn.lowLongOfPSN)
    cge.setIntegerValueField(.eventTargetProcessSerialNumber, value: psnPacked)
    if let p = _slPost { p(target.pid, cge) }
    else { cge.postToPid(target.pid) }
}

func postKeyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, target: WindowTarget) {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
    e.flags = flags
    e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.pid))
    if let p = _slPost { p(target.pid, e) }
    else { e.postToPid(target.pid) }
}

private func nsEventType(_ t: CGEventType) -> NSEvent.EventType {
    switch t {
    case .leftMouseDown: return .leftMouseDown; case .leftMouseUp: return .leftMouseUp
    case .rightMouseDown: return .rightMouseDown; case .rightMouseUp: return .rightMouseUp
    case .mouseMoved: return .mouseMoved; case .leftMouseDragged: return .leftMouseDragged
    default: return .mouseMoved
    }
}
private func nsMods(_ f: CGEventFlags) -> NSEvent.ModifierFlags {
    var m: NSEvent.ModifierFlags = []
    if f.contains(.maskShift) { m.insert(.shift) }; if f.contains(.maskCommand) { m.insert(.command) }
    if f.contains(.maskAlternate) { m.insert(.option) }; if f.contains(.maskControl) { m.insert(.control) }
    return m
}

// MARK: - CGEvent helpers

func cgFlags(_ mods: [String]?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in mods ?? [] {
        switch m.lowercased() {
        case "shift": f.insert(.maskShift)
        case "meta","cmd","command": f.insert(.maskCommand)
        case "alt","option": f.insert(.maskAlternate)
        case "ctrl","control": f.insert(.maskControl)
        default: break
        }
    }
    return f
}

func cgBtn(_ b: Int?) -> CGMouseButton { b == 2 ? .right : b == 1 ? .center : .left }

func mouseType(_ btn: CGMouseButton, down: Bool) -> CGEventType {
    switch btn {
    case .left:  return down ? .leftMouseDown  : .leftMouseUp
    case .right: return down ? .rightMouseDown : .rightMouseUp
    default:     return down ? .otherMouseDown : .otherMouseUp
    }
}

// MARK: - AX window controller (move/resize only)

final class WindowController {
    private let axApp: AXUIElement
    private var axWin: AXUIElement?
    init(pid: pid_t) { axApp = AXUIElementCreateApplication(pid) }
    func findWindow(_ id: CGWindowID) {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String:Any]],
              let bd = info.first?[kCGWindowBounds as String] as? [String:Any],
              let cx = bd["X"] as? Double, let cy = bd["Y"] as? Double else { return }
        var list: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list)
        guard let wins = list as? [AXUIElement] else { return }
        for w in wins {
            var pv: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success, let pv else { continue }
            var pt = CGPoint.zero; AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
            if abs(pt.x-cx) < 2 && abs(pt.y-cy) < 2 { axWin = w; return }
        }
        axWin = wins.first
    }
    func move(to p: CGPoint) {
        guard let w = axWin else { return }; var pt = p
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pt)!)
    }
    func resize(to s: CGSize) {
        guard let w = axWin else { return }; var sz = s
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sz)!)
    }
}

// MARK: - Dispatcher
// No sleeps. No primer. No redundant clicks.
// Focus is sent once when windowID is first seen (or on explicit "focus" event).

final class InputDispatcher {
    private var targetCache: [UInt32: WindowTarget] = [:]
    private var axCache:     [UInt32: WindowController] = [:]
    private var focusedWID:  UInt32? = nil
    // Click state for down+up sequencing
    private var clickCount:  Int = 0
    private var lastClickBtn: CGMouseButton = .left

    private func target(_ wid: UInt32) -> WindowTarget? {
        if let t = targetCache[wid] { return t }
        guard let t = resolveTarget(wid) else { return nil }
        targetCache[wid] = t
        return t
    }

    private func ax(_ wid: UInt32) -> WindowController? {
        if let c = axCache[wid] { return c }
        guard let t = target(wid) else { return nil }
        let c = WindowController(pid: t.pid); c.findWindow(CGWindowID(wid))
        axCache[wid] = c; return c
    }

    // Focus once per window when first interacting (or on "enterfocus" event)
    private func ensureFocus(wid: UInt32, t: WindowTarget) {
        guard focusedWID != wid else { return }
        targetOnlyFocus(t)
        focusedWID = wid
    }

    func dispatch(_ ev: InputEvent) {
        let wid = ev.windowID
        let tgt: WindowTarget? = wid.flatMap { target($0) }

        switch ev.type {

        // "enterfocus": called once when client enters passthrough mode
        case "enterfocus":
            guard let wid, let t = tgt else { return }
            focusedWID = nil          // force re-focus
            ensureFocus(wid: wid, t: t)

        case "mousedown":
            guard let x = ev.x, let y = ev.y, let t = tgt, let wid else { return }
            ensureFocus(wid: wid, t: t)
            let btn = cgBtn(ev.button)
            clickCount = btn == lastClickBtn ? clickCount + 1 : 1
            lastClickBtn = btn
            postMouseEvent(type: mouseType(btn, down: true),
                           globalPt: CGPoint(x: x, y: y),
                           button: btn, clickState: clickCount,
                           flags: cgFlags(ev.modifiers), target: t)

        case "mouseup":
            guard let x = ev.x, let y = ev.y, let t = tgt else { return }
            let btn = cgBtn(ev.button)
            postMouseEvent(type: mouseType(btn, down: false),
                           globalPt: CGPoint(x: x, y: y),
                           button: btn, clickState: clickCount,
                           flags: cgFlags(ev.modifiers), target: t)

        case "mousemove":
            guard let x = ev.x, let y = ev.y, let t = tgt else { return }
            postMouseEvent(type: .mouseMoved, globalPt: CGPoint(x: x, y: y),
                           button: .left, clickState: 0,
                           flags: [], target: t)

        case "scroll":
            guard let x = ev.x, let y = ev.y, let t = tgt else {
                fputs("[input] scroll missing coords or target\n", stderr)
                return
            }
            let globalPt = CGPoint(x: x, y: y)
            let dyPixels = (ev.deltaY ?? 0)
            let dxPixels = (ev.deltaX ?? 0)
            let dyLines = Int32((dyPixels / 10.0).rounded())
            let dxLines = Int32((dxPixels / 10.0).rounded())
            fputs("[input] scroll dy=\(dyLines) dx=\(dxLines)\n", stderr)

            guard let source = CGEventSource(stateID: .hidSystemState),
                  let e = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                  wheelCount: 2, wheel1: -dyLines, wheel2: -dxLines, wheel3: 0) else { return }
            e.location = globalPt
            // Post to HID tap to confirm events work at all (cursor will warp temporarily)
            e.post(tap: .cghidEventTap)

        case "keydown":
            guard let kc = ev.keyCode, let t = tgt else { return }
            postKeyEvent(keyCode: CGKeyCode(kc), down: true, flags: cgFlags(ev.modifiers), target: t)

        case "keyup":
            guard let kc = ev.keyCode, let t = tgt else { return }
            postKeyEvent(keyCode: CGKeyCode(kc), down: false, flags: cgFlags(ev.modifiers), target: t)

        case "move":
            guard let wid, let x = ev.x, let y = ev.y, let c = ax(wid) else { return }
            c.move(to: CGPoint(x: x, y: y))
            targetCache.removeValue(forKey: wid)  // invalidate bounds cache after move

        case "resize":
            guard let wid, let w = ev.width, let h = ev.height, let c = ax(wid) else { return }
            c.resize(to: CGSize(width: w, height: h))

        default:
            fputs("[input] unknown: \(ev.type)\n", stderr)
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
        self.serverPort = serverPort; super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        task?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://127.0.0.1:\(serverPort)") else { return }
        let t = session!.webSocketTask(with: url); task = t; t.resume()
        fputs("[input] connecting to ws://127.0.0.1:\(serverPort)\n", stderr)
        receive()
        t.sendPing { [weak self] err in
            if let err { fputs("[input] ping: \(err) — retry\n", stderr); self?.scheduleReconnect() }
            else { fputs("[input] connected\n", stderr) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s): if let d = s.data(using: .utf8) { handleMessage(d) }
                case .data(let d): handleMessage(d)
                @unknown default: break
                }
                receive()
            case .failure(let err):
                fputs("[input] recv: \(err) — retry\n", stderr)
                scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            let ev = try JSONDecoder().decode(InputEvent.self, from: data)
            dispatcher.dispatch(ev)
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

@main struct InputBridge {
    static func main() {
        fputs("[input] starting\n", stderr)
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        fputs("[input] accessibility: \(trusted ? "✓" : "⚠️  not granted")\n", stderr)
        fputs("[input] SLEventPostToPid: \(_slPost != nil ? "✓" : "⚠️  missing")\n", stderr)
        fputs("[input] SLPSPostEventRecordTo: \(_slpsPost != nil ? "✓" : "⚠️  missing")\n", stderr)

        let port: UInt16 = {
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--port"), i+1 < a.count { return UInt16(a[i+1]) ?? 8767 }
            return 8767
        }()
        let client = InputBridgeClient(serverPort: port)
        client.connect()
        RunLoop.main.run()
    }
}
