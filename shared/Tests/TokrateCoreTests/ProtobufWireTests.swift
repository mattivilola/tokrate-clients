import Foundation
import XCTest
@testable import TokrateCore

final class ProtobufWireTests: XCTestCase {
    func testReadsEveryWireTypeAndNestedMessages() throws {
        var writer = ProtoWriter()
        writer.varint(1, 300)
        writer.fixed64(2, 0x0102_0304_0506_0708)
        writer.fixed32(3, 0xAABB_CCDD)
        writer.string(4, "héllo")
        writer.message(5) { outer in
            outer.message(1) { $0.varint(28, 7) }
            outer.string(2, "inner")
        }
        let message = try XCTUnwrap(ProtobufMessage(writer.data))

        XCTAssertEqual(message.varint(1), 300)
        XCTAssertEqual(message.fields.first { $0.number == 2 }?.value, .fixed64(0x0102_0304_0506_0708))
        XCTAssertEqual(message.fields.first { $0.number == 3 }?.value, .fixed32(0xAABB_CCDD))
        XCTAssertEqual(message.string(4), "héllo")
        XCTAssertEqual(message.message(at: [5, 1])?.varint(28), 7)
        XCTAssertEqual(message.message(5)?.string(2), "inner")
        XCTAssertNil(message.message(1), "a varint is not a message")
        XCTAssertNil(message.message(at: [9, 1]), "an absent field has no children")
    }

    func testLargeAndMaximumVarints() throws {
        var writer = ProtoWriter()
        writer.varint(1, UInt64.max)
        writer.varint(2, 1 << 35)
        let message = try XCTUnwrap(ProtobufMessage(writer.data))
        XCTAssertEqual(message.varint(1), UInt64.max)
        XCTAssertEqual(message.varint(2), 1 << 35)
    }

    func testLastOccurrenceWinsAndRepeatedFieldsKeepOrder() throws {
        var writer = ProtoWriter()
        writer.varint(1, 1)
        writer.varint(1, 2)
        writer.message(2) { $0.string(1, "a") }
        writer.message(2) { $0.string(1, "b") }
        let message = try XCTUnwrap(ProtobufMessage(writer.data))
        XCTAssertEqual(message.varint(1), 2)
        XCTAssertEqual(message.repeatedMessages(2)?.compactMap { $0.string(1) }, ["a", "b"])
        XCTAssertEqual(message.repeatedMessages(9)?.count, 0)
    }

    func testProto3VarintTreatsAbsentAsZeroAndWrongTypeAsUnreadable() throws {
        var writer = ProtoWriter()
        writer.string(2, "text")
        let message = try XCTUnwrap(ProtobufMessage(writer.data))
        XCTAssertEqual(message.proto3Varint(1), 0, "an absent proto3 scalar is zero")
        XCTAssertNil(message.varint(1))
        XCTAssertNil(message.proto3Varint(2), "a present field of another wire type is unreadable")
        XCTAssertFalse(message.contains(1))
        XCTAssertTrue(message.contains(2))
    }

    func testEmptyMessageIsValidAndAbsentMessageIsNot() throws {
        var writer = ProtoWriter()
        writer.message(9) { _ in }
        let message = try XCTUnwrap(ProtobufMessage(writer.data))
        XCTAssertNotNil(message.message(9), "a present empty message is not absent")
        XCTAssertNil(message.message(8))
        XCTAssertNotNil(ProtobufMessage(Data()))
    }

    func testRejectsTruncatedAndInvalidWire() {
        var truncatedString = ProtoWriter()
        truncatedString.rawKey(1, wireType: 2)
        truncatedString.rawBytes([5, 0x61])
        XCTAssertNil(ProtobufMessage(truncatedString.data), "length beyond the end")

        var truncatedVarint = ProtoWriter()
        truncatedVarint.rawKey(1, wireType: 0)
        truncatedVarint.rawBytes([0x80])
        XCTAssertNil(ProtobufMessage(truncatedVarint.data))

        var truncatedFixed = ProtoWriter()
        truncatedFixed.rawKey(1, wireType: 1)
        truncatedFixed.rawBytes([1, 2, 3])
        XCTAssertNil(ProtobufMessage(truncatedFixed.data))

        var overlong = ProtoWriter()
        overlong.rawKey(1, wireType: 0)
        overlong.rawBytes(Array(repeating: 0xFF, count: 10) + [0x01])
        XCTAssertNil(ProtobufMessage(overlong.data), "eleven varint bytes")

        var overflowing = ProtoWriter()
        overflowing.rawKey(1, wireType: 0)
        overflowing.rawBytes(Array(repeating: 0xFF, count: 9) + [0x02])
        XCTAssertNil(ProtobufMessage(overflowing.data), "a tenth byte above 1 does not fit 64 bits")

        for wireType: UInt64 in [3, 4, 6, 7] {
            var group = ProtoWriter()
            group.rawKey(1, wireType: wireType)
            XCTAssertNil(ProtobufMessage(group.data), "wire type \(wireType)")
        }

        var fieldZero = ProtoWriter()
        fieldZero.rawKey(0, wireType: 0)
        fieldZero.rawBytes([1])
        XCTAssertNil(ProtobufMessage(fieldZero.data), "field number 0")
        XCTAssertNil(ProtobufMessage(Data("not protobuf at all, only text".utf8)))
    }

    func testNestedMessageWithBadContentIsUnreadableButParentStays() throws {
        var writer = ProtoWriter()
        writer.varint(1, 5)
        writer.bytes(2, Data([0x08]))
        let message = try XCTUnwrap(ProtobufMessage(writer.data))
        XCTAssertEqual(message.varint(1), 5)
        XCTAssertNil(message.message(2), "the nested payload is a truncated varint")
        XCTAssertNil(message.repeatedMessages(2))
    }

    func testInvalidUTF8IsNotAString() throws {
        var writer = ProtoWriter()
        writer.bytes(1, Data([0xFF, 0xFE]))
        let message = try XCTUnwrap(ProtobufMessage(writer.data))
        XCTAssertNil(message.string(1))
    }

    func testDataSlicesWithANonZeroStartIndexDecodeTheSame() throws {
        var writer = ProtoWriter()
        writer.message(1) { $0.string(2, "slice") }
        let padded = Data([0xDE, 0xAD]) + writer.data
        let slice = padded[2...]
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(ProtobufMessage(slice)?.message(1)?.string(2), "slice")
    }
}
