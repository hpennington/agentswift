import Foundation

// MARK: - Display model

struct ChatItem: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        case user(String)
        case assistant(String, isStreaming: Bool)
        case tool(name: String, input: String, output: String?, isError: Bool, isRunning: Bool)
    }

    mutating func appendText(_ delta: String) {
        guard case .assistant(let text, _) = kind else { return }
        kind = .assistant(text + delta, isStreaming: true)
    }

    mutating func finalizeText() {
        guard case .assistant(let text, _) = kind else { return }
        kind = .assistant(text, isStreaming: false)
    }

    mutating func setToolInput(_ input: String) {
        guard case .tool(let name, _, let out, let err, _) = kind else { return }
        kind = .tool(name: name, input: input, output: out, isError: err, isRunning: true)
    }

    mutating func setToolResult(_ output: String, isError: Bool) {
        guard case .tool(let name, let input, _, _, _) = kind else { return }
        kind = .tool(name: name, input: input, output: output, isError: isError, isRunning: false)
    }
}
