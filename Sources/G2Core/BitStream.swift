// BitStream.swift
// Bit-level reader/writer for Nord G2 binary patch format (.pch2)
// Ported from g2ools/nord/g2/bits.py (Matt Gerassimoff, GPL)

import Foundation

/// Reads and writes individual bits from a byte buffer.
/// The G2 .pch2 format packs data at bit granularity — fields
/// can be 1, 5, 6, 7, 8, 14 bits wide, not aligned to bytes.
public struct BitStream {
    private var data: [UInt8]
    private var bitPos: Int // current position in bits

    public init(data: [UInt8], startBit: Int = 0) {
        self.data = data
        self.bitPos = startBit
    }

    public var currentBitPosition: Int {
        bitPos
    }

    // MARK: - Reading

    /// Read `count` bits and return as UInt32 (MSB first).
    /// Matches g2ools getbits() behavior: reads a 32-bit word aligned to the
    /// starting byte, so bits slightly past the end of the buffer read as 0.
    public mutating func readBits(_ count: Int) throws -> UInt32 {
        guard count > 0, count <= 32 else {
            throw BitStreamError.invalidBitCount(count)
        }
        // Read 4 bytes starting at the byte containing bitPos, padding with 0
        let startByte = bitPos / 8
        var word: UInt32 = 0
        for i in 0 ..< 4 {
            word <<= 8
            if startByte + i < data.count {
                word |= UInt32(data[startByte + i])
            }
            // else: pad with zero (matches g2ools behavior)
        }
        // Extract `count` bits starting at bit offset (bitPos % 8) within the word
        let shift = 32 - (bitPos % 8) - count
        let mask = UInt32((1 << count) - 1)
        let result = (word >> shift) & mask
        bitPos += count
        return result
    }

    /// Przesuwa pozycję bez czytania — używane przy nadpisywaniu sekcji w miejscu:
    /// pola, których nie modelujemy, są przeskakiwane, żeby te modelowane trafiły
    /// dokładnie na bity, które zajmowały wcześniej.
    public mutating func skip(_ count: Int) {
        bitPos += count
    }

    /// Read a null-terminated (or fixed-length) ASCII string.
    public mutating func readString(length: Int) throws -> String {
        var bytes = [UInt8]()
        for _ in 0 ..< length {
            let byte = try UInt8(readBits(8))
            if byte == 0 { break }
            bytes.append(byte)
        }
        // consume remaining bytes if string was shorter than length
        let remaining = length - bytes.count - 1
        if remaining > 0 {
            bitPos += remaining * 8
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Czyta null-terminated ASCII string, max maxChars znaków (format G2 module labels).
    /// Zgodny z BVerhue ReadName i pch2csd read_null_term_str:
    /// - czyta bajty aż do \0 (który jest konsumowany) lub do maxChars (bez konsumowania \0)
    /// - NIE paduje do stałej długości — zmienna liczba bajtów w strumieniu
    public mutating func readNullTermString(maxChars: Int) throws -> String {
        var bytes = [UInt8]()
        while bytes.count < maxChars {
            let byte = try UInt8(readBits(8))
            if byte == 0 { break } // \0 skonsumowany, pętla kończy się
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    // MARK: - Writing

    /// Write `count` low-order bits of `value` (MSB first).
    public mutating func writeBits(_ count: Int, value: UInt32) throws {
        guard count > 0, count <= 32 else {
            throw BitStreamError.invalidBitCount(count)
        }
        // Grow buffer if needed
        let neededBytes = (bitPos + count + 7) / 8
        while data.count < neededBytes {
            data.append(0)
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            let bit = (value >> i) & 1
            let byteIndex = bitPos / 8
            let bitIndex = 7 - (bitPos % 8)
            if bit == 1 {
                data[byteIndex] |= (1 << bitIndex)
            } else {
                data[byteIndex] &= ~(1 << bitIndex)
            }
            bitPos += 1
        }
    }

    public func toBytes() -> [UInt8] {
        data
    }
}

public enum BitStreamError: Error, CustomStringConvertible {
    case invalidBitCount(Int)
    case outOfBounds(Int, Int, Int)

    public var description: String {
        switch self {
        case let .invalidBitCount(n):
            "Invalid bit count: \(n) (must be 1–32)"
        case let .outOfBounds(pos, count, total):
            "Out of bounds: reading \(count) bits at \(pos), buffer has \(total) bits"
        }
    }
}
