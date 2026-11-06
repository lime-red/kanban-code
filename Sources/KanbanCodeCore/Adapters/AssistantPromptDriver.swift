import Foundation

/// Defines how an assistant CLI presents interactive prompts and formats keystroke responses.
public protocol AssistantPromptDriver: Sendable {
    var assistant: CodingAssistant { get }

    /// Whether this assistant's CLI prompt can be answered reliably through native GUI keystroke emulation.
    func supportsNativeInteraction(for questions: [AskQuestion]) -> Bool

    /// Formats keystrokes and human-readable summary for user selections.
    func formatAnswer(
        questions: [AskQuestion],
        selections: [Int: Set<Int>],
        customTexts: [Int: String]
    ) -> StructuredQuestionAnswer?

    /// Keystrokes to trigger "Chat about this" in the assistant's CLI prompt, if supported.
    func chatAboutThisKeys(questions: [AskQuestion]) -> [String]?
}

public enum AssistantPromptDrivers {
    public static func driver(for assistant: CodingAssistant) -> any AssistantPromptDriver {
        switch assistant {
        case .claude:
            return ClaudeCodePromptDriver()
        case .gemini:
            return GeminiPromptDriver()
        case .codex:
            return CodexPromptDriver()
        }
    }
}
