import Foundation

// ─── CLI tool: wr ─────────────────────────────────────────────────────
// Sends commands to WindowRecorder.app via Unix domain socket
//
// Usage:
//   wr list                          — list available windows
//   wr start --app "Google Chrome" --out rec.mov [--duration 30]
//   wr stop                           — stop recording
//   wr status                         — check if recording
//   wr launch                         — launch the recorder app if not running
//   wr kill                           — kill the recorder app

let SOCKET_PATH = "/tmp/window-recorder.sock"
let APP_PATH = "/Applications/WindowRecorder.app"

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let cmd = args[1]

switch cmd {
case "list":
    sendCommand(["cmd": "list"])
case "start":
    var app = "Google Chrome"
    var out = "/tmp/recording.mov"
    var duration = 0.0
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--app": app = args[i + 1]; i += 2
        case "--out": out = args[i + 1]; i += 2
        case "--duration": duration = Double(args[i + 1]) ?? 0; i += 2
        default: i += 1
        }
    }
    sendCommand(["cmd": "start", "app": app, "out": out, "duration": duration])
case "stop":
    sendCommand(["cmd": "stop"])
case "status":
    sendCommand(["cmd": "status"])
case "launch":
    launchApp()
case "kill":
    killApp()
case "e2e":
    runE2E()
case "--help", "-h", "help":
    printUsage()
default:
    print("Unknown command: \(cmd)")
    printUsage()
    exit(1)
}

func printUsage() {
    print("""
    wr — Window Recorder CLI

    Usage:
      wr list                          List available on-screen windows
      wr start --app "Google Chrome"   Start recording a window
        --out <path>                   Output file (default: /tmp/recording.mov)
        --duration <seconds>           Auto-stop after N seconds (0 = manual)
      wr stop                          Stop recording
      wr status                        Check recording status
      wr launch                        Launch the recorder daemon
      wr kill                          Kill the recorder daemon
    wr e2e [spec] [--no-record]      Run E2E test with recording

    Examples:
      wr launch
      wr list
      wr start --app "Google Chrome" --out ~/Desktop/demo.mov --duration 30
      wr stop
      wr e2e e2e/specs/example.json
      wr e2e e2e/specs/google.json --no-record
    """)
}

func sendCommand(_ payload: [String: Any]) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        print("Error: Could not create socket. Is the recorder running? Use 'wr launch' first.")
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

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        print("Error: Cannot connect to recorder. Launch it first with: wr launch")
        close(fd)
        exit(1)
    }

    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let str = String(data: data, encoding: .utf8) {
        _ = str.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
    }
    _ = write(fd, "\n", 1)

    // Read response
    var buffer = [UInt8](repeating: 0, count: 8192)
    let n = read(fd, &buffer, buffer.count)
    if n > 0 {
        let response = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
        // Pretty-print JSON response
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let windows = json["windows"] as? [[String: Any]] {
                print("Available windows:")
                for w in windows {
                    let id = w["id"] ?? "?"
                    let owner = w["owner"] ?? ""
                    let title = w["title"] ?? ""
                    print("  [\(id)] \(owner) — \(title)")
                }
            } else {
                for (key, value) in json {
                    print("\(key): \(value)")
                }
            }
        } else {
            print(response)
        }
    }
    close(fd)
}

func launchApp() {
    // Check if already running
    let task = Process()
    task.launchPath = "/usr/bin/pgrep"
    task.arguments = ["-f", "WindowRecorder"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if !data.isEmpty {
        print("Recorder is already running")
        return
    }

    // Check if app bundle exists
    if !FileManager.default.fileExists(atPath: APP_PATH) {
        print("Error: \(APP_PATH) not found. Build it first.")
        exit(1)
    }

    // Launch via open (gives it GUI context)
    let openTask = Process()
    openTask.launchPath = "/usr/bin/open"
    openTask.arguments = [APP_PATH]
    try? openTask.run()
    openTask.waitUntilExit()

    // Wait for socket to appear
    for _ in 0..<20 {
        if FileManager.default.fileExists(atPath: SOCKET_PATH) {
            print("Recorder launched successfully")
            return
        }
        usleep(250_000) // 0.25s
    }
    print("Error: Recorder did not start within 5 seconds")
    exit(1)
}

func killApp() {
    let task = Process()
    task.launchPath = "/usr/bin/pkill"
    task.arguments = ["-f", "WindowRecorder"]
    try? task.run()
    task.waitUntilExit()
    unlink(SOCKET_PATH)
    print("Recorder killed")
}

func runE2E() {
    let scriptDir = FileManager.default.currentDirectoryPath
    let scriptPath = scriptDir + "/e2e/e2e-record.sh"

    var e2eArgs: [String] = []
    var i = 2
    while i < args.count {
        e2eArgs.append(args[i])
        i += 1
    }

    if !FileManager.default.fileExists(atPath: scriptPath) {
        print("Error: e2e/e2e-record.sh not found at \(scriptPath)")
        print("Make sure you're running from the project root directory.")
        exit(1)
    }

    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [scriptPath] + e2eArgs
    task.environment = ProcessInfo.processInfo.environment
    do {
        try task.run()
        task.waitUntilExit()
        exit(task.terminationStatus)
    } catch {
        print("Error: Failed to run e2e script: \(error.localizedDescription)")
        exit(1)
    }
}
