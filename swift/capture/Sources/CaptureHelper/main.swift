import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics
import Network

// MARK: - WebSocket client (connects to Node broker as a capture producer)

final class BrokerClient: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let host: String
    private let port: UInt16
    var isReady = false

    init(host: String = "127.0.0.1", port: UInt16 = 8765) {
        self.host = host
        self.port = port
    }

    func connect() {
        fputs("[capture] Connecting to broker at ws://\(host):\(port)...\n", stderr)
        let url = URL(string: "ws://\(host):\(port)")!
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isReady = true
        fputs("[capture] ✓ connected to broker\n", stderr)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isReady = false
        fputs("[capture] connection closed: \(closeCode)\n", stderr)
        // Reconnect after 2s
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connect()
        }
    }

    private var sendCount = 0

    /// Send binary frame to broker.
    func send(_ data: Data) {
        guard isReady, let task = webSocketTask else { return }
        sendCount += 1
        task.send(.data(data)) { _ in }
    }

    /// Send text (meta JSON) to broker.
    func sendText(_ text: String) {
        guard isReady, let task = webSocketTask else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success: break
            case .failure(let error):
                fputs("[capture] recv error: \(error)\n", stderr)
            }
            self?.receive()
        }
    }
}

// MARK: - H.264 encoder

final class H264Encoder {
    private var session: VTCompressionSession?
    var onEncodedData: ((Data) -> Void)?

    init(width: Int32, height: Int32, fps: Int32 = 30) {
        var s: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s
        )
        guard let s else { fputs("[capture] Failed to create VTCompressionSession\n", stderr); return }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,            value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // 20 Mbps average — enough headroom for 3520×2848 @ 60fps without frame drops
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: 20_000_000))
        // Allow 40 Mbps burst over 1 second (each element is a CFNumber pair: bytes, seconds)
        let dataRateLimits: [NSNumber] = [NSNumber(value: 5_000_000), NSNumber(value: 1)]
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,       value: dataRateLimits as CFArray)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: fps * 2))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: fps))
        // Prefer hardware encoder (Apple Silicon VT H.264 encoder)
        VTSessionSetProperty(s, key: kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sb = sampleBuffer else { return }
                self?.handleEncoded(sb)
            }
        )
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard let dataBuffer = sb.dataBuffer else { return }
        let isKeyFrame = sb.sampleAttachments.isEmpty ||
            sb.sampleAttachments[0][.notSync] == nil

        var nalUnits = Data()

        // Prepend SPS/PPS for key frames
        if isKeyFrame, let formatDesc = sb.formatDescription {
            var paramCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
            )
            for i in 0..<paramCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if let ptr {
                    nalUnits.append(contentsOf: [0, 0, 0, 1])
                    nalUnits.append(contentsOf: UnsafeBufferPointer(start: ptr, count: size))
                }
            }
        }

        // Convert AVCC length-prefixed NALUs to Annex B
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        var rawData = Data(count: totalLength)
        _ = rawData.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength, destination: ptr.baseAddress!)
        }

        var offset = 0
        while offset + 4 <= rawData.count {
            let naluLength = Int(rawData[offset]) << 24 | Int(rawData[offset+1]) << 16 |
                             Int(rawData[offset+2]) << 8  | Int(rawData[offset+3])
            nalUnits.append(contentsOf: [0, 0, 0, 1])
            let start = offset + 4
            let end = start + naluLength
            if end <= rawData.count {
                nalUnits.append(rawData[start..<end])
            }
            offset += 4 + naluLength
        }

        onEncodedData?(nalUnits)
    }
}

// MARK: - Frame meta JSON

struct FrameMeta: Codable {
    let type: String
    let windowID: UInt32
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double
    let contentScale: Double
}

// MARK: - Separate delegate to avoid XPC interruption with delegate:self
final class StreamDelegate: NSObject, SCStreamDelegate {
    weak var owner: WindowCapture?
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.handleStreamStop(error: error)
    }
}

// MARK: - Capture session

