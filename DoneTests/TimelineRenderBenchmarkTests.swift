import XCTest
import SwiftUI
import UIKit
@testable import Done

/// THROWAWAY micro-benchmark for GitHub issue #14 (SwiftUI -> UIKit/CALayer
/// rewrite of the calendar timeline). Measures per-frame layout/render cost of
/// N event-block-equivalent views as a function of N, for two approaches:
///
///   A — SwiftUI tree update (GeometryReader + bg fill + stroke + shadow +
///       Text + .mask per block), driven by a shared `hourHeight` change.
///   B — CALayer update (CAShapeLayer bg+border+shadow + CATextLayer per block),
///       updated inside one CATransaction with actions disabled.
///
/// Not a production file. Safe to delete. Does NOT touch TimelineView/EventBlock.
///
/// Run:
///   xcodebuild test -scheme Done \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:DoneTests/TimelineRenderBenchmarkTests
final class TimelineRenderBenchmarkTests: XCTestCase {

    // N values to sweep.
    private let counts = [50, 200, 500, 1000]
    // Measured update cycles per N (after warmup). Median is reported.
    private let iterations = 60
    private let warmup = 10

    // MARK: - Block-equivalent SwiftUI view (approximates EventBlock cost)

    private struct BenchEventBlock: View {
        let index: Int
        let hourHeight: CGFloat

