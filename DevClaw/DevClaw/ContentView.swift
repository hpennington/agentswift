import Combine
import SwiftUI

// MARK: - View Model (agentic loop)

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isRunning = false
    @Published var changeCount = 0  // incremented on every streaming update → scroll trigger

    private let service = AnthropicService()
    private let executor = ToolExecutor()
    private var conversationHistory: [[String: Any]] = []

    func send(_ text: String, apiKey: String) {
        guard !isRunning, !text.isEmpty, !apiKey.isEmpty else { return }
        isRunning = true

        items.append(ChatItem(kind: .user(text)))
        conversationHistory.append(["role": "user", "content": text])

        Task {
            defer { isRunning = false }
            await agenticLoop(apiKey: apiKey)
        }
    }

    func clear() {
        items.removeAll()
        conversationHistory.removeAll()
    }

    // MARK: - Agentic loop

    private func agenticLoop(apiKey: String) async {
        while true {
            var streamingTextIdx: Int?    // index into items[] of the current assistant text bubble
            var toolItemIdxBySSE: [Int: Int] = [:]   // SSE block index → items[] index

            var finishedBlocks: [Int: ContentBlock] = [:]
            var stopReason = "end_turn"

            do {
                for try await chunk in service.stream(messages: conversationHistory, apiKey: apiKey) {
                    switch chunk {

                    case .textDelta(let delta):
                        if let i = streamingTextIdx {
                            items[i].appendText(delta)
                        } else {
                            let item = ChatItem(kind: .assistant(delta, isStreaming: true))
                            streamingTextIdx = items.count
                            items.append(item)
                        }
                        changeCount += 1

                    case .toolCallAnnounced(let sseIdx, _, let name):
                        if let i = streamingTextIdx {
                            items[i].finalizeText()
                            streamingTextIdx = nil
                        }
                        let item = ChatItem(kind: .tool(
                            name: name, input: "", output: nil, isError: false, isRunning: true
                        ))
                        toolItemIdxBySSE[sseIdx] = items.count
                        items.append(item)
                        changeCount += 1

                    case .done(let reason, let blocks):
                        stopReason = reason
                        finishedBlocks = blocks

                        if let i = streamingTextIdx {
                            items[i].finalizeText()
                        }

                        // Fill in tool inputs now that they're fully streamed
                        for (sseIdx, itemsIdx) in toolItemIdxBySSE {
                            if let block = blocks[sseIdx] {
                                items[itemsIdx].setToolInput(
                                    displayInput(name: block.toolName ?? "", json: block.toolInputJSON ?? "")
                                )
                            }
                        }
                        changeCount += 1
                    }
                }
            } catch {
                items.append(ChatItem(kind: .assistant(
                    "Error: \(error.localizedDescription)", isStreaming: false
                )))
                return
            }

            // Append assistant turn to history (text + tool_use blocks, in SSE order)
            let assistantContent = finishedBlocks
                .sorted { $0.key < $1.key }
                .map { $0.value.toAPIDict() }
                .filter { !$0.isEmpty }

            if !assistantContent.isEmpty {
                conversationHistory.append(["role": "assistant", "content": assistantContent])
            }

            guard stopReason == "tool_use" else { break }

            // Execute each tool call and collect results
            var toolResults: [[String: Any]] = []

            for (sseIdx, block) in finishedBlocks.sorted(by: { $0.key < $1.key }) {
                guard block.type == "tool_use",
                      let toolId = block.toolId,
                      let toolName = block.toolName,
                      let input = block.parsedInput
                else { continue }

                let (output, isError) = await executor.execute(name: toolName, input: input)

                if let itemsIdx = toolItemIdxBySSE[sseIdx] {
                    items[itemsIdx].setToolResult(output, isError: isError)
                    changeCount += 1
                }

                toolResults.append(toolResultMessage(
                    toolUseId: toolId, content: output, isError: isError
                ))
            }

            if !toolResults.isEmpty {
                conversationHistory.append(["role": "user", "content": toolResults])
            }
        }
    }

    // Pretty-print tool input for display
    private func displayInput(name: String, json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        switch name {
        case "bash":    return "$ \(obj["command"] as? String ?? "")"
        case "read_file":  return "cat \(obj["path"] as? String ?? "")"
        case "write_file": return "→ \(obj["path"] as? String ?? "")"
        default:        return json
        }
    }
}

// MARK: - Root View

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @AppStorage("anthropicAPIKey") private var apiKey = ""
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: {
                    Image(systemName: "key.fill")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Clear") { viewModel.clear() }
                    .disabled(viewModel.items.isEmpty || viewModel.isRunning)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $apiKey)
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay {
            if apiKey.isEmpty && viewModel.items.isEmpty {
                SetupPrompt { showSettings = true }
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.items) { item in
                        ChatItemView(item: item)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: viewModel.changeCount) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("bottom")
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                Image(systemName: viewModel.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .primary : .secondary)
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !viewModel.isRunning &&
        !apiKey.isEmpty
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        viewModel.send(text, apiKey: apiKey)
    }
}

// MARK: - Chat item views

struct ChatItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text)
        case .assistant(let text, let isStreaming):
            AssistantBubble(text: text, isStreaming: isStreaming)
        case .tool(let name, let input, let output, let isError, let isRunning):
            ToolCard(name: name, input: input, output: output, isError: isError, isRunning: isRunning)
        }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                if text.isEmpty && isStreaming {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text(text)
                        .textSelection(.enabled)
                }
                if isStreaming && !text.isEmpty {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 12)
                        .opacity(0.8)
                }
            }

            Spacer(minLength: 40)
        }
    }
}

struct ToolCard: View {
    let name: String
    let input: String
    let output: String?
    let isError: Bool
    let isRunning: Bool

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolIcon)
                        .foregroundStyle(isError ? .red : .secondary)
                        .frame(width: 16)

                    Text(name)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)

                    if !input.isEmpty {
                        Text(input)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if isRunning {
                        ProgressView().scaleEffect(0.6)
                    } else if let _ = output {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Color.secondary.opacity(0.08))

            // Output
            if isExpanded, let out = output, !out.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(out)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isError ? .red : .primary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        )
    }

    private var toolIcon: String {
        switch name {
        case "bash": return "terminal"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        default: return "wrench"
        }
    }
}

// MARK: - Supporting views

struct SetupPrompt: View {
    let action: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Add your Anthropic API key to start")
                .foregroundStyle(.secondary)
            Button("Open Settings", action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Anthropic API Key")
                    .font(.subheadline.weight(.medium))
                SecureField("sk-ant-api03-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in UserDefaults. Used only to call the Anthropic API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

#Preview {
    ContentView()
}