final class WindowCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let broker: BrokerClient
    private var encoder: H264Encoder?
    private var frameCount: Int = 0
    private var lastMetaSent: Date = .distantPast
    private var contentScale: Double = 2.0
    private let targetWindowID: CGWindowID
    private var pts: CMTime = .zero
    private var streamDelegate: StreamDelegate?

    init(windowID: CGWindowID, broker: BrokerClient) {
        self.targetWindowID = windowID
        self.broker = broker
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == targetWindowID }) else {
            fputs("[capture] Window \(targetWindowID) not found in shareable content\n", stderr)
            exit(1)
        }

        fputs("[capture] Capturing '\(window.title ?? "?")' \(Int(window.frame.width))x\(Int(window.frame.height)) app=\(window.owningApplication?.applicationName ?? "?")\n", stderr)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Capture at 1× logical resolution — halves pixel count vs 2×,
        // cuts encode/decode load significantly without visible quality loss.
        let scale: Int = 1
        config.width  = max(1, Int(window.frame.width)  * scale)
        config.height = max(1, Int(window.frame.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        encoder = H264Encoder(
            width: Int32(config.width),
            height: Int32(config.height),
            fps: 60
        )
        encoder?.onEncodedData = { [weak self] data in
            self?.broker.send(data)
        }

        let delegate = StreamDelegate()
        delegate.owner = self
        streamDelegate = delegate  // retain
        stream = SCStream(filter: filter, configuration: config, delegate: delegate)

        let sampleQueue = DispatchQueue(label: "capture.frames", qos: .userInitiated)

        do {
            try stream?.addStreamOutput(
                self, type: .screen,
                sampleHandlerQueue: sampleQueue
            )
        } catch {
            fputs("[capture] addStreamOutput threw: \(error)\n", stderr)
            throw error
        }

        // Small delay to let any immediate errors surface
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            try await stream?.startCapture()
            fputs("[capture] Stream started\n", stderr)
        } catch {
            fputs("[capture] startCapture() threw: \(error)\n", stderr)
            throw error
        }

        sendMeta(window: window)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if frameCount == 0 {
            fputs("[capture] ✓ First frame received!\n", stderr)
        }

        guard type == .screen, sb.isValid else {
            fputs("[capture] didOutputSampleBuffer: type=\(type) valid=\(sb.isValid)\n", stderr)
            return
        }

        // Only process complete frames
        guard
            let attachments = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
            let statusRaw = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else {
            if frameCount < 5 {
                fputs("[capture] frame not complete\n", stderr)
            }
            return
        }

        if let scale = attachments[.scaleFactor] as? Double { contentScale = scale }

        guard let imageBuffer = sb.imageBuffer else { return }
        pts = CMTime(value: CMTimeValue(frameCount), timescale: 60)

        encoder?.encode(imageBuffer, pts: pts)

        frameCount += 1

        if Date().timeIntervalSince(lastMetaSent) > 2.0 { refreshMeta() }
    }

    func handleStreamStop(error: Error) {
        fputs("[capture] Stream stopped: \(error)\n", stderr)
        // Auto-restart after brief backoff
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            fputs("[capture] Restarting capture for window \(targetWindowID)...\n", stderr)
            try? await self.start()
        }
    }

    private func refreshMeta() {
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == self.targetWindowID }) else { return }
            self.sendMeta(window: window)
        }
    }

    private func sendMeta(window: SCWindow) {
        let meta = FrameMeta(
            type: "meta",
            windowID: window.windowID,
            originX: window.frame.origin.x,
            originY: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height,
            contentScale: contentScale
        )
        if let data = try? JSONEncoder().encode(meta) {
            broker.sendText(String(data: data, encoding: .utf8) ?? "{}")
        }
        lastMetaSent = Date()
    }
}

// MARK: - List windows

func listWindows() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let windows = content.windows.filter { $0.title != nil && !($0.title?.isEmpty ?? true) }
    print("Available windows (id\tapp\ttitle\tframe):")
    for w in windows.prefix(60) {
        let app = w.owningApplication?.applicationName ?? "?"
        print("  \(w.windowID)\t\(app)\t\(w.title ?? "")\t\(w.frame)")
    }
}

// MARK: - Entry point

// Global to keep capture alive
var globalCapture: WindowCapture?

@main
struct CaptureHelper {
    static func main() async throws {
        // Bootstrap app context — required for SCK + CoreGraphics window server
        let _ = NSApplication.shared

        let args = CommandLine.arguments

        if args.contains("--list") {
            try await listWindows()
            return
        }

        let brokerPort: UInt16 = {
            if let i = args.firstIndex(of: "--port"), i + 1 < args.count {
                return UInt16(args[i + 1]) ?? 8765
            }
            return 8765
        }()

        // Resolve target window
        let windowID: CGWindowID
        if let widx = args.firstIndex(of: "--window"), widx + 1 < args.count,
           let wid = UInt32(args[widx + 1]) {
            windowID = wid
        } else {
            // Auto-select the largest Chrome window (excludes menu bar / small utility windows)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let chrome = content.windows
                .filter {
                    $0.owningApplication?.applicationName == "Google Chrome" &&
                    $0.frame.width > 200 &&
                    $0.frame.height > 200
                }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
                .first
            guard let chrome else {
                fputs("[capture] No suitable Chrome window found. Use --list to see windows.\n", stderr)
                exit(1)
            }
            windowID = chrome.windowID
            fputs("[capture] Auto-selected Chrome window \(windowID): '\(chrome.title ?? "")' \(chrome.frame)\n", stderr)
        }

        let broker = BrokerClient(port: brokerPort)
        broker.connect()

        // Brief wait for connection before streaming
        try await Task.sleep(nanoseconds: 500_000_000)

        let capture = WindowCapture(windowID: windowID, broker: broker)
        globalCapture = capture  // Keep alive globally
        try await capture.start()

        // Keep running
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            RunLoop.main.run()
        }
    }
}
