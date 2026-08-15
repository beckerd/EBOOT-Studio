//
//  PSXConverter.swift
//  EBOOT Studio
//
//  PSX BIN/CUE -> PSP EBOOT.PBP converter.
//  Ported from pop-fe/popstation.py (Ronnie Sahlberg, LGPLv2.1). Supports
//  multi-disc EBOOTs (up to 5 discs) and LibCrypt subchannel injection.
//  Audio tracks (CDDA) and magic-word hotfixes are not yet implemented.
//

import Foundation
import Compression
import CryptoKit

struct PSXConversionOptions {
    struct Disc {
        // One or more .bin/.img files. When multiple are provided (for
        // multi-track PSX rips split into per-track BINs), they are streamed
        // in the given order and treated as one contiguous disc image.
        var imageURLs: [URL]
        var discID: String     // e.g. "SLUS00000"
        // Optional pre-built TOC (e.g. from a .ccd). If nil, a fake single-track
        // TOC is generated from the image size.
        var toc: Data? = nil
        // Optional subchannel blob (12 bytes per sector, Q subchannel).
        // If a raw CloneCD .sub was supplied, this must be pre-extracted.
        var subchannel: Data? = nil
    }

    var discs: [Disc]          // 1..5 discs; first disc's ID is the game ID
    var outputURL: URL         // where to write EBOOT.PBP
    var gameTitle: String
    var icon0PNG: Data?        // 144x80 recommended
    var pic0PNG: Data?         // 310x180 recommended
    var pic1PNG: Data?         // 480x272 recommended
    // Optional replacement for the POPS boot splash shown at launch.
    // Must fit within the stock logo slot; it is zero-padded to that size.
    var bootLogoPNG: Data? = nil
}

enum PSXConverter {
    static let blockSize = 0x9300 // 16 sectors * 2352 bytes
    static let psarAlign = 0x10000
    static let psisoAlign = 0x8000
    static let psarLeadInReserved = 0x100000

