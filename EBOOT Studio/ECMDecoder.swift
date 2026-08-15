//
//  ECMDecoder.swift
//  EBOOT Studio
//
//  Decoder for Neill Corlett's ECM (Error Code Modeler) format.
//  Ported to Swift from unecm.c v1.0 (GPLv2), Copyright (C) 2002 Neill Corlett.
//  Handles raw / Mode 1 / Mode 2 Form 1 / Mode 2 Form 2 sectors and
//  reconstructs the stripped EDC + P/Q parity bytes.
//

import Foundation

enum ECMDecoder {
    static let magic: [UInt8] = [0x45, 0x43, 0x4D, 0x00] // "ECM\0"
    private static let outputBufferSize = 4 * 1024 * 1024

    // Decodes an .ecm file to `outputURL`. Reports progress in [0, 1].
    static func decode(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        // Memory-map the ECM input so index-based access is cheap.
        let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let inSize = inputData.count
        guard inSize > 8 else { throw ECMError.emptyInput }

        // Verify magic.
        guard inputData[0] == magic[0], inputData[1] == magic[1],
              inputData[2] == magic[2], inputData[3] == magic[3] else {
            throw ECMError.badMagic
        }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL) else {
            throw ECMError.cannotOpenOutput
        }
        defer { try? output.close() }

        var eccF = [UInt8](repeating: 0, count: 256)
        var eccB = [UInt8](repeating: 0, count: 256)
        var edcLut = [UInt32](repeating: 0, count: 256)
        initLUTs(eccF: &eccF, eccB: &eccB, edcLut: &edcLut)

        var checkEDC: UInt32 = 0
        var sector = [UInt8](repeating: 0, count: 2352)
        var cursor = 4
        var outBuffer = [UInt8]()
        outBuffer.reserveCapacity(outputBufferSize)
        var lastReported: Double = -1

