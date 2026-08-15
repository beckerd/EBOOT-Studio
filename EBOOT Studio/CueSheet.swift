//
//  CueSheet.swift
//  EBOOT Studio
//
//  Minimal .cue parser sufficient for feeding the PSX converter.
//  Ported from pop-fe/cue.py.
//

import Foundation

struct CueSheet {
    enum TrackMode: String {
        case mode1_2352 = "MODE1/2352"
        case mode2_2352 = "MODE2/2352"
        case mode2_2336 = "MODE2/2336"
        case audio = "AUDIO"

        init(raw: String) throws {
            guard let m = TrackMode(rawValue: raw.uppercased()) else {
                throw CueError.unsupportedTrackMode(raw)
            }
            self = m
        }
    }

    struct Track {
        var number: Int
        var mode: TrackMode
        var fileURL: URL
        // startSector for INDEX 01, keyed by index number (0 for pre-gap, 1 for main)
        var indexSectors: [Int: Int]
    }

    var tracks: [Track]

    // The image is the single BIN file that backs the first track. All tracks
    // in a typical PSX rip share the same BIN.
    var primaryImageURL: URL {
        tracks.first?.fileURL ?? URL(fileURLWithPath: "/dev/null")
    }
}

enum CueError: LocalizedError {
    case unsupportedTrackMode(String)
    case malformed(String)
    case missingReferencedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTrackMode(let m): return "Unsupported CUE track mode \(m)."
        case .malformed(let line): return "Malformed CUE line: \(line)."
        case .missingReferencedFile(let name): return "CUE references file that could not be found: \(name)."
        }
    }
}

enum CueParser {
    static func parse(url cueURL: URL) throws -> CueSheet {
        let data = try Data(contentsOf: cueURL)
        var contents = decodeText(data)
        if contents.hasPrefix("\u{FEFF}") { contents.removeFirst() }
        let cueDir = cueURL.deletingLastPathComponent()

        var tracks: [CueSheet.Track] = []
        var currentFileURL: URL?
        var currentTrack: CueSheet.Track?

        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = trim(rawLine)
            if trimmed.isEmpty { continue }
            let upper = trimmed.uppercased()

            if upper.hasPrefix("FILE ") {
                let body = String(trimmed.dropFirst(5))
                let name = extractQuoted(body)
                let resolved = resolveFile(name: name, cueDir: cueDir)
                currentFileURL = resolved
            } else if upper.hasPrefix("TRACK ") {
                if let prev = currentTrack { tracks.append(prev) }
                let body = String(trimmed.dropFirst(6))
                let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let num = Int(parts[0]) else {
                    throw CueError.malformed(trimmed)
                }
                let mode = try CueSheet.TrackMode(raw: String(parts[1]))
                guard let file = currentFileURL else {
                    throw CueError.malformed("TRACK appeared before FILE")
                }
                currentTrack = CueSheet.Track(
                    number: num,
                    mode: mode,
                    fileURL: file,
                    indexSectors: [:]
                )
            } else if upper.hasPrefix("INDEX ") {
                let body = String(trimmed.dropFirst(6))
                let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let idx = Int(parts[0]) else {
                    throw CueError.malformed(trimmed)
                }
                let mmssff = parts[1].split(separator: ":")
                guard mmssff.count == 3,
                      let mm = Int(mmssff[0]),
                      let ss = Int(mmssff[1]),
                      let ff = Int(mmssff[2]) else {
                    throw CueError.malformed(trimmed)
                }
                let sector = 75 * (mm * 60 + ss) + ff
                currentTrack?.indexSectors[idx] = sector
            }
        }
        if let last = currentTrack { tracks.append(last) }

        if tracks.isEmpty {
            throw CueError.malformed("No TRACK lines found in CUE.")
        }
        return CueSheet(tracks: tracks)
    }

    private static func decodeText(_ data: Data) -> String {
        // Detect UTF-16 by BOM.
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            }
            if data[0] == 0xFE && data[1] == 0xFF {
                return String(data: data, encoding: .utf16BigEndian) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            }
        }
        // Heuristic: if every other byte is 0, treat as UTF-16 LE without BOM.
        if data.count >= 8 {
            var zeros = 0
            let sample = min(data.count, 256)
            for i in stride(from: 1, to: sample, by: 2) where data[i] == 0 { zeros += 1 }
            if Double(zeros) / Double(sample / 2) > 0.8 {
                return String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            }
        }
        // Try UTF-8, then fall back to Windows-1252 (which never fails).
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? ""
    }

    private static func trim(_ s: String) -> String {
        var start = s.startIndex
        var end = s.endIndex
        let bad: Set<Character> = [" ", "\t", "\r", "\n", "\""]
        while start < end, bad.contains(s[start]) { start = s.index(after: start) }
        while end > start, bad.contains(s[s.index(before: end)]) { end = s.index(before: end) }
        return String(s[start..<end])
    }

    // "filename.bin" BINARY -> filename.bin
    private static func extractQuoted(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        // Quoted filename: keep everything between the first and last quote.
        if trimmed.first == "\"", let closing = trimmed.range(of: "\"", options: .backwards),
           closing.lowerBound > trimmed.startIndex {
            let start = trimmed.index(after: trimmed.startIndex)
            return String(trimmed[start..<closing.lowerBound])
        }
        // Unquoted: strip the trailing filetype keyword if present.
        if let space = trimmed.range(of: " ", options: .backwards) {
            return String(trimmed[..<space.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func resolveFile(name: String, cueDir: URL) -> URL {
        // Try exact filename in CUE's directory first, then fall back to absolute.
        let candidate = cueDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Case-insensitive lookup in the directory (CUEs commonly use different casing).
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cueDir.path) {
            for entry in entries where entry.compare(name, options: .caseInsensitive) == .orderedSame {
                return cueDir.appendingPathComponent(entry)
            }
        }
        return URL(fileURLWithPath: name)
    }
}
