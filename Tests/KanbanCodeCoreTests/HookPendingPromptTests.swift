import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Hook pending prompt")
struct HookPendingPromptTests {
    func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    let questionInput: [String: Any] = [
        "questions": [[
            "question": "How should I build the 6h cool-off?", "header": "Alert design", "multiSelect": false,
            "options": [["label": "Windmill evaluator", "description": "d"], ["label": "OpenObserve only", "description": "d"]],
        ]],
    ]

    func payload(tool: String = "AskUserQuestion", input: [String: Any]? = nil, session: String = "sess-1") -> Data {
        Data(json([
            "session_id": session, "hook_event_name": "PermissionRequest", "permission_mode": "bypassPermissions",
            "tool_name": tool, "tool_input": input ?? questionInput,
        ]).utf8)
    }

    func askLine(timestamp: String, input: [String: Any]? = nil) -> String {
        json([
            "type": "assistant", "timestamp": timestamp,
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_x", "name": "AskUserQuestion", "input": input ?? questionInput,
            ]]],
        ])
    }

    let askedAt = ISO8601DateFormatter.withFractions.date(from: "2026-11-05T21:19:27.000Z")!

    @Test("a question payload becomes a pending question with its options")
    func parsesQuestion() throws {
        let prompt = try #require(HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt))
        #expect(prompt.sessionId == "sess-1")
        #expect(prompt.decision.kind == .question)
        #expect(prompt.decision.title == "Alert design")
        #expect(prompt.decision.options == ["Windmill evaluator", "OpenObserve only"])
        #expect(prompt.decision.requestId.hasPrefix("att_hook_"))
        guard case .question(let questions) = prompt.content else { Issue.record("not a question"); return }
        #expect(questions.first?.options.count == 2)
    }

    @Test("the request id is the same for the same question")
    func stableId() {
        let a = HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt)
        let b = HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt.addingTimeInterval(5))
        #expect(a?.decision.requestId == b?.decision.requestId)
    }

    @Test("a plan payload becomes a plan approval; other tools are ignored")
    func parsesPlanIgnoresOthers() {
        let plan = HookPendingPromptStore.prompt(fromPayload: payload(tool: "ExitPlanMode", input: ["plan": "1. Ship"]), askedAt: askedAt)
        #expect(plan?.decision.kind == .planApproval)
        #expect(HookPendingPromptStore.prompt(fromPayload: payload(tool: "Bash", input: ["command": "ls"]), askedAt: askedAt) == nil)
    }

    @Test("not settled while the transcript lacks the question")
    func pendingWhileUnflushed() throws {
        let prompt = try #require(HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt))
        let before = json(["type": "user", "timestamp": "2026-11-05T21:19:20.878Z",
                           "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "w", "content": "ok"]]]])
        #expect(!HookPendingPromptStore.isSettled(prompt, inLines: [before]))
    }

    @Test("settled once the transcript writes the same question, stamped a little before the hook")
    func settledWhenFlushed() throws {
        let prompt = try #require(HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt))
        #expect(HookPendingPromptStore.isSettled(prompt, inLines: [askLine(timestamp: "2026-11-05T21:19:26.485Z")]))
    }

    @Test("an older, different question does not settle it")
    func differentQuestionDoesNotSettle() throws {
        let prompt = try #require(HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt))
        let other: [String: Any] = ["questions": [["question": "Which DB?", "options": [["label": "A"]]]]]
        #expect(!HookPendingPromptStore.isSettled(prompt, inLines: [askLine(timestamp: "2026-11-05T21:18:00.000Z", input: other)]))
    }

    @Test("a typed prompt after the question settles it")
    func typedPromptSettles() throws {
        let prompt = try #require(HookPendingPromptStore.prompt(fromPayload: payload(), askedAt: askedAt))
        let typed = json(["type": "user", "timestamp": "2026-11-05T21:25:00.000Z", "message": ["role": "user", "content": "never mind"]])
        #expect(HookPendingPromptStore.isSettled(prompt, inLines: [typed]))
    }

    @Test("pending reads the file and removes it once the transcript caught up")
    func pendingReadsAndCleansUp() throws {
        let dir = NSTemporaryDirectory() + "pending-prompts-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = HookPendingPromptStore.path(sessionId: "sess-1", directory: dir)
        try payload().write(to: URL(fileURLWithPath: file))
        let transcript = dir + "/t.jsonl"
        try "".write(toFile: transcript, atomically: true, encoding: .utf8)

        #expect(HookPendingPromptStore.pending(sessionId: "sess-1", transcriptPath: transcript, directory: dir) != nil)
        #expect(HookPendingPromptStore.pending(sessionId: "other", transcriptPath: transcript, directory: dir) == nil)

        let iso = ISO8601DateFormatter.withFractions
        try (askLine(timestamp: iso.string(from: Date())) + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        #expect(HookPendingPromptStore.pending(sessionId: "sess-1", transcriptPath: transcript, directory: dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("remove drops only a file written before the event")
    func removeIfWrittenBefore() throws {
        let dir = NSTemporaryDirectory() + "pending-prompts-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = HookPendingPromptStore.path(sessionId: "sess-1", directory: dir)
        try payload().write(to: URL(fileURLWithPath: file))

        HookPendingPromptStore.remove(sessionId: "sess-1", ifWrittenBefore: Date().addingTimeInterval(-60), directory: dir)
        #expect(FileManager.default.fileExists(atPath: file))
        HookPendingPromptStore.remove(sessionId: "sess-1", ifWrittenBefore: Date().addingTimeInterval(60), directory: dir)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("StructuredQuestionAnswer formats single question with single-select into option number")
    func structuredAnswerSingleSelect() {
        let q = AskQuestion(header: "Header", question: "Which layout?", options: [
            AskQuestionOption(label: "Compact", description: "desc", preview: "box"),
            AskQuestionOption(label: "Detailed", description: "desc", preview: nil),
        ], multiSelect: false)
        let answer = StructuredQuestionAnswer.format(questions: [q], selections: [0: [1]])
        #expect(answer.keys == ["2"])
        #expect(answer.summary == "Detailed")
    }

    @Test("StructuredQuestionAnswer formats multiple questions and multi-select into Tab navigation and Submit")
    func structuredAnswerMultiQuestion() {
        let q1 = AskQuestion(header: "Multi", question: "Which UI elements?", options: [
            AskQuestionOption(label: "Status badge"),
            AskQuestionOption(label: "Assignee avatar"),
            AskQuestionOption(label: "Due date"),
            AskQuestionOption(label: "Comment count"),
        ], multiSelect: true)
        let q2 = AskQuestion(header: "Preview", question: "Which layout?", options: [
            AskQuestionOption(label: "Compact", preview: "mockup"),
            AskQuestionOption(label: "Detailed"),
        ], multiSelect: false)
        let q3 = AskQuestion(header: "Long text", question: "How to notify?", options: [
            AskQuestionOption(label: "Badge + notification"),
            AskQuestionOption(label: "Badge only"),
        ], multiSelect: false)

        let selections: [Int: Set<Int>] = [
            0: [0, 2], // Status badge (1), Due date (3)
            1: [1],    // Detailed (2)
            2: [0],    // Badge + notification (1)
        ]

        let answer = StructuredQuestionAnswer.format(questions: [q1, q2, q3], selections: selections)
        #expect(answer.keys == ["1", "3", "Right", "2", "Right", "1", "Right", "1"])
        #expect(answer.summary == "Multi: Status badge, Due date | Preview: Detailed | Long text: Badge + notification")

        // Test round-trip serialization
        let encoded = try! #require(answer.encode())
        let decoded = try! #require(StructuredQuestionAnswer.decode(from: encoded))
        #expect(decoded == answer)
    }

    @Test("formats single-select preview with notes and custom text")
    func structuredAnswerPreviewNotesAndCustom() {
        let qPreview = AskQuestion(header: "Preview", question: "Which layout?", options: [
            AskQuestionOption(label: "Compact", preview: "compact mockup"),
            AskQuestionOption(label: "Detailed", preview: "detailed mockup"),
        ], multiSelect: false)

        // Preview with notes: option 1 (Compact) + notes "Looks great"
        let answerWithNotes = StructuredQuestionAnswer.format(
            questions: [qPreview],
            selections: [0: [0]],
            customTexts: [0: "Looks great"]
        )
        #expect(answerWithNotes.keys == ["1", "n", "Looks great", "Enter"])
        #expect(answerWithNotes.summary == "Compact (Notes: Looks great)")

        // Single select without preview: option 3 is "Type something"
        let qPlain = AskQuestion(header: "DB", question: "Which database?", options: [
            AskQuestionOption(label: "SQLite"),
            AskQuestionOption(label: "PostgreSQL"),
        ], multiSelect: false)
        let answerCustom = StructuredQuestionAnswer.format(
            questions: [qPlain],
            selections: [0: []],
            customTexts: [0: "DuckDB"]
        )
        #expect(answerCustom.keys == ["3", "DuckDB", "Enter"])
        #expect(answerCustom.summary == "DuckDB")
    }

    @Test("parses option previews from tool input")
    func parsesOptionPreview() {
        let input: [String: Any] = [
            "questions": [[
                "question": "Which mockup?", "header": "Preview", "multiSelect": false,
                "options": [
                    ["label": "Compact", "description": "1 line", "preview": "box mockup"],
                    ["label": "Code", "description": "code", "preview": "```ts\nlet x = 1\n```"],
                ],
            ]],
        ]
        let questions = TranscriptReader.parseAskQuestions(input)
        #expect(questions.count == 1)
        #expect(questions[0].options[0].preview == "box mockup")
        #expect(questions[0].options[1].preview == "```ts\nlet x = 1\n```")
    }
}
