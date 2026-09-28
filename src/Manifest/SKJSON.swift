/// Minimal JSON model, strict parser and compact encoder for the SandboxArk/1 manifest and
/// hash index. Foundation is not used: the archive layer must build and verify documents
/// from a plain POSIX build, and the strict reader needs rules `JSONSerialization` lacks.
indirect enum SKJSONValue: Equatable, Sendable {
    case object([SKJSONMember])
    case array([SKJSONValue])
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case null
}

/// One object member. Members keep insertion order, so the emitted order is the builder's choice.
struct SKJSONMember: Equatable, Sendable {
    let name: String
    let value: SKJSONValue

    init(_ name: String, _ value: SKJSONValue) {
        self.name = name
        self.value = value
    }
}

extension SKJSONValue {
    static func object(_ members: [(String, SKJSONValue)]) -> SKJSONValue {
        .object(members.map { SKJSONMember($0.0, $0.1) })
    }

    var objectMembers: [SKJSONMember]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    var arrayItems: [SKJSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    func member(_ name: String) -> SKJSONValue? {
        objectMembers?.first { $0.name == name }?.value
    }
}

/// Strict JSON reader. Every deviation RFC 8259 leaves to the implementation is
/// resolved the narrow way: duplicate keys, control characters, malformed escapes,
/// unpaired surrogates, non-integer numbers and trailing bytes are all rejected.
enum SKJSONParser {
    struct Limits: Sendable {
        var maxBytes = SKResourceLimits.maxManifestBytes
        /// Nesting bound; RFC 8259 allows deeper documents than any SandboxArk/1
        /// field could meaningfully use.
        var maxDepth = 64
        /// Objects plus arrays plus their members, bounded so a small input cannot
        /// expand into an unbounded tree.
        var maxItems = SKResourceLimits.maxArchiveMembers
        /// Single string bound; archive paths are capped well below this.
        var maxStringBytes = SKResourceLimits.maxScanPathBytes

        static let `default` = Limits()
    }

    static func parse(_ bytes: [UInt8], limits: Limits = .default) throws -> SKJSONValue {
        guard bytes.count <= limits.maxBytes else {
            throw malformed("document exceeds \(limits.maxBytes) bytes")
        }
        var decoder = Decoder(bytes: bytes, limits: limits)
        try decoder.skipWhitespace()
        let value = try decoder.value(depth: 0)
        try decoder.skipWhitespace()
        guard decoder.isAtEnd else { throw malformed("trailing bytes after the root value") }
        return value
    }

    static func malformed(_ reason: String) -> SKError {
        SKError(code: .integrityManifestInvalid, stage: "json", reason: reason)
    }

