import Foundation

public struct ClaudeCodePromptDriver: AssistantPromptDriver {
    public let assistant: CodingAssistant = .claude

    public init() {}

    public func supportsNativeInteraction(for questions: [AskQuestion]) -> Bool {
        !questions.isEmpty
    }

    public func formatAnswer(
        questions: [AskQuestion],
        selections: [Int: Set<Int>],
        customTexts: [Int: String] = [:]
    ) -> StructuredQuestionAnswer? {
        guard !questions.isEmpty else { return nil }

        if questions.count == 1 && !questions[0].multiSelect {
            let q = questions[0]
            let hasPreview = q.options.contains { $0.preview != nil }
            let selectedIdx = selections[0]?.first ?? 0
            let label = (selectedIdx < q.options.count) ? q.options[selectedIdx].label : "Option \(selectedIdx + 1)"
            let custom = customTexts[0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if hasPreview {
                if !custom.isEmpty {
                    return StructuredQuestionAnswer(
                        keys: [String(selectedIdx + 1), "n", custom, "Enter"],
                        summary: "\(label) (Notes: \(custom))"
                    )
                } else {
                    return StructuredQuestionAnswer(keys: [String(selectedIdx + 1)], summary: label)
                }
            } else {
                if !custom.isEmpty && (selections[0]?.isEmpty ?? true) {
                    return StructuredQuestionAnswer(
                        keys: [String(q.options.count + 1), custom, "Enter"],
                        summary: custom
                    )
                } else {
                    return StructuredQuestionAnswer(keys: [String(selectedIdx + 1)], summary: label)
                }
            }
        }

        if questions.count == 1 && questions[0].multiSelect {
            let q = questions[0]
            var keys: [String] = []
            var chosenLabels: [String] = []
            let chosen = (selections[0] ?? []).sorted()
            for idx in chosen {
                guard idx < q.options.count else { continue }
                keys.append(String(idx + 1))
                chosenLabels.append(q.options[idx].label)
            }
            let custom = customTexts[0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !custom.isEmpty {
                keys.append(String(q.options.count + 1))
                keys.append(custom)
                keys.append("Enter")
                chosenLabels.append("Other: \(custom)")
            }
            keys.append("Enter")
            let summary = chosenLabels.joined(separator: ", ")
            return StructuredQuestionAnswer(keys: keys, summary: summary.isEmpty ? "Submitted" : summary)
        }

        var keys: [String] = []
        var summaryParts: [String] = []

        for (qIndex, q) in questions.enumerated() {
            let hasPreview = q.options.contains { $0.preview != nil }
            let chosen = (selections[qIndex] ?? []).sorted()
            var chosenLabels = chosen.compactMap { idx -> String? in
                guard idx < q.options.count else { return nil }
                return q.options[idx].label
            }
            let custom = customTexts[qIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            for idx in chosen {
                keys.append(String(idx + 1))
            }

            if hasPreview {
                if !custom.isEmpty {
                    keys.append("n")
                    keys.append(custom)
                    keys.append("Enter")
                    if let first = chosenLabels.first {
                        chosenLabels[0] = "\(first) (Notes: \(custom))"
                    } else {
                        chosenLabels.append("Notes: \(custom)")
                    }
                }
            } else if !custom.isEmpty {
                keys.append(String(q.options.count + 1))
                keys.append(custom)
                keys.append("Enter")
                chosenLabels.append("Other: \(custom)")
            }

            if !chosenLabels.isEmpty {
                let header = q.header.flatMap { $0.isEmpty ? nil : $0 } ?? "Q\(qIndex + 1)"
                summaryParts.append("\(header): \(chosenLabels.joined(separator: ", "))")
            }

            // In Claude Code's multi-question wizard, Right arrow switches tabs
            keys.append("Right")
        }
        // On the final Submit screen, "1" selects "1. Submit answers"
        keys.append("1")

        let summary = summaryParts.isEmpty ? "Submitted" : summaryParts.joined(separator: " | ")
        return StructuredQuestionAnswer(keys: keys, summary: summary)
    }

    public func chatAboutThisKeys(questions: [AskQuestion]) -> [String]? {
        guard let first = questions.first else { return nil }
        // In Claude Code's TUI, "Chat about this" is the option following options + "Type something."
        let optionNumber = first.options.count + 2
        return [String(optionNumber)]
    }
}
