import Foundation

// ─── CLI tool: wr ─────────────────────────────────────────────────────

let SOCKET_PATH = "/tmp/window-recorder.sock"
let APP_PATH = "/Applications/WindowRecorder.app"
let args = CommandLine.arguments

@main
struct WRMain {
    static func main() {
        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        let cmd = args[1]

        switch cmd {
        case "list":
            sendCommand(["cmd": "list"])
        case "start":
            var out = "/tmp/recording.mov"
            var duration = 0.0
            var i = 2
            while i < args.count {
                switch args[i] {
                case "--out": out = args[i + 1]; i += 2
                case "--duration": duration = Double(args[i + 1]) ?? 0; i += 2
                case "--app": i += 2
                default: i += 1
                }
            }
            launchIfNeeded()
            ensureChromeWithCDP()
            sendCommand(["cmd": "start", "app": "Google Chrome", "out": out, "duration": duration])
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
        case "chrome":
            runChrome()
        case "mcp":
            runMCPServer()
        case "--help", "-h", "help":
            printUsage()
        default:
            print("Unknown command: \(cmd)")
            printUsage()
            exit(1)
        }
    }
}
// ─── Usage ────────────────────────────────────────────────────────────

func printUsage() {
    print("""
    wr — Window Recorder CLI

    Recording:
      wr list                          List available on-screen windows
      wr start [--out <path>]          Start recording Chrome window
        --out <path>                   Output file (default: /tmp/recording.mov)
        --duration <seconds>           Auto-stop after N seconds (0 = manual)
      wr stop                          Stop recording
      wr status                        Check recording status
      wr launch                        Launch the recorder daemon
      wr kill                          Kill the recorder daemon

    Chrome (CDP):
      wr chrome launch [--url <url>]   Launch Chrome with remote debugging
      wr chrome tabs                   List open Chrome tabs
      wr chrome navigate <url>         Navigate current tab to URL
      wr chrome screenshot [--out p]   Take a screenshot
      wr chrome click <selector>       Click an element
      wr chrome type <selector> <text> Type text into an element
      wr chrome press <key>            Press a key (Enter, Tab, Escape)
      wr chrome scroll <selector>      Scroll to an element
      wr chrome evaluate <expr>        Evaluate JavaScript expression
      wr chrome assert <sel> <text>    Assert element contains text
      wr chrome wait <ms>              Wait for N milliseconds
      wr chrome snapshot               Get page accessibility tree
      wr chrome console [--errors]     Get console messages
      wr chrome network                List network requests
      wr chrome record <url> <dur>     Record Chrome while navigating
        --out <path>                   Output file (default: /tmp/recording.mov)

    E2E Testing:
      wr e2e [spec] [--no-record]      Run E2E test with recording

    MCP Server:
      wr mcp                           Run as MCP server (JSON-RPC over stdio)
                                       Exposes Chrome recording tools to AI agents

      MCP Tools:
        record_chrome                  Record Chrome window (duration, out)
        record_chrome_navigate         Navigate + record (url, duration, out)
        stop_recording                 Stop current recording
        recording_status               Check recording state
        chrome_screenshot              Take screenshot (out)
        chrome_navigate                Navigate to URL (url)
        chrome_click                   Click element (selector)
        chrome_type                    Type text (selector, text)
        chrome_evaluate                Evaluate JS (expression)
        chrome_press                   Press key (key)
        chrome_scroll                  Scroll to element (selector)
        chrome_assert                  Assert text content (selector, expected)
        chrome_wait                    Wait milliseconds (ms)
        chrome_snapshot                Get accessibility tree
        chrome_tabs                    List Chrome tabs
        chrome_network                 List network requests

    Examples:
      wr launch
      wr list
      wr start --out ~/Desktop/demo.mov --duration 30
      wr stop
      wr chrome launch --url https://example.com
      wr chrome navigate https://google.com
      wr chrome type "textarea[name='q']" "hello world"
      wr chrome press Enter
      wr chrome screenshot --out ~/Desktop/screenshot.png
      wr chrome record https://example.com 10 --out ~/Desktop/rec.mov
      wr e2e e2e/specs/example.json
    """)
}

