import Foundation

// MARK: - Content blocks (used for conversation history)

struct ContentBlock {
    let type: String          // "text" | "tool_use"
    var text: String?
    var toolId: String?
    var toolName: String?
    var toolInputJSON: String?

    static func text(_ t: String) -> ContentBlock {
        ContentBlock(type: "text", text: t)
    }

    static func toolUse(id: String, name: String) -> ContentBlock {
        ContentBlock(type: "tool_use", toolId: id, toolName: name, toolInputJSON: "")
    }

    var parsedInput: [String: Any]? {
        guard let json = toolInputJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func toAPIDict() -> [String: Any] {
        switch type {
        case "text":
            return ["type": "text", "text": text ?? ""]
        case "tool_use":
            return [
                "type": "tool_use",
                "id": toolId ?? "",
                "name": toolName ?? "",
                "input": parsedInput ?? [:]
            ]
        default:
            return [:]
        }
    }

    private init(type: String, text: String? = nil, toolId: String? = nil,
                 toolName: String? = nil, toolInputJSON: String? = nil) {
        self.type = type
        self.text = text
        self.toolId = toolId
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
    }
}

func toolResultMessage(toolUseId: String, content: String, isError: Bool) -> [String: Any] {
    ["type": "tool_result", "tool_use_id": toolUseId, "content": content, "is_error": isError]
}

// MARK: - Stream events

enum StreamChunk: Sendable {
    case textDelta(String)
    case toolCallAnnounced(index: Int, id: String, name: String)
    case done(stopReason: String, blocks: [Int: ContentBlock])
}

// MARK: - Service

struct AnthropicService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let tools: [[String: Any]] = [
        [
            "name": "bash",
            "description": "Execute a bash shell command and return stdout + stderr. Use for running scripts, listing files, compiling, testing, etc.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The bash command to run."]
                ],
                "required": ["command"]
            ]
        ],
        [
            "name": "read_file",
            "description": "Read and return the full text content of a file.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute or relative path to the file."]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": "write_file",
            "description": "Write text content to a file, creating or overwriting it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path where the file should be written."],
                    "content": ["type": "string", "description": "Text content to write."]
                ],
                "required": ["path", "content"]
            ]
        ]
    ]

    func stream(messages: [[String: Any]], apiKey: String) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let body: [String: Any] = [
                        "model": "claude-opus-4-7",
                        "max_tokens": 64000,
                        "stream": true,
                        "system": [[
                            "type": "text",
                            "text": """
                            You are DevClaw, a powerful AI coding assistant for Apple platform development. \
                            You have bash, file read, and file write tools. You work through a strict \
                            multi-phase feedback cycle using `xcodebuildmcp` as the primary CLI for all \
                            Xcode operations — never use raw `xcodebuild`, `xcrun`, or `simctl` directly.

                            ═══════════════════════════════════════════════
                            PHASE 0 — DISCOVER (when project/scheme unknown)
                            ═══════════════════════════════════════════════
                            xcodebuildmcp macos discover-projects --directory <dir>
                            xcodebuildmcp macos list-schemes --project-path <path>
                            xcodebuildmcp simulator list                         # find simulator IDs

                            ══════════════════════════════════════════
                            PHASE 1 — SCAFFOLD (new projects only)
                            ══════════════════════════════════════════
                            xcodebuildmcp project-scaffolding scaffold-macos \\
                              --project-name <name> --output-path <dir>
                            xcodebuildmcp project-scaffolding scaffold-ios \\
                              --project-name <name> --output-path <dir>

                            ══════════════════════════════════════════
                            PHASE 2 — CHANGE
                            ══════════════════════════════════════════
                            - Read relevant source files first to understand the current state.
                            - Make targeted edits with write_file or bash.
                            - Keep changes minimal and surgical.

                            ══════════════════════════════════════════
                            PHASE 3 — BUILD
                            ══════════════════════════════════════════
                            macOS:
                              xcodebuildmcp macos build \\
                                --scheme <scheme> --project-path <path>

                            iOS (builds AND launches on simulator in one step):
                              xcodebuildmcp simulator build-and-run \\
                                --scheme <scheme> --project-path <path> \\
                                --simulator-id <id>

                            On build failure: fix every error, then rebuild. Never proceed with a red build.

                            ══════════════════════════════════════════
                            PHASE 4 — LAUNCH (macOS only; iOS uses build-and-run above)
                            ══════════════════════════════════════════
                            xcodebuildmcp macos build-and-run \\
                              --scheme <scheme> --project-path <path>

                            ══════════════════════════════════════════
                            PHASE 5 — INTERACT & VALIDATE (iOS Simulator)
                            ══════════════════════════════════════════
                            After the app is running, explore and interact with the live UI:

                            1. Snapshot the view hierarchy to find elements and coordinates:
                               xcodebuildmcp simulator snapshot-ui --simulator-id <id>
                               xcodebuildmcp ui-automation snapshot-ui --simulator-id <id>

                            2. Take a screenshot to visually inspect the current state:
                               xcodebuildmcp simulator screenshot --simulator-id <id>
                               xcodebuildmcp ui-automation screenshot --simulator-id <id>

                            3. Tap elements by accessibility ID (preferred) or coordinates:
                               xcodebuildmcp ui-automation tap \\
                                 --simulator-id <id> --id <accessibility-id>
                               xcodebuildmcp ui-automation tap \\
                                 --simulator-id <id> -x <x> -y <y>

                            4. Type text into focused fields:
                               xcodebuildmcp ui-automation type-text \\
                                 --simulator-id <id> --text "<text>"

                            5. Swipe, long-press, or use hardware buttons as needed:
                               xcodebuildmcp ui-automation swipe --simulator-id <id> \\
                                 --start-x <x1> --start-y <y1> --end-x <x2> --end-y <y2>
                               xcodebuildmcp ui-automation button \\
                                 --simulator-id <id> --button home

                            6. Capture logs if behavior is unexpected:
                               xcodebuildmcp simulator start-simulator-log-capture --simulator-id <id>
                               # ... trigger the behavior ...
                               xcodebuildmcp simulator stop-simulator-log-capture --simulator-id <id>

                            ══════════════════════════════════════════
                            RULES
                            ══════════════════════════════════════════
                            - NEVER report success without a clean build and runtime validation.
                            - ALWAYS use xcodebuildmcp — never raw xcodebuild, xcrun, or simctl.
                            - ALWAYS snapshot the UI before tapping to confirm element positions.
                            - Fix ALL compiler errors before moving to launch/interact phases.
                            - Iterate: if interaction reveals bugs, return to PHASE 2 and fix.
                            """,
                            "cache_control": ["type": "ephemeral"]
                        ]],
                        "tools": Self.tools,
                        "messages": messages
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let msg = parseError(data) ?? "HTTP \(http.statusCode)"
                        throw StreamError.apiError(msg)
                    }

                    // Accumulate content blocks by SSE index
                    var blocks: [Int: ContentBlock] = [:]
                    var stopReason = "end_turn"

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(SSEEvent.self, from: data)
                        else { continue }

                        switch event.type {
                        case "content_block_start":
                            guard let cb = event.content_block else { break }
                            let idx = event.index ?? 0
                            switch cb.type {
                            case "text":
                                blocks[idx] = .text("")
                            case "tool_use":
                                blocks[idx] = .toolUse(id: cb.id ?? "", name: cb.name ?? "")
                                continuation.yield(.toolCallAnnounced(
                                    index: idx, id: cb.id ?? "", name: cb.name ?? ""
                                ))
                            default:
                                break
                            }

                        case "content_block_delta":
                            let idx = event.index ?? 0
                            guard let delta = event.delta else { break }
                            switch delta.type {
                            case "text_delta":
                                guard let t = delta.text else { break }
                                let existingText = blocks[idx]?.text ?? ""
                                blocks[idx]?.text = existingText + t
                                continuation.yield(.textDelta(t))
                            case "input_json_delta":
                                guard let p = delta.partial_json else { break }
                                let existingJSON = blocks[idx]?.toolInputJSON ?? ""
                                blocks[idx]?.toolInputJSON = existingJSON + p
                            default:
                                break
                            }

                        case "message_delta":
                            if let r = event.delta?.stop_reason { stopReason = r }

                        default:
                            break
                        }
                    }

                    continuation.yield(.done(stopReason: stopReason, blocks: blocks))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func parseError(_ data: Data) -> String? {
        struct E: Decodable { struct D: Decodable { let message: String }; let error: D }
        return try? JSONDecoder().decode(E.self, from: data).error.message
    }
}

// MARK: - SSE Decodables

private struct SSEEvent: Decodable {
    let type: String
    let index: Int?
    let content_block: SSEBlock?
    let delta: SSEDelta?
}

private struct SSEBlock: Decodable {
    let type: String
    let id: String?
    let name: String?
}

private struct SSEDelta: Decodable {
    let type: String?
    let text: String?
    let partial_json: String?
    let stop_reason: String?
}

// MARK: - Errors

enum StreamError: LocalizedError {
    case apiError(String)
    var errorDescription: String? {
        if case .apiError(let msg) = self { return msg }
        return nil
    }
}