    // Progress: 0.0 ... 1.0
    static func convert(
        options: PSXConversionOptions,
        progress: @escaping (Double, String) -> Void
    ) throws {
        progress(0.0, "Preparing…")
        guard !options.discs.isEmpty else { throw PSXConversionError.noDiscs }
        guard options.discs.count <= 5 else { throw PSXConversionError.tooManyDiscs }

        // 0) Any .ecm inputs need to be decompressed to a temp file first.
        var effectiveDiscs = options.discs
        var tempFilesToDelete: [URL] = []
        defer {
            for url in tempFilesToDelete { try? FileManager.default.removeItem(at: url) }
        }
        // ECM decompression gets 40% of the overall progress bar (0.00 → 0.40)
        // divided evenly across ECM files (across all discs).
        var ecmToDecode: [(discIndex: Int, urlIndex: Int)] = []
        for (di, d) in effectiveDiscs.enumerated() {
            for (ui, u) in d.imageURLs.enumerated() where u.pathExtension.lowercased() == "ecm" {
                ecmToDecode.append((di, ui))
            }
        }
        let ecmShare = ecmToDecode.isEmpty ? 0.0 : 0.40 / Double(ecmToDecode.count)
        for (order, ref) in ecmToDecode.enumerated() {
            let src = effectiveDiscs[ref.discIndex].imageURLs[ref.urlIndex]
            let baseProgress = Double(order) * ecmShare
            let discLabel = options.discs.count == 1 ? "Decompressing ECM" : "Decompressing ECM (disc \(ref.discIndex + 1))"
            progress(baseProgress, "\(discLabel) 0%")
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("psxswap-\(UUID().uuidString).bin")
            try ECMDecoder.decode(inputURL: src, outputURL: tmp) { p in
                let pct = Int((p * 100).rounded())
                progress(baseProgress + p * ecmShare, "\(discLabel) \(pct)%")
            }
            effectiveDiscs[ref.discIndex].imageURLs[ref.urlIndex] = tmp
            tempFilesToDelete.append(tmp)
        }

        // 1) Build PARAM.SFO using the first disc's ID as the game ID.
        let sfo = buildSFO(title: options.gameTitle, discID: effectiveDiscs[0].discID)

        // 2) Open output file (truncate).
        FileManager.default.createFile(atPath: options.outputURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: options.outputURL) else {
            throw PSXConversionError.cannotWriteOutput
        }
        defer { try? out.close() }

        // 3) Compute PBP header offsets.
        var curOffset: UInt32 = 0x28
        var offsets = [UInt32](repeating: 0, count: 8)
        offsets[0] = curOffset                            // PARAM.SFO
        curOffset += UInt32(sfo.count)
        offsets[1] = curOffset                            // ICON0.PNG
        curOffset += UInt32(options.icon0PNG?.count ?? 0)
        offsets[2] = curOffset                            // ICON1.PMF (empty)
        // ICON1 empty
        offsets[3] = curOffset                            // PIC0.PNG
        curOffset += UInt32(options.pic0PNG?.count ?? 0)
        offsets[4] = curOffset                            // PIC1.PNG
        curOffset += UInt32(options.pic1PNG?.count ?? 0)
        offsets[5] = curOffset                            // SND0.AT3 (empty)
        offsets[6] = curOffset                            // DATA.PSP

        // pop-fe reserves 30632 bytes for DATA.PSP even though the embedded
        // stub is smaller; the tail is left as implicit zero-fill.
        let reservedDataPSP: UInt32 = 30632
        var psarStart = curOffset + reservedDataPSP
        if psarStart % UInt32(psarAlign) != 0 {
            psarStart += UInt32(psarAlign) - (psarStart % UInt32(psarAlign))
        }
        offsets[7] = psarStart                            // DATA.PSAR

        // Write PBP header.
        var header = Data(count: 0x28)
        header.replaceSubrange(0..<4, with: [0x00, 0x50, 0x42, 0x50]) // "\0PBP"
        writeUInt32LE(&header, at: 4, 0x10000)
        for i in 0..<8 {
            writeUInt32LE(&header, at: 8 + i * 4, offsets[i])
        }
        out.write(header)

        progress(0.02, "Writing header…")

        // 4) Write PARAM.SFO + images (or nothing) in the exact declared order.
        out.write(sfo)
        if let d = options.icon0PNG { out.write(d) }
        // icon1 empty
        if let d = options.pic0PNG { out.write(d) }
        if let d = options.pic1PNG { out.write(d) }
        // snd0 empty

        // 5) DATA.PSP body. Extend with zero fill to the reserved size.
        out.write(PopstationBlobs.dataPSPBody)
        let bodyLen = UInt32(PopstationBlobs.dataPSPBody.count)
        let pspEnd = offsets[6] + reservedDataPSP
        if bodyLen < reservedDataPSP {
            out.write(Data(count: Int(reservedDataPSP - bodyLen)))
        }
        // Pad to PSAR alignment.
        if pspEnd < psarStart {
            out.write(Data(count: Int(psarStart - pspEnd)))
        }

        // 6) PSTITLE placeholder at PSAR start. Re-written at the end with the
        // final STARTDAT offset and game metadata.
        var psTitle = Data(PopstationBlobs.psTitleData)
        out.write(psTitle)

        // Compression phase spans from (after ECM) to 95% of the bar.
        let compressionStart = ecmToDecode.isEmpty ? 0.05 : 0.40
        let compressionTotal = 0.95 - compressionStart
        progress(compressionStart, "Compressing disc image 0%")

        // 7) For each disc: align to 0x8000, record offset in PSTITLE, encode PSISO.
        let discCount = effectiveDiscs.count
        var psisoOffsets: [UInt64] = []
        for (discIndex, disc) in effectiveDiscs.enumerated() {
            try alignFile(out, to: psisoAlign)
            let psisoOffset = out.offsetInFile
            psisoOffsets.append(psisoOffset)
            writeUInt32LE(&psTitle, at: 0x200 + discIndex * 4, UInt32(psisoOffset - UInt64(psarStart)))

            let discShare = compressionTotal / Double(discCount)
            let baseFraction = compressionStart + discShare * Double(discIndex)
            let label = discCount == 1 ? "Compressing disc image" : "Compressing disc \(discIndex + 1) of \(discCount)"
            try encodePSISO(
                imageURLs: disc.imageURLs,
                discID: disc.discID,
                title: options.gameTitle,
                providedTOC: disc.toc,
                providedSubchannel: disc.subchannel,
                out: out,
                psisoOffset: psisoOffset,
                progress: { p, msg in
                    let pct = Int((p * 100).rounded())
                    let statusBase = msg.isEmpty ? label : msg
                    progress(baseFraction + p * discShare, "\(statusBase) \(pct)%")
                }
            )
            try alignFile(out, to: 16)
        }

        // 8) Align, then write STARTDAT.
        try alignFile(out, to: 16)
        let startDatOffset = out.offsetInFile

        // Patch PSTITLE with final values.
        psTitle.replaceSubrange(0..<16, with: "PSTITLEIMG000000".data(using: .ascii)!)
        writeUInt32LE(&psTitle, at: 0x10, UInt32(startDatOffset - UInt64(psarStart)))
        writeUInt32LE(&psTitle, at: 0x284, UInt32(startDatOffset - UInt64(psarStart) + 0x2d31))
        // Disc ID at 0x264 as "_SLUS_00000" (11 ASCII bytes, no dot).
        let gid = normalizedDiscID(effectiveDiscs[0].discID)
        let idBytes = psisoDiscIDBytes(gid)
        for (i, b) in idBytes.enumerated() where 0x264 + i < psTitle.count {
            psTitle[0x264 + i] = b
        }
        // Title at 0x30c.
        let titleBytes = Array(options.gameTitle.utf8.prefix(128))
        for (i, b) in titleBytes.enumerated() where 0x30c + i < psTitle.count {
            psTitle[0x30c + i] = b
        }

        try out.seek(toOffset: UInt64(psarStart))
        out.write(psTitle)

        try out.seek(toOffset: startDatOffset)
        // A custom boot screen is zero-padded into the stock logo slot so the
        // STARTDAT layout (and every offset derived from it) stays unchanged.
        var logo = PopstationBlobs.logoBuffer
        if let png = options.bootLogoPNG {
            guard png.count <= logo.count else { throw PSXConversionError.bootScreenTooLarge }
            logo = png + Data(count: logo.count - png.count)
        }
        // STARTDAT header: patch offset 20 with logo length.
        var startDat = Data(PopstationBlobs.startDatHeader)
        writeUInt32LE(&startDat, at: 20, UInt32(logo.count))
        out.write(startDat)
        out.write(logo)
        out.write(PopstationBlobs.startDatFooter)

        progress(1.0, "Done")
    }