        inputData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = raw   // silence unused warning in case body doesn't reference it
        }

        outer: while true {
            guard cursor < inSize else { throw ECMError.unexpectedEOF }
            var c = Int(inputData[cursor]); cursor += 1
            var bits = 5
            let type = c & 0x03
            var num = UInt64((c >> 2) & 0x1F)
            while (c & 0x80) != 0 {
                guard cursor < inSize else { throw ECMError.unexpectedEOF }
                c = Int(inputData[cursor]); cursor += 1
                num |= UInt64(c & 0x7F) << bits
                bits += 7
            }
            if num == 0xFFFFFFFF { break outer }
            num += 1
            if num >= 0x80000000 { throw ECMError.corrupt }

            switch type {
            case 0:
                var remaining = Int(num)
                while remaining > 0 {
                    let chunk = min(2352, remaining)
                    guard cursor + chunk <= inSize else { throw ECMError.unexpectedEOF }
                    for i in 0..<chunk { sector[i] = inputData[cursor + i] }
                    cursor += chunk
                    checkEDC = partialEDC(checkEDC, bytes: sector, count: chunk, lut: edcLut)
                    outBuffer.append(contentsOf: sector[0..<chunk])
                    remaining -= chunk
                    try flushIfNeeded(&outBuffer, to: output)
                }
            case 1:
                for _ in 0..<num {
                    zeroSector(&sector)
                    for i in 1...10 { sector[i] = 0xFF }
                    sector[0x0F] = 0x01
                    guard cursor + 3 + 0x800 <= inSize else { throw ECMError.unexpectedEOF }
                    sector[0x0C] = inputData[cursor]
                    sector[0x0D] = inputData[cursor + 1]
                    sector[0x0E] = inputData[cursor + 2]
                    cursor += 3
                    for i in 0..<0x800 { sector[0x10 + i] = inputData[cursor + i] }
                    cursor += 0x800
                    generateECCEDC(sector: &sector, type: 1, eccF: eccF, eccB: eccB, edcLut: edcLut)
                    checkEDC = partialEDC(checkEDC, bytes: sector, count: 2352, lut: edcLut)
                    outBuffer.append(contentsOf: sector)
                    try flushIfNeeded(&outBuffer, to: output)
                }
            case 2:
                for _ in 0..<num {
                    zeroSector(&sector)
                    for i in 1...10 { sector[i] = 0xFF }
                    sector[0x0F] = 0x02
                    guard cursor + 0x804 <= inSize else { throw ECMError.unexpectedEOF }
                    for i in 0..<0x804 { sector[0x14 + i] = inputData[cursor + i] }
                    cursor += 0x804
                    sector[0x10] = sector[0x14]; sector[0x11] = sector[0x15]
                    sector[0x12] = sector[0x16]; sector[0x13] = sector[0x17]
                    generateECCEDC(sector: &sector, type: 2, eccF: eccF, eccB: eccB, edcLut: edcLut)
                    checkEDC = partialEDC(checkEDC, bytes: sector, count: 2336, startingAt: 0x10, lut: edcLut)
                    outBuffer.append(contentsOf: sector[0x10..<(0x10 + 2336)])
                    try flushIfNeeded(&outBuffer, to: output)
                }
            case 3:
                for _ in 0..<num {
                    zeroSector(&sector)
                    for i in 1...10 { sector[i] = 0xFF }
                    sector[0x0F] = 0x02
                    guard cursor + 0x918 <= inSize else { throw ECMError.unexpectedEOF }
                    for i in 0..<0x918 { sector[0x14 + i] = inputData[cursor + i] }
                    cursor += 0x918
                    sector[0x10] = sector[0x14]; sector[0x11] = sector[0x15]
                    sector[0x12] = sector[0x16]; sector[0x13] = sector[0x17]
                    generateECCEDC(sector: &sector, type: 3, eccF: eccF, eccB: eccB, edcLut: edcLut)
                    checkEDC = partialEDC(checkEDC, bytes: sector, count: 2336, startingAt: 0x10, lut: edcLut)
                    outBuffer.append(contentsOf: sector[0x10..<(0x10 + 2336)])
                    try flushIfNeeded(&outBuffer, to: output)
                }
            default:
                throw ECMError.corrupt
            }

            let pos = Double(cursor) / Double(inSize)
            if pos - lastReported >= 0.005 {
                lastReported = pos
                progress(min(pos, 0.999))
            }
        }

        // Flush any remaining output.
        if !outBuffer.isEmpty {
            output.write(Data(outBuffer))
            outBuffer.removeAll(keepingCapacity: true)
        }

        // Trailer: 4 bytes EDC of the reconstructed stream.
        guard cursor + 4 <= inSize else { throw ECMError.unexpectedEOF }
        let recorded = UInt32(inputData[cursor]) | (UInt32(inputData[cursor + 1]) << 8)
            | (UInt32(inputData[cursor + 2]) << 16) | (UInt32(inputData[cursor + 3]) << 24)
        if recorded != checkEDC {
            throw ECMError.edcMismatch(expected: recorded, got: checkEDC)
        }
        progress(1.0)
    }

    // MARK: - Buffered output

    private static func flushIfNeeded(_ buffer: inout [UInt8], to fh: FileHandle) throws {
        if buffer.count >= outputBufferSize {
            fh.write(Data(buffer))
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private static func zeroSector(_ sector: inout [UInt8]) {
        for i in 0..<2352 { sector[i] = 0 }
    }

    // MARK: - EDC / ECC

    private static func initLUTs(eccF: inout [UInt8], eccB: inout [UInt8], edcLut: inout [UInt32]) {
        for i in 0..<256 {
            var j: Int = (i << 1) ^ ((i & 0x80) != 0 ? 0x11D : 0)
            j &= 0xFF
            eccF[i] = UInt8(j)
            eccB[i ^ j] = UInt8(i)
            var edc = UInt32(i)
            for _ in 0..<8 {
                edc = (edc >> 1) ^ ((edc & 1) != 0 ? 0xD8018001 : 0)
            }
            edcLut[i] = edc
        }
    }

    private static func partialEDC(_ initial: UInt32, bytes: [UInt8], count: Int, startingAt: Int = 0, lut: [UInt32]) -> UInt32 {
        var edc = initial
        let end = startingAt + count
        for i in startingAt..<end {
            edc = (edc >> 8) ^ lut[Int((edc ^ UInt32(bytes[i])) & 0xFF)]
        }
        return edc
    }

    private static func edcComputeBlock(sector: inout [UInt8], srcStart: Int, size: Int, destStart: Int, lut: [UInt32]) {
        var edc: UInt32 = 0
        for i in 0..<size {
            edc = (edc >> 8) ^ lut[Int((edc ^ UInt32(sector[srcStart + i])) & 0xFF)]
        }
        sector[destStart + 0] = UInt8(edc & 0xFF)
        sector[destStart + 1] = UInt8((edc >> 8) & 0xFF)
        sector[destStart + 2] = UInt8((edc >> 16) & 0xFF)
        sector[destStart + 3] = UInt8((edc >> 24) & 0xFF)
    }

    private static func eccComputeBlock(
        sector: inout [UInt8],
        srcStart: Int,
        majorCount: Int,
        minorCount: Int,
        majorMult: Int,
        minorInc: Int,
        destStart: Int,
        eccF: [UInt8],
        eccB: [UInt8]
    ) {
        let size = majorCount * minorCount
        for major in 0..<majorCount {
            var index = (major >> 1) * majorMult + (major & 1)
            var eccA: UInt8 = 0
            var eccB0: UInt8 = 0
            for _ in 0..<minorCount {
                let temp = sector[srcStart + index]
                index += minorInc
                if index >= size { index -= size }
                eccA ^= temp
                eccB0 ^= temp
                eccA = eccF[Int(eccA)]
            }
            let out = eccB[Int(eccF[Int(eccA)] ^ eccB0)]
            sector[destStart + major] = out
            sector[destStart + major + majorCount] = out ^ eccB0
        }
    }

    private static func generateECCEDC(
        sector: inout [UInt8],
        type: Int,
        eccF: [UInt8],
        eccB: [UInt8],
        edcLut: [UInt32]
    ) {
        switch type {
        case 1:
            edcComputeBlock(sector: &sector, srcStart: 0x00, size: 0x810, destStart: 0x810, lut: edcLut)
            for i in 0..<8 { sector[0x814 + i] = 0 }
            eccGenerate(sector: &sector, zeroAddress: false, eccF: eccF, eccB: eccB)
        case 2:
            edcComputeBlock(sector: &sector, srcStart: 0x10, size: 0x808, destStart: 0x818, lut: edcLut)
            eccGenerate(sector: &sector, zeroAddress: true, eccF: eccF, eccB: eccB)
        case 3:
            edcComputeBlock(sector: &sector, srcStart: 0x10, size: 0x91C, destStart: 0x92C, lut: edcLut)
        default:
            break
        }
    }

    private static func eccGenerate(sector: inout [UInt8], zeroAddress: Bool, eccF: [UInt8], eccB: [UInt8]) {
        var saved: [UInt8] = [0, 0, 0, 0]
        if zeroAddress {
            for i in 0..<4 {
                saved[i] = sector[12 + i]
                sector[12 + i] = 0
            }
        }
        eccComputeBlock(sector: &sector, srcStart: 0x0C, majorCount: 86, minorCount: 24, majorMult: 2, minorInc: 86, destStart: 0x81C, eccF: eccF, eccB: eccB)
        eccComputeBlock(sector: &sector, srcStart: 0x0C, majorCount: 52, minorCount: 43, majorMult: 86, minorInc: 88, destStart: 0x8C8, eccF: eccF, eccB: eccB)
        if zeroAddress {
            for i in 0..<4 { sector[12 + i] = saved[i] }
        }
    }
}

enum ECMError: LocalizedError {
    case emptyInput
    case cannotOpenOutput
    case badMagic
    case unexpectedEOF
    case corrupt
    case edcMismatch(expected: UInt32, got: UInt32)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "ECM input is empty."
        case .cannotOpenOutput: return "Could not create the decompressed output file."
        case .badMagic: return "Not a valid ECM file (missing magic bytes)."
        case .unexpectedEOF: return "ECM file ended unexpectedly."
        case .corrupt: return "ECM file appears corrupt."
        case .edcMismatch(let e, let g):
            return String(format: "ECM EDC check failed (expected %08x, got %08x).", e, g)
        }
    }
}
