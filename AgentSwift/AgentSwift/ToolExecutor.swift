import Foundation

struct ToolExecutor {
    func execute(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        switch name {
        case "bash":
            guard let command = input["command"] as? String else {
                return ("Missing 'command' parameter", true)
            }
            return await runBash(command)

        case "read_file":
            guard let path = input["path"] as? String else {
                return ("Missing 'path' parameter", true)
            }
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                return (content, false)
            } catch {
                return (error.localizedDescription, true)
            }

        case "write_file":
            guard let path = input["path"] as? String,
                  let content = input["content"] as? String else {
                return ("Missing 'path' or 'content' parameter", true)
            }
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                return ("Written to \(path)", false)
            } catch {
                return (error.localizedDescription, true)
            }

        case "open_spec_docs":
            guard let changeName = input["change_name"] as? String,
                  let proposalPath = input["proposal_path"] as? String,
                  let designPath = input["design_path"] as? String else {
                return ("Missing 'change_name', 'proposal_path', or 'design_path' parameter", true)
            }
            let proposal = (try? String(contentsOfFile: proposalPath, encoding: .utf8)) ?? ""
            let design = (try? String(contentsOfFile: designPath, encoding: .utf8)) ?? ""
            guard !proposal.isEmpty || !design.isEmpty else {
                return ("Could not read proposal.md or design.md at the provided paths.", true)
            }
            let content = SpecDocsContent(
                changeName: changeName,
                proposalMarkdown: proposal,
                designMarkdown: design
            )
            let accepted = await SpecDocsWindowManager.shared.open(content)
            if accepted {
                return ("Spec accepted by the user. Proceed with implementation.", false)
            } else {
                return ("Spec rejected by the user. Stop implementation and ask the user what changes they want to the proposal or design before continuing.", true)
            }

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private static let richPATH: String = {
        // Standard locations where Homebrew, npm globals, and developer tools live.
        let standard = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        // Prepend whatever the app process already has so nothing is lost.
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let merged = (standard + existing.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, p in
                if !acc.contains(p) { acc.append(p) }
            }
        return merged.joined(separator: ":")
    }()

    private func runBash(_ command: String) async -> (String, Bool) {
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.richPATH

        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        proc.environment = env
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: ("Cancelled", false))
                    return
                }
                proc.terminationHandler = { p in
                    let stdout = String(
                        data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                    ) ?? ""
                    let stderr = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                    ) ?? ""
                    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    let isError = p.terminationStatus != 0
                    continuation.resume(returning: (combined.isEmpty ? "(no output)" : combined, isError))
                }
                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: (error.localizedDescription, true))
                }
            }
        } onCancel: {
            proc.terminate()
        }
    }
}
