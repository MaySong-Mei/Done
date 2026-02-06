//
//  DiagonalHatchingPattern.swift
//  Done
//
//  Diagonal hatching pattern shape for timer-active event blocks.
//

import SwiftUI

struct DiagonalHatchingPattern: Shape {
    var spacing: CGFloat = 6
    var lineWidth: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Draw diagonal lines from bottom-left to top-right
        // Cover enough distance to fill the rect even at 45 degrees
        let totalLength = rect.width + rect.height
        var offset: CGFloat = -rect.height
        while offset < totalLength {
            path.move(to: CGPoint(x: offset, y: rect.height))
            path.addLine(to: CGPoint(x: offset + rect.height, y: 0))
            offset += spacing
        }
        return path
    }
}