        var body: some View {
            // height scales with the shared hourHeight, like a real event block.
            let h = max(8, hourHeight * 0.9)
            GeometryReader { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.blue.opacity(0.35))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        Text("Event \(index)")
                            .font(.caption)
                            .padding(4)
                    }
                    .shadow(radius: 2)
                    .mask {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                    }
            }
            .frame(height: h)
        }
    }

    private struct BenchContainer: View {
        let count: Int
        let hourHeight: CGFloat
        var body: some View {
            VStack(spacing: 1) {
                ForEach(0..<count, id: \.self) { i in
                    BenchEventBlock(index: i, hourHeight: hourHeight)
                }
            }
            .frame(width: 320)
        }
    }

    // MARK: - Helpers

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    // Force SwiftUI to lay out and render into a real bitmap context so the
    // layout/draw cost is actually paid (not lazily deferred).
    @MainActor
    private func renderSwiftUI(_ count: Int, hourHeight: CGFloat,
                               renderer: inout ImageRenderer<BenchContainer>?) {
        let view = BenchContainer(count: count, hourHeight: hourHeight)
        if renderer == nil {
            renderer = ImageRenderer(content: view)
        } else {
            renderer?.content = view
        }
        renderer?.scale = 2
        // Accessing uiImage forces the layout + render pass to settle.
        _ = renderer?.uiImage
    }

    // MARK: - Approach A: SwiftUI

    @MainActor
    private func measureSwiftUI(_ count: Int) -> Double {
        var samples: [Double] = []
        var renderer: ImageRenderer<BenchContainer>? = nil
        // Warmup (first render allocates; exclude it).
        for w in 0..<warmup {
            renderSwiftUI(count, hourHeight: 60 + CGFloat(w), renderer: &renderer)
        }
        for i in 0..<iterations {
            // Vary hourHeight every iteration => a real layout-changing update,
            // analogous to a pinch frame.
            let hh = 60 + CGFloat(i % 30) * 1.5
            let t0 = CACurrentMediaTime()
            renderSwiftUI(count, hourHeight: hh, renderer: &renderer)
            let t1 = CACurrentMediaTime()
            samples.append((t1 - t0) * 1000.0)
        }
        return median(samples)
    }

    // MARK: - Approach B: CALayer

    @MainActor
    private func measureCALayer(_ count: Int) -> Double {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        var shapes: [CAShapeLayer] = []
        var texts: [CATextLayer] = []
        shapes.reserveCapacity(count)
        texts.reserveCapacity(count)

        for i in 0..<count {
            let shape = CAShapeLayer()
            shape.fillColor = UIColor.blue.withAlphaComponent(0.35).cgColor
            shape.strokeColor = UIColor.blue.withAlphaComponent(0.6).cgColor
            shape.lineWidth = 1
            shape.shadowRadius = 2
            shape.shadowOpacity = 0.3
            shape.shadowOffset = .zero

            let text = CATextLayer()
            text.string = "Event \(i)"
            text.fontSize = 11
            text.foregroundColor = UIColor.label.cgColor
            text.contentsScale = 2
            shape.addSublayer(text)

            host.layer.addSublayer(shape)
            shapes.append(shape)
            texts.append(text)
        }

        func update(hourHeight: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let h = max(8, hourHeight * 0.9)
            var y: CGFloat = 0
            for i in 0..<count {
                let rect = CGRect(x: 0, y: y, width: 320, height: h)
                let shape = shapes[i]
                shape.frame = rect
                // Rebuild the rounded-rect path for the new size — the CALayer
                // analogue of the RoundedRectangle shape recomputing its path.
                shape.path = UIBezierPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size),
                    cornerRadius: 8
                ).cgPath
                shape.shadowPath = shape.path
                texts[i].frame = CGRect(x: 4, y: 2, width: 200, height: 14)
                y += h + 1
            }
            CATransaction.commit()
        }

        var samples: [Double] = []
        for w in 0..<warmup { update(hourHeight: 60 + CGFloat(w)) }
        for i in 0..<iterations {
            let hh = 60 + CGFloat(i % 30) * 1.5
            let t0 = CACurrentMediaTime()
            update(hourHeight: hh)
            let t1 = CACurrentMediaTime()
            samples.append((t1 - t0) * 1000.0)
        }
        return median(samples)
    }

    // MARK: - Approach C: REAL DayLayerHostView pinch repaint (S3)

    /// Build N occurrences for one day (staggered start times, 30-min blocks)
    /// so the overlap topology is non-trivial.
    @MainActor
    private func makeOccurrences(_ count: Int, on day: Date) -> [CalendarLayout.EventOccurrence] {
        (0..<count).map { i in
            let start = day.addingTimeInterval(Double(i % 48) * 30 * 60)
            let end = start.addingTimeInterval(30 * 60)
            let event = Event(title: "Event \(i)", timeRanges: [Event.TimeRange(start: start, end: end)])
            return CalendarLayout.EventOccurrence(
                id: event.id.uuidString,
                event: event,
                range: Event.TimeRange(start: start, end: end)
            )
        }
    }

    /// Build N occurrences SPREAD uniformly across the 24h day (distinct,
    /// non-piling start times) so that as total-N grows the count of
    /// occurrences inside a FIXED small viewport stays genuinely small — the
    /// regime S6 culling targets. (Contrast `makeOccurrences`, which piles all
    /// events into 48 slots to stress the overlap topology.)
    @MainActor
    private func makeSpreadOccurrences(_ count: Int, on day: Date) -> [CalendarLayout.EventOccurrence] {
        let span: Double = 24 * 3600
        let step = span / Double(max(1, count))
        return (0..<count).map { i in
            let start = day.addingTimeInterval(Double(i) * step)
            let end = start.addingTimeInterval(min(step, 30 * 60))
            let event = Event(title: "Event \(i)", timeRanges: [Event.TimeRange(start: start, end: end)])
            return CalendarLayout.EventOccurrence(
                id: event.id.uuidString,
                event: event,
                range: Event.TimeRange(start: start, end: end)
            )
        }
    }

    @MainActor
    private func model(
        for occurrences: [CalendarLayout.EventOccurrence],
        day: Date,
        hourHeight: CGFloat,
        isPinchActive: Bool,
        frozenSlotMinutes: Int?
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: day,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: max(14, (hourHeight * 0.28).rounded()),
            hourHeight: hourHeight,
            eventHorizontalInset: 8,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            showEventText: true,
            isWeekMode: false,
            isThreeDayMode: false,
            titleFontSizeSetting: 13,
            showTimeBelowTitle: true,
            multiTypeEnabled: false,
            nearFutureHorizonDays: 7,
            isPinchActive: isPinchActive,
            frozenSlotMinutes: frozenSlotMinutes
        )
    }

    /// Median per-frame cost of the REAL `DayLayerHostView` cheap repaint path
    /// driven by hourHeight changes (the actual S3 production code).
    @MainActor
    private func measureCALayerCheapRepaint(_ count: Int) -> Double {
        let day = Calendar.current.startOfDay(for: Date())
        let occurrences = makeOccurrences(count, on: day)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 4000))
        // First apply = full render (populates the cache). Excluded from timing.
        host.apply(model(for: occurrences, day: day, hourHeight: 56,
                         isPinchActive: false, frozenSlotMinutes: nil))
        let frozen = 60 // slot density frozen at pinch start (hourHeight 56 < 76).

        func update(hourHeight: CGFloat) {
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 4000)
            host.apply(model(for: occurrences, day: day, hourHeight: hourHeight,
                             isPinchActive: true, frozenSlotMinutes: frozen))
        }

        var samples: [Double] = []
        for w in 0..<warmup { update(hourHeight: 56 + CGFloat(w) * 0.7) }
        for i in 0..<iterations {
            let hh = 40 + CGFloat(i % 30) * 1.5 // never equals previous → real change
            let t0 = CACurrentMediaTime()
            update(hourHeight: hh)
            let t1 = CACurrentMediaTime()
            samples.append((t1 - t0) * 1000.0)
        }
        return median(samples)
    }

    /// Median per-frame cost if EVERY frame forced a FULL render (overlap
    /// recompute + layer rebuild). Reference point to show the cheap-path win.
    @MainActor
    private func measureCALayerFullEachFrame(_ count: Int) -> Double {
        let day = Calendar.current.startOfDay(for: Date())
        let occurrences = makeOccurrences(count, on: day)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 4000))

        // Force a structural change every frame by toggling contentWidth a hair
        // so the StructureKey never matches → always the full render path.
        func update(hourHeight: CGFloat, widthNudge: CGFloat) {
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 4000)
            var m = model(for: occurrences, day: day, hourHeight: hourHeight,
                          isPinchActive: true, frozenSlotMinutes: 60)
            m = DayLayerHostView.Model(
                date: m.date, occurrences: m.occurrences,
                contentWidth: 360 + widthNudge, headerHeight: m.headerHeight,
                hourHeight: m.hourHeight, eventHorizontalInset: m.eventHorizontalInset,
                leadingExtendedHours: m.leadingExtendedHours,
                trailingExtendedHours: m.trailingExtendedHours,
                showEventText: m.showEventText, isWeekMode: m.isWeekMode,
                isThreeDayMode: m.isThreeDayMode, titleFontSizeSetting: m.titleFontSizeSetting,
                showTimeBelowTitle: m.showTimeBelowTitle, multiTypeEnabled: m.multiTypeEnabled,
                nearFutureHorizonDays: m.nearFutureHorizonDays, isPinchActive: m.isPinchActive,
                frozenSlotMinutes: m.frozenSlotMinutes
            )
            host.apply(m)
        }

        var samples: [Double] = []
        for w in 0..<warmup { update(hourHeight: 56 + CGFloat(w) * 0.7, widthNudge: CGFloat(w) * 0.01) }
        for i in 0..<iterations {
            let hh = 40 + CGFloat(i % 30) * 1.5
            let t0 = CACurrentMediaTime()
            update(hourHeight: hh, widthNudge: CGFloat(i) * 0.01 + 1)
            let t1 = CACurrentMediaTime()
            samples.append((t1 - t0) * 1000.0)
        }
        return median(samples)
    }

    // MARK: - Approach S6: viewport-culled repaint at HIGH total-N

    /// Embed a real `DayLayerHostView` inside a `UIScrollView` whose viewport is
    /// SMALL relative to the (very tall) content, so only a handful of the day's
    /// occurrences fall inside the buffered visible rect. This is the S6 path:
    /// the host walks the superview chain to the scroll view, converts the
    /// visible bounds into its own coordinates (+1 viewport buffer), and only
    /// builds / configures `EventLayers` for on-screen occurrences. Driving
    /// hourHeight changes exercises the cheap repaint, which now ALSO culls, so
    /// per-frame cost tracks VISIBLE-N (≈ flat as total-N grows).
    @MainActor
    private func makeScrolledHost(
        _ count: Int,
        hourHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> (scroll: UIScrollView, host: DayLayerHostView, day: Date,
          occurrences: [CalendarLayout.EventOccurrence]) {
        let day = Calendar.current.startOfDay(for: Date())
        let occurrences = makeSpreadOccurrences(count, on: day)
        // Content height = the rendered day at this hourHeight (24h band). The
        // host canvas / scroll content match it so the visible rect maps to a
        // real slice of the day. With a SMALL viewport (relative to the 24h
        // content) the visible-slice + 1-viewport buffer covers only part of
        // the day, so off-screen occurrences are culled.
        let contentHeight: CGFloat = 24 * hourHeight + 64
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: viewportHeight))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: viewportHeight))
        scroll.contentSize = CGSize(width: 360, height: contentHeight)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: contentHeight))
        scroll.addSubview(host)
        window.addSubview(scroll)
        window.isHidden = false
        // Scroll to the middle so the visible slice has occurrences above AND
        // below the buffer (worst-case for the cull bookkeeping).
        scroll.contentOffset = CGPoint(x: 0, y: max(0, contentHeight / 2 - viewportHeight / 2))
        // First apply = full render (populates the S3 caches + initial cull).
        host.apply(model(for: occurrences, day: day, hourHeight: hourHeight,
                         isPinchActive: false, frozenSlotMinutes: nil))
        return (scroll, host, day, occurrences)
    }

    /// Median per-frame cost of the REAL viewport-culled repaint at high total-N
    /// with a fixed small viewport. Should be roughly FLAT as total-N grows
    /// (cost ∝ visible-N, not total-N) — the S6 data-growth payoff.
    @MainActor
    private func measureCALayerCulledRepaint(_ count: Int) -> Double {
        // Small viewport vs a tall 24h-at-96pt/hr day (≈2304pt): visible slice
        // + 1-viewport buffer ≈ 600pt out of 2304 → ~3/4 of the day is culled,
        // so the EXPENSIVE per-event configure runs for only the visible slice.
        let viewportHeight: CGFloat = 200
        let ctx = makeScrolledHost(count, hourHeight: 96, viewportHeight: viewportHeight)
        let frozen = 30 // hourHeight 96 ≥ 76 → slot density 30.

        // Keep hourHeight near the top of the range so the rendered day stays
        // tall and the fixed small viewport keeps covering only a slice. Vary
        // it slightly each frame so every `apply` is a real repaint (≠ previous)
        // and re-runs the cull, without collapsing the day shorter than the
        // scroll content (which would defeat the viewport slice).
        func update(hourHeight: CGFloat) {
            ctx.host.apply(model(for: ctx.occurrences, day: ctx.day, hourHeight: hourHeight,
                                 isPinchActive: true, frozenSlotMinutes: frozen))
        }
        var samples: [Double] = []
        for w in 0..<warmup { update(hourHeight: 90 + CGFloat(w % 6)) }
        for i in 0..<iterations {
            let hh = 88 + CGFloat(i % 8) // 88…95, day stays ≥ 2112pt
            let t0 = CACurrentMediaTime()
            update(hourHeight: hh)
            let t1 = CACurrentMediaTime()
            samples.append((t1 - t0) * 1000.0)
        }
        return median(samples)
    }

    /// Pre-S6 baseline for the S6 benchmark: the SAME spread data the culled
    /// path sees, but the host is NOT inside a scroll view, so the viewport
    /// resolves to nil ("show all") and every occurrence's subtree is built /
    /// updated every frame — i.e. the cheap repaint cost WITHOUT culling. Cost
    /// grows with total-N. (Apples-to-apples with `measureCALayerCulledRepaint`.)
    @MainActor
    private func measureCALayerUnculledSpread(_ count: Int) -> Double {
        let day = Calendar.current.startOfDay(for: Date())
        let occurrences = makeSpreadOccurrences(count, on: day)
        let contentHeight: CGFloat = 24 * 96 + 64
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: contentHeight))
        host.apply(model(for: occurrences, day: day, hourHeight: 96,
                         isPinchActive: false, frozenSlotMinutes: nil))
        let frozen = 30
        func update(hourHeight: CGFloat) {
            host.frame = CGRect(x: 0, y: 0, width: 360, height: contentHeight)
            host.apply(model(for: occurrences, day: day, hourHeight: hourHeight,
                             isPinchActive: true, frozenSlotMinutes: frozen))
        }
        // Same hourHeight regime as the culled measure so the only difference
        // is culling (host not in a scroll view → builds every occurrence).
        var samples: [Double] = []
        for w in 0..<warmup { update(hourHeight: 90 + CGFloat(w % 6)) }
        for i in 0..<iterations {
            let hh = 88 + CGFloat(i % 8)
            let t0 = CACurrentMediaTime()
            update(hourHeight: hh)
            let t1 = CACurrentMediaTime()
            samples.append((t1 - t0) * 1000.0)
        }
        return median(samples)
    }

    // MARK: - Driver

    func testRenderScalingBenchmark() {
        MainActor.assumeIsolated {
            runBenchmark()
        }
    }

    /// S6-focused benchmark: at a FIXED small viewport, sweep total-N high and
    /// show the culled per-frame cost stays ≈ flat (∝ visible-N) while the
    /// pre-S6 full-build cost grows with total-N.
    func testViewportCullingBenchmark() {
        MainActor.assumeIsolated {
            runViewportCullingBenchmark()
        }
    }

    @MainActor
    private func runViewportCullingBenchmark() {
        var lines: [String] = []
        lines.append("")
        lines.append("=== S6 VIEWPORT CULLING BENCHMARK (issue #14) ===")
        lines.append("Device: \(UIDevice.current.name)  scale: \(UIScreen.main.scale)")
        lines.append("Fixed viewport 700pt; content 24h; cull = visible slice + 1 viewport buffer.")
        lines.append(String(format: "%-6@ | %-22@ | %-22@ | %-8@",
                            "totalN" as NSString,
                            "S6 culled ms (fps)" as NSString,
                            "pre-S6 all-N ms (fps)" as NSString,
                            "speedup" as NSString))
        lines.append(String(repeating: "-", count: 70))
        // High total-N sweep — the data-growth regime S6 targets.
        let highCounts = [50, 200, 500, 1000]
        for n in highCounts {
            let culled = measureCALayerCulledRepaint(n)
            let full = measureCALayerUnculledSpread(n)
            let cFps = culled > 0 ? 1000.0 / culled : 0
            let fFps = full > 0 ? 1000.0 / full : 0
            let speedup = culled > 0 ? full / culled : 0
            lines.append(String(format: "%-6d | %8.3f (%6.1f) | %8.3f (%6.1f) | %5.1fx",
                                n, culled, cFps, full, fFps, speedup))
        }
        lines.append("S6 culled = host in a scroll view (builds only the visible slice + buffer);")
        lines.append("pre-S6 all-N = same data, no scroll view (builds every occurrence each frame).")
        lines.append("S6 builds the EXPENSIVE per-event subtree only for the visible slice; an")
        lines.append("O(N) struct-only cull scan (verticalFrame + intersect) remains, so cost grows")
        lines.append("sub-linearly vs pre-S6 (which pays the full per-event build for all N).")
        lines.append("=== END S6 BENCHMARK ===")
        print(lines.joined(separator: "\n"))
    }

    @MainActor
    private func runBenchmark() {
        var lines: [String] = []
        lines.append("")
        lines.append("=== TIMELINE RENDER BENCHMARK (issue #14) ===")
        lines.append("Device: \(UIDevice.current.name)  scale: \(UIScreen.main.scale)")
        lines.append(String(format: "%-6@ | %-20@ | %-20@ | %-20@ | %-20@ | %-8@",
                            "N" as NSString,
                            "A SwiftUI ms (fps)" as NSString,
                            "B synth CALayer ms" as NSString,
                            "C S3 cheap ms (fps)" as NSString,
                            "D full/frame ms" as NSString,
                            "A/C" as NSString))
        lines.append(String(repeating: "-", count: 110))

        for n in counts {
            let a = measureSwiftUI(n)
            let b = measureCALayer(n)
            let c = measureCALayerCheapRepaint(n)
            let d = measureCALayerFullEachFrame(n)
            let aFps = a > 0 ? 1000.0 / a : 0
            let bFps = b > 0 ? 1000.0 / b : 0
            let cFps = c > 0 ? 1000.0 / c : 0
            let dFps = d > 0 ? 1000.0 / d : 0
            let ratioAC = c > 0 ? a / c : 0
            lines.append(String(format: "%-6d | %7.3f (%5.1f) | %7.3f (%5.1f) | %7.3f (%5.1f) | %7.3f (%5.1f) | %5.1fx",
                                n, a, aFps, b, bFps, c, cFps, d, dFps, ratioAC))
        }
        lines.append("Legend: C = REAL DayLayerHostView S3 cheap repaint (overlap+horizontal cached);")
        lines.append("        D = REAL DayLayerHostView forced FULL render each frame (overlap recompute + rebuild).")
        lines.append("=== END BENCHMARK ===")
        print(lines.joined(separator: "\n"))
    }
}
