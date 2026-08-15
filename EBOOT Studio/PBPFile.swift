//
//  PBPFile.swift
//  EBOOT Studio
//

import Foundation

// PBP container used by PSP EBOOT files. The header is 40 bytes: a 4-byte magic
// "\0PBP", a 4-byte version, followed by eight little-endian UInt32 offsets to
// each named section. Empty sections have zero size (their offset equals the
// next section's offset, or EOF for the last one).
struct PBPFile: Equatable {
    static let magic = Data([0x00, 0x50, 0x42, 0x50])
    static let headerSize = 0x28
    static let sectionNames = [
        "PARAM.SFO",
        "ICON0.PNG",
        "ICON1.PMF",
        "PIC0.PNG",
        "PIC1.PNG",
        "SND0.AT3",
        "DATA.PSP",
        "DATA.PSAR",
    ]

    var version: UInt32
    var sections: [String: Data]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard data.count >= PBPFile.headerSize else {
            throw PBPError.invalidHeader("File is too small to be a PBP.")
        }
        guard data.prefix(4) == PBPFile.magic else {
            throw PBPError.invalidHeader("File does not start with PBP magic bytes.")
        }

        self.version = data.readUInt32LE(at: 4)

        var offsets: [Int] = []
        offsets.reserveCapacity(8)
        for i in 0..<8 {
            offsets.append(Int(data.readUInt32LE(at: 8 + i * 4)))
        }

        var parsed: [String: Data] = [:]
        for i in 0..<8 {
            let start = offsets[i]
            let end = i < 7 ? offsets[i + 1] : data.count
            if start >= 0, start <= end, end <= data.count, end > start {
                let range = data.startIndex.advanced(by: start)..<data.startIndex.advanced(by: end)
                parsed[PBPFile.sectionNames[i]] = data.subdata(in: range)
            } else {
                parsed[PBPFile.sectionNames[i]] = Data()
            }
        }
        self.sections = parsed
    }

    func serialize() -> Data {
        var output = Data()
        output.reserveCapacity(PBPFile.headerSize + sections.values.reduce(0) { $0 + $1.count })

        output.append(PBPFile.magic)
        output.appendUInt32LE(version)

        var current = UInt32(PBPFile.headerSize)
        for name in PBPFile.sectionNames {
            output.appendUInt32LE(current)
            current += UInt32(sections[name]?.count ?? 0)
        }

        for name in PBPFile.sectionNames {
            if let data = sections[name] {
                output.append(data)
            }
        }

        return output
    }
}

enum PBPError: LocalizedError {
    case invalidHeader(String)
    case notAPNG
    case dimensionMismatch(expectedWidth: Int, expectedHeight: Int, gotWidth: Int, gotHeight: Int)

    var errorDescription: String? {
        switch self {
        case .invalidHeader(let message):
            return message
        case .notAPNG:
            return "The dropped file is not a PNG image."
        case .dimensionMismatch(let ew, let eh, let gw, let gh):
            return "Replacement image must be \(ew)×\(eh) pixels, but this one is \(gw)×\(gh)."
        }
    }
}

// PNG header parsing: signature is 8 bytes, followed by the IHDR chunk that
// stores width and height as big-endian UInt32 at bytes 16 and 20.
enum PNGInspector {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func isPNG(_ data: Data) -> Bool {
        return data.count >= 8 && data.prefix(8) == signature
    }

    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, isPNG(data) else { return nil }
        let width = data.readUInt32BE(at: 16)
        let height = data.readUInt32BE(at: 20)
        return (Int(width), Int(height))
    }
}

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let base = startIndex.advanced(by: offset)
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let base = startIndex.advanced(by: offset)
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let base = startIndex.advanced(by: offset)
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// PARAM.SFO is a small key/value container used by PSP/PS3. Header is 20 bytes:
// magic "\0PSF", version, key-table offset, data-table offset, entry count.
// Each entry in the index table is 16 bytes and points into both tables.
struct ParamSFO: Equatable {
    static let magic = Data([0x00, 0x50, 0x53, 0x46])
    static let headerSize = 20
    static let indexEntrySize = 16

    // Common format codes stored in the index table.
    static let formatUTF8Special: UInt16 = 0x0004  // UTF-8, not null-terminated
    static let formatUTF8: UInt16 = 0x0204         // UTF-8, null-terminated
    static let formatInt32: UInt16 = 0x0404        // little-endian UInt32

    struct Entry: Equatable {
        var key: String
        var format: UInt16
        var data: Data
        var maxLength: Int
    }

    var version: UInt32
    var entries: [Entry]

    init(version: UInt32, entries: [Entry]) {
        self.version = version
        self.entries = entries
    }

