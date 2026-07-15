import Foundation

// ─── Chrome CDP Integration ───────────────────────────────────────────
// Shared CDP helpers and Chrome command functions used by wr.swift and mcp.swift
// Uses native URLSessionWebSocketTask — no Node.js or ws module needed.

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

// ─── CDP Communication (native URLSessionWebSocketTask) ───────────────

var cdpMessageId: Int = 1

func cdpCommand(_ method: String, _ params: [String: Any]) -> [String: Any]? {
    guard let tab = cdpGetFirstTab(),
          let wsUrlString = tab["webSocketDebuggerUrl"] as? String,
          let wsUrl = URL(string: wsUrlString) else {
        print("Error: Cannot connect to Chrome CDP. Is Chrome running with --remote-debugging-port=\(CDP_PORT)?")
        print("  Run: wr chrome launch")
        return nil
    }

    let messageId = cdpMessageId
    cdpMessageId += 1

    let payload: [String: Any] = ["id": messageId, "method": method, "params": params]
    guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
          let payloadString = String(data: payloadData, encoding: .utf8) else {
        return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    var responseResult: [String: Any]?

    let urlSession = URLSession(configuration: .default)
    let webSocketTask = urlSession.webSocketTask(with: wsUrl)
    webSocketTask.resume()

    webSocketTask.send(.string(payloadString)) { error in
        if let error = error {
            print("CDP WebSocket send error: \(error.localizedDescription)")
            semaphore.signal()
            return
        }

        let timeoutWorkItem = DispatchWorkItem {
            semaphore.signal()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutWorkItem)

        webSocketTask.receive { result in
            timeoutWorkItem.cancel()
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if json["id"] as? Int == messageId {
                        responseResult = json["result"] as? [String: Any]
                        if let error = json["error"] as? [String: Any] {
                            print("CDP error: \(error["message"] ?? "unknown")")
                        }
                    } else {
                        webSocketTask.receive { result2 in
                            if case .success(.string(let text2)) = result2,
                               let data2 = text2.data(using: .utf8),
                               let json2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
                               json2["id"] as? Int == messageId {
                                responseResult = json2["result"] as? [String: Any]
                            }
                            semaphore.signal()
                        }
                        return
                    }
                }
            case .success(.data):
                break
            case .failure(let error):
                print("CDP WebSocket receive error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
    }

    semaphore.wait()
    webSocketTask.cancel(with: .goingAway, reason: nil)
    urlSession.invalidateAndCancel()

    return responseResult
}

// ─── Helper: evaluate JS and return result value ─────────────────────

func jsEval(_ expression: String) -> [String: Any]? {
    _ = cdpCommand("Runtime.enable", [:])
    return cdpCommand("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true])
}

func jsResultString(_ expression: String) -> String? {
    guard let result = jsEval(expression),
          let value = result["result"] as? [String: Any] else {
        if let result = jsEval(expression),
           let exc = result["exceptionDetails"] as? [String: Any] {
            print("JS error: \(exc["text"] ?? "unknown")")
        }
        return nil
    }
    if let s = value["value"] as? String { return s }
    if let s = value["description"] as? String { return s }
    return nil
}

// ─── Helper: get element coordinates via JS ───────────────────────────

func getElementCenter(selector: String, container: String? = nil) -> (x: Double, y: Double)? {
    let rootExpr = container != nil ? "document.querySelector(\(jsString(container!)))" : "document"
    let expr = "(()=>{const root=\(rootExpr);if(!root)return JSON.stringify({error:'container not found'});const el=root.querySelector(\(jsString(selector)));if(!el)return JSON.stringify({error:'element not found'});const r=el.getBoundingClientRect();if(r.width===0||r.height===0)return JSON.stringify({error:'element has zero size'});return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,h:r.height});})()"
    guard let jsonStr = jsResultString(expr),
          let data = jsonStr.data(using: .utf8),
          let coords = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let error = coords["error"] as? String {
        print("Debug: \(error) for selector: \(selector)")
        return nil
    }
    guard let x = coords["x"] as? Double,
          let y = coords["y"] as? Double else {
        // Try parsing as NSNumber
        let xVal = (coords["x"] as? NSNumber)?.doubleValue
        let yVal = (coords["y"] as? NSNumber)?.doubleValue
        if let x = xVal, let y = yVal {
            return (x, y)
        }
        return nil
    }
    return (x, y)
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
        print("Error: Cannot connect to Chrome. Run 'wr chrome launch' first.")
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
        print("Error: screenshot failed. Is Chrome running with CDP? Try: wr chrome launch")
        exit(1)
    }
}

// Trusted click using CDP Input.dispatchMouseEvent (real pointer events)
func chromeClick(selector: String, container: String? = nil, text: String? = nil) {
    // Step 1: Find the element and get its coordinates
    let rootExpr = container != nil ? "document.querySelector(\(jsString(container!)))" : "document"

    let findExpr: String
    if let text = text {
        // Find by text: search all clickable elements for matching textContent
        findExpr = "(()=>{const root=\(rootExpr);if(!root)return JSON.stringify({error:'container not found: \(container ?? "")'});const els=[...root.querySelectorAll('button,a,[role=button],input[type=submit]')];const el=els.find(e=>(e.textContent||'').trim().includes(\(jsString(text))));if(!el)return JSON.stringify({error:'no element with text: \(text)',count:els.length,samples:els.slice(0,5).map(e=>e.textContent.trim().substring(0,30))});el.scrollIntoView({block:'center'});const r=el.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,h:r.height,text:el.textContent.trim().substring(0,50),tag:el.tagName});})()"
    } else {
        // Find by CSS selector
        findExpr = "(()=>{const root=\(rootExpr);if(!root)return JSON.stringify({error:'container not found: \(container ?? "")'});const el=root.querySelector(\(jsString(selector)));if(!el)return JSON.stringify({error:'element not found: \(selector)',tagCount:root.querySelectorAll('*').length});el.scrollIntoView({block:'center'});const r=el.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,h:r.height,tag:el.tagName});})()"
    }

    guard let jsonStr = jsResultString(findExpr),
          let data = jsonStr.data(using: .utf8),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("Error: Could not evaluate selector. Is Chrome running with CDP? Try: wr chrome launch")
        exit(1)
    }

    if let error = info["error"] as? String {
        print("Error: \(error)")
        if let count = info["count"] as? Int { print("  Found \(count) clickable elements total") }
        if let samples = info["samples"] as? [String] { print("  Sample texts: \(samples.joined(separator: ", "))") }
        if let tagCount = info["tagCount"] as? Int { print("  Page has \(tagCount) total elements") }
        exit(1)
    }

    guard let x = (info["x"] as? Double) ?? (info["x"] as? NSNumber)?.doubleValue,
          let y = (info["y"] as? Double) ?? (info["y"] as? NSNumber)?.doubleValue else {
        print("Error: Could not get element coordinates")
        exit(1)
    }

    if let text = text {
        print("Found: \"\(info["text"] ?? "")\" (\(info["tag"] ?? "?"))")
    }

    // Wait for scroll to settle
    usleep(300_000)

    // Step 2: Dispatch trusted mouse events via CDP
    _ = cdpCommand("Input.dispatchMouseEvent", [
        "type": "mouseMoved",
        "x": x,
        "y": y,
    ])
    _ = cdpCommand("Input.dispatchMouseEvent", [
        "type": "mousePressed",
        "x": x,
        "y": y,
        "button": "left",
        "clickCount": 1,
    ])
    _ = cdpCommand("Input.dispatchMouseEvent", [
        "type": "mouseReleased",
        "x": x,
        "y": y,
        "button": "left",
        "clickCount": 1,
    ])

    print("Clicked: \(text != nil ? "\"\(text!)\"" : selector) at (\(Int(x)), \(Int(y)))\(container != nil ? " in \(container!)" : "")")
}

func chromeType(selector: String, text: String) {
    // Step 1: Focus, clear, and set value via native setter (React-compatible)
    let expr = """
    (()=>{
        const el=document.querySelector(\(jsString(selector)));
        if(!el)return JSON.stringify({error:'element not found: \(selector)'});
        el.focus();
        el.scrollIntoView({block:'center'});
        const proto=el.tagName==='TEXTAREA'?window.HTMLTextAreaElement.prototype:window.HTMLInputElement.prototype;
        const setter=Object.getOwnPropertyDescriptor(proto,'value')?.set;
        if(setter){setter.call(el,\(jsString(text)));}
        else{el.value=\(jsString(text));}
        el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:\(jsString(text))}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return JSON.stringify({ok:true,value:el.value});
    })()
    """

    guard let jsonStr = jsResultString(expr),
          let data = jsonStr.data(using: .utf8),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("Error: type failed. Is Chrome running with CDP? Try: wr chrome launch")
        exit(1)
    }

    if let error = info["error"] as? String {
        print("Error: \(error)")
        exit(1)
    }

    // Step 2: Also dispatch CDP Input.insertText for trusted event listeners
    // This helps with contenteditable or non-standard inputs
    _ = cdpCommand("Input.insertText", ["text": text])

    if let value = info["value"] as? String {
        print("typed: \(value)")
    } else {
        print("typed: \(text)")
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
        print("Error: evaluate failed. Is Chrome running with CDP? Try: wr chrome launch")
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

func chromeWaitForText(selector: String, text: String, timeoutMs: Int) {
    _ = cdpCommand("Runtime.enable", [:])
    let expr = "(()=>{const el=document.querySelector(\(jsString(selector)));if(!el)return false;return (el.textContent||'').includes(\(jsString(text)));})()"
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
    var found = false
    while Date() < deadline {
        if let result = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true]),
           let value = result["result"] as? [String: Any],
           let val = value["value"] as? Bool,
           val {
            found = true
            break
        }
        usleep(300_000)
    }
    if found {
        print("Found: \"\(text)\" in \"\(selector)\"")
    } else {
        print("Timeout: \"\(text)\" not found in \"\(selector)\" within \(timeoutMs)ms")
        exit(1)
    }
}

