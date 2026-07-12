import Foundation

enum AgentSensitiveValueRedactor {
    static func redact(_ value: String, sensitiveValues: some Sequence<String>) -> String {
        sensitiveValues
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(value) { redacted, sensitiveValue in
                redacted.replacingOccurrences(of: sensitiveValue, with: "<redacted>")
            }
    }
}
