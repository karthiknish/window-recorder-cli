import Foundation

// ─── CLI tool: wr ─────────────────────────────────────────────────────
// Sends commands to WindowRecorder.app via Unix domain socket
// Also provides Chrome DevTools Protocol (CDP) integration for E2E testing

let SOCKET_PATH = "/tmp/window-recorder.sock"
let APP_PATH = "/Applications/WindowRecorder.app"
let CDP_PORT = 9222
let CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

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
case "chrome":
    runChrome()
case "--help", "-h", "help":
    printUsage()
default:
    print("Unknown command: \(cmd)")
    printUsage()
    exit(1)
}

// ─── Usage ────────────────────────────────────────────────────────────

func printUsage() {
    print("""
    wr — Window Recorder CLI

    Recording:
      wr list                          List available on-screen windows
      wr start --app "Google Chrome"   Start recording a window
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

    Examples:
      wr launch
      wr list
      wr start --app "Google Chrome" --out ~/Desktop/demo.mov --duration 30
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

// ─── Chrome CDP Integration ───────────────────────────────────────────

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
        chromeEvaluate(expression: args[3])
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

// ─── CDP HTTP Helpers ─────────────────────────────────────────────────

func cdpGet(_ path: String) -> Data? {
    let url = URL(string: "http://localhost:\(CDP_PORT)\(path)")!
    var result: Data?
    let semaphore = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: url) { data, _, _ in
        result = data
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    return result
}

func cdpGetJSON(_ path: String) -> [[String: Any]]? {
    guard let data = cdpGet("/json") else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
}

func cdpGetVersion() -> [String: Any]? {
    guard let data = cdpGet("/json/version") else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func cdpGetFirstTab() -> [String: Any]? {
    guard let tabs = cdpGetJSON("/json") else { return nil }
    return tabs.first { ($0["type"] as? String) == "page" } ?? tabs.first
}

// ─── CDP Communication (via Node.js helper) ──────────────────────────

func cdpCommand(_ method: String, _ params: [String: Any]) -> [String: Any]? {
    let payload = ["method": method, "params": params] as [String: Any]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else { return nil }

    let script = """
    const http = require('http');
    const payload = \(json);
    http.get('http://localhost:\(CDP_PORT)/json', (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        try {
          const tabs = JSON.parse(data);
          const tab = tabs.find(t => t.type === 'page') || tabs[0];
          if (!tab) { console.error('No tab found'); process.exit(1); }
          let WebSocket;
          try { WebSocket = require('ws'); }
          catch(e) {
            console.error('ws module not found. Install with: cd e2e && npm install ws');
            process.exit(1);
          }
          const ws = new WebSocket(tab.webSocketDebuggerUrl);
          ws.on('open', () => {
            ws.send(JSON.stringify({id:1, method:payload.method, params:payload.params}));
          });
          ws.on('message', (msg) => {
            const r = JSON.parse(msg.toString());
            if (r.id === 1) {
              console.log(JSON.stringify(r.result || r));
              ws.close();
              process.exit(0);
            }
          });
          ws.on('error', (e) => { console.error('WS error: '+e.message); process.exit(1); });
          setTimeout(() => { console.error('Timeout'); ws.close(); process.exit(1); }, 10000);
        } catch(e) {
          console.error('Parse error: '+e.message);
          process.exit(1);
        }
      });
    }).on('error', (e) => { console.error('HTTP error: '+e.message); process.exit(1); });
    """

    let tempDir = NSTemporaryDirectory()
    let scriptPath = tempDir + "wr_cdp_\(Int.random(in: 0..<999999)).js"
    try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: scriptPath) }

    let task = Process()
    // Find node binary
    let nodePaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    var nodePath: String?
    for path in nodePaths {
        if FileManager.default.fileExists(atPath: path) { nodePath = path; break }
    }
    guard let np = nodePath else {
        print("Error: Node.js not found. Install from https://nodejs.org/")
        return nil
    }
    task.launchPath = np
    task.arguments = [scriptPath]

    // Set NODE_PATH to find ws module
    let cwd = FileManager.default.currentDirectoryPath
    var env = ProcessInfo.processInfo.environment
    let nodePaths2 = [
        cwd + "/e2e/node_modules",
        (env["HOME"] ?? "") + "/.local/lib/node_modules",
        "/usr/local/lib/node_modules",
        "/opt/homebrew/lib/node_modules",
    ]
    env["NODE_PATH"] = nodePaths2.joined(separator: ":")
    task.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.standardOutput = stdoutPipe
    task.standardError = stderrPipe
    try? task.run()
    task.waitUntilExit()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    if task.terminationStatus != 0 {
        let error = String(data: errorData, encoding: .utf8) ?? ""
        if !error.isEmpty {
            print("CDP error: \(error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return nil
    }

    guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty,
          let responseData = output.data(using: .utf8),
          let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
        return nil
    }
    return result
}

// ─── Chrome Commands ──────────────────────────────────────────────────

func chromeLaunch() {
    var url: String? = nil
    var i = 3
    while i < args.count {
        if args[i] == "--url" { url = args[i + 1]; i += 2 } else { i += 1 }
    }

    // Check if Chrome is already running with CDP
    if let version = cdpGetVersion() {
        print("Chrome already running with CDP (v\(version["Browser"] ?? "?"))")
        if let url = url { chromeNavigate(url: url) }
        return
    }

    // Launch Chrome with remote debugging
    if !FileManager.default.fileExists(atPath: CHROME_PATH) {
        print("Error: Google Chrome not found at \(CHROME_PATH)")
        exit(1)
    }

    let task = Process()
    task.launchPath = CHROME_PATH
    var chromeArgs = ["--remote-debugging-port=\(CDP_PORT)", "--user-data-dir=/tmp/chrome-wr-profile"]
    if let url = url { chromeArgs.append(url) }
    task.arguments = chromeArgs
    try? task.run()

    // Wait for CDP to be ready
    for attempt in 0..<20 {
        usleep(500_000)
        if cdpGetVersion() != nil {
            print("Chrome launched with remote debugging on port \(CDP_PORT)")
            return
        }
    }
    print("Error: Chrome did not start CDP within 10 seconds")
    exit(1)
}

func chromeTabs() {
    guard let tabs = cdpGetJSON("/json") else {
        print("Error: Cannot connect to Chrome. Use 'wr chrome launch' first.")
        exit(1)
    }
    print("Chrome tabs:")
    for (i, tab) in tabs.enumerated() {
        let type = tab["type"] ?? "?"
        let title = tab["title"] ?? ""
        let url = tab["url"] ?? ""
        if type as? String == "page" {
            print("  [\(i)] \(title) — \(url)")
        }
    }
}

func chromeNavigate(url: String) {
    _ = cdpCommand("Page.enable", [:])
    let result = cdpCommand("Page.navigate", ["url": url])
    if let result = result, let errorText = result["errorText"] as? String {
        print("Navigate error: \(errorText)")
        exit(1)
    }
    print("Navigated to: \(url)")
    usleep(500_000)
}

func chromeScreenshot(out: String) {
    _ = cdpCommand("Page.enable", [:])
    if let result = cdpCommand("Page.captureScreenshot", ["format": "png"]),
       let data = result["data"] as? String {
        if let raw = Data(base64Encoded: data) {
            try? raw.write(to: URL(fileURLWithPath: out))
            print("Screenshot saved: \(out)")
        }
    } else {
        print("Error: screenshot failed")
        exit(1)
    }
}

func chromeClick(selector: String) {
    _ = cdpCommand("Runtime.enable", [:])
    let expr = "(()=>{const el=document.querySelector(\(jsString(selector)));if(!el)throw new Error('Not found: \(selector)');el.click();return 'clicked';})()"
    if let result = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true]),
       let value = result["result"] as? [String: Any],
       let resultValue = value["value"] as? String {
        print(resultValue)
    } else if let result = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true]),
              let exception = result["exceptionDetails"] as? [String: Any] {
        print("Error: \(exception["text"] ?? "click failed")")
        exit(1)
    } else {
        print("Error: click failed")
        exit(1)
    }
}

func chromeType(selector: String, text: String) {
    _ = cdpCommand("Runtime.enable", [:])
    let expr = "(()=>{const el=document.querySelector(\(jsString(selector)));if(!el)throw new Error('Not found: \(selector)');el.focus();el.value=\(jsString(text));el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return 'typed: '+el.value;})()"
    if let result = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true]),
       let value = result["result"] as? [String: Any],
       let resultValue = value["value"] as? String {
        print(resultValue)
    } else {
        print("Error: type failed")
        exit(1)
    }
}

func chromePress(key: String) {
    let keyMap: [String: [String: Any]] = [
        "Enter": ["key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13],
        "Tab": ["key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9],
        "Escape": ["key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27],
        "Space": ["key": " ", "code": "Space", "windowsVirtualKeyCode": 32],
    ]
    let keyDef = keyMap[key] ?? ["key": key, "code": key, "windowsVirtualKeyCode": 0]
    _ = cdpCommand("Input.dispatchKeyEvent", keyDef.merging(["type": "keyDown"], uniquingKeysWith: { a, _ in a }))
    _ = cdpCommand("Input.dispatchKeyEvent", keyDef.merging(["type": "keyUp"], uniquingKeysWith: { a, _ in a }))
    print("Pressed: \(key)")
}

func chromeScroll(selector: String) {
    _ = cdpCommand("Runtime.enable", [:])
    let expr = "(()=>{const el=document.querySelector(\(jsString(selector)));if(!el)throw new Error('Not found: \(selector)');el.scrollIntoView({behavior:'smooth',block:'center'});return 'scrolled';})()"
    _ = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true])
    print("Scrolled to: \(selector)")
}

func chromeEvaluate(expression: String) {
    _ = cdpCommand("Runtime.enable", [:])
    if let result = cdpCommand("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true]),
       let value = result["result"] as? [String: Any] {
        if let resultValue = value["value"] {
            print(resultValue)
        } else if let desc = value["description"] as? String {
            print(desc)
        } else {
            print("(no result)")
        }
    } else {
        print("Error: evaluate failed")
        exit(1)
    }
}

func chromeAssert(selector: String, expected: String) {
    _ = cdpCommand("Runtime.enable", [:])
    let expr = "(()=>{const el=document.querySelector(\(jsString(selector)));if(!el)return null;return el.textContent||el.innerText||'';})()"
    if let result = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true]),
       let value = result["result"] as? [String: Any],
       let actual = value["value"] as? String {
        if actual.contains(expected) {
            print("PASS: \"\(selector)\" contains \"\(expected)\"")
        } else {
            print("FAIL: \"\(selector)\" expected \"\(expected)\", got \"\(actual.trimmingCharacters(in: .whitespacesAndNewlines))\"")
            exit(1)
        }
    } else {
        print("FAIL: element \"\(selector)\" not found")
        exit(1)
    }
}

func chromeWait(ms: Int) {
    usleep(UInt32(ms * 1000))
    print("Waited \(ms)ms")
}

func chromeSnapshot() {
    _ = cdpCommand("Accessibility.enable", [:])
    if let result = cdpCommand("Accessibility.getFullAXTree", [:]) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else {
        print("Error: snapshot failed")
        exit(1)
    }
}

func chromeConsole(errorsOnly: Bool) {
    _ = cdpCommand("Runtime.enable", [:])
    _ = cdpCommand("Log.enable", [:])
    print("Console log retrieval requires event listening. Use 'wr e2e' for full console capture.")
    if let result = cdpCommand("Runtime.evaluate", ["expression": "performance.getEntries().length", "returnByValue": true]) {
        if let value = result["result"] as? [String: Any] {
            print("Page performance entries: \(value["value"] ?? 0)")
        }
    }
}

func chromeNetwork() {
    _ = cdpCommand("Network.enable", [:])
    if let result = cdpCommand("Runtime.evaluate", ["expression": "JSON.stringify(performance.getEntriesByType('resource').map(r=>({name:r.name,type:r.initiatorType,duration:Math.round(r.duration)})))", "returnByValue": true]),
       let value = result["result"] as? [String: Any],
       let jsonStr = value["value"] as? String,
       let data = jsonStr.data(using: .utf8),
       let resources = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        print("Network requests (\(resources.count) total):")
        for r in resources {
            let name = (r["name"] as? String ?? "")
            let shortName = name.count > 80 ? String(name.suffix(80)) : name
            let type = r["type"] ?? "?"
            let duration = r["duration"] ?? 0
            print("  [\(type)] \(shortName) (\(duration)ms)")
        }
    } else {
        print("Error: failed to get network requests")
    }
}

func chromeRecord(url: String, duration: Double, out: String) {
    // Ensure recorder is running
    launchIfNeeded()

    // Ensure Chrome is running with CDP
    if cdpGetVersion() == nil {
        chromeLaunch()
        usleep(1_000_000)
    }

    // Navigate to URL
    print("Navigating to: \(url)")
    chromeNavigate(url: url)
    usleep(1_000_000)

    // Start recording
    print("Starting recording...")
    sendCommand(["cmd": "start", "app": "Google Chrome", "out": out, "duration": duration])

    // Wait for recording to complete
    print("Recording for \(Int(duration))s...")
    Thread.sleep(forTimeInterval: duration + 2)

    // Check result
    if FileManager.default.fileExists(atPath: out) {
        let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
        print("Recording saved: \(out) (\(size) bytes)")
    } else {
        print("Warning: Recording file not found at \(out)")
    }
}

func launchIfNeeded() {
    let task = Process()
    task.launchPath = "/usr/bin/pgrep"
    task.arguments = ["-f", "WindowRecorder"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if data.isEmpty {
        launchApp()
        usleep(1_000_000)
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────

func jsString(_ s: String) -> String {
    return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}
