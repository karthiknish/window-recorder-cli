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
        if cdpGetVersion() == nil {
            chromeLaunch()
            usleep(1_000_000)
        }
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

    default:
        return "Unknown tool: \(name)"
    }
}
