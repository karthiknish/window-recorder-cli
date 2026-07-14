import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreVideo
import AppKit

// ─── Protocol ─────────────────────────────────────────────────────────
// The app listens on a Unix domain socket at /tmp/window-recorder.sock
// Commands are newline-delimited JSON:
//   {"cmd":"list"}
//   {"cmd":"start","app":"Google Chrome","out":"/path/rec.mov","duration":30}
//   {"cmd":"stop"}
//   {"cmd":"status"}
// Responses are newline-delimited JSON.

let SOCKET_PATH = "/tmp/window-recorder.sock"

// ─── Recorder ─────────────────────────────────────────────────────────
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var stream: SCStream?
    private var startTime: CFTimeInterval = 0
    private var frameCount: Int64 = 0
    private let queue = DispatchQueue(label: "com.windowrecorder.capture")
    private var isWriting = false
    private var recording = false
    private var outputPath: String = ""
    private var stopTimer: DispatchSourceTimer?

    var isRecording: Bool { recording }

    func start(window: SCWindow, display: SCDisplay, out: String, duration: TimeInterval) throws {
        if recording { throw RecorderError.alreadyRecording }

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let url = URL(fileURLWithPath: out)
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw RecorderError.writerFailed
        }
        self.assetWriter = writer
        self.outputPath = out

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        self.assetWriterInput = input

        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: display.width,
                kCVPixelBufferHeightKey as String: display.height,
            ]
        )

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = scStream

        Task {
            do {
                try await scStream.startCapture()
                self.recording = true

                if duration > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + duration)
                    timer.setEventHandler { [weak self] in
                        self?.stop()
                    }
                    timer.resume()
                    self.stopTimer = timer
                }
            } catch {
                NotificationCenter.default.post(
                    name: .recorderError, object: nil,
                    userInfo: ["error": error.localizedDescription]
                )
            }
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        stopTimer?.cancel()
        stopTimer = nil

        Task {
            if let stream = self.stream {
                try? await stream.stopCapture()
            }

            // Give the capture pipeline a moment to flush any pending frames
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s

            // Only finish writing if we actually received frames
            if self.isWriting && self.frameCount > 0, let writer = self.assetWriter, let input = self.assetWriterInput {
                input.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self = self else { return }
                    let status: String
                    if self.assetWriter?.status == .completed {
                        status = "completed"
                    } else {
                        status = "failed"
                    }
                    NotificationCenter.default.post(
                        name: .recorderStopped, object: nil,
                        userInfo: ["status": status, "path": self.outputPath, "frames": self.frameCount]
                    )
                }
            } else {
                // No frames were captured — remove the empty file
                try? FileManager.default.removeItem(atPath: self.outputPath)
                NotificationCenter.default.post(
                    name: .recorderStopped, object: nil,
                    userInfo: ["status": "completed", "path": self.outputPath, "frames": 0]
                )
            }
        }
    }

    func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer) {
        guard recording else { return }
        guard let writer = assetWriter, let input = assetWriterInput else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            startTime = CFAbsoluteTimeGetCurrent()
            isWriting = true
        }

        guard isWriting, input.isReadyForMoreMediaData else { return }

        if let buffer = adaptor {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMTime(seconds: CFAbsoluteTimeGetCurrent() - startTime, preferredTimescale: 600)
            buffer.append(pixelBuffer, withPresentationTime: time)
            frameCount += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NotificationCenter.default.post(
            name: .recorderError, object: nil,
            userInfo: ["error": error.localizedDescription]
        )
    }
}

enum RecorderError: Error {
    case alreadyRecording
    case writerFailed
}

extension Notification.Name {
    static let recorderStopped = Notification.Name("recorderStopped")
    static let recorderError = Notification.Name("recorderError")
}

// ─── Socket Server ────────────────────────────────────────────────────
final class SocketServer {
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let recorder = Recorder()

    func start() {
        unlink(SOCKET_PATH)
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            NSLog("[WindowRecorder] Failed to create socket")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        SOCKET_PATH.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: SOCKET_PATH.count + 1) {
                    strcpy($0, ptr)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("[WindowRecorder] Failed to bind socket")
            exit(1)
        }

        chmod(SOCKET_PATH, 0o666)

        listen(serverFd, 1)
        NSLog("[WindowRecorder] Listening on \(SOCKET_PATH)")

        // Accept loop
        DispatchQueue.global(qos: .background).async { [weak self] in
            while true {
                guard let self = self else { return }
                let client = accept(self.serverFd, nil, nil)
                if client >= 0 {
                    self.handleClient(client)
                }
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { close(fd); return }

        let data = Data(buffer[0..<n])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else {
            send(fd, ["error": "invalid command"])
            close(fd)
            return
        }

        switch cmd {
        case "list":
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let windows = content.windows.map { w in
                        [
                            "id": w.windowID,
                            "owner": w.owningApplication?.applicationName ?? "",
                            "title": w.title ?? "",
                        ]
                    }
                    self.send(fd, ["windows": windows])
                } catch {
                    self.send(fd, ["error": error.localizedDescription])
                }
                close(fd)
            }

        case "start":
            let app = json["app"] as? String ?? "Google Chrome"
            let out = json["out"] as? String ?? "/tmp/recording.mov"
            let duration = (json["duration"] as? Double) ?? 0

            if recorder.isRecording {
                send(fd, ["error": "already recording"])
                close(fd)
                return
            }

            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let window = content.windows.first(where: {
                        ($0.owningApplication?.applicationName ?? "").contains(app) ||
                        ($0.title ?? "").contains(app)
                    }) else {
                        self.send(fd, ["error": "window not found: \(app)"])
                        close(fd)
                        return
                    }
                    guard let display = content.displays.first else {
                        self.send(fd, ["error": "no display"])
                        close(fd)
                        return
                    }

                    try self.recorder.start(window: window, display: display, out: out, duration: duration)
                    self.send(fd, ["status": "recording", "window": window.title ?? "", "out": out])
                } catch {
                    self.send(fd, ["error": error.localizedDescription])
                }
                close(fd)
            }

        case "stop":
            recorder.stop()
            send(fd, ["status": "stopping"])
            close(fd)

        case "status":
            send(fd, [
                "recording": recorder.isRecording,
            ])
            close(fd)

        default:
            send(fd, ["error": "unknown command: \(cmd)"])
            close(fd)
        }
    }

    private func send(_ fd: Int32, _ response: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let str = String(data: data, encoding: .utf8) {
            _ = str.withCString { ptr in
                write(fd, ptr, strlen(ptr))
            }
        }
        _ = write(fd, "\n", 1)
    }
}

// ─── App Delegate ─────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = SocketServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no dock icon
        server.start()
        NSLog("[WindowRecorder] Ready")
    }
}

// ─── Main ─────────────────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
