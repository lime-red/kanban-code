import Foundation

/// Retains draft selections and inputs for pending question cards across
/// tab switches (e.g. Chat -> Terminal -> Chat) or view recreations.
@MainActor
final class PendingQuestionDraftStore {
    static let shared = PendingQuestionDraftStore()

    struct DraftState: Equatable {
        var questionIndex: Int = 0
        var selections: [Int: Set<Int>] = [:]
        var customTexts: [Int: String] = [:]
        var isCustomTextActive: [Int: Bool] = [:]
        var fingerprint: String = ""
    }

    private var drafts: [String: DraftState] = [:]

    private init() {}

    func draft(for cardId: String, fingerprint: String) -> DraftState {
        if let existing = drafts[cardId], existing.fingerprint == fingerprint {
            return existing
        }
        var newDraft = DraftState()
        newDraft.fingerprint = fingerprint
        drafts[cardId] = newDraft
        return newDraft
    }

    func updateDraft(for cardId: String, _ update: (inout DraftState) -> Void) {
        var d = drafts[cardId] ?? DraftState()
        update(&d)
        drafts[cardId] = d
    }

    func clear(for cardId: String) {
        drafts.removeValue(forKey: cardId)
    }
}
