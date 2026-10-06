import Foundation

/// One decoded protobuf message: its fields by number, without a schema.
///
/// Only the wire format is understood (varint, 64-bit, length-delimited, 32-bit). Anything else, a
/// truncated value or an invalid field number makes the whole message unreadable (`nil`), never a
/// partial result. Length-delimited payloads are kept as ranges into the shared storage, so reading a
/// few fields out of a large message copies nothing.
struct ProtobufMessage: Sendable {
    enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        /// A length-delimited payload (string, bytes or nested message) as offsets into the storage.
        case bytes(Range<Int>)
    }

    struct Field: Sendable, Equatable {
        let number: Int
        let value: Value
    }

    /// Protobuf field numbers run from 1 to 2^29 - 1.
    private static let maximumFieldNumber = 536_870_911
    /// A larger message is not a metadata blob; refusing it bounds memory and parsing time.
    static let maximumBytes = 32 * 1_024 * 1_024
    /// Nesting is only entered on demand, but a single message with more fields than this is not one
    /// of the small records Tokrate reads.
    private static let maximumFields = 1_000_000

    private let storage: Data
    let fields: [Field]

    init?(_ data: Data) {
        // `Data` slices can start at a non-zero index; ranges below are offsets from zero.
        let storage = data.startIndex == 0 ? data : Data(data)
        guard storage.count <= Self.maximumBytes else { return nil }
        self.init(storage: storage, range: 0..<storage.count)
    }

    private init?(storage: Data, range: Range<Int>) {
        guard let fields = Self.parse(storage, range: range) else { return nil }
        self.storage = storage
        self.fields = fields
    }

    // MARK: Lookup

    /// Whether the message carries the field at all, with any wire type.
    func contains(_ number: Int) -> Bool { last(number) != nil }

    /// The field's value as a varint; `nil` when absent or of another wire type.
    func varint(_ number: Int) -> UInt64? {
        guard case .varint(let value)? = last(number)?.value else { return nil }
        return value
    }

    /// A proto3 scalar: an absent field is 0, a present field of another wire type is unreadable (`nil`).
    func proto3Varint(_ number: Int) -> UInt64? {
        guard let field = last(number) else { return 0 }
        guard case .varint(let value) = field.value else { return nil }
        return value
    }

    /// The field as a nested message; `nil` when absent, of another wire type or itself unreadable.
    func message(_ number: Int) -> ProtobufMessage? {
        guard case .bytes(let range)? = last(number)?.value else { return nil }
        return ProtobufMessage(storage: storage, range: range)
    }

    /// The message reached by following the field numbers in order, such as `10.1` as `[10, 1]`.
    func message(at path: [Int]) -> ProtobufMessage? {
        var current = self
        for number in path {
            guard let next = current.message(number) else { return nil }
            current = next
        }
        return current
    }

    /// The field as a UTF-8 string; `nil` when absent, of another wire type or not valid UTF-8.
    func string(_ number: Int) -> String? {
        guard case .bytes(let range)? = last(number)?.value else { return nil }
        return String(data: storage[range], encoding: .utf8)
    }

    /// Every occurrence of a repeated length-delimited field as nested messages. `nil` when any
    /// occurrence is of another wire type or unreadable.
    func repeatedMessages(_ number: Int) -> [ProtobufMessage]? {
        var result: [ProtobufMessage] = []
        for field in fields where field.number == number {
            guard case .bytes(let range) = field.value,
                  let message = ProtobufMessage(storage: storage, range: range) else { return nil }
            result.append(message)
        }
        return result
    }

    /// The last occurrence wins, as in protobuf for a singular field.
    private func last(_ number: Int) -> Field? {
        fields.last { $0.number == number }
    }

    // MARK: Wire format

    private static func parse(_ storage: Data, range: Range<Int>) -> [Field]? {
        storage.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Field]? in
            var position = range.lowerBound
            let end = range.upperBound
            var fields: [Field] = []

            func readVarint() -> UInt64? {
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while position < end, shift < 70 {
                    let byte = bytes[position]
                    position += 1
                    // The tenth byte may only carry the top bit of a 64-bit value.
                    if shift == 63, byte > 1 { return nil }
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                }
                return nil
            }

            func readFixed(_ count: Int) -> UInt64? {
                guard end - position >= count else { return nil }
                var value: UInt64 = 0
                for offset in 0..<count { value |= UInt64(bytes[position + offset]) << UInt64(8 * offset) }
                position += count
                return value
            }

            while position < end {
                guard fields.count < maximumFields, let key = readVarint() else { return nil }
                let number = key >> 3
                guard number >= 1, number <= UInt64(maximumFieldNumber) else { return nil }
                switch key & 7 {
                case 0:
                    guard let value = readVarint() else { return nil }
                    fields.append(Field(number: Int(number), value: .varint(value)))
                case 1:
                    guard let value = readFixed(8) else { return nil }
                    fields.append(Field(number: Int(number), value: .fixed64(value)))
                case 2:
                    guard let length = readVarint(), length <= UInt64(end - position) else { return nil }
                    let start = position
                    position += Int(length)
                    fields.append(Field(number: Int(number), value: .bytes(start..<position)))
                case 5:
                    guard let value = readFixed(4) else { return nil }
                    fields.append(Field(number: Int(number), value: .fixed32(UInt32(truncatingIfNeeded: value))))
                default:
                    // Groups (3, 4) and the reserved types (6, 7) are not valid in this data.
                    return nil
                }
            }
            return fields
        }
    }
}
