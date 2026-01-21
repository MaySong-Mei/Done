//
//  GridDotsView.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct GridDotsView: View {
    let columns: Int
    let rows: Int
    let cellSize: CGFloat
    private let dotRadius: CGFloat = 1.5
    private let dotColor = Color.black.opacity(0.08)

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            let diameter = dotRadius * 2

            for row in 0..<rows {
                for column in 0..<columns {
                    let x = (CGFloat(column) + 0.5) * cellSize - dotRadius
                    let y = (CGFloat(row) + 0.5) * cellSize - dotRadius
                    path.addEllipse(in: CGRect(x: x, y: y, width: diameter, height: diameter))
                }
            }

            context.fill(path, with: .color(dotColor))
        }
    }
}
