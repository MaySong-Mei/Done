//
//  CalendarPageView.swift
//  Done
//
//  Entry point for the calendar tab. Retrieves event data from `EventStore`
//  and composes the glass header (via `GlassCardView`) above the paged timeline
//  (`CalendarTimelineView` → `TimelineDayView` + `CalendarLayout` helpers).
//  This file orchestrates layout helpers (geometry metrics) and keeps the page
//  structure stable while allowing the detailed timeline implementation to live
//  in the component files.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Hosts the calendar tab layout and handles shared spacing metrics.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(containerSize: proxy.size)

            VStack(spacing: metrics.verticalSpacing) {
                headerCard(metrics: metrics)
                timelineScroll(metrics: metrics)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private extension CalendarPageView {
    // MARK: - Layout Metrics
    struct Metrics {
        let containerSize: CGSize
        let verticalSpacing: CGFloat = 16

        var topCardHeight: CGFloat {
            max(120, containerSize.height * 0.12)
        }

        let horizontalPadding: CGFloat = 16
        let topPadding: CGFloat = 16
        let timelineBottomPadding: CGFloat = 24
    }

    // MARK: - Composition
    /// Wraps the glass header card and pins it to the top with consistent padding.
    func headerCard(metrics: Metrics) -> some View {
        GlassCardView()
            .frame(height: metrics.topCardHeight)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)
    }

    /// Embeds the timeline scroll view that pages `TimelineDayView`s via `CalendarTimelineView`.
    func timelineScroll(metrics: Metrics) -> some View {
        ScrollView {
            CalendarTimelineView(events: store.events)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.timelineBottomPadding)
        }
    }
}