    init(data: Data) throws {
        guard data.count >= ParamSFO.headerSize else {
            throw PBPError.invalidHeader("PARAM.SFO is too small.")
        }
        guard data.prefix(4) == ParamSFO.magic else {
            throw PBPError.invalidHeader("PARAM.SFO magic bytes are missing.")
        }

        self.version = data.readUInt32LE(at: 4)
        let keyTableStart = Int(data.readUInt32LE(at: 8))
        let dataTableStart = Int(data.readUInt32LE(at: 12))
        let count = Int(data.readUInt32LE(at: 16))

        var parsed: [Entry] = []
        parsed.reserveCapacity(count)

        for i in 0..<count {
            let indexOffset = ParamSFO.headerSize + i * ParamSFO.indexEntrySize
            guard indexOffset + ParamSFO.indexEntrySize <= data.count else {
                throw PBPError.invalidHeader("PARAM.SFO index table is truncated.")
            }
            let keyOffset = Int(data.readUInt16LE(at: indexOffset))
            let format = data.readUInt16LE(at: indexOffset + 2)
            let dataLen = Int(data.readUInt32LE(at: indexOffset + 4))
            let dataMaxLen = Int(data.readUInt32LE(at: indexOffset + 8))
            let dataOffset = Int(data.readUInt32LE(at: indexOffset + 12))

            let keyAbsolute = keyTableStart + keyOffset
            guard keyAbsolute < data.count else {
                throw PBPError.invalidHeader("PARAM.SFO key offset out of bounds.")
            }
            var keyBytes: [UInt8] = []
            var idx = data.startIndex.advanced(by: keyAbsolute)
            while idx < data.endIndex, data[idx] != 0 {
                keyBytes.append(data[idx])
                idx = data.index(after: idx)
            }
            let key = String(bytes: keyBytes, encoding: .utf8) ?? ""

            let dataAbsolute = dataTableStart + dataOffset
            guard dataAbsolute + dataLen <= data.count else {
                throw PBPError.invalidHeader("PARAM.SFO data offset out of bounds.")
            }
            let start = data.startIndex.advanced(by: dataAbsolute)
            let end = data.startIndex.advanced(by: dataAbsolute + dataLen)
            let entryData = data.subdata(in: start..<end)

            parsed.append(Entry(key: key, format: format, data: entryData, maxLength: dataMaxLen))
        }
        self.entries = parsed
    }

    func serialize() -> Data {
        let indexTableSize = entries.count * ParamSFO.indexEntrySize

        var keyTable = Data()
        var keyOffsets: [Int] = []
        for entry in entries {
            keyOffsets.append(keyTable.count)
            if let bytes = entry.key.data(using: .utf8) {
                keyTable.append(bytes)
            }
            keyTable.append(0)
        }
        while keyTable.count % 4 != 0 { keyTable.append(0) }

        let keyTableStart = ParamSFO.headerSize + indexTableSize
        let dataTableStart = keyTableStart + keyTable.count

        var dataTable = Data()
        var dataOffsets: [Int] = []
        for entry in entries {
            dataOffsets.append(dataTable.count)
            dataTable.append(entry.data)
            let padding = max(0, entry.maxLength - entry.data.count)
            if padding > 0 {
                dataTable.append(Data(repeating: 0, count: padding))
            }
        }

        var output = Data()
        output.reserveCapacity(dataTableStart + dataTable.count)
        output.append(ParamSFO.magic)
        output.appendUInt32LE(version)
        output.appendUInt32LE(UInt32(keyTableStart))
        output.appendUInt32LE(UInt32(dataTableStart))
        output.appendUInt32LE(UInt32(entries.count))

        for i in 0..<entries.count {
            output.appendUInt16LE(UInt16(keyOffsets[i]))
            output.appendUInt16LE(entries[i].format)
            output.appendUInt32LE(UInt32(entries[i].data.count))
            output.appendUInt32LE(UInt32(entries[i].maxLength))
            output.appendUInt32LE(UInt32(dataOffsets[i]))
        }
        output.append(keyTable)
        output.append(dataTable)
        return output
    }

    func string(forKey key: String) -> String? {
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        // Trim trailing NULs for both null-terminated and special UTF-8 formats.
        var bytes = [UInt8](entry.data)
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
    }

    mutating func setString(_ value: String, forKey key: String) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        var entry = entries[index]
        var encoded = value.data(using: .utf8) ?? Data()
        // Format 0x0204 stores a null terminator; 0x0004 does not.
        if entry.format != ParamSFO.formatUTF8Special {
            encoded.append(0)
        }
        // Grow the padded slot if the new value doesn't fit; round up to 4 bytes.
        if encoded.count > entry.maxLength {
            entry.maxLength = ((encoded.count + 3) / 4) * 4
        }
        entry.data = encoded
        entries[index] = entry
    }
}

extension PBPFile {
    var title: String? {
        get {
            guard let sfoData = sections["PARAM.SFO"], !sfoData.isEmpty,
                  let sfo = try? ParamSFO(data: sfoData) else { return nil }
            return sfo.string(forKey: "TITLE")
        }
    }

    mutating func setTitle(_ newTitle: String) throws {
        guard let sfoData = sections["PARAM.SFO"], !sfoData.isEmpty else {
            throw PBPError.invalidHeader("This PBP has no PARAM.SFO section to edit.")
        }
        var sfo = try ParamSFO(data: sfoData)
        sfo.setString(newTitle, forKey: "TITLE")
        sections["PARAM.SFO"] = sfo.serialize()
    }
}
