import Foundation

extension ClaudeStreamDecoder {
    func systemMetadata(from envelope: ClaudeStreamEnvelope) -> [String: JSONValue] {
        let stringFields: [(String, String?)] = [
            ("session_id", envelope.sessionId),
            ("model", envelope.model),
            ("tool_use_id", envelope.toolUseId),
            ("description", envelope.description),
            ("summary", envelope.summary),
            ("task_type", envelope.taskType),
            ("last_tool_name", envelope.lastToolName),
            ("status", envelope.status),
            ("compact_result", envelope.compactResult),
            ("compact_error", envelope.compactError),
            ("output_file", envelope.outputFile)
        ]
        var metadata = Dictionary(uniqueKeysWithValues: stringFields.compactMap { key, value -> (String, JSONValue)? in
            guard let value else {
                return nil
            }
            return (key, .string(value))
        })
        if let uuid = envelope.uuid {
            metadata["uuid"] = .string(uuid)
        }
        metadata.merge(envelope.compactMetadata?.metadata ?? [:]) { _, new in new }
        metadata.merge(envelope.usage?.taskMetadata ?? [:]) { _, new in new }
        return metadata
    }

    func contextCompactionEvent(from envelope: ClaudeStreamEnvelope, metadata: [String: JSONValue]) -> AgentEvent? {
        let phase: AgentContextCompactionPhase?
        if envelope.status == "compacting" {
            phase = .started
        } else if envelope.compactResult == "success" || envelope.subtype == "compact_boundary" {
            phase = .completed
        } else if envelope.compactResult == "failed" {
            phase = .failed
        } else {
            phase = nil
        }
        guard let phase else {
            return nil
        }
        var metadata = metadata
        if let subtype = envelope.subtype {
            metadata["subtype"] = .string(subtype)
        }
        let idParts = [
            "claude-context-compaction",
            envelope.sessionId,
            envelope.uuid,
            envelope.subtype ?? envelope.status ?? envelope.compactResult
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return .contextCompaction(AgentContextCompactionEvent(
            id: idParts.joined(separator: "-"),
            phase: phase,
            trigger: envelope.compactMetadata?.trigger,
            errorMessage: envelope.compactError,
            preTokens: envelope.compactMetadata?.preTokens,
            postTokens: envelope.compactMetadata?.postTokens,
            durationMs: envelope.compactMetadata?.durationMs,
            metadata: metadata
        ))
    }
}
