import Foundation
import KanbanCodeRemoteKit

/// Errors from image sending operations.
public enum ImageSendError: Error, LocalizedError {
    case assistantNotReady(CodingAssistant)
    case imageUploadTimeout(expected: Int, assistant: CodingAssistant)
    case trustAnswerNotSelected
    case folderNotTrusted

    public var errorDescription: String? {
        switch self {
        case .assistantNotReady(let assistant):
            "\(assistant.displayName) did not become ready within the timeout period"
        case .imageUploadTimeout(let n, let assistant):
            "Timed out waiting for image #\(n) to be accepted by \(assistant.displayName)"
        case .trustAnswerNotSelected:
            "Could not select the answer on Claude Code's trust screen"
        case .folderNotTrusted:
            "Claude Code quit: the folder was not trusted"
        }
    }
}

/// Orchestrates sending images to a Claude Code session via tmux.
///
/// For each image:
/// 1. Sets the system clipboard to the image data (via injected closure)
/// 2. Sends an empty bracketed paste event to the tmux session
/// 3. Polls `tmux capture-pane` until Claude confirms the image with `[Image #N]`
public actor ImageSender {
    private let tmux: TmuxManagerPort

    public init(tmux: TmuxManagerPort) {
        self.tmux = tmux
    }

    /// Wait for the coding assistant to show its input prompt.
    ///
    /// Claude Code first asks whether to trust a folder it has not seen. With
    /// `trustFolder` (the person ticked "Trust this folder" when launching)
    /// the answer is "Yes, I trust this folder": the highlight is moved there
    /// and Enter pressed only once the pane shows it selected, since the
    /// default answer exits Claude. Otherwise the person answers it in the
    /// terminal or from the card: `onTrustPrompt(true)` runs when the screen
    /// comes up and `onTrustPrompt(false)` when it goes, and the wait lasts
    /// up to `trustAnswerTimeout` while it is up.
    public func waitForReady(
        sessionName: String,
        assistant: CodingAssistant = .claude,
        trustFolder: Bool = false,
        onTrustPrompt: (@Sendable (Bool) async -> Void)? = nil,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration? = nil,
        trustAnswerTimeout: Duration = .seconds(12 * 3600)
    ) async throws {
        // A rush host takes messages as soon as it runs, and queues them.
        if RushSessionName.isRush(sessionName) { return }
        // Gemini and Codex can take longer to start (auth checks, banners, model setup).
        let effectiveTimeout = timeout ?? (assistant == .gemini || assistant == .codex ? .seconds(60) : .seconds(30))
        var start = ContinuousClock.now
        var acceptedCodexStartupPrompt = false
        var trustPromptSince: ContinuousClock.Instant?
        var trustKeysSent = 0
        var trustShown = false
        while ContinuousClock.now - start < effectiveTimeout {
            let output = try await tmux.capturePane(sessionName: sessionName)
            // Answered No: Claude has quit, and the prompt would go to the shell.
            if assistant == .claude, PaneOutputParser.claudeTrustDeclined(output) {
                if trustShown { await onTrustPrompt?(false) }
                throw ImageSendError.folderNotTrusted
            }
            let ready = PaneOutputParser.isReady(output, assistant: assistant)
            let screen = !ready && assistant == .claude ? PaneOutputParser.claudeTrustPrompt(output) : nil
            // The person is asked while the screen is up and launch is not answering it.
            let asking = screen != nil && !(trustFolder && trustKeysSent < 4)
            if asking != trustShown {
                trustShown = asking
                await onTrustPrompt?(asking)
            }
            if ready { return }
            if let trust = screen {
                if trustFolder, trustKeysSent < 4 {
                    // At most a few presses: the menu has two answers.
                    trustKeysSent += 1
                    try await tmux.sendKey(to: sessionName, key: trust.yesIsSelected ? "Enter" : "Down")
                } else if trustPromptSince == nil {
                    trustPromptSince = .now
                }
                // Claude waits on the person, so the start-up timeout waits too.
                if let since = trustPromptSince, ContinuousClock.now - since >= trustAnswerTimeout { break }
                start = .now
                try await Task.sleep(for: pollInterval)
                continue
            }
            if assistant == .codex,
               !acceptedCodexStartupPrompt,
               PaneOutputParser.codexNeedsStartupConfirmation(output) {
                acceptedCodexStartupPrompt = true
                try await tmux.submitPrompt(to: sessionName)
            }
            try await Task.sleep(for: pollInterval)
        }
        throw ImageSendError.assistantNotReady(assistant)
    }

    /// Answers Claude's folder trust screen: moves the highlight to the
    /// answer and presses Enter only once the pane shows it selected. Does
    /// nothing when the screen is not up.
    public func answerTrustPrompt(
        sessionName: String,
        trust: Bool,
        pollInterval: Duration = .milliseconds(300)
    ) async throws {
        // Versions list the answers in either order, so the arrow that did
        // not move the highlight is swapped for the other one.
        var key = "Down"
        var pressed = false
        for _ in 0..<4 {
            let output = try await tmux.capturePane(sessionName: sessionName)
            guard let screen = PaneOutputParser.claudeTrustPrompt(output) else { return }
            if screen.yesIsSelected == trust {
                try await tmux.sendKey(to: sessionName, key: "Enter")
                return
            }
            if pressed { key = key == "Down" ? "Up" : "Down" }
            try await tmux.sendKey(to: sessionName, key: key)
            pressed = true
            try await Task.sleep(for: pollInterval)
        }
        throw ImageSendError.trustAnswerNotSelected
    }

    /// Send images one by one, confirming each before sending the next.
    ///
    /// - Parameters:
    ///   - sessionName: tmux session target
    ///   - images: images to send
    ///   - setClipboard: closure that sets the system clipboard to image data (injected for testability)
    ///   - pollInterval: how often to check for confirmation
    ///   - timeout: max time to wait per image
    public func sendImages(
        sessionName: String,
        images: [ImageAttachment],
        assistant: CodingAssistant = .claude,
        setClipboard: @Sendable (Data) -> Void,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(30)
    ) async throws {
        for (index, image) in images.enumerated() {
            // Count before sending
            let before = try await tmux.capturePane(sessionName: sessionName)
            let countBefore = PaneOutputParser.countImages(in: before)

            setClipboard(image.data)
            try await tmux.sendBracketedPaste(to: sessionName)

            // Poll until count goes up
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                try await Task.sleep(for: pollInterval)
                let output = try await tmux.capturePane(sessionName: sessionName)
                if PaneOutputParser.countImages(in: output) > countBefore {
                    break
                }
                if ContinuousClock.now - start >= timeout {
                    throw ImageSendError.imageUploadTimeout(expected: index + 1, assistant: assistant)
                }
            }
        }
    }

    /// Send a text prompt with image attachments as one user turn.
    ///
    /// Image placeholders in `prompt` (`[Image #1]`, `[Image #2]`, ...) are
    /// replaced by image paste events at the same position. If no placeholders
    /// are present, images are appended after the text for backwards
    /// compatibility with older stored prompts.
    public func sendPromptWithImages(
        sessionName: String,
        prompt: String,
        images: [ImageAttachment],
        assistant: CodingAssistant = .claude,
        setClipboard: @Sendable (Data) -> Void,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(30)
    ) async throws {
        let parts = PromptImageLayout.parts(in: prompt, imageCount: images.count)
        let hasInlineImages = parts.contains { $0.imageIndex != nil }
        let stagedParts: [PromptImageLayout.Part]

        if hasInlineImages {
            stagedParts = parts
        } else {
            var appendedParts: [PromptImageLayout.Part] = []
            if !prompt.isEmpty {
                appendedParts.append(.init(text: prompt))
            }
            appendedParts += images.indices.map { .init(text: "", imageIndex: $0) }
            stagedParts = appendedParts
        }

        try await sendParts(
            stagedParts,
            sessionName: sessionName,
            images: images,
            assistant: assistant,
            setClipboard: setClipboard,
            pollInterval: pollInterval,
            timeout: timeout
        )

        if !prompt.isEmpty || !images.isEmpty {
            try await tmux.submitPrompt(to: sessionName)
        }
    }

    private func sendParts(
        _ parts: [PromptImageLayout.Part],
        sessionName: String,
        images: [ImageAttachment],
        assistant: CodingAssistant,
        setClipboard: @Sendable (Data) -> Void,
        pollInterval: Duration,
        timeout: Duration
    ) async throws {
        var carryNewlines = ""
        for (offset, part) in parts.enumerated() {
            if let imageIndex = part.imageIndex {
                try await sendImages(
                    sessionName: sessionName,
                    images: [images[imageIndex]],
                    assistant: assistant,
                    setClipboard: setClipboard,
                    pollInterval: pollInterval,
                    timeout: timeout
                )
                continue
            }

            var text = carryNewlines + part.text
            carryNewlines = ""

            // Claude Code can submit the current draft when an image is pasted
            // after a text chunk that ends with a newline. Keep image ordering
            // reliable by never leaving the pre-image paste newline-terminated;
            // carry those line breaks forward and paste them after the image.
            if nextPartIsImage(parts, after: offset) {
                let split = splitTrailingNewlines(from: text)
                text = split.body
                carryNewlines = split.trailingNewlines
            }

            if !text.isEmpty {
                try await tmux.pasteText(to: sessionName, text: text)
            }
        }

        if !carryNewlines.isEmpty {
            try await tmux.pasteText(to: sessionName, text: carryNewlines)
        }
    }

    private func nextPartIsImage(_ parts: [PromptImageLayout.Part], after offset: Int) -> Bool {
        let next = offset + 1
        guard parts.indices.contains(next) else { return false }
        return parts[next].imageIndex != nil
    }

    private func splitTrailingNewlines(from text: String) -> (body: String, trailingNewlines: String) {
        var splitIndex = text.endIndex
        while splitIndex > text.startIndex {
            let previous = text.index(before: splitIndex)
            guard text[previous].isNewline else { break }
            splitIndex = previous
        }
        return (String(text[..<splitIndex]), String(text[splitIndex...]))
    }
}
