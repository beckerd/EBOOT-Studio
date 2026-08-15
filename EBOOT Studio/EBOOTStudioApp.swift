//
//  EBOOTStudioApp.swift
//  EBOOT Studio
//
//  Created by David Becker on 7/7/26.
//

import SwiftUI

@main
struct EBOOTStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Transparent title bar: the blueprint backdrop extends to the top
        // of the window, with only the traffic lights overlaid.
        .windowStyle(.hiddenTitleBar)
    }
}
