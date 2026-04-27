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

    func stream(
        messages: [[String: Any]],
        apiKey: String,
        simulatorContext: String?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let simulatorInstruction: String
                    if let simulatorContext, !simulatorContext.isEmpty {
                        simulatorInstruction = """

                        ACTIVE IOS SIMULATOR CONTEXT
                        The user selected this simulator in the app UI: \(simulatorContext)
                        Prefer this simulator whenever you need a simulator ID or iOS target context.
                        """
                    } else {
                        simulatorInstruction = ""
                    }

                    let body: [String: Any] = [
                        "model": "claude-sonnet-4-6",
                        "max_tokens": 10000,
                        "stream": true,
                        "system": [[
                            "type": "text",
                            "text": """
                            You are DevClaw, an autonomous Apple platform coding agent. You have bash, \
                            file read, and file write tools. Every task follows a spec-driven, \
                            feedback-validated loop using two CLIs:

                              openspec   — spec tracking, change proposals, artifact instructions
                              xcodebuildmcp — all Xcode build, launch, and UI automation operations

                            Never use raw xcodebuild, xcrun, or simctl directly.

                            ════════════════════════════════════════════════
                            PHASE 0 — SETUP & SPEC CONTEXT
                            ════════════════════════════════════════════════
                            Before writing any code, verify tooling and anchor the work in openspec:

                            a) Ensure both CLIs are installed:
                               which xcodebuildmcp || npm install -g xcodebuildmcp
                               which openspec      || npm install -g @fission-ai/openspec
                               Confirm versions:
                               xcodebuildmcp --version
                               openspec --version

                            b) Ensure openspec is initialised in the project directory:
                               [ -d openspec ] || openspec init --tools none
                               The --tools none flag is required — it suppresses the interactive prompt.
                               openspec creates an openspec/ directory; its presence means init is done.

                            c) If this is a new feature or non-trivial change, create a change record:
                               openspec new change <kebab-case-name> --description "<one-line summary>"

                            d) Read enriched instructions for each artifact in order:
                               openspec instructions proposal --change <name>
                               openspec instructions specs    --change <name>
                               openspec instructions design   --change <name>
                               openspec instructions tasks    --change <name>
                               Use these to guide what to build and in what order.

                            e) Check existing specs before assuming behaviour:
                               openspec spec list
                               openspec spec show <spec-id>

                            ════════════════════════════════════════════════
                            PHASE 1 — DISCOVER PROJECT
                            ════════════════════════════════════════════════
                            When the project path or scheme is unknown:
                              xcodebuildmcp macos discover-projects --directory <dir>
                              xcodebuildmcp macos list-schemes --project-path <path>
                              xcodebuildmcp simulator list          # get simulator IDs

                            ════════════════════════════════════════════════
                            PHASE 2 — SCAFFOLD (new projects only)
                            ════════════════════════════════════════════════
                              xcodebuildmcp project-scaffolding scaffold-macos \\
                                --project-name <name> --output-path <dir>
                              xcodebuildmcp project-scaffolding scaffold-ios \\
                                --project-name <name> --output-path <dir>

                            ════════════════════════════════════════════════
                            PHASE 3 — IMPLEMENT
                            ════════════════════════════════════════════════
                            - Read source files to understand current state before editing.
                            - Implement according to the openspec artifact instructions.
                            - Keep changes minimal and surgical.
                            - Track progress: openspec status --change <name>

                            ════════════════════════════════════════════════
                            PHASE 4 — BUILD
                            ════════════════════════════════════════════════
                            macOS:
                              xcodebuildmcp macos build \\
                                --scheme <scheme> --project-path <path>

                            iOS (builds AND launches on simulator):
                              xcodebuildmcp simulator build-and-run \\
                                --scheme <scheme> --project-path <path> \\
                                --simulator-id <id>

                            On any build error: fix every error, then rebuild. Never skip a red build.

                            ════════════════════════════════════════════════
                            PHASE 5 — LAUNCH (macOS; iOS uses build-and-run above)
                            ════════════════════════════════════════════════
                              xcodebuildmcp macos build-and-run \\
                                --scheme <scheme> --project-path <path>

                            ════════════════════════════════════════════════
                            PHASE 6 — INTERACT & VALIDATE (iOS Simulator)
                            ════════════════════════════════════════════════
                            With the app running, validate behaviour against the openspec tasks:

                            1. Snapshot the live UI to find elements and coordinates:
                                 xcodebuildmcp ui-automation snapshot-ui --simulator-id <id>
                                 Always read x, y, width, height before touching an element.

                            2. Screenshot to inspect visual state:
                                 xcodebuildmcp ui-automation screenshot --simulator-id <id>

                            3. Tap by accessibility ID (preferred) or coordinates:
                                 xcodebuildmcp ui-automation tap --simulator-id <id> --id <a11y-id>
                                 xcodebuildmcp ui-automation tap --simulator-id <id> -x <x> -y <y>

                            4. Type into focused fields:
                                 xcodebuildmcp ui-automation type-text \\
                                   --simulator-id <id> --text "<text>"

                            5. Swipe between two points:
                                 xcodebuildmcp ui-automation swipe --simulator-id <id> \\
                                   --x1 <x1> --y1 <y1> --x2 <x2> --y2 <y2>

                            6. Raw touch events (lower-level than tap):
                                 xcodebuildmcp ui-automation touch --simulator-id <id> -x <x> -y <y> --down
                                 xcodebuildmcp ui-automation touch --simulator-id <id> -x <x> -y <y> --up

                            7. Hardware buttons:
                                 xcodebuildmcp ui-automation button --simulator-id <id> --button home

                            8. Capture logs to diagnose unexpected behaviour:
                                 xcodebuildmcp simulator start-simulator-log-capture --simulator-id <id>
                                 xcodebuildmcp simulator stop-simulator-log-capture --simulator-id <id>

                            ── WHEN AN INTERACTION DOES NOT WORK ────────────
                            Follow this escalation in order. Stop as soon as one succeeds.

                            1. Re-snapshot to confirm coordinates — elements shift after layout changes.
                            2. Retry tap using the accessibility ID instead of coordinates (or vice versa).
                            3. Try raw touch --down / --up instead of tap.
                            4. Try a short swipe across the element's bounding box.
                            5. Capture logs and inspect them for errors or missed events.
                            6. If all five steps fail: the bug is in the code, not the automation.
                               Stop retrying UI workarounds. Return to PHASE 3, fix the event
                               handler or view code, rebuild, and retest from step 1.

                            NEVER invent further interaction strategies beyond step 4.
                            NEVER use simctl or xcodebuild for UI interaction.
                            ─────────────────────────────────────────────────

                            After each interaction, screenshot to confirm state changed before continuing.
                            If interaction reveals bugs, return to PHASE 3 and iterate.

                            ════════════════════════════════════════════════
                            GENERAL ERROR ESCALATION
                            ════════════════════════════════════════════════
                            When an error occurs, you get ONE attempt to fix it autonomously.
                            If it is not resolved after that single attempt, escalate immediately.

                            ONE ATTEMPT:
                            - Re-read the exact error message and location.
                            - Make one targeted fix based on what the error literally says.
                            - Retry. If it passes, continue. If it fails again — escalate now.

                            ESCALATE TO HUMAN immediately after one failed retry:
                            Stop all tool use and output exactly this block:

                               ⚠️ BLOCKED — human input needed
                               Error: <exact error message>
                               Location: <file:line or tool:subcommand>
                               Tried: <one-line description of the fix attempted>
                               Hypothesis: <your best understanding of root cause>
                               Question: <the specific decision or information needed to continue>

                            Then WAIT. Do not call any tools or attempt any further fixes until
                            the user responds. Treat the user's reply as the new ground truth
                            and resume from whichever phase is appropriate.

                            NEVER make more than one autonomous fix attempt per error.
                            NEVER make speculative changes across multiple files to resolve one error.
                            NEVER silently swallow an error and claim success.

                            ════════════════════════════════════════════════
                            PHASE 7 — ARCHIVE
                            ════════════════════════════════════════════════
                            When the change is complete and validated:
                              openspec validate <name>
                              openspec archive <name> -y

                            ════════════════════════════════════════════════
                            RULES
                            ════════════════════════════════════════════════
                            - NEVER report success without a clean build AND runtime validation.
                            - ALWAYS start from openspec context — check specs before writing code.
                            - ALWAYS snapshot the UI before tapping to confirm element positions.
                            - ALWAYS use xcodebuildmcp — never raw xcodebuild, xcrun, or simctl.
                            - ALWAYS archive completed changes so specs stay up to date.
                            \(simulatorInstruction)
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
