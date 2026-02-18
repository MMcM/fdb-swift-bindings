/*
 * Tuple.swift
 *
 * This source file is part of the FoundationDB open source project
 *
 * Copyright 2016-2025 Apple Inc. and the FoundationDB project authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

public enum TupleError: Error, Sendable {
    case invalidTupleElement
    case invalidEncoding
    case invalidDecoding(String)
    case unsupportedType
}

enum TupleTypeCode: UInt8, CaseIterable {
    case null = 0x00
    case bytes = 0x01
    case string = 0x02
    case nested = 0x05
    case negativeIntStart = 0x0B
    case intZero = 0x14
    case positiveIntEnd = 0x1D
    case float = 0x20
    case double = 0x21
    case boolFalse = 0x26
    case boolTrue = 0x27
    case uuid = 0x30
    case versionstamp = 0x33
}

/// ## Equality and Hashing
///
/// Tuple equality is based on the encoded byte representation of each element, which matches
/// FoundationDB's tuple comparison semantics. This differs from Swift's native equality for
/// floating-point values in the following ways:
///
/// - **Positive and negative zero**: `Tuple(0.0)` and `Tuple(-0.0)` are **not equal** because
///   they have different bit patterns and encode to different bytes. This differs from Swift,
///   where `0.0 == -0.0` is `true`.
///
/// - **NaN values**: `Tuple(Float.nan)` and `Tuple(Float.nan)` **are equal** if they have the
///   same bit pattern, because they encode to the same bytes. This differs from Swift, where
///   `Float.nan == Float.nan` is `false`.
///
/// These semantic differences ensure consistency with FoundationDB's tuple ordering and are
/// important when using tuples as dictionary keys or in sets.

@nonexhaustive
public enum TupleElement: Sendable, Hashable, Equatable, Comparable {
    case null
    case bytes(FDB.Bytes)
    case string(String)
    case nested(Tuple)
    case int(Int64)
    case float(Float)
    case double(Double)
    case bool(Bool)
    case uuid(UUID)

    func encode() -> FDB.Bytes {
        switch self {
        case .null:
            return [TupleTypeCode.null.rawValue]
        case let .bytes(b):
            return b.encodeTuple()
        case let .string(s):
            return s.encodeTuple()
        case let .nested(t):
            return t.encodeTuple()
        case let .int(i):
            return i.encodeTuple()
        case let .float(f):
            return f.encodeTuple()
        case let .double(d):
            return d.encodeTuple()
        case let .bool(b):
            return b.encodeTuple()
        case let .uuid(u):
            return u.encodeTuple()
        }
    }

    public static func == (lhs: TupleElement, rhs: TupleElement) -> Bool {
        switch lhs {
        case .null:
            switch rhs {
            case .null:
                return true
            default:
                return false
            }
        case let .bytes(bl):
            switch rhs {
            case let .bytes(br):
                return bl == br
            default:
                return false
            }
        case let .string(sl):
            switch rhs {
            case let .string(sr):
                return sl == sr
            default:
                return false
            }
        case let .nested(tl):
            switch rhs {
            case let .nested(tr):
                return tl == tr
            default:
                return false
            }
        case let .int(il):
            switch rhs {
            case let .int(ir):
                return il == ir
            default:
                return false
            }
        case let .float(fl):
            switch rhs {
            case let .float(fr):
                return fl.bitPattern == fr.bitPattern
            default:
                return false
            }
        case let .double(dl):
            switch rhs {
            case let .double(dr):
                return dl.bitPattern == dr.bitPattern
            default:
                return false
            }
        case let .bool(bl):
            switch rhs {
            case let .bool(br):
                return bl == br
            default:
                return false
            }
        case let .uuid(ul):
            switch rhs {
            case let .uuid(ur):
                return ul == ur
            default:
                return false
            }
        }
    }

    public static func < (lhs: TupleElement, rhs: TupleElement) -> Bool {
        lhs.encode().lexicographicallyPrecedes(rhs.encode())
    }
}

// public protocol for converting between Swift native types and Tuple element types.
public protocol TupleElementConvertible {
    func tupleElement() -> TupleElement

    static func fromTuple(element: TupleElement?) -> Self?
}

extension TupleElement: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        self
    }

    public static func fromTuple(element: TupleElement?) -> TupleElement? {
        element
    }
}

// internal protocol for converting between Tuple elements and byte strings.
protocol TupleCodable {
    func encodeTuple() -> FDB.Bytes
    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Self
}

/// A tuple represents an ordered collection of elements that can be encoded to and decoded from bytes.
///
/// Tuples can be used as keys in FoundationDB, and their encoding preserves lexicographic ordering.
///
public struct Tuple: Sendable, Hashable, Equatable, Comparable, CustomStringConvertible {
    // TODO: Any issues with making this public?
    public let elements: [TupleElement]

    public init(_ elements: [TupleElement]) {
        self.elements = elements
    }

    public init(_ elements: [TupleElementConvertible]) {
        self.init(elements.map { $0.tupleElement() })
    }

    public init(_ elements: TupleElementConvertible...) {
        self.init(elements)
    }

    // TODO: Result is optional, like a Dictionary and not like a Collection. Is that right?
    //  Should this implement more of [RandomAccess]Collection or is using elements array sufficient?

    public subscript(index: Int) -> TupleElement? {
        guard index >= 0, index < elements.count else { return nil }
        return elements[index]
    }

    public var count: Int {
        elements.count
    }

    public func encode() -> FDB.Bytes {
        var result = FDB.Bytes()
        for element in elements {
            result.append(contentsOf: element.encode())
        }
        return result
    }

    public static func decode(from bytes: FDB.Bytes) throws -> Self {
        var elements: [TupleElement] = []
        var offset = 0

        while offset < bytes.count {
            let typeCode = bytes[offset]
            offset += 1

            switch typeCode {
            case TupleTypeCode.null.rawValue:
                elements.append(TupleElement.null)
            case TupleTypeCode.bytes.rawValue:
                let element = try FDB.Bytes.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.string.rawValue:
                let element = try String.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.boolFalse.rawValue, TupleTypeCode.boolTrue.rawValue:
                let element = try Bool.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.float.rawValue:
                let element = try Float.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.double.rawValue:
                let element = try Double.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.uuid.rawValue:
                let element = try UUID.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.intZero.rawValue:
                elements.append(TupleElement.int(0))
            case TupleTypeCode.negativeIntStart.rawValue ... TupleTypeCode.positiveIntEnd.rawValue:
                let element = try Int64.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            case TupleTypeCode.nested.rawValue:
                let element = try Tuple.decodeTuple(from: bytes, at: &offset)
                elements.append(element.tupleElement())
            default:
                throw TupleError.invalidDecoding("Unknown type code: \(typeCode)")
            }
        }

        return Self(elements)
    }

    public static func < (lhs: Tuple, rhs: Tuple) -> Bool {
        let lc = lhs.count
        let rc = rhs.count
        for i in 0..<min(lc, rc) {
            let le = lhs.elements[i]
            let re = rhs.elements[i]
            if le < re {
                return true
            }
            if le > re {
                return false
            }
        }
        return lc < rc
    }

    public var description: String {
        elements.description
    }
}

extension String: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .string(self)
    }

    public static func fromTuple(element: TupleElement?) -> String? {
        switch element {
        case let .string(s):
            return s
        default:
            return nil
        }
    }
}

extension String: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        var encoded = [TupleTypeCode.string.rawValue]
        let utf8Bytes = Array(utf8)

        for byte in utf8Bytes {
            if byte == 0x00 {
                encoded.append(contentsOf: [0x00, 0xFF])
            } else {
                encoded.append(byte)
            }
        }
        encoded.append(0x00)
        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> String {
        var decoded = FDB.Bytes()

        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1

            if byte == 0x00 {
                if offset < bytes.count && bytes[offset] == 0xFF {
                    offset += 1
                    decoded.append(0x00)
                } else {
                    break
                }
            } else {
                decoded.append(byte)
            }
        }

        return String(bytes: decoded, encoding: .utf8)!
    }
}

extension FDB.Bytes: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .bytes(self)
    }

    public static func fromTuple(element: TupleElement?) -> FDB.Bytes? {
        switch element {
        case let .bytes(b):
            return b
        default:
            return nil
        }
    }
}

extension FDB.Bytes: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        var encoded = [TupleTypeCode.bytes.rawValue]
        for byte in self {
            if byte == 0x00 {
                encoded.append(contentsOf: [0x00, 0xFF])
            } else {
                encoded.append(byte)
            }
        }
        encoded.append(0x00)
        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> FDB.Bytes {
        var decoded = FDB.Bytes()

        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1

            if byte == 0x00 {
                if offset < bytes.count && bytes[offset] == 0xFF {
                    offset += 1
                    decoded.append(0x00)
                } else {
                    break
                }
            } else {
                decoded.append(byte)
            }
        }

        return decoded
    }
}

extension Bool: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .bool(self)
    }

    public static func fromTuple(element: TupleElement?) -> Bool? {
        switch element {
        case let .bool(b):
            return b
        default:
            return nil
        }
    }
}

extension Bool: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        return self ? [TupleTypeCode.boolTrue.rawValue] : [TupleTypeCode.boolFalse.rawValue]
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Bool {
        guard offset > 0 else {
            throw TupleError.invalidDecoding("Bool decoding requires type code")
        }
        let typeCode = bytes[offset - 1]

        switch typeCode {
        case TupleTypeCode.boolTrue.rawValue:
            return true
        case TupleTypeCode.boolFalse.rawValue:
            return false
        default:
            throw TupleError.invalidDecoding("Invalid bool type code: \(typeCode)")
        }
    }
}

extension Float: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .float(self)
    }

    public static func fromTuple(element: TupleElement?) -> Float? {
        switch element {
        case let .float(f):
            return f
        default:
            return nil
        }
    }
}

extension Float: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        var encoded = [TupleTypeCode.float.rawValue]
        let bitPattern = self.bitPattern
        let bytes = withUnsafeBytes(of: bitPattern.bigEndian) { Array($0) }
        encoded.append(contentsOf: bytes)
        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Float {
        guard offset + 4 <= bytes.count else {
            throw TupleError.invalidDecoding("Not enough bytes for Float")
        }

        let floatBytes = Array(bytes[offset ..< offset + 4])
        offset += 4

        let bigEndianValue = floatBytes.withUnsafeBytes { bytes in
            bytes.load(as: UInt32.self)
        }
        let bitPattern = UInt32(bigEndian: bigEndianValue)
        return Float(bitPattern: bitPattern)
    }
}

extension Double: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .double(self)
    }

    public static func fromTuple(element: TupleElement?) -> Double? {
        switch element {
        case let .double(d):
            return d
        default:
            return nil
        }
    }
}

extension Double: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        var encoded = [TupleTypeCode.double.rawValue]
        let bitPattern = self.bitPattern
        let bytes = withUnsafeBytes(of: bitPattern.bigEndian) { Array($0) }
        encoded.append(contentsOf: bytes)
        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Double {
        guard offset + 8 <= bytes.count else {
            throw TupleError.invalidDecoding("Not enough bytes for Double")
        }

        let doubleBytes = Array(bytes[offset ..< offset + 8])
        offset += 8

        let bigEndianValue = doubleBytes.withUnsafeBytes { bytes in
            bytes.load(as: UInt64.self)
        }
        let bitPattern = UInt64(bigEndian: bigEndianValue)
        return Double(bitPattern: bitPattern)
    }
}

extension UUID: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .uuid(self)
    }

    public static func fromTuple(element: TupleElement?) -> UUID? {
        switch element {
        case let .uuid(u):
            return u
        default:
            return nil
        }
    }
}

extension UUID: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        var encoded = [TupleTypeCode.uuid.rawValue]
        let (u1, u2, u3, u4, u5, u6, u7, u8, u9, u10, u11, u12, u13, u14, u15, u16) = uuid
        encoded.append(contentsOf: [
            u1, u2, u3, u4, u5, u6, u7, u8, u9, u10, u11, u12, u13, u14, u15, u16,
        ])
        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> UUID {
        guard offset + 16 <= bytes.count else {
            throw TupleError.invalidDecoding("Not enough bytes for UUID")
        }

        let uuidBytes = Array(bytes[offset ..< offset + 16])
        offset += 16

        let uuidTuple = (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )

        return UUID(uuid: uuidTuple)
    }
}

private let sizeLimits: [UInt64] = [
    (1 << (0 * 8)) - 1,
    (1 << (1 * 8)) - 1,
    (1 << (2 * 8)) - 1,
    (1 << (3 * 8)) - 1,
    (1 << (4 * 8)) - 1,
    (1 << (5 * 8)) - 1,
    (1 << (6 * 8)) - 1,
    (1 << (7 * 8)) - 1,
    UInt64.max, // (1 << (8 * 8)) - 1 would overflow, so use UInt64.max instead
]

private func bisectLeft(_ value: UInt64) -> Int {
    var n = 0
    while n < sizeLimits.count && sizeLimits[n] < value {
        n += 1
    }
    return n
}

extension Int64: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .int(self)
    }

    public static func fromTuple(element: TupleElement?) -> Int64? {
        switch element {
        case let .int(i):
            return i
        default:
            return nil
        }
    }
}

extension Int64: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        encodeInt(self)
    }

    private func encodeInt(_ value: Int64) -> FDB.Bytes {
        if value == 0 {
            return [TupleTypeCode.intZero.rawValue]
        }

        var encoded = FDB.Bytes()
        if value > 0 {
            let n = bisectLeft(UInt64(value))
            encoded.append(TupleTypeCode.intZero.rawValue + UInt8(n))
            let bigEndianValue = UInt64(bitPattern: value).bigEndian
            let bytes = withUnsafeBytes(of: bigEndianValue) { Array($0) }
            encoded.append(contentsOf: bytes.suffix(n))
        } else {
            let n = bisectLeft(UInt64(-value))
            encoded.append(TupleTypeCode.intZero.rawValue - UInt8(n))

            if n < 8 {
                let offset = UInt64(sizeLimits[n]) &+ UInt64(bitPattern: value)
                let bigEndianValue = offset.bigEndian
                let bytes = withUnsafeBytes(of: bigEndianValue) { Array($0) }
                encoded.append(contentsOf: bytes.suffix(n))
            } else {
                // n == 8 case
                let offset = UInt64(bitPattern: value)
                let bigEndianValue = offset.bigEndian
                let bytes = withUnsafeBytes(of: bigEndianValue) { Array($0) }
                encoded.append(contentsOf: bytes)
            }
        }

        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Int64 {
        guard offset > 0 else {
            throw TupleError.invalidDecoding("Int64 decoding requires type code")
        }
        let typeCode = bytes[offset - 1]

        if typeCode == TupleTypeCode.intZero.rawValue {
            return 0
        }

        var n = Int(typeCode) - Int(TupleTypeCode.intZero.rawValue)
        var neg = false
        if n < 0 {
            n = -n
            neg = true
        }

        var bp = [UInt8](repeating: 0, count: 8)
        bp.replaceSubrange((8 - n) ..< 8, with: bytes[offset ... (offset + n - 1)])
        offset += n

        var ret: Int64 = 0
        for byte in bp {
            ret = (ret << 8) | Int64(byte)
        }

        if neg {
            if n == 8 {
                return ret
            } else {
                return ret - Int64(sizeLimits[n])
            }
        }

        if ret > 0 {
            return ret
        }

        return ret
    }
}

extension Tuple: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .nested(self)
    }

    public static func fromTuple(element: TupleElement?) -> Tuple? {
        switch element {
        case let .nested(t):
            return t
        default:
            return nil
        }
    }
}

extension Tuple: TupleCodable {
    func encodeTuple() -> FDB.Bytes {
        var encoded = [TupleTypeCode.nested.rawValue]
        for element in elements {
            let elementBytes = element.encode()
            for byte in elementBytes {
                if byte == 0x00 {
                    encoded.append(contentsOf: [0x00, 0xFF])
                } else {
                    encoded.append(byte)
                }
            }
        }
        encoded.append(0x00)
        return encoded
    }

    static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Tuple {
        var nestedBytes = FDB.Bytes()

        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1

            if byte == 0x00 {
                if offset < bytes.count && bytes[offset] == 0xFF {
                    offset += 1
                    nestedBytes.append(0x00)
                } else {
                    break
                }
            } else {
                nestedBytes.append(byte)
            }
        }

        return try Tuple.decode(from: nestedBytes)
    }
}

extension Int: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .int(Int64(self))
    }

    public static func fromTuple(element: TupleElement?) -> Int? {
        switch element {
        case let .int(i):
            return Int(i)
        default:
            return nil
        }
    }
}

extension Int32: TupleElementConvertible {
    public func tupleElement() -> TupleElement {
        .int(Int64(self))
    }

    public static func fromTuple(element: TupleElement?) -> Int32? {
        switch element {
        case let .int(i):
            return Int32(i)
        default:
            return nil
        }
    }
}

// TODO: Make a TypedTuple so that we don't have to typecast manually.

public func decodeTuple<each T: TupleElementConvertible>(from bytes: FDB.Bytes) throws -> (repeat each T) {
    let t = try Tuple.decode(from: bytes)
    var i = 0
    func _next() -> TupleElement? {
        let e = t[i]
        i += 1
        return e
    }
    let st = (repeat (each T).fromTuple(element: _next())!)
    if i != t.count {
        throw TupleError.invalidDecoding("Left over tuple elements")
    }
    return st
}
