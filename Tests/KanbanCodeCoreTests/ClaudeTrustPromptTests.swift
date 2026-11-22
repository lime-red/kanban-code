import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Claude folder trust")
struct ClaudeTrustPromptTests {

    // Claude Code 2.1.330 in a folder it had not seen.
    static let trustScreen = """
    ────────────────────────────────────────────────────────────────
     Accessing workspace:

     /private/tmp/trust-probe

     Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
     project, or work from your team). If not, take a moment to review what's in this folder first.

     Claude Code'll be able to read, edit, and execute files here.

     Security guide

     ❯ No, exit
       Yes, I trust this folder

     Enter to confirm · Esc to cancel
    """

    static let yesSelected = trustScreen
        .replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
        .replacingOccurrences(of: "  Yes, I trust this folder", with: "❯ Yes, I trust this folder")

    // Earlier versions.
    static let olderTrustScreen = """
     Do you trust the files in this folder?

     /Users/me/project

     ❯ 1. Yes, proceed
       2. No, exit

     Enter to confirm · Esc to exit
    """

    static let readyPrompt = """
    ╭───────────────────────────────────────────╮
    │ ✻ Welcome to Claude Code!                 │
    ╰───────────────────────────────────────────╯
    ────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────
      ? for shortcuts
    """

    final class MockTmux: TmuxManagerPort, @unchecked Sendable {
        var screens: [String] = []
        /// Moves to the next screen after each key press, as the pane would.
        var screenIndex = 0
        var keys: [String] = []

        func createSession(name: String, path: String, command: String?) async throws {}
        func killSession(name: String) async throws {}
        func listSessions() async throws -> [TmuxSession] { [] }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func pasteText(to sessionName: String, text: String) async throws {}
        func submitPrompt(to sessionName: String) async throws {}
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
        func sendKey(to sessionName: String, key: String) async throws {
            keys.append(key)
            screenIndex = min(screenIndex + 1, screens.count - 1)
        }
        func capturePane(sessionName: String) async throws -> String { screens[screenIndex] }
    }

    final class Events: @unchecked Sendable {
        var shown: [Bool] = []
    }

    static let olderNoSelected = olderTrustScreen
        .replacingOccurrences(of: "❯ 1. Yes, proceed", with: "  1. Yes, proceed")
        .replacingOccurrences(of: "  2. No, exit", with: "❯ 2. No, exit")

    @Test("The trust screen is recognised, with which answer is highlighted")
    func parsesTrustScreen() {
        #expect(PaneOutputParser.claudeTrustPrompt(Self.trustScreen) == .init(yesIsSelected: false))
        #expect(PaneOutputParser.claudeTrustPrompt(Self.yesSelected) == .init(yesIsSelected: true))
        #expect(PaneOutputParser.claudeTrustPrompt(Self.olderTrustScreen) == .init(yesIsSelected: true))
        #expect(PaneOutputParser.claudeTrustPrompt(Self.readyPrompt) == nil)
    }

    @Test("Another menu with Yes and No answers is not the trust screen")
    func otherMenusAreNotTrust() {
        let bypass = """
         WARNING: Claude Code running in Bypass Permissions mode

         ❯ 1. No, exit
           2. Yes, I accept
        """
        #expect(PaneOutputParser.claudeTrustPrompt(bypass) == nil)
        let proceedWithoutTrustQuestion = """
         ❯ 1. Yes, proceed
           2. No, exit
        """
        #expect(PaneOutputParser.claudeTrustPrompt(proceedWithoutTrustQuestion) == nil)
    }

    @Test("The trust screen's ❯ does not count as Claude's input prompt")
    func trustScreenIsNotReady() {
        #expect(!PaneOutputParser.isReady(Self.trustScreen, assistant: .claude))
        #expect(!PaneOutputParser.isReady(Self.olderTrustScreen, assistant: .claude))
        #expect(PaneOutputParser.isReady(Self.readyPrompt, assistant: .claude))
    }

    @Test("Trusting moves to Yes and presses Enter only once Yes is highlighted")
    func trustFolderAnswersYes() async throws {
        let mock = MockTmux()
        mock.screens = [Self.trustScreen, Self.yesSelected, Self.readyPrompt]
        let events = Events()
        try await ImageSender(tmux: mock).waitForReady(
            sessionName: "s", assistant: .claude, trustFolder: true,
            onTrustPrompt: { events.shown.append($0) },
            pollInterval: .milliseconds(5), timeout: .seconds(5))
        #expect(mock.keys == ["Down", "Enter"])
        #expect(events.shown.isEmpty)
    }

    @Test("Without trusting, nothing is pressed, the card is told when the screen comes and goes, and the wait outlasts the start-up timeout")
    func waitsForThePerson() async throws {
        let mock = MockTmux()
        mock.screens = [Self.trustScreen]
        let events = Events()
        let sender = ImageSender(tmux: mock)
        let wait = Task {
            try await sender.waitForReady(
                sessionName: "s", assistant: .claude,
                onTrustPrompt: { events.shown.append($0) },
                pollInterval: .milliseconds(5), timeout: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200))
        // The person answers.
        mock.screens = [Self.readyPrompt]
        try await wait.value
        #expect(mock.keys.isEmpty)
        #expect(events.shown == [true, false])
    }

