import Foundation

public struct CodexPromptDriver: AssistantPromptDriver {
    public let assistant: CodingAssistant = .codex

    public init() {}

    public func supportsNativeInteraction(for questions: [AskQuestion]) -> Bool {
        // Fall back to terminal for Codex CLI until structured hook contracts are available
        false
    }

    public func formatAnswer(
        questions: [AskQuestion],
        selections: [Int: Set<Int>],
        customTexts: [Int: String] = [:]
    ) -> StructuredQuestionAnswer? {
        nil
    }

    public func chatAboutThisKeys(questions: [AskQuestion]) -> [String]? {
        nil
    }
}
