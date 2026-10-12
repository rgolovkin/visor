import Foundation
import Testing
@testable import NotchApp

struct JSONValueTests {
    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test(arguments: [
        JSONValue.null,
        .bool(true),
        .bool(false),
        .number(0),
        .number(-12.5),
        .number(1_000_000),
        .string(""),
        .string("привет \"quoted\""),
        .array([]),
        .array([.null, .bool(true), .number(1), .string("x")]),
        .object([:]),
        .object(["a": .object(["b": .array([.number(2)])]), "c": .null]),
    ])
    func roundTripsEveryCase(_ value: JSONValue) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test func distinguishesBoolFromNumber() throws {
        let data = Data(#"{"flag": true, "count": 1}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["flag"] == .bool(true))
        #expect(value["count"] == .number(1))
    }

    @Test func integersAreWrittenWithoutFraction() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["v": .number(1)]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"v":1}"#)
    }

    // Security: 2^63 used to pass a `<= Double(Int.max)` check and trap in `Int(value)`.
    @Test(arguments: [9_223_372_036_854_775_808.0, 1e19, -1e19, .infinity, -.infinity, .nan, 0.5])
    func intValueRejectsOutOfRangeAndFractions(_ value: Double) {
        #expect(JSONValue.number(value).intValue == nil)
    }

    @Test func intValueAcceptsInt64Bounds() {
        #expect(JSONValue.number(-9_223_372_036_854_775_808.0).intValue == Int.min)
        #expect(JSONValue.number(9_223_372_036_854_774_784.0).intValue == 9_223_372_036_854_774_784)
        #expect(JSONValue.number(-0.0).intValue == 0)
    }

    @Test func hugeSchemaVersionDoesNotCrashDecoding() throws {
        let doc = try ConfigCodec.decode(Data(#"{"schemaVersion": 9223372036854775808}"#.utf8))
        #expect(doc.schemaVersion == ConfigCodec.currentSchemaVersion)
    }

    private func reencode(_ text: String) throws -> String {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // Integers must survive a round trip verbatim (AC-16, Windows client).
    @Test(arguments: [
        ("9223372036854775807", "9223372036854775807"),
        ("-9223372036854775808", "-9223372036854775808"),
        ("9007199254740993", "9007199254740993"),
        ("-9007199254740993", "-9007199254740993"),
        ("0", "0"),
        ("-0", "0"),
        ("42", "42"),
    ])
    func integersRoundTripExactly(_ input: String, _ expected: String) throws {
        #expect(try reencode("[\(input)]") == "[\(expected)]")
    }

    @Test func integersAreDecodedAsInteger() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("9007199254740993".utf8))
        #expect(value == .integer(9_007_199_254_740_993))
        #expect(value.intValue == 9_007_199_254_740_993)
        #expect(value != .number(9_007_199_254_740_992))
    }

    @Test(arguments: ["1.5", "-0.25", "1e19", "-1e19", "9223372036854775808", "1.5e300", "2.5E-3"])
    func nonInt64NumbersFallBackToDoubleWithoutCrash(_ input: String) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
        guard case .number(let decoded) = value else {
            Issue.record("expected .number for \(input), got \(value)")
            return
        }
        #expect(decoded == Double(input))
        let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
        #expect(again == value)
    }

    @Test func outOfInt64RangeValuesHaveNoIntValue() throws {
        for input in ["9223372036854775808", "1e19", "-1e19"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
            #expect(value.intValue == nil)
        }
    }

    @Test func exponentAndFractionFormsOfIntegersKeepTheirValue() throws {
        for input in ["1e2", "100.0", "1E2"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
            #expect(value == .integer(100))
            #expect(value.intValue == 100)
            let text = try reencode(input)
            #expect(text == "100" || text == "100.0" || text == "1e+2", "unexpected re-encoding \(text)")
        }
    }

    @Test func mixedIntegerAndDoubleEquality() {
        #expect(JSONValue.integer(1) == .number(1))
        #expect(JSONValue.number(1) == .integer(1))
        #expect(JSONValue.integer(Int64.max) != .number(9_223_372_036_854_775_808))
        #expect(JSONValue.integer(1) != .number(1.5))
        #expect(JSONValue.object(["a": .integer(2)]) == .object(["a": .number(2)]))
        #expect(JSONValue.integer(3).doubleValue == 3)
        #expect(JSONValue.integer(Int64.min).intValue == Int.min)
    }

    @Test func mergingKeepsUnknownKeys() {
        let original = JSONValue.object(["known": .number(1), "unknown": .string("keep")])
        let merged = original.merging(["known": .number(2), "added": .bool(true)])
        #expect(merged == .object(["known": .number(2), "unknown": .string("keep"), "added": .bool(true)]))
    }

    @Test func mergingIntoNonObjectStartsFromEmpty() {
        #expect(JSONValue.null.merging(["a": .null]) == .object(["a": .null]))
    }

    @Test func accessors() {
        #expect(JSONValue.number(3).intValue == 3)
        #expect(JSONValue.number(3.5).intValue == nil)
        #expect(JSONValue.string("s").stringValue == "s")
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.array([.null]).arrayValue == [.null])
        #expect(JSONValue.string("s")["key"] == nil)
    }

    private struct Sample: Codable, Equatable {
        var name: String
        var count: Int
        var when: Date
    }

    @Test func codableThroughJSONValueUsesISO8601Dates() throws {
        let sample = Sample(name: "n", count: 2, when: Date(timeIntervalSince1970: 1_700_000_000))
        let json = try JSONValue.encode(sample)
        #expect(json["when"] == .string("2023-11-14T22:13:20Z"))
        #expect(json["count"] == .number(2))
        #expect(try json.decode(Sample.self) == sample)
    }
}
