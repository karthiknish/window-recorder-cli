import Foundation

// ─── MCP Server ──────────────────────────────────────────────────────
// JSON-RPC over stdio MCP server exposing Chrome recording tools

func runMCPServer() {
    let tools: [[String: Any]] = [
        [
            "name": "record_chrome",
            "description": "Record a Chrome window for a specified duration. Returns the path to the .mov file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "duration": ["type": "number", "description": "Recording duration in seconds (default: 10)"],
                    "out": ["type": "string", "description": "Output file path (default: /tmp/recording.mov)"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "name": "record_chrome_navigate",
            "description": "Navigate Chrome to a URL and record the window for a specified duration. Returns the path to the .mov file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "URL to navigate to"],
                    "duration": ["type": "number", "description": "Recording duration in seconds (default: 10)"],
                    "out": ["type": "string", "description": "Output file path (default: /tmp/recording.mov)"]
                ] as [String: Any],
                "required": ["url"]
            ] as [String: Any]
        ],
        [
            "name": "stop_recording",
            "description": "Stop the current recording.",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any]
        ],
        [
            "name": "recording_status",
            "description": "Check if a recording is in progress.",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any]
        ],
        [
            "name": "chrome_screenshot",
            "description": "Take a screenshot of the current Chrome tab.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "out": ["type": "string", "description": "Output file path (default: /tmp/screenshot.png)"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "name": "chrome_navigate",
            "description": "Navigate the current Chrome tab to a URL.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "URL to navigate to"]
                ] as [String: Any],
                "required": ["url"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_click",
            "description": "Click an element in Chrome by CSS selector.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "CSS selector for the element to click"]
                ] as [String: Any],
                "required": ["selector"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_type",
            "description": "Type text into an element in Chrome by CSS selector.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "CSS selector for the input element"],
                    "text": ["type": "string", "description": "Text to type"]
                ] as [String: Any],
                "required": ["selector", "text"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_evaluate",
            "description": "Evaluate a JavaScript expression in Chrome and return the result.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "expression": ["type": "string", "description": "JavaScript expression to evaluate"]
                ] as [String: Any],
                "required": ["expression"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_press",
            "description": "Press a keyboard key in Chrome (Enter, Tab, Escape, Space).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "Key to press (Enter, Tab, Escape, Space)"]
                ] as [String: Any],
                "required": ["key"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_scroll",
            "description": "Scroll to an element in Chrome by CSS selector.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "CSS selector for the element to scroll to"]
                ] as [String: Any],
                "required": ["selector"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_assert",
            "description": "Assert that an element in Chrome contains expected text.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "CSS selector for the element"],
                    "expected": ["type": "string", "description": "Expected text content"]
                ] as [String: Any],
                "required": ["selector", "expected"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_wait",
            "description": "Wait for a specified number of milliseconds.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ms": ["type": "number", "description": "Milliseconds to wait"]
                ] as [String: Any],
                "required": ["ms"]
            ] as [String: Any]
        ],
        [
            "name": "chrome_snapshot",
            "description": "Get the accessibility tree of the current Chrome page.",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any]
        ],
        [
            "name": "chrome_tabs",
            "description": "List all open Chrome tabs.",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any]
        ],
        [
            "name": "chrome_network",
            "description": "List network requests made by the current Chrome page.",
            "inputSchema": ["type": "object", "properties": [:]] as [String: Any]
        ]
    ]

    let stdout = FileHandle.standardOutput

    while true {
        let line = readLine()
        guard let line = line, !line.isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else { continue }

        let id = json["id"]

        switch method {
        case "initialize":
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [
                        "tools": [:]
                    ] as [String: Any],
                    "serverInfo": [
                        "name": "window-recorder",
                        "version": "1.0.0"
                    ] as [String: Any]
                ] as [String: Any]
            ]
            sendJSON(stdout, response)

        case "notifications/initialized":
            break

        case "tools/list":
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": ["tools": tools]
            ]
            sendJSON(stdout, response)

        case "tools/call":
            guard let params = json["params"] as? [String: Any],
                  let name = params["name"] as? String else { continue }
            let args = (params["arguments"] as? [String: Any]) ?? [:]

            let result = handleMCPTool(name: name, args: args)

            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "content": [
                        ["type": "text", "text": result]
                    ]
                ] as [String: Any]
            ]
            sendJSON(stdout, response)

        default:
            if id != nil {
                let response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "error": ["code": -32601, "message": "Method not found"]
                ]
                sendJSON(stdout, response)
            }
        }
    }
}

func sendJSON(_ handle: FileHandle, _ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let str = String(data: data, encoding: .utf8) {
        handle.write("\(str)\n".data(using: .utf8)!)
    }
}

