import AppKit
import SwiftUI
import Textual

struct SpecDocsContent {
    let changeName: String
    let proposalMarkdown: String
    let designMarkdown: String
}

// MARK: - Window manager

@MainActor
final class SpecDocsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SpecDocsWindowManager()

    private struct Pending {
        let window: NSWindow
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var pending: [String: Pending] = [:]

    func open(_ content: SpecDocsContent) async -> Bool {
        // Replace any existing window for this change (shouldn't happen, but be safe).
        if let existing = pending[content.changeName] {
            pending.removeValue(forKey: content.changeName)
            existing.window.close()
            existing.continuation.resume(returning: false)
        }

        return await withCheckedContinuation { continuation in
            let view = SpecDocsView(content: content) { [weak self] accepted in
                self?.resolve(changeName: content.changeName, accepted: accepted)
            }
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Spec: \(content.changeName)"
            window.contentView = hosting
            window.center()
            window.setFrameAutosaveName("SpecDocs-\(content.changeName)")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            pending[content.changeName] = Pending(window: window, continuation: continuation)
        }
    }

    private func resolve(changeName: String, accepted: Bool) {
        guard let p = pending.removeValue(forKey: changeName) else { return }
        p.window.close()
        p.continuation.resume(returning: accepted)
    }

    // Called when the user closes the window via the red button — treat as rejection.
    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let (key, p) = self.pending.first(where: { $0.value.window === window }) {
                self.pending.removeValue(forKey: key)
                p.continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - Views

struct SpecDocsView: View {
    let content: SpecDocsContent
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                MarkdownPane(markdown: content.proposalMarkdown)
                    .tabItem { Label("Proposal", systemImage: "doc.text") }
                MarkdownPane(markdown: content.designMarkdown)
                    .tabItem { Label("Design", systemImage: "pencil.and.ruler") }
            }

            Divider()

            HStack {
                Button("Reject", role: .destructive) { onDecision(false) }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Accept") { onDecision(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

private struct MarkdownPane: View {
    let markdown: String

    var body: some View {
        if markdown.isEmpty {
            ContentUnavailableView("File not found", systemImage: "doc.badge.exclamationmark")
        } else {
            ScrollView {
                StructuredText(markdown: markdown)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