    @Test("Answering from the card selects the answer before pressing Enter")
    func answersFromTheCard() async throws {
        let yes = MockTmux()
        yes.screens = [Self.trustScreen, Self.yesSelected]
        try await ImageSender(tmux: yes).answerTrustPrompt(sessionName: "s", trust: true, pollInterval: .milliseconds(1))
        #expect(yes.keys == ["Down", "Enter"])

        let no = MockTmux()
        no.screens = [Self.trustScreen]
        try await ImageSender(tmux: no).answerTrustPrompt(sessionName: "s", trust: false, pollInterval: .milliseconds(1))
        #expect(no.keys == ["Enter"])

        // Yes first and highlighted: Down reaches No.
        let older = MockTmux()
        older.screens = [Self.olderTrustScreen, Self.olderNoSelected]
        try await ImageSender(tmux: older).answerTrustPrompt(sessionName: "s", trust: false, pollInterval: .milliseconds(1))
        #expect(older.keys == ["Down", "Enter"])
    }

    @Test("An arrow that does not move the highlight is swapped for the other one")
    func swapsTheArrow() async throws {
        let mock = MockTmux()
        mock.screens = [Self.trustScreen, Self.trustScreen, Self.yesSelected]
        try await ImageSender(tmux: mock).answerTrustPrompt(sessionName: "s", trust: true, pollInterval: .milliseconds(1))
        #expect(mock.keys == ["Down", "Up", "Enter"])
    }

    @Test("Answering when the screen has gone presses nothing")
    func answerWithoutScreen() async throws {
        let mock = MockTmux()
        mock.screens = [Self.readyPrompt]
        try await ImageSender(tmux: mock).answerTrustPrompt(sessionName: "s", trust: true)
        #expect(mock.keys.isEmpty)
    }

    @Test("The card keeps the question until it is answered or goes")
    func reducerKeepsTheQuestion() {
        var state = AppState()
        state.links["card_a"] = Link(id: "card_a", name: "a", column: .inProgress, tmuxLink: TmuxLink(sessionName: "claude-a"))
        _ = Reducer.reduce(state: &state, action: .claudeTrustPrompt(cardId: "card_a", showing: true))
        #expect(state.claudeTrustPrompts == ["card_a"])

        let effects = Reducer.reduce(state: &state, action: .answerClaudeTrustPrompt(cardId: "card_a", trust: true))
        #expect(state.claudeTrustPrompts.isEmpty)
        guard case .answerClaudeTrustPrompt(let cardId, let session, let trust)? = effects.first else {
            Issue.record("no answer effect: \(effects)")
            return
        }
        #expect(cardId == "card_a" && session == "claude-a" && trust)

        // A second click after the question went does nothing.
        #expect(Reducer.reduce(state: &state, action: .answerClaudeTrustPrompt(cardId: "card_a", trust: true)).isEmpty)

        _ = Reducer.reduce(state: &state, action: .claudeTrustPrompt(cardId: "card_a", showing: true))
        _ = Reducer.reduce(state: &state, action: .claudeTrustPrompt(cardId: "card_a", showing: false))
        #expect(state.claudeTrustPrompts.isEmpty)
    }

    @Test("An unanswered trust screen ends the wait after its own limit")
    func trustWaitHasALimit() async {
        let mock = MockTmux()
        mock.screens = [Self.trustScreen]
        await #expect(throws: (any Error).self) {
            try await ImageSender(tmux: mock).waitForReady(
                sessionName: "s", assistant: .claude,
                pollInterval: .milliseconds(5), timeout: .milliseconds(20),
                trustAnswerTimeout: .milliseconds(60))
        }
    }

    @Test("Trust is read from the config, and a trusted folder trusts the folders inside it")
    func readsTrustFromConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent(".claude.json").path
        let json = """
        {"projects": {
          "/Users/me/code/app": {"hasTrustDialogAccepted": true},
          "/Users/me/code/other": {"hasTrustDialogAccepted": false},
          "/Users/me/code/seen": {}
        }}
        """
        try json.write(toFile: config, atomically: true, encoding: .utf8)
        #expect(ClaudeFolderTrust.isTrusted("/Users/me/code/app", configPath: config) == true)
        #expect(ClaudeFolderTrust.isTrusted("/Users/me/code/app/.claude/worktrees/x", configPath: config) == true)
        #expect(ClaudeFolderTrust.isTrusted("/Users/me/code/app/", configPath: config) == true)
        #expect(ClaudeFolderTrust.isTrusted("/Users/me/code/other", configPath: config) == false)
        #expect(ClaudeFolderTrust.isTrusted("/Users/me/code/seen", configPath: config) == false)
        #expect(ClaudeFolderTrust.isTrusted("/Users/me/code/application", configPath: config) == false)
        #expect(ClaudeFolderTrust.isTrusted("/x", configPath: dir.appendingPathComponent("missing.json").path) == nil)
    }

    @Test("CLAUDE_CONFIG_DIR moves the config")
    func configPathFollowsClaudeConfigDir() {
        #expect(ClaudeFolderTrust.configPath(environment: [:], home: "/Users/me") == "/Users/me/.claude.json")
        #expect(ClaudeFolderTrust.configPath(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: "/Users/me") == "/cfg/.claude.json")
    }
}
