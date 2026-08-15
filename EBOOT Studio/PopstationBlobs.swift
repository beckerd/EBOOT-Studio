//
//  PopstationBlobs.swift
//  EBOOT Studio
//
//  Template blobs used to build PSP EBOOT.PBP files for PSX Classics.
//  Extracted verbatim from pop-fe (Ronnie Sahlberg, LGPLv2.1):
//  https://github.com/sahlberg/pop-fe
//

import Foundation

enum PopstationBlobs {
    static let basicTOC = load("_basic_toc")
    static let psTitleData = load("_pstitledata")
    static let startDatHeader = load("_startdatheader")
    static let startDatFooter = load("_startdatfooter")
    static let logoBuffer = load("_logo_buffer")
    static let dataPSPBody = load("_datapspbody")

    private static func load(_ name: String) -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "bin"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing bundled resource: \(name).bin")
        }
        return data
    }
}
