import Foundation

struct CodexStderrRedactingBuffer {
    private let maxBufferedBytes: Int
    private var buffer = Data()
    private var truncatedPrefixBytesToDiscard = 0

    init(maxBufferedBytes: Int = 64 * 1_024) {
        self.maxBufferedBytes = max(1, maxBufferedBytes)
    }

    var bufferedByteCount: Int {
        buffer.count
    }

    mutating func append(_ data: Data, sensitiveValues: Set<String>) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            let safeLineData = boundedLineData(lineData, sensitiveValues: sensitiveValues)
            if let line = redactedLine(safeLineData, sensitiveValues: sensitiveValues) {
                lines.append(line)
            }
            truncatedPrefixBytesToDiscard = 0
        }
        trimBufferedFragment(sensitiveValues: sensitiveValues)
        return lines
    }

    mutating func flush(sensitiveValues: Set<String>) -> String? {
        guard !buffer.isEmpty else {
            return nil
        }
        let remaining = boundedLineData(buffer, sensitiveValues: sensitiveValues)
        buffer.removeAll()
        truncatedPrefixBytesToDiscard = 0
        return redactedLine(remaining, sensitiveValues: sensitiveValues)
    }

    private mutating func trimBufferedFragment(sensitiveValues: Set<String>) {
        guard buffer.count > maxBufferedBytes else {
            return
        }
        buffer = Data(buffer.suffix(maxBufferedBytes))
        truncatedPrefixBytesToDiscard = boundaryDiscardCount(
            availableBytes: buffer.count,
            sensitiveValues: sensitiveValues
        )
    }

    private func boundedLineData(_ data: Data, sensitiveValues: Set<String>) -> Data {
        var bounded = data
        var prefixBytesToDiscard = truncatedPrefixBytesToDiscard
        if bounded.count > maxBufferedBytes {
            bounded = Data(bounded.suffix(maxBufferedBytes))
            prefixBytesToDiscard = boundaryDiscardCount(
                availableBytes: bounded.count,
                sensitiveValues: sensitiveValues
            )
        }
        guard prefixBytesToDiscard > 0 else {
            return bounded
        }
        return Data(bounded.dropFirst(min(prefixBytesToDiscard, bounded.count)))
    }

    private func boundaryDiscardCount(availableBytes: Int, sensitiveValues: Set<String>) -> Int {
        let longestSensitiveValue = sensitiveValues.lazy.map { $0.utf8.count }.max() ?? 0
        return min(availableBytes, max(0, longestSensitiveValue - 1))
    }

    private func redactedLine(_ data: Data, sensitiveValues: Set<String>) -> String? {
        guard let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return AgentSensitiveValueRedactor.redact(line, sensitiveValues: sensitiveValues)
    }
}
