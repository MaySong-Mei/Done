//
//  TimelineMaskView.swift
//  Done
//
//  Shared fade mask for the calendar timeline. Uses hold + feather stops
//  at both edges to avoid hard cuts.
//

import SwiftUI

struct EdgeFadeConfig {
    let holdHeight: CGFloat
    let featherHeight: CGFloat

    var maskHeight: CGFloat {
        max(0, holdHeight + featherHeight)
    }

    var holdStop: CGFloat {
        guard maskHeight > 0 else { return 0 }
        return min(1, max(0, holdHeight / maskHeight))
    }
}

struct TimelineMaskView: View {
    let top: EdgeFadeConfig
    let bottom: EdgeFadeConfig

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0), location: top.holdStop),
                    .init(color: .black.opacity(1), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: top.maskHeight)

            Rectangle()
                .fill(.black)
                .frame(maxHeight: .infinity)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(1), location: 0),
                    .init(color: .black.opacity(1), location: bottom.holdStop),
                    .init(color: .black.opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bottom.maskHeight)
        }
    }
}
