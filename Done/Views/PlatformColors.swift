//
//  PlatformColors.swift
//  Done
//
//  UIKit's system colors that shared SwiftUI views use, with the Mac's
//  nearest AppKit counterparts. On the phone each one IS the UIKit color, so
//  a view switched to these names renders exactly as before.
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
