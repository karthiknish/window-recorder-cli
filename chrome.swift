import Foundation

// ─── Chrome CDP Integration ───────────────────────────────────────────
// Shared CDP helpers and Chrome command functions used by wr.swift and mcp.swift

let CDP_PORT = 9222
let CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

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
    while i < CommandLine.arguments.count {
        if CommandLine.arguments[i] == "--url" { url = CommandLine.arguments[i + 1]; i += 2 } else { i += 1 }
    }

    if let version = cdpGetVersion() {
        print("Chrome already running with CDP (v\(version["Browser"] ?? "?"))")
        if let url = url { chromeNavigate(url: url) }
        return
    }

    if !FileManager.default.fileExists(atPath: CHROME_PATH) {
        print("Error: Google Chrome not found at \(CHROME_PATH)")
        exit(1)
    }

    let task = Process()
    task.launchPath = "/usr/bin/open"
    let chromeProfile = "/tmp/chrome-wr-profile"
    var chromeArgs = ["-a", CHROME_PATH, "--args", "--remote-debugging-port=\(CDP_PORT)", "--user-data-dir=\(chromeProfile)"]
    if let url = url { chromeArgs.append(url) }
    task.arguments = chromeArgs
    try? task.run()

    for _ in 0..<30 {
        usleep(500_000)
        if cdpGetVersion() != nil {
            print("Chrome launched with remote debugging on port \(CDP_PORT)")
            return
        }
    }
    print("Error: Chrome did not start CDP within 15 seconds")
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
    
    let activateTask = Process()
    activateTask.launchPath = "/usr/bin/open"
    activateTask.arguments = ["-a", "Google Chrome"]
    try? activateTask.run()
    
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

func chromeEvaluate(expression: String) -> String {
    _ = cdpCommand("Runtime.enable", [:])
    if let result = cdpCommand("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true]),
       let value = result["result"] as? [String: Any] {
        if let resultValue = value["value"] {
            let s = String(describing: resultValue)
            print(s)
            return s
        } else if let desc = value["description"] as? String {
            print(desc)
            return desc
        } else {
            print("(no result)")
            return "(no result)"
        }
    } else {
        print("Error: evaluate failed")
        return "Error: evaluate failed"
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
    launchIfNeeded()
    ensureChromeWithCDP()
    print("Navigating to: \(url)")
    chromeNavigate(url: url)
    usleep(1_000_000)
    print("Starting recording...")
    sendCommand(["cmd": "start", "app": "Google Chrome", "out": out, "duration": duration])
    print("Recording for \(Int(duration))s...")
    Thread.sleep(forTimeInterval: duration + 2)
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

func ensureChromeWithCDP() {
    if cdpGetVersion() != nil {
        return
    }

    if !FileManager.default.fileExists(atPath: CHROME_PATH) {
        print("Error: Google Chrome not found at \(CHROME_PATH)")
        exit(1)
    }

    print("Launching Chrome with remote debugging...")
    let chromeProfile = "/tmp/chrome-wr-profile"
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-a", CHROME_PATH, "--args", "--remote-debugging-port=\(CDP_PORT)", "--user-data-dir=\(chromeProfile)"]
    try? task.run()

    for _ in 0..<30 {
        usleep(500_000)
        if cdpGetVersion() != nil {
            print("Chrome ready with CDP on port \(CDP_PORT)")
            usleep(2_000_000)
            return
        }
    }
    print("Warning: Chrome CDP did not become ready, recording may fail")
}

func jsString(_ s: String) -> String {
    return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

func sendCommandSync(_ cmd: [String: Any]) -> String {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return "socket error" }
    defer { close(sock) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    SOCKET_PATH.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: SOCKET_PATH.count + 1) {
                strcpy($0, ptr)
            }
        }
    }

    let conn = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard conn == 0 else { return "connect error" }

    if let data = try? JSONSerialization.data(withJSONObject: cmd),
       let str = String(data: data, encoding: .utf8) {
        _ = str.withCString { ptr in write(sock, ptr, strlen(ptr)) }
    }

    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(sock, &buf, buf.count)
    if n > 0 {
        return String(bytes: buf[0..<n], encoding: .utf8) ?? ""
    }
    return ""
}
