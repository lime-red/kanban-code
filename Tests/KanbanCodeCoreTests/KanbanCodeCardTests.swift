import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("KanbanCodeCard")
struct KanbanCodeCardTests {

    @Test("Display title uses link name first")
    func displayTitleLinkName() {
        let link = Link(name: "Fix login bug", sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCodeCard(link: link)
        #expect(card.displayTitle == "Fix login bug")
    }

    @Test("Display title falls back to session")
    func displayTitleSession() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let session = Session(id: "s1", firstPrompt: "Help me debug the auth flow")
        let card = KanbanCodeCard(link: link, session: session)
        #expect(card.displayTitle == "Help me debug the auth flow")
    }

    @Test("Display title falls back to full session ID")
    func displayTitleFallback() {
        let link = Link(sessionLink: SessionLink(sessionId: "abcdef01-2345-6789-abcd-ef0123456789"))
        let card = KanbanCodeCard(link: link)
        #expect(card.displayTitle == "abcdef01-2345-6789-abcd-ef0123456789")
    }

    @Test("Project name extracted from path")
    func projectName() {
        let link = Link(projectPath: "/Users/test/Projects/my-cool-app", sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCodeCard(link: link)
        #expect(card.projectName == "my-cool-app")
    }

    @Test("Project name from session when link has none")
    func projectNameFromSession() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let session = Session(id: "s1", projectPath: "/Users/test/Projects/langwatch")
        let card = KanbanCodeCard(link: link, session: session)
        #expect(card.projectName == "langwatch")
    }

    @Test("Relative time formats correctly")
    func relativeTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Construct 2026-11-11 12:00:00 UTC
        var comps = DateComponents(year: 2026, month: 11, day: 11, hour: 12, minute: 0, second: 0)
        let now = cal.date(from: comps)!

        #expect(KanbanCodeCard.formatRelativeTime(now, relativeTo: now, calendar: cal) == "just now")
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-30), relativeTo: now, calendar: cal) == "just now")
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-120), relativeTo: now, calendar: cal) == "2m ago")
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-7200), relativeTo: now, calendar: cal) == "2h ago")
        // Same day earlier (e.g. 10 hours ago at 02:00 AM on the same day) -> shows "10h ago"
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-36000), relativeTo: now, calendar: cal) == "10h ago")
        // Yesterday (e.g. 18 hours ago at 18:00 on the previous calendar day) -> shows "yesterday"
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-64800), relativeTo: now, calendar: cal) == "yesterday")
        // Exactly 24 hours ago (yesterday at 12:00) -> shows "yesterday"
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-86400), relativeTo: now, calendar: cal) == "yesterday")
        // 2 days ago (2026-11-09) -> shows "2d ago"
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-172800), relativeTo: now, calendar: cal) == "2d ago")
        // 3 days ago -> shows "3d ago"
        #expect(KanbanCodeCard.formatRelativeTime(now.addingTimeInterval(-259200), relativeTo: now, calendar: cal) == "3d ago")
    }

    @Test("Column comes from link")
    func column() {
        let link = Link(column: .inReview, sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCodeCard(link: link)
        #expect(card.column == .inReview)
    }
}