func handleMCPTool(name: String, args: [String: Any]) -> String {
    switch name {
    case "record_chrome":
        let duration = (args["duration"] as? Double) ?? 10
        let out = (args["out"] as? String) ?? "/tmp/recording.mov"
        launchIfNeeded()
        ensureChromeWithCDP()
        let resp = sendCommandSync(["cmd": "start", "app": "Google Chrome", "out": out, "duration": duration])
        Thread.sleep(forTimeInterval: duration + 2)
        if FileManager.default.fileExists(atPath: out) {
            let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
            return "Recording complete. File: \(out) (\(size) bytes, \(Int(duration))s)"
        }
        return "Recording finished but file not found at \(out). Response: \(resp)"

    case "record_chrome_navigate":
        guard let url = args["url"] as? String else { return "Error: url required" }
        let duration = (args["duration"] as? Double) ?? 10
        let out = (args["out"] as? String) ?? "/tmp/recording.mov"
        launchIfNeeded()
        ensureChromeWithCDP()
        chromeNavigate(url: url)
        usleep(1_000_000)
        _ = sendCommandSync(["cmd": "start", "app": "Google Chrome", "out": out, "duration": duration])
        Thread.sleep(forTimeInterval: duration + 2)
        if FileManager.default.fileExists(atPath: out) {
            let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
            return "Recording complete. Navigated to \(url). File: \(out) (\(size) bytes, \(Int(duration))s)"
        }
        return "Recording finished but file not found at \(out)"

    case "stop_recording":
        _ = sendCommandSync(["cmd": "stop"])
        return "Recording stopped"

    case "recording_status":
        let resp = sendCommandSync(["cmd": "status"])
        return "Status: \(resp)"

    case "chrome_screenshot":
        let out = (args["out"] as? String) ?? "/tmp/screenshot.png"
        chromeScreenshot(out: out)
        return "Screenshot saved to \(out)"

    case "chrome_navigate":
        guard let url = args["url"] as? String else { return "Error: url required" }
        chromeNavigate(url: url)
        return "Navigated to \(url)"

    case "chrome_click":
        guard let selector = args["selector"] as? String else { return "Error: selector required" }
        chromeClick(selector: selector)
        return "Clicked element: \(selector)"

    case "chrome_type":
        guard let selector = args["selector"] as? String,
              let text = args["text"] as? String else { return "Error: selector and text required" }
        chromeType(selector: selector, text: text)
        return "Typed '\(text)' into \(selector)"

    case "chrome_evaluate":
        guard let expr = args["expression"] as? String else { return "Error: expression required" }
        let result = chromeEvaluate(expression: expr)
        return "Result: \(result)"

    case "chrome_press":
        guard let key = args["key"] as? String else { return "Error: key required" }
        chromePress(key: key)
        return "Pressed: \(key)"

    case "chrome_scroll":
        guard let selector = args["selector"] as? String else { return "Error: selector required" }
        chromeScroll(selector: selector)
        return "Scrolled to: \(selector)"

    case "chrome_assert":
        guard let selector = args["selector"] as? String,
              let expected = args["expected"] as? String else { return "Error: selector and expected required" }
        _ = cdpCommand("Runtime.enable", [:])
        let expr = "(()=>{const el=document.querySelector(\(jsString(selector)));if(!el)return null;return el.textContent||el.innerText||'';})()"
        if let result = cdpCommand("Runtime.evaluate", ["expression": expr, "returnByValue": true]),
           let value = result["result"] as? [String: Any],
           let actual = value["value"] as? String {
            if actual.contains(expected) {
                return "PASS: \"\(selector)\" contains \"\(expected)\""
            } else {
                return "FAIL: \"\(selector)\" expected \"\(expected)\", got \"\(actual.trimmingCharacters(in: .whitespacesAndNewlines))\""
            }
        }
        return "FAIL: element \"\(selector)\" not found"

    case "chrome_wait":
        guard let ms = args["ms"] as? Int else { return "Error: ms required" }
        usleep(UInt32(ms * 1000))
        return "Waited \(ms)ms"

    case "chrome_snapshot":
        _ = cdpCommand("Accessibility.enable", [:])
        if let result = cdpCommand("Accessibility.getFullAXTree", [:]) {
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        return "Error: snapshot failed"

    case "chrome_tabs":
        guard let tabs = cdpGetJSON("/json") else {
            return "Error: Cannot connect to Chrome. Use chrome_navigate or record_chrome_navigate first."
        }
        var lines: [String] = ["Chrome tabs:"]
        for (i, tab) in tabs.enumerated() {
            let type = tab["type"] ?? "?"
            let title = tab["title"] ?? ""
            let url = tab["url"] ?? ""
            if type as? String == "page" {
                lines.append("  [\(i)] \(title) — \(url)")
            }
        }
        return lines.joined(separator: "\n")

    case "chrome_network":
        _ = cdpCommand("Network.enable", [:])
        if let result = cdpCommand("Runtime.evaluate", ["expression": "JSON.stringify(performance.getEntriesByType('resource').map(r=>({name:r.name,type:r.initiatorType,duration:Math.round(r.duration)})))", "returnByValue": true]),
           let value = result["result"] as? [String: Any],
           let jsonStr = value["value"] as? String,
           let data = jsonStr.data(using: .utf8),
           let resources = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var lines: [String] = ["Network requests (\(resources.count) total):"]
            for r in resources {
                let name = (r["name"] as? String ?? "")
                let shortName = name.count > 80 ? String(name.suffix(80)) : name
                let type = r["type"] ?? "?"
                let duration = r["duration"] ?? 0
                lines.append("  [\(type)] \(shortName) (\(duration)ms)")
            }
            return lines.joined(separator: "\n")
        }
        return "Error: failed to get network requests"

    default:
        return "Unknown tool: \(name)"
    }
}