// ─── Socket Communication ─────────────────────────────────────────────

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

    var buffer = [UInt8](repeating: 0, count: 8192)
    let n = read(fd, &buffer, buffer.count)
    if n > 0 {
        let response = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
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

// ─── App Management ───────────────────────────────────────────────────

func launchApp() {
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

    let binaryPath = "\(APP_PATH)/Contents/MacOS/WindowRecorder"
    if !FileManager.default.fileExists(atPath: binaryPath) {
        print("Error: \(binaryPath) not found. Build it first.")
        exit(1)
    }

    let proc = Process()
    proc.launchPath = binaryPath
    proc.arguments = []
    try? proc.run()

    for _ in 0..<20 {
        if FileManager.default.fileExists(atPath: SOCKET_PATH) {
            print("Recorder launched successfully")
            return
        }
        usleep(250_000)
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

// ─── E2E ──────────────────────────────────────────────────────────────

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

// ─── Chrome CLI Handler ───────────────────────────────────────────────

func runChrome() {
    guard args.count >= 3 else {
        printChromeUsage()
        exit(1)
    }

    let subcmd = args[2]

    switch subcmd {
    case "launch":
        chromeLaunch()
    case "tabs":
        chromeTabs()
    case "navigate":
        guard args.count >= 4 else { print("Usage: wr chrome navigate <url>"); exit(1) }
        chromeNavigate(url: args[3])
    case "screenshot":
        var out = "/tmp/screenshot.png"
        var i = 3
        while i < args.count {
            if args[i] == "--out" { out = args[i + 1]; i += 2 } else { i += 1 }
        }
        chromeScreenshot(out: out)
    case "click":
        guard args.count >= 4 else { print("Usage: wr chrome click <selector>"); exit(1) }
        chromeClick(selector: args[3])
    case "type":
        guard args.count >= 5 else { print("Usage: wr chrome type <selector> <text>"); exit(1) }
        chromeType(selector: args[3], text: args[4])
    case "press":
        guard args.count >= 4 else { print("Usage: wr chrome press <key>"); exit(1) }
        chromePress(key: args[3])
    case "scroll":
        guard args.count >= 4 else { print("Usage: wr chrome scroll <selector>"); exit(1) }
        chromeScroll(selector: args[3])
    case "evaluate":
        guard args.count >= 4 else { print("Usage: wr chrome evaluate <expression>"); exit(1) }
        _ = chromeEvaluate(expression: args[3])
    case "assert":
        guard args.count >= 5 else { print("Usage: wr chrome assert <selector> <expected>"); exit(1) }
        chromeAssert(selector: args[3], expected: args[4])
    case "wait":
        guard args.count >= 4 else { print("Usage: wr chrome wait <ms>"); exit(1) }
        chromeWait(ms: Int(args[3]) ?? 1000)
    case "snapshot":
        chromeSnapshot()
    case "console":
        var errorsOnly = false
        if args.count >= 4 && args[3] == "--errors" { errorsOnly = true }
        chromeConsole(errorsOnly: errorsOnly)
    case "network":
        chromeNetwork()
    case "record":
        guard args.count >= 5 else { print("Usage: wr chrome record <url> <duration> [--out <path>]"); exit(1) }
        let url = args[3]
        let duration = Double(args[4]) ?? 10
        var out = "/tmp/recording.mov"
        var i = 5
        while i < args.count {
            if args[i] == "--out" { out = args[i + 1]; i += 2 } else { i += 1 }
        }
        chromeRecord(url: url, duration: duration, out: out)
    case "--help", "-h", "help":
        printChromeUsage()
    default:
        print("Unknown chrome command: \(subcmd)")
        printChromeUsage()
        exit(1)
    }
}

func printChromeUsage() {
    print("""
    wr chrome — Chrome DevTools Protocol integration

    Usage:
      wr chrome launch [--url <url>]       Launch Chrome with remote debugging
      wr chrome tabs                       List open Chrome tabs
      wr chrome navigate <url>             Navigate current tab to URL
      wr chrome screenshot [--out <path>]  Take a screenshot (default: /tmp/screenshot.png)
      wr chrome click <selector>           Click an element by CSS selector
      wr chrome type <selector> <text>     Type text into an element
      wr chrome press <key>                Press a key (Enter, Tab, Escape, Space)
      wr chrome scroll <selector>          Scroll to an element
      wr chrome evaluate <expression>      Evaluate JavaScript and print result
      wr chrome assert <selector> <text>   Assert element contains text
      wr chrome wait <ms>                  Wait for N milliseconds
      wr chrome snapshot                   Get page accessibility tree
      wr chrome console [--errors]         Get console messages (optionally errors only)
      wr chrome network                    List network requests
      wr chrome record <url> <duration>    Record Chrome window while navigating
        --out <path>                       Output file (default: /tmp/recording.mov)

    Examples:
      wr chrome launch --url https://example.com
      wr chrome navigate https://google.com
      wr chrome type "textarea[name='q']" "hello world"
      wr chrome press Enter
      wr chrome screenshot --out ~/Desktop/screenshot.png
      wr chrome click "#login-btn"
      wr chrome evaluate "document.title"
      wr chrome assert "h1" "Welcome"
      wr chrome record https://example.com 15 --out ~/Desktop/rec.mov
    """)
}

// ─── Helpers ──────────────────────────────────────────────────────────