func chromeSnapshot() {
    _ = cdpCommand("Accessibility.enable", [:])
    if let result = cdpCommand("Accessibility.getFullAXTree", [:]) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else {
        print("Error: snapshot failed. Is Chrome running with CDP? Try: wr chrome launch")
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
        print("Error: failed to get network requests. Is Chrome running with CDP? Try: wr chrome launch")
    }
}

func chromeRecord(url: String, duration: Double, out: String) {
    launchIfNeeded()
    // Don't call ensureChromeWithCDP() — it would relaunch Chrome and kill the existing session.
    // Just check if CDP is available.
    if cdpGetVersion() == nil {
        print("Error: Chrome not running with CDP. Run 'wr chrome launch' first.")
        print("  If Chrome is already open, launch it with: wr chrome launch")
        exit(1)
    }

    print("Navigating to: \(url)")
    chromeNavigate(url: url)
    usleep(1_000_000)
    print("Starting recording...")
    _ = sendCommandSync(["cmd": "start", "app": "Google Chrome", "out": out, "duration": duration])
    print("Recording for \(Int(duration))s... (non-blocking — run 'wr status' to check)")
    print("Recording will auto-stop after \(Int(duration))s. File: \(out)")

    Thread.sleep(forTimeInterval: 2)

    let status = sendCommandSync(["cmd": "status"])
    if status.contains("true") || status.contains("1") {
        print("Recording started successfully. Auto-stops in \(Int(duration))s.")
        print("Run 'wr status' to monitor. Run 'wr stop' to stop early.")
    } else {
        print("Warning: Recording may not have started. Check with: wr status")
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
