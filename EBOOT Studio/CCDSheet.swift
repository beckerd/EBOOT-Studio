//
//  CCDSheet.swift
//  EBOOT Studio
//
//  Minimal CloneCD .ccd parser. INI-style key/value sections. We only pull
//  what's needed to build a PSISO TOC block: the [Disc] TocEntries count and
//  the [Entry N] table.
//  Ported from pop-fe/popstation.py get_toc_from_ccd().
//

import Foundation

enum CCDParser {
    static func parseTOC(url: URL) throws -> Data {
        let text = try readText(url: url)
        let sections = parseINI(text)

        guard let disc = sections["Disc"], let countStr = disc["TocEntries"], let count = Int(countStr) else {
            throw CCDError.malformed("Missing Disc.TocEntries in CCD.")
        }
        guard count > 0 else {
            throw CCDError.malformed("CCD reports zero TOC entries.")
        }

        var toc = Data()
        for i in 0..<count {
            let sec = "Entry \(i)"
            guard let entry = sections[sec] else {
                throw CCDError.malformed("Missing section [\(sec)] in CCD.")
            }
            let control = try intValue(entry, "Control") & 0xF
            let adr = try intValue(entry, "ADR") & 0xF
            let trackNo = try intValue(entry, "TrackNo")
            var point = try intValue(entry, "Point")
            if point <= 0x99 { point = Int(bcd(point)) }
            let amin = bcd(try intValue(entry, "AMin"))
            let asec = bcd(try intValue(entry, "ASec"))
            let aframe = bcd(try intValue(entry, "AFrame"))
            let zero = try intValue(entry, "Zero")
            let pmin = bcd(try intValue(entry, "PMin"))
            let psec = bcd(try intValue(entry, "PSec"))
            let pframe = bcd(try intValue(entry, "PFrame"))

            var row = Data(count: 10)
            row[0] = UInt8((control << 4) | adr)
            row[1] = UInt8(trackNo & 0xFF)
            row[2] = UInt8(point & 0xFF)
            row[3] = amin
            row[4] = asec
            row[5] = aframe
            row[6] = UInt8(zero & 0xFF)
            row[7] = pmin
            row[8] = psec
            row[9] = pframe
            toc.append(row)
        }
        return toc
    }

    // Reads the primary IMG path referenced by this CCD (companion file).
    static func expectedImagePath(for ccdURL: URL) -> URL {
        return ccdURL.deletingPathExtension().appendingPathExtension("img")
    }

    // Reads the SUB path referenced by this CCD (companion file).
    static func expectedSubPath(for ccdURL: URL) -> URL {
        return ccdURL.deletingPathExtension().appendingPathExtension("sub")
    }

    // MARK: - INI parsing

    private static func parseINI(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var currentSection = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                if result[currentSection] == nil { result[currentSection] = [:] }
                continue
            }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !currentSection.isEmpty {
                    result[currentSection, default: [:]][key] = value
                }
            }
        }
        return result
    }

    private static func intValue(_ dict: [String: String], _ key: String) throws -> Int {
        guard let raw = dict[key] else {
            throw CCDError.malformed("Missing CCD key \(key).")
        }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return Int(raw.dropFirst(2), radix: 16) ?? 0
        }
        return Int(raw) ?? 0
    }

    private static func bcd(_ i: Int) -> UInt8 {
        return UInt8(i % 10) + 16 * UInt8((i / 10) % 10)
    }

    private static func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw CCDError.malformed("Unrecognized CCD text encoding.")
    }
}

enum CCDError: LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let m): return "Malformed CCD: \(m)"
        }
    }
}
