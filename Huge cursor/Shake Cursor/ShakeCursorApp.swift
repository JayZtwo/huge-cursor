//
//  ShakeCursorApp.swift
//  Shake Cursor
//
//  Created by Rokid on 2026/5/13.
//

import SwiftUI
import AppKit

@main
struct ShakeCursorApp: App {
    init() {
        BundledFontRegistrar.registerFonts()
        activateExistingInstanceIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    private func activateExistingInstanceIfNeeded() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first {
                $0.processIdentifier != currentProcessIdentifier && !$0.isTerminated
            }

        guard let existingApp else { return }
        existingApp.activate()
        exit(0)
    }
}
