//
//  BundledFontRegistrar.swift
//  Shake Cursor
//
//  Created by Codex on 2026/5/16.
//

import CoreText
import Foundation

enum BundledFontRegistrar {
    static func registerFonts() {
        for font in [
            ("LXGWWenKaiLite-Regular", "ttf"),
            ("LXGWWenKaiLite-Medium", "ttf")
        ] {
            registerFont(named: font.0, extension: font.1)
        }
    }

    private static func registerFont(named name: String, extension fileExtension: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
            CodexBridgeLog.write("bundled font missing name=\(name).\(fileExtension)")
            return
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            CodexBridgeLog.write("bundled font registered name=\(name).\(fileExtension)")
            return
        }

        if let error = error?.takeRetainedValue() {
            let nsError = error as Error as NSError
            if nsError.domain == kCTFontManagerErrorDomain as String,
               nsError.code == CTFontManagerError.alreadyRegistered.rawValue {
                return
            }
            CodexBridgeLog.write("bundled font register failed name=\(name).\(fileExtension) error=\(nsError.localizedDescription)")
        }
    }
}
