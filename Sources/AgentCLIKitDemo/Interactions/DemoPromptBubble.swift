import AgentCLIKit
import SwiftUI

struct PromptBubble: View {
    let prompt: DemoPrompt
    var onSubmit: ([DemoPromptAnswer]) -> Void

    @State private var singleSelections: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    @State private var customResponses: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.submittedAnswers == nil ? "Questions" : "Submitted responses")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let submittedAnswers = prompt.submittedAnswers {
                submittedAnswersView(submittedAnswers)
            } else {
                ForEach(prompt.questions) { question in
                    questionView(question)
                }
                Button {
                    guard let answers else {
                        return
                    }
                    onSubmit(answers)
                } label: {
                    Label("Submit", systemImage: "paperplane.fill")
                }
                .disabled(answers == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func submittedAnswersView(_ submittedAnswers: [DemoPromptAnswer]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(submittedAnswers) { answer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(answer.question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(answer.answer)
                        .font(.body)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func questionView(_ question: DemoPromptQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let header = question.header {
                    Text(header)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(question.question)
                    .font(.body.weight(.semibold))
            }

            ForEach(question.renderedOptions) { option in
                optionButton(option, question: question)
            }
        }
    }

    private func optionButton(_ option: DemoPromptOption, question: DemoPromptQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle(option, question: question)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selectionImageName(option, question: question))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.caption.weight(.semibold))
                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if option.isCustomResponse && isSelected(option, question: question) {
                TextField("", text: customResponseBinding(for: question))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var answers: [DemoPromptAnswer]? {
        var resolved: [DemoPromptAnswer] = []
        for question in prompt.questions {
            guard let answer = answer(for: question) else {
                return nil
            }
            resolved.append(DemoPromptAnswer(id: question.id, question: question.question, answer: answer))
        }
        return resolved
    }

    private func answer(for question: DemoPromptQuestion) -> String? {
        if question.multiSelect {
            let selected = multiSelections[question.id] ?? []
            guard !selected.isEmpty else {
                return nil
            }
            var labels: [String] = []
            for option in question.renderedOptions where selected.contains(option.id) {
                if option.isCustomResponse {
                    guard let customResponse = trimmedCustomResponse(for: question) else {
                        return nil
                    }
                    labels.append(customResponse)
                } else {
                    labels.append(option.label)
                }
            }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        }

        guard let selected = singleSelections[question.id],
              let option = question.renderedOptions.first(where: { $0.id == selected }) else {
            return nil
        }
        return option.isCustomResponse ? trimmedCustomResponse(for: question) : option.label
    }

    private func toggle(_ option: DemoPromptOption, question: DemoPromptQuestion) {
        if question.multiSelect {
            var selected = multiSelections[question.id] ?? []
            if selected.contains(option.id) {
                selected.remove(option.id)
            } else {
                selected.insert(option.id)
            }
            multiSelections[question.id] = selected
        } else {
            singleSelections[question.id] = option.id
        }
    }

    private func isSelected(_ option: DemoPromptOption, question: DemoPromptQuestion) -> Bool {
        if question.multiSelect {
            return multiSelections[question.id]?.contains(option.id) == true
        }
        return singleSelections[question.id] == option.id
    }

    private func selectionImageName(_ option: DemoPromptOption, question: DemoPromptQuestion) -> String {
        if question.multiSelect {
            return isSelected(option, question: question) ? "checkmark.square.fill" : "square"
        }
        return isSelected(option, question: question) ? "largecircle.fill.circle" : "circle"
    }

    private func customResponseBinding(for question: DemoPromptQuestion) -> Binding<String> {
        Binding(
            get: { customResponses[question.id] ?? "" },
            set: { customResponses[question.id] = $0 }
        )
    }

    private func trimmedCustomResponse(for question: DemoPromptQuestion) -> String? {
        let trimmed = (customResponses[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
