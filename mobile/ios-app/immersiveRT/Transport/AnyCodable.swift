import Foundation

/// A type-erased `Codable` wrapper that can encode/decode arbitrary JSON:
/// objects, arrays, strings, numbers (int/double), booleans, and null.
///
/// Swift's `Codable` has no native equivalent to TypeScript's
/// `Record<string, unknown>`, which is what `SignalingEnvelope.payload`
/// needs to model on the wire (the server's `serde_json::Value` payload
/// field, see `server/src/signaling.rs`). `AnyCodable` fills that gap.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any?) {
        self.value = value ?? ()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = ()
        } else if let boolValue = try? container.decode(Bool.self) {
            self.value = boolValue
        } else if let intValue = try? container.decode(Int.self) {
            self.value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            self.value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            self.value = stringValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            self.value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            self.value = dictValue.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable: unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is Void:
            try container.encodeNil()
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let arrayValue as [Any?]:
            try container.encode(arrayValue.map { AnyCodable($0) })
        case let dictValue as [String: Any?]:
            try container.encode(dictValue.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "AnyCodable: unsupported value of type \(type(of: value))"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
}
