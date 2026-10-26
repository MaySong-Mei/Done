//
//  PlatformColors.swift
//  Done
//
//  UIKit's system colors that shared SwiftUI views use, with the Mac's
//  nearest AppKit counterparts. On the phone each one IS the UIKit color, so
//  a view switched to these names renders exactly as before. Same rule for
//  the few iOS-only modifiers below: the phone applies them unchanged, the
//  Mac skips them.
//

import SwiftUI

extension Color {
    #if canImport(UIKit)
    static var platformBackground: Color { Color(.systemBackground) }
    static var platformGray4: Color { Color(.systemGray4) }
    static var platformGray5: Color { Color(.systemGray5) }
    static var platformGray6: Color { Color(.systemGray6) }
    #else
    static var platformBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var platformGray4: Color { Color(nsColor: .tertiaryLabelColor) }
    static var platformGray5: Color { Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
    static var platformGray6: Color { Color(nsColor: .controlBackgroundColor) }
    #endif
}

extension View {
    /// `.textInputAutocapitalization(.words)` on the phone; the Mac has no
    /// autocapitalization.
    @ViewBuilder
    func platformWordsCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// `.toolbar(.hidden, for: .navigationBar)` on the phone; a Mac sheet
    /// has no navigation bar to hide.
    @ViewBuilder
    func platformHiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// A Mac sheet's Esc / Return; the phone keeps its buttons tap-only.
    @ViewBuilder
    func macKeyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
        #if os(macOS)
        keyboardShortcut(shortcut)
        #else
        self
        #endif
    }
}
