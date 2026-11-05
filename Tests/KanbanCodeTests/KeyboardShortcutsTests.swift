import Testing
import SwiftUI
@testable import KanbanCode

@Suite("Keyboard Shortcuts")
struct KeyboardShortcutsTests {
    @Test("resume uses command-return and view toggle uses command-shift-return")
    func resumeAndToggleShortcutsDoNotConflict() {
        #expect(AppShortcut.resumeAssistant.key == .return)
        #expect(AppShortcut.resumeAssistant.modifiers == .command)
        #expect(AppShortcut.resumeAssistant.displayString == "⌘↩")

        #expect(AppShortcut.toggleExpanded.key == .return)
        #expect(AppShortcut.toggleExpanded.modifiers == [.command, .shift])
        #expect(AppShortcut.toggleExpanded.displayString == "⇧⌘↩")
    }

    @Test("resume is active only for selected ended assistant session")
    func resumeActiveOnlyForEndedAssistantSession() {
        #expect(AppShortcut.resumeAssistant.isActive(in: AppShortcutContext(
            paletteOpen: false,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: false,
            canResumeAssistant: true
        )))

        #expect(!AppShortcut.resumeAssistant.isActive(in: AppShortcutContext(
            paletteOpen: false,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: false,
            canResumeAssistant: false
        )))
    }

    @Test("delete card shortcuts are inactive when prompt editor is focused, palette is open, or no card is selected")
    func deleteCardShortcutsRespectFocusAndSelection() {
        let activeBoardContext = AppShortcutContext(
            paletteOpen: false,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: false,
            hasSelectedCard: true
        )
        #expect(AppShortcut.deleteCard.isActive(in: activeBoardContext))
        #expect(AppShortcut.deleteCardForward.isActive(in: activeBoardContext))

        let promptFocusedContext = AppShortcutContext(
            paletteOpen: false,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: true,
            hasSelectedCard: true
        )
        #expect(!AppShortcut.deleteCard.isActive(in: promptFocusedContext))
        #expect(!AppShortcut.deleteCardForward.isActive(in: promptFocusedContext))

        let paletteOpenContext = AppShortcutContext(
            paletteOpen: true,
            detailOpen: true,
            expandedDetail: false,
            promptEditorFocused: false,
            hasSelectedCard: true
        )
        #expect(!AppShortcut.deleteCard.isActive(in: paletteOpenContext))
        #expect(!AppShortcut.deleteCardForward.isActive(in: paletteOpenContext))

        let noSelectionContext = AppShortcutContext(
            paletteOpen: false,
            detailOpen: false,
            expandedDetail: false,
            promptEditorFocused: false,
            hasSelectedCard: false
        )
        #expect(!AppShortcut.deleteCard.isActive(in: noSelectionContext))
        #expect(!AppShortcut.deleteCardForward.isActive(in: noSelectionContext))
    }
}
