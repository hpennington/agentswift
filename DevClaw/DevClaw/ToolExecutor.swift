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

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private func runBash(_ command: String) async -> (String, Bool) {
        await withCheckedContinuation { continuation in
            let proc = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", command]
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.currentDirectoryURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            )

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
    }
}
