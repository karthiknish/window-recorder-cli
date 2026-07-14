import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreVideo
import AppKit
import os.log

let log = OSLog(subsystem: "com.falnor.window-recorder", category: "recorder")

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
    private var stream: SCStream?
    private var frameCount: Int64 = 0
    private let queue = DispatchQueue(label: "com.windowrecorder.capture")
    private var sessionStarted = false
    private var recording = false
    private var outputPath: String = ""
    private var stopTimer: DispatchSourceTimer?

    var isRecording: Bool { recording }

    func start(window: SCWindow, display: SCDisplay, out: String, duration: TimeInterval) throws {
        if recording { throw RecorderError.alreadyRecording }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let captureWidth = Int(filter.contentRect.width) * Int(filter.pointPixelScale)
        let captureHeight = Int(filter.contentRect.height) * Int(filter.pointPixelScale)

        os_log("Starting recording: window=%{public}s, size=%dx%d, out=%{public}s", log: log, type: .info, window.title ?? "?", captureWidth, captureHeight, out)

        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = false

        let url = URL(fileURLWithPath: out)
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw RecorderError.writerFailed
        }
        self.assetWriter = writer
        self.outputPath = out

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: captureWidth,
            AVVideoHeightKey: captureHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input) }
        self.assetWriterInput = input

        // Start writing BEFORE capture starts
        writer.startWriting()
        sessionStarted = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = scStream

        Task {
            do {
                try await scStream.startCapture()
                self.recording = true
                os_log("Capture started for window: %{public}s", log: log, type: .info, window.title ?? "?")

                if duration > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + duration)
                    timer.setEventHandler { [weak self] in
                        os_log("Duration timer fired, stopping", log: log, type: .info)
                        self?.stop()
                    }
                    timer.resume()
                    self.stopTimer = timer
                }
            } catch {
                os_log("Capture failed: %{public}s", log: log, type: .error, error.localizedDescription)
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
        os_log("Stopping recording, frames captured: %d", log: log, type: .info, frameCount)

        Task {
            if let stream = self.stream {
                try? await stream.stopCapture()
            }

            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s

            if self.frameCount > 0, let writer = self.assetWriter, let input = self.assetWriterInput {
                input.markAsFinished()
                await writer.finishWriting()
                let status: String
                if writer.status == .completed {
                    status = "completed"
                } else {
                    status = "failed"
                    os_log("Writer finished with status: %d, error: %{public}s", log: log, type: .error, writer.status.rawValue, writer.error?.localizedDescription ?? "none")
                }
                os_log("Recording finished: %{public}s, frames: %d", log: log, type: .info, status, self.frameCount)
                NotificationCenter.default.post(
                    name: .recorderStopped, object: nil,
                    userInfo: ["status": status, "path": self.outputPath, "frames": self.frameCount]
                )
            } else {
                try? FileManager.default.removeItem(atPath: self.outputPath)
                os_log("No frames captured, removed empty file", log: log, type: .info)
                NotificationCenter.default.post(
                    name: .recorderStopped, object: nil,
                    userInfo: ["status": "completed", "path": self.outputPath, "frames": 0]
                )
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        os_log("didOutput called, type=%d, recording=%d", log: log, type: .info, outputType.rawValue, recording ? 1 : 0)
        guard recording else { return }
        guard outputType == .screen else { return }
        guard let writer = assetWriter, let input = assetWriterInput else { return }

        // Check frame status — only process complete frames
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachment = attachments.first else { return }
        let statusRawValue = attachment[SCStreamFrameInfo.status.rawValue] as? Int ?? 0
        guard let status = SCFrameStatus(rawValue: statusRawValue), status == .complete else { return }

        // Start session at the first complete frame's PTS
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
            os_log("First complete frame received, starting session", log: log, type: .info)
        }

        guard input.isReadyForMoreMediaData else { return }

        // Append the CMSampleBuffer directly — no PixelBufferAdaptor needed
        input.append(sampleBuffer)
        frameCount += 1
        if frameCount == 1 || frameCount % 30 == 0 {
            os_log("Frame %d appended", log: log, type: .info, frameCount)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        os_log("Stream stopped with error: %{public}s", log: log, type: .error, error.localizedDescription)
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
    let recorder = Recorder()

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

// ─── Menu Bar Controller ──────────────────────────────────────────────
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var recorder: Recorder
    private var server: SocketServer
    private var version: String
    private var updateMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var recordingInfoMenuItem: NSMenuItem!
    private var statusTimer: Timer?
    private var recordingInfoTimer: Timer?

    init(recorder: Recorder, server: SocketServer, version: String) {
        self.recorder = recorder
        self.server = server
        self.version = version
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "●"

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        recordingInfoMenuItem = NSMenuItem(title: "No active recording", action: nil, keyEquivalent: "")
        recordingInfoMenuItem.isEnabled = false
        menu.addItem(recordingInfoMenuItem)

        menu.addItem(NSMenuItem.separator())

        let listMenuItem = NSMenuItem(title: "List Windows", action: #selector(listWindows), keyEquivalent: "l")
        listMenuItem.target = self
        menu.addItem(listMenuItem)

        let stopMenuItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s")
        stopMenuItem.target = self
        menu.addItem(stopMenuItem)

        menu.addItem(NSMenuItem.separator())

        let aboutMenuItem = NSMenuItem(title: "About WindowRecorder", action: #selector(showAbout), keyEquivalent: "")
        aboutMenuItem.target = self
        menu.addItem(aboutMenuItem)

        updateMenuItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        updateMenuItem.target = self
        menu.addItem(updateMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu

        startStatusTimer()
    }

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        statusTimer?.fire()
    }

    private func refreshStatus() {
        if recorder.isRecording {
            statusItem.button?.title = "●"
            statusItem.button?.contentTintColor = .systemRed
            statusMenuItem.title = "Status: Recording"
            recordingInfoMenuItem.title = "Recording in progress..."
            recordingInfoMenuItem.isHidden = false
        } else {
            statusItem.button?.title = "●"
            statusItem.button?.contentTintColor = .systemGreen
            statusMenuItem.title = "Status: Ready"
            recordingInfoMenuItem.title = "No active recording"
            recordingInfoMenuItem.isHidden = false
        }
    }

    @objc func listWindows() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let windowList = content.windows.prefix(20).map { w in
                    "  \(w.windowID)  \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "?")"
                }.joined(separator: "\n")
                let alert = NSAlert()
                alert.messageText = "Available Windows"
                alert.informativeText = windowList.isEmpty ? "No windows found" : windowList
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                showError("Failed to list windows: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopRecording() {
        if !recorder.isRecording {
            showError("Not currently recording")
            return
        }
        recorder.stop()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "WindowRecorder"
        alert.informativeText = "Version \(version)\n\nmacOS screen recording tool\nScreenCaptureKit + AVFoundation\n\nhttps://github.com/karthiknish/window-recorder-cli"
        alert.alertStyle = .informational
        alert.icon = NSImage(contentsOfFile: "/Applications/WindowRecorder.app/Contents/Resources/AppIcon.icns")
        alert.runModal()
    }

    @objc func checkForUpdates() {
        updateMenuItem.title = "Checking..."
        updateMenuItem.isEnabled = false

        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/karthiknish/window-recorder-cli/releases/latest")!
                let (data, _) = try await URLSession.shared.data(from: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let latestVersion = (json?["tag_name"] as? String ?? "").replacingOccurrences(of: "v", with: "")
                let releaseURL = json?["html_url"] as? String ?? ""
                let releaseNotes = json?["body"] as? String ?? ""

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.updateMenuItem.isEnabled = true

                    if latestVersion.isEmpty {
                        self.updateMenuItem.title = "Check for Updates..."
                        self.showError("Could not fetch latest version")
                        return
                    }

                    if latestVersion == self.version {
                        self.updateMenuItem.title = "Up to date (v\(self.version))"
                        let alert = NSAlert()
                        alert.messageText = "You're up to date!"
                        alert.informativeText = "WindowRecorder v\(self.version) is the latest version."
                        alert.alertStyle = .informational
                        alert.runModal()
                    } else {
                        self.updateMenuItem.title = "Update available (v\(latestVersion))"
                        let alert = NSAlert()
                        alert.messageText = "Update available!"
                        alert.informativeText = "v\(self.version) → v\(latestVersion)\n\n\(releaseNotes.prefix(500))\n\nDownload: \(releaseURL)"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "Download")
                        alert.addButton(withTitle: "Later")
                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            if let url = URL(string: releaseURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updateMenuItem.isEnabled = true
                    self?.updateMenuItem.title = "Check for Updates..."
                    self?.showError("Could not check for updates: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func quit() {
        if recorder.isRecording {
            recorder.stop()
        }
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// ─── App Delegate ─────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = SocketServer()
    var menuBarController: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        let version = readVersion()
        menuBarController = MenuBarController(recorder: server.recorder, server: server, version: version)
        menuBarController.setup()

        server.start()
        os_log("WindowRecorder Ready (v%{public}s)", log: log, type: .info, version)
    }

    private func readVersion() -> String {
        let plistPath = "/Applications/WindowRecorder.app/Contents/Info.plist"
        if let plist = FileManager.default.contents(atPath: plistPath),
           let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
           let v = dict["CFBundleShortVersionString"] as? String {
            return v
        }
        return "1.0.0"
    }
}

// ─── Main ─────────────────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
