import Combine
import SwiftUI

// MARK: - View Model (agentic loop)

struct SimulatorOption: Identifiable, Hashable {
    let id: String
    let name: String
    let runtime: String

    var label: String {
        "\(name) (\(runtime))"
    }
}

@MainActor
final class SimulatorStore: ObservableObject {
    @Published private(set) var simulators: [SimulatorOption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil

        Task {
            do {
                let simulators = try await fetchSimulators()
                isLoading = false
                self.simulators = simulators
            } catch {
                isLoading = false
                self.simulators = []
                self.loadError = error.localizedDescription
            }
        }
    }

    private func fetchSimulators() async throws -> [SimulatorOption] {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "devices", "available", "-j"]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let output = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let errorOutput = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                guard process.terminationStatus == 0 else {
                    let message = errorOutput.isEmpty ? "Unable to load simulators." : errorOutput
                    continuation.resume(throwing: SimulatorLoadError.message(
                        message.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }

                do {
                    let devices = try Self.parseSimulators(from: output)
                    continuation.resume(returning: devices)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func parseSimulators(from json: String) throws -> [SimulatorOption] {
        struct SimctlResponse: Decodable {
            let devices: [String: [SimDevice]]
        }

        struct SimDevice: Decodable {
            let name: String
            let udid: String
            let isAvailable: Bool?
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(SimctlResponse.self, from: Data(json.utf8))

        return response.devices
            .flatMap { runtimeKey, devices -> [SimulatorOption] in
                let runtime = runtimeName(from: runtimeKey)
                return devices.compactMap { device -> SimulatorOption? in
                    guard device.isAvailable != false else { return nil }
                    return SimulatorOption(id: device.udid, name: device.name, runtime: runtime)
                }
            }
            .sorted {
                if $0.runtime == $1.runtime {
                    return $0.name < $1.name
                }
                return $0.runtime > $1.runtime
            }
    }

    nonisolated private static func runtimeName(from runtimeKey: String) -> String {
        let rawName = runtimeKey.split(separator: ".").last.map(String.init) ?? runtimeKey
        return rawName
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "iOS ", with: "iOS ")
    }

    private enum SimulatorLoadError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isRunning = false
    @Published var changeCount = 0  // incremented on every streaming update → scroll trigger

    private let service = AnthropicService()
    private let executor = ToolExecutor()
    private var conversationHistory: [[String: Any]] = []
    private var agentTask: Task<Void, Never>?
    private var messageQueue: [QueuedMessage] = []

    func send(_ text: String, apiKey: String, simulatorContext: String?) {
        guard !text.isEmpty, !apiKey.isEmpty else { return }

        items.append(ChatItem(kind: .user(text)))

        if isRunning {
            messageQueue.append(QueuedMessage(text: text, simulatorContext: simulatorContext))
            return
        }

        isRunning = true
        conversationHistory.append(["role": "user", "content": contextualizedMessage(text, simulatorContext: simulatorContext)])

        agentTask = Task {
            defer { isRunning = false }
            await agenticLoop(apiKey: apiKey, simulatorContext: simulatorContext)
        }
    }

    func stop() {
        agentTask?.cancel()
        agentTask = nil
        messageQueue.removeAll()
        isRunning = false
    }

    func clear() {
        items.removeAll()
        conversationHistory.removeAll()
    }

    // MARK: - Agentic loop

    private func agenticLoop(apiKey: String, simulatorContext: String?) async {
        while true {
            var streamingTextIdx: Int?    // index into items[] of the current assistant text bubble
            var toolItemIdxBySSE: [Int: Int] = [:]   // SSE block index → items[] index

            var finishedBlocks: [Int: ContentBlock] = [:]
            var stopReason = "end_turn"

            do {
                for try await chunk in service.stream(
                    messages: conversationHistory,
                    apiKey: apiKey,
                    simulatorContext: simulatorContext
                ) {
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
            } catch is CancellationError {
                return
            } catch {
                items.append(ChatItem(kind: .assistant(
                    "Error: \(error.localizedDescription)", isStreaming: false
                )))
                return
            }

            guard !Task.isCancelled else { return }

            // Append assistant turn to history (text + tool_use blocks, in SSE order)
            let assistantContent = finishedBlocks
                .sorted { $0.key < $1.key }
                .map { $0.value.toAPIDict() }
                .filter { !$0.isEmpty }

            if !assistantContent.isEmpty {
                conversationHistory.append(["role": "assistant", "content": assistantContent])
            }

            if stopReason != "tool_use" {
                guard !messageQueue.isEmpty, !Task.isCancelled else { break }
                let next = messageQueue.removeFirst()
                conversationHistory.append([
                    "role": "user",
                    "content": contextualizedMessage(next.text, simulatorContext: next.simulatorContext)
                ])
                continue
            }

            if let next = takeLatestQueuedMessage() {
                let supersededMessage = "Skipped because a newer queued message superseded this tool call."
                var skippedToolResults: [[String: Any]] = []

                for (_, block) in finishedBlocks.sorted(by: { $0.key < $1.key }) {
                    guard block.type == "tool_use", let toolId = block.toolId else { continue }
                    skippedToolResults.append(toolResultMessage(
                        toolUseId: toolId,
                        content: supersededMessage,
                        isError: false
                    ))
                }

                for itemsIdx in toolItemIdxBySSE.values {
                    items[itemsIdx].setToolResult(supersededMessage, isError: false)
                }
                changeCount += 1

                var userContent = skippedToolResults
                userContent.append([
                    "type": "text",
                    "text": contextualizedMessage(next.text, simulatorContext: next.simulatorContext)
                ])
                conversationHistory.append(["role": "user", "content": userContent])
                continue
            }

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

    private func contextualizedMessage(_ text: String, simulatorContext: String?) -> String {
        guard let simulatorContext, !simulatorContext.isEmpty else { return text }
        return """
        [Selected iOS Simulator]
        \(simulatorContext)

        [User Message]
        \(text)
        """
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

    private func takeLatestQueuedMessage() -> QueuedMessage? {
        guard let latest = messageQueue.last else { return nil }
        messageQueue.removeAll()
        return latest
    }

    private struct QueuedMessage {
        let text: String
        let simulatorContext: String?
    }
}

// MARK: - Root View

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var simulatorStore = SimulatorStore()
    @AppStorage("anthropicAPIKey") private var apiKey = ""
    @AppStorage("selectedSimulatorID") private var selectedSimulatorID = ""
    @State private var input = ""
    @State private var showSettingsPanel = false

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSettingsPanel.toggle() } label: {
                    Image(systemName: showSettingsPanel ? "sidebar.trailing" : "sidebar.right")
                }
                .help(showSettingsPanel ? "Hide Settings" : "Show Settings")
            }
            ToolbarItem(placement: .automatic) {
                Button("Clear") { viewModel.clear() }
                    .disabled(viewModel.items.isEmpty || viewModel.isRunning)
            }
        }
        .inspector(isPresented: $showSettingsPanel) {
            SettingsPanel(
                apiKey: $apiKey,
                simulatorStore: simulatorStore,
                selectedSimulatorID: $selectedSimulatorID
            )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay {
            if apiKey.isEmpty && viewModel.items.isEmpty {
                SetupPrompt { showSettingsPanel = true }
            }
        }
        .task {
            simulatorStore.refresh()
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

            Button(action: {
                if hasInputText {
                    sendMessage()
                } else {
                    viewModel.stop()
                }
            }) {
                Image(systemName: viewModel.isRunning && !hasInputText ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .primary : .secondary)
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hasInputText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !apiKey.isEmpty && (hasInputText || viewModel.isRunning)
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        viewModel.send(text, apiKey: apiKey, simulatorContext: selectedSimulatorContext)
    }

    private var selectedSimulatorContext: String? {
        guard let simulator = simulatorStore.simulators.first(where: { $0.id == selectedSimulatorID }) else {
            return nil
        }
        return "\(simulator.label) [\(simulator.id)]"
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

struct SettingsPanel: View {
    @Binding var apiKey: String
    @ObservedObject var simulatorStore: SimulatorStore
    @Binding var selectedSimulatorID: String

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

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("iOS Simulator")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        simulatorStore.refresh()
                    } label: {
                        if simulatorStore.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Refresh available simulators")
                }

                Picker("iOS Simulator", selection: $selectedSimulatorID) {
                    Text("None").tag("")
                    ForEach(simulatorStore.simulators) { simulator in
                        Text(simulator.label).tag(simulator.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(simulatorStore.simulators.isEmpty)

                if let simulator = simulatorStore.simulators.first(where: { $0.id == selectedSimulatorID }) {
                    Text("Injected into chat context as \(simulator.label).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let loadError = simulatorStore.loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Choose a simulator to give the agent a concrete iOS target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: simulatorStore.simulators) { _, simulators in
            if !selectedSimulatorID.isEmpty && !simulators.contains(where: { $0.id == selectedSimulatorID }) {
                selectedSimulatorID = ""
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
