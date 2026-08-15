//
//  SubchannelReader.swift
//  EBOOT Studio
//
//  Converts a CloneCD-style .sub file into the 12-byte-per-sector
//  Q-subchannel format popstation expects when injecting into PSISO.
//

import Foundation

enum SubchannelReader {
    // Loads .sub file and returns a 12-byte-per-sector Q-subchannel blob.
    // Layout is inferred from the file's own size: prefer 96 (CloneCD raw),
    // then 16, then 12. We don't need the disc image size for this.
    static func load(url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 0 else { return Data() }

        if data.count % 96 == 0 {
            let sectors = data.count / 96
            var out = Data(capacity: sectors * 12)
            for i in 0..<sectors {
                let start = i * 96 + 12
                out.append(data[start..<(start + 12)])
            }
            return out
        }
        if data.count % 16 == 0 {
            let sectors = data.count / 16
            var out = Data(capacity: sectors * 12)
            for i in 0..<sectors {
                let start = i * 16
                out.append(data[start..<(start + 12)])
            }
            return out
        }
        if data.count % 12 == 0 {
            return data
        }
        throw SubchannelError.unexpectedSize(actual: data.count)
    }
}

enum SubchannelError: LocalizedError {
    case unexpectedSize(actual: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedSize(let actual):
            return "SUB file is \(actual) bytes — not a multiple of 12, 16, or 96 bytes per sector."
        }
    }
}