    private struct Decoder {
        let bytes: [UInt8]
        let limits: Limits
        var index = 0
        var itemCount = 0

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() throws {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                case let other where other >= 0x80:
                    // A UTF-8 continuation byte here cannot open any JSON token.
                    throw malformed("unexpected byte at offset \(index)")
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws -> SKJSONValue {
            guard depth <= limits.maxDepth else { throw malformed("nesting exceeds \(limits.maxDepth)") }
            guard index < bytes.count else { throw malformed("document ends where a value was expected") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try objectValue(depth: depth)
            case UInt8(ascii: "["): return try arrayValue(depth: depth)
            case UInt8(ascii: "\""): return .string(try stringValue())
            case UInt8(ascii: "t"): try literal("true"); return .boolean(true)
            case UInt8(ascii: "f"): try literal("false"); return .boolean(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .integer(try integerValue())
            default: throw malformed("unexpected byte at offset \(index)")
            }
        }

        private mutating func objectValue(depth: Int) throws -> SKJSONValue {
            try consume(UInt8(ascii: "{"), "object")
            try countItem()
            var members: [SKJSONMember] = []
            var names: Set<String> = []
            try skipWhitespace()
            if peek(UInt8(ascii: "}")) {
                index += 1
                return .object(members)
            }
            while true {
                try skipWhitespace()
                guard peek(UInt8(ascii: "\"")) else { throw malformed("object key is not a string") }
                let name = try stringValue()
                guard names.insert(name).inserted else { throw malformed("duplicate object key") }
                try skipWhitespace()
                try consume(UInt8(ascii: ":"), "member separator")
                try skipWhitespace()
                members.append(SKJSONMember(name, try value(depth: depth + 1)))
                try skipWhitespace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                try consume(UInt8(ascii: "}"), "object terminator")
                return .object(members)
            }
        }

        private mutating func arrayValue(depth: Int) throws -> SKJSONValue {
            try consume(UInt8(ascii: "["), "array")
            try countItem()
            var items: [SKJSONValue] = []
            try skipWhitespace()
            if peek(UInt8(ascii: "]")) {
                index += 1
                return .array(items)
            }
            while true {
                try skipWhitespace()
                items.append(try value(depth: depth + 1))
                try skipWhitespace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                try consume(UInt8(ascii: "]"), "array terminator")
                return .array(items)
            }
        }

        private mutating func stringValue() throws -> String {
            try consume(UInt8(ascii: "\""), "string")
            var content: [UInt8] = []
            while true {
                guard index < bytes.count else { throw malformed("string is not terminated") }
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    let text = String(decoding: content, as: UTF8.self)
                    // Decoding substitutes U+FFFD for ill-formed sequences, so a
                    // byte-for-byte round trip is the validity check.
                    guard Array(text.utf8) == content else { throw malformed("string is not valid UTF-8") }
                    return text
                case UInt8(ascii: "\\"):
                    index += 1
                    try escape(into: &content)
                case 0x00...0x1F:
                    throw malformed("string contains a raw control character")
                default:
                    index += 1
                    content.append(byte)
                }
                guard content.count <= limits.maxStringBytes else {
                    throw malformed("string exceeds \(limits.maxStringBytes) bytes")
                }
            }
        }

        private mutating func escape(into content: inout [UInt8]) throws {
            guard index < bytes.count else { throw malformed("string ends inside an escape") }
            let marker = bytes[index]
            index += 1
            switch marker {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                content.append(marker)
            case UInt8(ascii: "b"): content.append(0x08)
            case UInt8(ascii: "f"): content.append(0x0C)
            case UInt8(ascii: "n"): content.append(0x0A)
            case UInt8(ascii: "r"): content.append(0x0D)
            case UInt8(ascii: "t"): content.append(0x09)
            case UInt8(ascii: "u"):
                let scalar = try unicodeEscape()
                append(scalar, into: &content)
            default:
                throw malformed("unknown escape sequence")
            }
        }

        private mutating func unicodeEscape() throws -> UInt32 {
            let high = try hexQuad()
            guard high >= 0xD800, high <= 0xDFFF else { return high }
            guard high <= 0xDBFF else { throw malformed("unpaired low surrogate") }
            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                  bytes[index + 1] == UInt8(ascii: "u") else {
                throw malformed("unpaired high surrogate")
            }
            index += 2
            let low = try hexQuad()
            guard low >= 0xDC00, low <= 0xDFFF else { throw malformed("unpaired high surrogate") }
            return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
        }

        private mutating func hexQuad() throws -> UInt32 {
            guard index + 3 < bytes.count else { throw malformed("truncated \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = SKHex.value(of: bytes[index]) else {
                    throw malformed("malformed \\u escape")
                }
                value = value << 4 | UInt32(digit)
                index += 1
            }
            return value
        }

        /// Appends in the same UTF-8 shape the input used, so the bytes stay directly decodable.
        private func append(_ scalar: UInt32, into content: inout [UInt8]) {
            if scalar < 0x80 {
                content.append(UInt8(scalar))
            } else if scalar < 0x800 {
                content.append(UInt8(0xC0 | scalar >> 6))
                content.append(UInt8(0x80 | scalar & 0x3F))
            } else if scalar < 0x10000 {
                content.append(UInt8(0xE0 | scalar >> 12))
                content.append(UInt8(0x80 | scalar >> 6 & 0x3F))
                content.append(UInt8(0x80 | scalar & 0x3F))
            } else {
                content.append(UInt8(0xF0 | scalar >> 18))
                content.append(UInt8(0x80 | scalar >> 12 & 0x3F))
                content.append(UInt8(0x80 | scalar >> 6 & 0x3F))
                content.append(UInt8(0x80 | scalar & 0x3F))
            }
        }

        /// JSON numbers here are whole numbers only: the SandboxArk/1 schemas declare
        /// no fractional field, so an exponent or decimal point is a foreign document.
        private mutating func integerValue() throws -> Int64 {
            let negative = peek(UInt8(ascii: "-"))
            if negative { index += 1 }
            guard index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") else {
                throw malformed("number has no digits")
            }
            if bytes[index] == UInt8(ascii: "0"), index + 1 < bytes.count {
                let next = bytes[index + 1]
                if next >= UInt8(ascii: "0"), next <= UInt8(ascii: "9") {
                    throw malformed("number has a leading zero")
                }
            }
            var magnitude: UInt64 = 0
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                let digit = UInt64(bytes[index] - UInt8(ascii: "0"))
                let (scaled, scaleOverflow) = magnitude.multipliedReportingOverflow(by: 10)
                let (sum, addOverflow) = scaled.addingReportingOverflow(digit)
                guard !scaleOverflow, !addOverflow else { throw malformed("number is out of range") }
                magnitude = sum
                index += 1
            }
            if index < bytes.count {
                let next = bytes[index]
                if next == UInt8(ascii: ".") || next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
                    throw malformed("fractional numbers are not accepted")
                }
            }
            if negative {
                guard magnitude <= UInt64(Int64.max) + 1 else { throw malformed("number is out of range") }
                if magnitude == 0 { throw malformed("negative zero is not accepted") }
                return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
            }
            guard magnitude <= UInt64(Int64.max) else { throw malformed("number is out of range") }
            return Int64(magnitude)
        }