    // MARK: - PSISO encoding

    private static func encodePSISO(
        imageURLs: [URL],
        discID: String,
        title: String,
        providedTOC: Data?,
        providedSubchannel: Data?,
        out: FileHandle,
        psisoOffset: UInt64,
        progress: (Double, String) -> Void
    ) throws {
        guard !imageURLs.isEmpty else { throw PSXConversionError.emptyImage }
        var fileSize: UInt64 = 0
        for u in imageURLs {
            let s = (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.uint64Value ?? 0
            fileSize += s
        }
        guard fileSize > 0 else { throw PSXConversionError.emptyImage }

        // Round isosize up to blockSize.
        var isoSize = fileSize
        if isoSize % UInt64(blockSize) != 0 {
            isoSize += UInt64(blockSize) - (isoSize % UInt64(blockSize))
        }

        // Block #1: PSISOIMG0000 header. Length filled in later.
        var block1 = Data(count: 1024)
        block1.replaceSubrange(0..<12, with: "PSISOIMG0000".data(using: .ascii)!)
        writeUInt32LE(&block1, at: 12, UInt32(isoSize + UInt64(psarLeadInReserved)))
        out.write(block1)

        // Block #2: disc ID as "_SLUS_00000" (11 ASCII bytes, no dot).
        var block2 = Data(count: 1024)
        let gid = normalizedDiscID(discID)
        let idBytes = psisoDiscIDBytes(gid)
        block2.replaceSubrange(0..<idBytes.count, with: idBytes)
        out.write(block2)

        // Block #3: TOC. Use a provided TOC (from CCD/etc) if available,
        // otherwise fall back to a fake single-track TOC.
        var block3 = Data(count: 1024)
        let toc = providedTOC ?? basicTOC(isoSize: isoSize)
        let tocLen = min(toc.count, block3.count - 4)  // leave room for the disc-offset u32
        block3.replaceSubrange(0..<tocLen, with: toc.prefix(tocLen))
        writeUInt32LE(&block3, at: 0x3fc, UInt32(psarLeadInReserved))
        out.write(block3)

        // Block #4: audio track table (empty).
        let attOffset = out.offsetInFile
        out.write(Data(count: 1568))

        // Block #5: P2 block (game title + magic word).
        let p2Offset = out.offsetInFile
        var block5 = Data(count: 480)
        block5[8] = 0xff
        block5[9] = 0x07
        if let t = title.data(using: .utf8) {
            block5.replaceSubrange(12..<12 + min(t.count, block5.count - 12), with: t.prefix(block5.count - 12))
        }
        out.write(block5)

        // Blocks 6..16 padding.
        out.write(Data(count: 11264))

        // Reserve index table area (32 bytes per compressed block).
        let indexOffset = out.offsetInFile
        let blockCount = Int(isoSize / UInt64(blockSize))
        out.write(Data(count: blockCount * 32))

        // Optional subchannel injection. Popstation expects a 12-byte-per-sector
        // Q-subchannel blob to live BEFORE the disc data at psisoOffset+0x100000.
        // Full-disc subchannel dumps (~1-2MB) don't fit — pop-fe uses this slot
        // for tiny LibCrypt sector-pair blobs (a few hundred bytes). Skip if the
        // supplied SUB would overflow the pre-disc region.
        if let sub = providedSubchannel, !sub.isEmpty {
            let subFileOffset = out.offsetInFile
            let subEndOffset = subFileOffset + UInt64(sub.count)
            let discStart = psisoOffset + UInt64(psarLeadInReserved)
            if subEndOffset <= discStart {
                var header = Data(count: 8)
                writeUInt32LE(&header, at: 0, UInt32(subFileOffset - psisoOffset))
                writeUInt32LE(&header, at: 4, UInt32(sub.count / 12))
                try out.seek(toOffset: psisoOffset + 0x12d4)
                out.write(header)
                try out.seek(toOffset: subFileOffset)
                out.write(sub)
            }
        }

        // Pad to psisoOffset + 0x100000 (the disc image starts 1 MB into PSAR).
        let currentOffset = out.offsetInFile
        let discStart = psisoOffset + UInt64(psarLeadInReserved)
        if currentOffset < discStart {
            out.write(Data(count: Int(discStart - currentOffset)))
        }

        // Stream one or more BINs sequentially and compress each block. Reads
        // that span a file boundary continue into the next BIN in order.
        var inputs: [FileHandle] = []
        for u in imageURLs {
            guard let fh = try? FileHandle(forReadingFrom: u) else {
                throw PSXConversionError.cannotReadImage
            }
            inputs.append(fh)
        }
        defer { for fh in inputs { try? fh.close() } }
        var inputIndex = 0

        var indexes = Data(capacity: blockCount * 32)
        var relativeOffset: UInt32 = 0
        var readBytes: UInt64 = 0
        var blocksDone = 0

        while readBytes < fileSize {
            var buf = Data(capacity: blockSize)
            while buf.count < blockSize && inputIndex < inputs.count {
                let need = blockSize - buf.count
                let chunk = inputs[inputIndex].readData(ofLength: need)
                if chunk.isEmpty {
                    inputIndex += 1
                } else {
                    buf.append(chunk)
                }
            }
            if buf.count < blockSize {
                buf.append(Data(count: blockSize - buf.count))
            }
            readBytes += UInt64(buf.count)

            let compressed = rawDeflate(buf) ?? buf

            var idx = Data(count: 32)
            writeUInt32LE(&idx, at: 0, relativeOffset)

            // SHA-1 of the *uncompressed* block, first 16 bytes.
            let hash = Insecure.SHA1.hash(data: buf)
            let hashBytes = Array(hash).prefix(16)
            for (i, b) in hashBytes.enumerated() { idx[8 + i] = b }

            if compressed.count >= blockSize {
                writeUInt16LE(&idx, at: 4, UInt16(blockSize))
                out.write(buf)
                relativeOffset &+= UInt32(blockSize)
            } else {
                writeUInt16LE(&idx, at: 4, UInt16(compressed.count))
                out.write(compressed)
                relativeOffset &+= UInt32(compressed.count)
            }
            indexes.append(idx)
            blocksDone += 1

            if blocksDone % 32 == 0 {
                progress(Double(readBytes) / Double(fileSize), "Compressing \(blocksDone)/\(blockCount) blocks…")
            }
        }

        // Align to 16 bytes at end of PSISO section.
        try alignFile(out, to: 16)
        let endOffset = out.offsetInFile - psisoOffset
        let afterEnd = out.offsetInFile

        // Write compressed-block index table.
        try out.seek(toOffset: indexOffset)
        out.write(indexes)

        // Update the PSISOIMG length at psisoOffset + 12.
        var lenBuf = Data(count: 4)
        writeUInt32LE(&lenBuf, at: 0, UInt32(endOffset))
        try out.seek(toOffset: psisoOffset + 12)
        out.write(lenBuf)

        // Update the length at p2Offset (endOffset + 0x2d31).
        var p2Buf = Data(count: 4)
        writeUInt32LE(&p2Buf, at: 0, UInt32(endOffset + 0x2d31))
        try out.seek(toOffset: p2Offset)
        out.write(p2Buf)

        // Audio track table stays empty for now.
        _ = attOffset

        try out.seek(toOffset: afterEnd)
    }

    // MARK: - Helpers

    private static func basicTOC(isoSize: UInt64) -> Data {
        var toc = Data(PopstationBlobs.basicTOC)
        // Size of image plus 2 seconds pre-gap.
        let sectors = (isoSize + 352800) / 2352
        let frames = Int(sectors % 75)
        let secondsTotal = sectors / 75
        let secs = Int(secondsTotal % 60)
        let mins = Int(secondsTotal / 60)
        toc[29] = bcd(frames)
        toc[28] = bcd(secs)
        toc[27] = bcd(mins)
        return toc
    }

    private static func bcd(_ i: Int) -> UInt8 {
        return UInt8(i % 10) + 16 * UInt8((i / 10) % 10)
    }

    private static func alignFile(_ fh: FileHandle, to alignment: Int) throws {
        let pos = fh.offsetInFile
        let aligned = (pos + UInt64(alignment - 1)) & ~UInt64(alignment - 1)
        if aligned > pos {
            fh.write(Data(count: Int(aligned - pos)))
        }
    }

    private static func writeUInt16LE(_ data: inout Data, at offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func writeUInt32LE(_ data: inout Data, at offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    // Raw DEFLATE (RFC 1951), matching Python's zlib.compress(buf, 1)[2:-4].
    private static func rawDeflate(_ input: Data) -> Data? {
        let scratchSize = input.count + 1024
        var scratch = Data(count: scratchSize)
        let produced = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            scratch.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                guard let srcPtr = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dstPtr = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_encode_buffer(dstPtr, scratchSize, srcPtr, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { return nil }
        return scratch.prefix(produced)
    }

    // "SLUS00000" -> "_SLUS_00000" (11 ASCII bytes, no dot). Matches the
    // encoding pop-fe writes into both PSISO Block #2 and PSTITLE at 0x264.
    private static func psisoDiscIDBytes(_ gid: String) -> [UInt8] {
        var out: [UInt8] = []
        out.append(0x5F) // _
        out.append(contentsOf: Array(gid.utf8.prefix(4)))
        out.append(0x5F) // _
        out.append(contentsOf: Array(gid.utf8.dropFirst(4).prefix(5)))
        // Pad to 11 in case the input was shorter.
        while out.count < 11 { out.append(0x30) } // '0'
        return Array(out.prefix(11))
    }

    private static func normalizedDiscID(_ raw: String) -> String {
        // Strip non-alphanumeric to get 9-char form "SLUS00000".
        let filtered = raw.filter { $0.isLetter || $0.isNumber }.uppercased()
        if filtered.count >= 9 { return String(filtered.prefix(9)) }
        return filtered.padding(toLength: 9, withPad: "0", startingAt: 0)
    }

    // MARK: - SFO builder

    private static func buildSFO(title: String, discID: String) -> Data {
        // Recreate the entry set pop-fe writes.
        var sfo = ParamSFO(version: 0x00000101, entries: [
            ParamSFO.Entry(key: "BOOTABLE", format: ParamSFO.formatInt32,
                           data: uint32LE(1), maxLength: 4),
            ParamSFO.Entry(key: "CATEGORY", format: ParamSFO.formatUTF8,
                           data: nullTerm("ME"), maxLength: 4),
            ParamSFO.Entry(key: "DISC_ID", format: ParamSFO.formatUTF8,
                           data: nullTerm(normalizedDiscID(discID)), maxLength: 16),
            ParamSFO.Entry(key: "DISC_VERSION", format: ParamSFO.formatUTF8,
                           data: nullTerm("1.00"), maxLength: 8),
            ParamSFO.Entry(key: "LICENSE", format: ParamSFO.formatUTF8,
                           data: nullTerm("Copyright(C) Sony Computer Entertainment America Inc."),
                           maxLength: 512),
            ParamSFO.Entry(key: "PARENTAL_LEVEL", format: ParamSFO.formatInt32,
                           data: uint32LE(3), maxLength: 4),
            ParamSFO.Entry(key: "PSP_SYSTEM_VER", format: ParamSFO.formatUTF8,
                           data: nullTerm("3.01"), maxLength: 8),
            ParamSFO.Entry(key: "REGION", format: ParamSFO.formatInt32,
                           data: uint32LE(32768), maxLength: 4),
            ParamSFO.Entry(key: "TITLE", format: ParamSFO.formatUTF8,
                           data: nullTerm(title), maxLength: 128),
        ])
        // Ensure TITLE fits in 128 padded bytes; ParamSFO.setString would grow if needed.
        sfo.setString(title, forKey: "TITLE")
        sfo.setString(normalizedDiscID(discID), forKey: "DISC_ID")
        return sfo.serialize()
    }

    private static func nullTerm(_ s: String) -> Data {
        var d = s.data(using: .utf8) ?? Data()
        d.append(0)
        return d
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var d = Data(count: 4)
        writeUInt32LE(&d, at: 0, v)
        return d
    }
}

enum PSXConversionError: LocalizedError {
    case cannotWriteOutput
    case cannotReadImage
    case emptyImage
    case noDiscs
    case tooManyDiscs
    case bootScreenTooLarge

    var errorDescription: String? {
        switch self {
        case .cannotWriteOutput: return "Could not open the output file for writing."
        case .cannotReadImage: return "Could not read the source disc image."
        case .emptyImage: return "The disc image is empty."
        case .noDiscs: return "No discs were provided."
        case .tooManyDiscs: return "Only up to 5 discs are supported."
        case .bootScreenTooLarge: return "The boot screen image is too large for the logo slot."
        }
    }
}
