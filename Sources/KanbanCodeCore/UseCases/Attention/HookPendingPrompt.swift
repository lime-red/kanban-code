import Foundation
import KanbanCodeRemoteKit

/// A question (AskUserQuestion) or plan approval (ExitPlanMode) that Claude
/// Code is waiting on, as the PermissionRequest hook reported it.
///
/// Claude Code holds an assistant message back from the transcript until its
/// turn settles, and a turn that ends in AskUserQuestion settles only once the
/// question is answered. So the transcript shows nothing while Claude waits:
/// the question lands in the file together with its answer. The hook sees the
/// question as it is asked, and leaves a copy in
/// `~/.kanban-code/pending-prompts/<session>.json` for the chat and the
/// attention monitor to show until the transcript catches up.
public struct HookPendingPrompt: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case question([AskQuestion])
        case plan(String)
    }

    public var sessionId: String
    public var content: Content
    /// When the hook wrote the file.
    public var askedAt: Date
    /// What the attention monitor raises for it.
    public var decision: PendingDecision

    public var toolName: String {
        switch content {
        case .question: return "AskUserQuestion"
        case .plan: return "ExitPlanMode"
        }
    }
}

/// An answer to a question or multi-question prompt with the keystrokes needed
/// to apply it in the Claude Code terminal and a human-readable summary.
public struct StructuredQuestionAnswer: Codable, Sendable, Equatable {
    public var keys: [String]
    public var summary: String

    public init(keys: [String], summary: String) {
        self.keys = keys
        self.summary = summary
    }

    public func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(from text: String) -> StructuredQuestionAnswer? {
        guard text.contains("\"keys\""),
              let data = text.data(using: .utf8),
              let answer = try? JSONDecoder().decode(StructuredQuestionAnswer.self, from: data)
        else { return nil }
        return answer
    }

    /// Formats the keystrokes and summary for a set of questions and user selections.
    public static func format(
        questions: [AskQuestion],
        selections: [Int: Set<Int>],
        customTexts: [Int: String] = [:]
    ) -> StructuredQuestionAnswer {
        ClaudeCodePromptDriver().formatAnswer(
            questions: questions,
            selections: selections,
            customTexts: customTexts
        ) ?? StructuredQuestionAnswer(keys: [], summary: "Submitted")
    }
}

public enum HookPendingPromptStore {
    /// How far before the hook's write a transcript line may be stamped and
    /// still be the same call: the transcript stamps a message with the time
    /// it streamed, a little before the hook ran.
    static let flushSlack: TimeInterval = 600

    public static var directory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/pending-prompts")
    }

    public static func path(sessionId: String, directory: String = directory) -> String {
        (directory as NSString).appendingPathComponent("\(sessionId).json")
    }

    /// Parses a PermissionRequest hook payload. Nil for any other tool.
    public static func prompt(fromPayload data: Data, askedAt: Date) -> HookPendingPrompt? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["session_id"] as? String, !sessionId.isEmpty,
              let toolName = obj["tool_name"] as? String
        else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        switch toolName {
        case "AskUserQuestion":
            let questions = TranscriptReader.parseAskQuestions(input)
            guard !questions.isEmpty else { return nil }
            let id = "hook_" + stableHash(contentKey(questions: questions))
            return HookPendingPrompt(
                sessionId: sessionId, content: .question(questions), askedAt: askedAt,
                decision: AttentionDetector.question(id: id, input: input, at: askedAt))
        case "ExitPlanMode":
            let plan = (input["plan"] as? String) ?? ""
            let id = "hook_" + stableHash(contentKey(plan: plan))
            return HookPendingPrompt(
                sessionId: sessionId, content: .plan(plan), askedAt: askedAt,
                decision: PendingDecision(
                    toolUseId: id, kind: .planApproval, title: "Plan ready for review",
                    body: AttentionDetector.clipped(plan, 1500), options: AttentionDetector.planOptions,
                    askedAt: askedAt))
        default:
            return nil
        }
    }

    /// Whether the transcript has caught up with `prompt`: the same call is in
    /// it (it is written together with its answer), or the person typed a
    /// prompt after it was asked.
    public static func isSettled(_ prompt: HookPendingPrompt, inLines lines: [String]) -> Bool {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let key = contentKey(prompt.content)
        for line in lines {
            guard line.contains("\"message\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any]
            else { continue }
            let timestamp = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
            if let timestamp, timestamp < prompt.askedAt.addingTimeInterval(-flushSlack) { continue }

            if obj["type"] as? String == "user" {
                if let text = message["content"] as? String, let timestamp, timestamp > prompt.askedAt,
                   !AttentionDetector.isMetaPrompt(text, obj) {
                    return true
                }
                continue
            }
            guard obj["type"] as? String == "assistant",
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard block["name"] as? String == prompt.toolName else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let blockKey: String
                switch prompt.content {
                case .question: blockKey = contentKey(questions: TranscriptReader.parseAskQuestions(input))
                case .plan: blockKey = contentKey(plan: (input["plan"] as? String) ?? "")
                }
                if blockKey == key { return true }
            }
        }
        return false
    }

    /// The prompt the session waits on, if the hook left one the transcript
    /// has not caught up with. A settled file is removed.
    public static func pending(
        sessionId: String, transcriptPath: String?, directory: String = directory
    ) -> HookPendingPrompt? {
        let file = path(sessionId: sessionId, directory: directory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let modified = attrs[.modificationDate] as? Date,
              let data = FileManager.default.contents(atPath: file),
              let prompt = prompt(fromPayload: data, askedAt: modified),
              prompt.sessionId == sessionId
        else { return nil }
        if let transcriptPath {
            let lines = AttentionDetector.tailLines(path: transcriptPath, bytes: 256 * 1024)
            if isSettled(prompt, inLines: lines) {
                try? FileManager.default.removeItem(atPath: file)
                return nil
            }
        }
        return prompt
    }

    /// Drops the session's file when it was written before `date`: a Stop or a
    /// prompt means whatever was asked before it is over.
    public static func remove(sessionId: String, ifWrittenBefore date: Date, directory: String = directory) {
        let file = path(sessionId: sessionId, directory: directory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let modified = attrs[.modificationDate] as? Date,
              modified <= date
        else { return }
        try? FileManager.default.removeItem(atPath: file)
    }

    // MARK: Keys

    static func contentKey(_ content: HookPendingPrompt.Content) -> String {
        switch content {
        case .question(let questions): return contentKey(questions: questions)
        case .plan(let plan): return contentKey(plan: plan)
        }
    }

    static func contentKey(questions: [AskQuestion]) -> String {
        "q:" + questions.map(\.question).joined(separator: "\u{1f}")
    }

    static func contentKey(plan: String) -> String {
        "p:" + plan.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a: the same on every launch and every master, unlike `hashValue`.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
