import Foundation

enum SSEMessageDecoder {
    static func messages(from data: Data) -> [Data] {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return self.expandBatch(data, json: json)
        }
        // HTTP responses may contain buffered SSE frames or already-decoded JSON.
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var messages: [Data] = []
        var lines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            if line.isEmpty {
                if !lines.isEmpty {
                    messages.append(contentsOf: self.jsonMessages(from: Data(lines.joined(separator: "\n").utf8)))
                    lines.removeAll()
                }
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " {
                    value = value.dropFirst()
                }
                lines.append(String(value))
            }
        }
        return messages
    }

    static func jsonMessages(from data: Data) -> [Data] {
        self.expandBatch(data, json: try? JSONSerialization.jsonObject(with: data))
    }

    private static func expandBatch(_ data: Data, json: Any?) -> [Data] {
        guard let batch = json as? [Any] else { return [data] }
        guard !batch.isEmpty else { return [] }
        let bytes = Array(data)
        guard let opening = bytes.firstIndex(of: 91), let closing = bytes.lastIndex(of: 93) else { return [data] }
        var messages: [Data] = []
        var start = opening + 1
        var depth = 0
        var quoted = false
        var escaped = false
        // Slice the validated JSON instead of re-encoding numbers through NSNumber.
        for index in start..<closing {
            let byte = bytes[index]
            if quoted {
                if !escaped, byte == 34 {
                    quoted = false
                }
                escaped = !escaped && byte == 92
                continue
            }
            switch byte {
            case 34:
                quoted = true
            case 91, 123:
                depth += 1
            case 93, 125:
                depth -= 1
            case 44 where depth == 0:
                messages.append(Data(bytes[start..<index]))
                start = index + 1
            default:
                break
            }
        }
        messages.append(Data(bytes[start..<closing]))
        return messages
    }
}
