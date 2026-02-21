//
//  EventGridTypes.swift
//  Done
//
//  Created by Shiqi Liu on 1/21/26.
//

import SwiftUI

struct DragState {
    let eventID: UUID
    var translation: CGSize
}

struct ReorderTarget: Equatable {
    let column: Int // 0 = left, 1 = right
    let row: Int
}

struct MasonryLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 300
        let colWidth = (width - spacing) / 2
        var leftHeight: CGFloat = 0
        var rightHeight: CGFloat = 0

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.init(width: colWidth, height: nil))
            if i % 2 == 0 {
                if leftHeight > 0 { leftHeight += spacing }
                leftHeight += size.height
            } else {
                if rightHeight > 0 { rightHeight += spacing }
                rightHeight += size.height
            }
        }

        return CGSize(width: width, height: max(leftHeight, rightHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colWidth = (bounds.width - spacing) / 2
        var leftY = bounds.minY
        var rightY = bounds.minY

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.init(width: colWidth, height: nil))
            if i % 2 == 0 {
                subview.place(
                    at: CGPoint(x: bounds.minX, y: leftY),
                    anchor: .topLeading,
                    proposal: .init(width: colWidth, height: size.height)
                )
                leftY += size.height + spacing
            } else {
                subview.place(
                    at: CGPoint(x: bounds.minX + colWidth + spacing, y: rightY),
                    anchor: .topLeading,
                    proposal: .init(width: colWidth, height: size.height)
                )
                rightY += size.height + spacing
            }
        }
    }
}