        private mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw malformed("malformed literal")
            }
            index += expected.count
        }

        private mutating func countItem() throws {
            itemCount += 1
            guard itemCount <= limits.maxItems else {
                throw malformed("document exceeds \(limits.maxItems) items")
            }
        }

        private mutating func consume(_ byte: UInt8, _ what: String) throws {
            guard index < bytes.count, bytes[index] == byte else { throw malformed("expected \(what)") }
            index += 1
        }

        private func peek(_ byte: UInt8) -> Bool {
            index < bytes.count && bytes[index] == byte
        }

        private func malformed(_ reason: String) -> SKError {
            SKJSONParser.malformed(reason)
        }
    }
}

/// Compact encoder. Key order is the member order, so a document's bytes are stable
/// for a given builder; `/` is never escaped and non-ASCII stays as UTF-8.
enum SKJSONEncoder {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func bytes(_ value: SKJSONValue) -> [UInt8] {
        var output: [UInt8] = []
        encode(value, into: &output)
        return output
    }

    static func text(_ value: SKJSONValue) -> String {
        String(decoding: bytes(value), as: UTF8.self)
    }

    private static func encode(_ value: SKJSONValue, into output: inout [UInt8]) {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .boolean(let flag):
            output.append(contentsOf: (flag ? "true" : "false").utf8)
        case .integer(let number):
            output.append(contentsOf: String(number).utf8)
        case .string(let text):
            encode(string: text, into: &output)
        case .array(let items):
            output.append(UInt8(ascii: "["))
            for (offset, item) in items.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                encode(item, into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let members):
            output.append(UInt8(ascii: "{"))
            for (offset, member) in members.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                encode(string: member.name, into: &output)
                output.append(UInt8(ascii: ":"))
                encode(member.value, into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func encode(string text: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                output.append(UInt8(ascii: "\\"))
                output.append(byte)
            case 0x08: output.append(contentsOf: "\\b".utf8)
            case 0x0C: output.append(contentsOf: "\\f".utf8)
            case 0x0A: output.append(contentsOf: "\\n".utf8)
            case 0x0D: output.append(contentsOf: "\\r".utf8)
            case 0x09: output.append(contentsOf: "\\t".utf8)
            case 0x00...0x1F:
                output.append(contentsOf: "\\u00".utf8)
                output.append(SKJSONEncoder.hexDigits[Int(byte >> 4)])
                output.append(SKJSONEncoder.hexDigits[Int(byte & 0x0F)])
            default:
                output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}
