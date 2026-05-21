import AgentCLIKit
import Foundation

struct DemoPrompt: Equatable, Identifiable {
    let id: AgentInteractionID
    let conversationID: AgentConversationID
    let questions: [DemoPromptQuestion]
    let rawInput: JSONValue
    var submittedAnswers: [DemoPromptAnswer]?

    init(
        id: AgentInteractionID,
        conversationID: AgentConversationID,
        questions: [DemoPromptQuestion],
        rawInput: JSONValue,
        submittedAnswers: [DemoPromptAnswer]? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.questions = questions
        self.rawInput = rawInput
        self.submittedAnswers = submittedAnswers
    }

    init?(id: AgentInteractionID, conversationID: AgentConversationID, rawInput: JSONValue) {
        guard case let .object(inputObject) = rawInput,
              case let .array(rawQuestions)? = inputObject["questions"] else {
            return nil
        }
        let questions = rawQuestions.enumerated().compactMap { index, value in
            DemoPromptQuestion(index: index, json: value)
        }
        guard !questions.isEmpty else {
            return nil
        }
        self.id = id
        self.conversationID = conversationID
        self.questions = questions
        self.rawInput = rawInput
        self.submittedAnswers = nil
    }

    func updatedInput(answers: [DemoPromptAnswer]) -> JSONValue {
        guard case var .object(object) = rawInput else {
            return rawInput
        }
        var answerObject: [String: JSONValue] = [:]
        for answer in answers {
            answerObject[answer.question] = .string(answer.answer)
        }
        object["answers"] = .object(answerObject)
        return .object(object)
    }
}

struct DemoPromptQuestion: Equatable, Identifiable {
    let id: String
    let question: String
    let header: String?
    let options: [DemoPromptOption]
    let multiSelect: Bool
    let allowsCustomResponse: Bool

    init?(index: Int, json: JSONValue) {
        guard case let .object(object) = json,
              let question = object["question"]?.stringValue else {
            return nil
        }
        self.id = "\(index)"
        self.question = question
        self.header = object["header"]?.stringValue
        self.options = object["options"]?.arrayValue?.compactMap(DemoPromptOption.init(json:)) ?? []
        self.multiSelect = object["multiSelect"]?.boolValue ?? false
        self.allowsCustomResponse = object["allowCustomResponse"]?.boolValue ?? true
    }

    var renderedOptions: [DemoPromptOption] {
        guard allowsCustomResponse,
              !options.contains(where: \.isCustomResponse) else {
            return options
        }
        return options + [.customResponse]
    }
}

struct DemoPromptOption: Equatable, Identifiable {
    static let customResponseID = "__other__"

    let id: String
    let label: String
    let description: String
    let isCustomResponse: Bool

    init?(json: JSONValue) {
        guard case let .object(object) = json,
              let label = object["label"]?.stringValue else {
            return nil
        }
        self.id = label
        self.label = label
        self.description = object["description"]?.stringValue ?? ""
        self.isCustomResponse = (object["allowCustomResponse"]?.boolValue ?? false)
            || label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Other") == .orderedSame
    }

    private init(id: String, label: String, description: String, isCustomResponse: Bool) {
        self.id = id
        self.label = label
        self.description = description
        self.isCustomResponse = isCustomResponse
    }

    static let customResponse = DemoPromptOption(
        id: customResponseID,
        label: "Other",
        description: "Write a custom response.",
        isCustomResponse: true
    )
}

struct DemoPromptAnswer: Equatable, Identifiable {
    let id: String
    let question: String
    let answer: String
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }
}
