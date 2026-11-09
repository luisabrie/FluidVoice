import Foundation

/// Decodes AWS event stream frames (`application/vnd.amazon.eventstream`), the framing ConverseStream uses.
/// Each frame: total length, headers length, prelude CRC, headers, payload, message CRC. TLS already
/// protects the bytes, so the CRCs are not checked.
nonisolated struct AWSEventStreamDecoder {
    struct Message {
        let headers: [String: String]
        let payload: Data
    }

    private static let preludeLength = 12
    private static let maxMessageLength = 16 * 1024 * 1024

    private var buffer: [UInt8] = []

    /// Returns a message when `byte` completes one.
    mutating func append(_ byte: UInt8) throws -> Message? {
        self.buffer.append(byte)
        guard self.buffer.count >= Self.preludeLength else { return nil }
        let total = Int(self.uint32(at: 0))
        let headersLength = Int(self.uint32(at: 4))
        guard total >= Self.preludeLength + 4, total <= Self.maxMessageLength, headersLength <= total - Self.preludeLength - 4 else {
            throw LLMError.invalidResponse
        }
        guard self.buffer.count >= total else { return nil }

        let headersEnd = Self.preludeLength + headersLength
        let message = try Message(
            headers: Self.headers(self.buffer[Self.preludeLength..<headersEnd]),
            payload: Data(self.buffer[headersEnd..<(total - 4)])
        )
        self.buffer.removeFirst(total)
        return message
    }

    private func uint32(at offset: Int) -> UInt32 {
        self.buffer[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Keeps string headers (`:event-type`, `:message-type`, ...) and skips the other value types.
    private static func headers(_ bytes: ArraySlice<UInt8>) throws -> [String: String] {
        var headers: [String: String] = [:]
        var index = bytes.startIndex
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, index + count <= bytes.endIndex else { throw LLMError.invalidResponse }
            defer { index += count }
            return bytes[index..<(index + count)]
        }
        func length(_ width: Int) throws -> Int {
            try take(width).reduce(0) { $0 << 8 | Int($1) }
        }

        while index < bytes.endIndex {
            guard let name = try String(bytes: take(length(1)), encoding: .utf8),
                  let type = try take(1).first
            else { throw LLMError.invalidResponse }
            switch type {
            case 0, 1: continue // bool true / false
            case 2: _ = try take(1)
            case 3: _ = try take(2)
            case 4: _ = try take(4)
            case 5, 8: _ = try take(8) // int64, timestamp
            case 6: _ = try take(length(2)) // byte array
            case 7:
                guard let value = try String(bytes: take(length(2)), encoding: .utf8) else { throw LLMError.invalidResponse }
                headers[name] = value
            case 9: _ = try take(16) // uuid
            default: throw LLMError.invalidResponse
            }
        }
        return headers
    }
}
