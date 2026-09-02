//
//  GlassCardView.swift
//  Done
//
//  Reusable glass-styled container. Apply your own content; padding/size
//  are controlled by the caller so this can be used beyond the calendar page.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// 功能： Renders a reusable glass-styled container around arbitrary content.
struct GlassCardView<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var contentPadding: CGFloat = 12
    @ViewBuilder var content: Content

    init(
        cornerRadius: CGFloat = 20,
        contentPadding: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(cornerRadius: cornerRadius) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(contentPadding)
        }
    }
}

private struct AdaptivePanelWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AdaptivePanelPair<Primary: View, Secondary: View>: View {
    var spacing: CGFloat = 12
    var horizontalThreshold: CGFloat = 440
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    @State private var availableWidth: CGFloat = 0

    init(
        spacing: CGFloat = 12,
        horizontalThreshold: CGFloat = 440,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.spacing = spacing
        self.horizontalThreshold = horizontalThreshold
        self.primary = primary()
        self.secondary = secondary()
    }

    private var layout: AnyLayout {
        if availableWidth >= horizontalThreshold {
            AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        } else {
            AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        }
    }

    var body: some View {
        layout {
            primary
                .frame(maxWidth: .infinity, alignment: .topLeading)
            secondary
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AdaptivePanelWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(AdaptivePanelWidthPreferenceKey.self) { newValue in
            availableWidth = newValue
        }
    }
}

struct CalendarHumanEffortDescriptor: Equatable {
    let title: String
    let subtitle: String
}

private func calendarCurrentLanguage() -> AppLanguage {
    AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey) ?? AppLanguage.english.rawValue
    ) ?? .english
}

func calendarHumanEffortDescriptor(for value: Int) -> CalendarHumanEffortDescriptor {
    switch calendarCurrentLanguage() {
    case .english:
        switch value {
        case 1:
            return CalendarHumanEffortDescriptor(
                title: "Easy",
                subtitle: "Barely took effort."
            )
        case 2:
            return CalendarHumanEffortDescriptor(
                title: "Light",
                subtitle: "A little effort, still comfortable."
            )
        case 3:
            return CalendarHumanEffortDescriptor(
                title: "Steady",
                subtitle: "A normal amount of energy."
            )
        case 4:
            return CalendarHumanEffortDescriptor(
                title: "Demanding",
                subtitle: "Took solid effort to stay on it."
            )
        case 5:
            return CalendarHumanEffortDescriptor(
                title: "Draining",
                subtitle: "This felt genuinely hard."
            )
        default:
            return CalendarHumanEffortDescriptor(
                title: "Effort",
                subtitle: "How demanding this felt."
            )
        }
    case .chinese:
        switch value {
        case 1:
            return CalendarHumanEffortDescriptor(
                title: "很轻松",
                subtitle: "几乎没怎么费力。"
            )
        case 2:
            return CalendarHumanEffortDescriptor(
                title: "还算轻松",
                subtitle: "需要投入一点，但整体轻松。"
            )
        case 3:
            return CalendarHumanEffortDescriptor(
                title: "正常投入",
                subtitle: "这次大致是正常消耗。"
            )
        case 4:
            return CalendarHumanEffortDescriptor(
                title: "挺费劲",
                subtitle: "需要明显用力才能推进。"
            )
        case 5:
            return CalendarHumanEffortDescriptor(
                title: "很吃力",
                subtitle: "这次确实很耗人。"
            )
        default:
            return CalendarHumanEffortDescriptor(
                title: "投入程度",
                subtitle: "标记一下这次有多费力。"
            )
        }
    }
}

func calendarHumanEffortPrompt() -> String {
    switch calendarCurrentLanguage() {
    case .english:
        return "Drag to mark how demanding this felt."
    case .chinese:
        return "拖一下，标记这次有多费力。"
    }
}

func calendarHumanEffortRangeLabels() -> (leading: String, trailing: String) {
    switch calendarCurrentLanguage() {
    case .english:
        return ("Lighter", "Heavier")
    case .chinese:
        return ("轻松", "吃力")
    }
}

struct CalendarEffortScrubber: View {
    @Binding var value: Int?
    var tint: Color = .accentColor
    /// Fires once per gesture (tap, drag-to-release, or drag-cancelled) with
    /// the final snapped value, after `value` has already been updated to
    /// match. `value` alone keeps tracking every intermediate step for live
    /// visual feedback; a caller whose `value` setter reaches a durable
    /// store uses this to commit once at release instead of on every step.
    /// `nearestValue` only ever returns 1...stepCount, so unlike `value`
    /// this can't carry the "untouched" nil -- non-optional on purpose
    /// (gh#162 W7).
    var onCommit: ((Int) -> Void)? = nil

    private let stepCount = 5

    /// True while SwiftUI considers a touch on the track "in progress".
    /// `@GestureState` rather than `@State` for the one property that
    /// distinguishes it: SwiftUI resets it back to `false` when the gesture
    /// ends **or is cancelled**, and cancellation is exactly the case
    /// `.onEnded` cannot see (gh#162 W2) -- e.g. `effortQuickSection` sits
    /// inside `reflectionPage`'s `ScrollView`, and `minimumDistance: 0`
    /// means `.onChanged` already fired (so `value` already moved) by the
    /// time the scroll view's pan recognizer can win arbitration and cancel
    /// this gesture. See `handleDragActiveChanged`, the one place this is
    /// read.
    @GestureState private var isDragActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let trackWidth = max(geo.size.width, 1)
                let thumbValue = value ?? 3
                let progress = CGFloat(thumbValue - 1) / CGFloat(stepCount - 1)
                let fillWidth = trackWidth * progress

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: trackWidth, height: 4)

                    if value != nil {
                        Capsule()
                            .fill(tint.opacity(0.4))
                            .frame(width: fillWidth, height: 4)
                    }

                    ForEach(0..<stepCount, id: \.self) { step in
                        let stepProgress = CGFloat(step) / CGFloat(stepCount - 1)
                        let isAtOrBefore = value != nil && step + 1 <= (value ?? 0)
                        Circle()
                            .fill(isAtOrBefore ? tint : Color.primary.opacity(0.35))
                            .frame(width: 6, height: 6)
                            .position(x: trackWidth * stepProgress, y: geo.size.height / 2)
                    }

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.ultraThickMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(value == nil ? Color.secondary.opacity(0.4) : tint).padding(3))
                        .frame(width: 8, height: 22)
                        .position(x: fillWidth, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    // Location extracted here, not passed as DragGesture.Value,
                    // so handleChanged/handleEnded stay plain methods a test
                    // can call directly — DragGesture.Value has no public
                    // initializer, so it can't be synthesized in a test.
                    DragGesture(minimumDistance: 0)
                        .updating($isDragActive) { _, state, _ in state = true }
                        .onChanged { drag in
                            // gh#201 measurement seam. Emitted from the
                            // gesture closure, not from handleChanged, for
                            // two reasons: `drag.time` (the touch event's
                            // own timestamp, which is exactly what a
                            // delivery-lag measurement needs) exists only
                            // here, and handleChanged/handleEnded must keep
                            // the plain-value signatures that let a test
                            // call them directly. No-op unless a spike is
                            // armed: one optional-closure nil-check.
                            SpikeProbe.emit(.gesture(
                                Spike201SignalID.effortScrubber,
                                .changed,
                                eventTime: drag.time,
                                locationX: drag.location.x
                            ))
                            handleChanged(locationX: drag.location.x, trackWidth: trackWidth)
                        }
                        .onEnded { drag in
                            SpikeProbe.emit(.gesture(
                                Spike201SignalID.effortScrubber,
                                .ended,
                                eventTime: drag.time,
                                locationX: drag.location.x
                            ))
                            handleEnded(locationX: drag.location.x, trackWidth: trackWidth)
                        }
                )
            }
            .frame(height: 22)

            let labels = calendarHumanEffortRangeLabels()
            HStack {
                Text(labels.leading)
                Spacer()
                Text(labels.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // The one signal a cancelled drag still delivers (gh#162 W2) --
        // see `isDragActive`'s doc comment for why `.onEnded` can't be it.
        .onChange(of: isDragActive) { wasActive, isActive in
            handleDragActiveChanged(wasActive: wasActive, isActive: isActive)
        }
    }

    private func nearestValue(for locationX: CGFloat, trackWidth: CGFloat) -> Int {
        let progress = min(max(locationX / trackWidth, 0), 1)
        return Int(round(progress * CGFloat(stepCount - 1))) + 1
    }

    /// Every intermediate step touches only `value` (a caller may bind this
    /// straight to a durable store, so this must never call `onCommit`).
    /// Not `private`: called from a test via `@testable import Done` to pin
    /// that a drag sweep never fires a commit.
    func handleChanged(locationX: CGFloat, trackWidth: CGFloat) {
        let nextValue = nearestValue(for: locationX, trackWidth: trackWidth)
        guard nextValue != value else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            value = nextValue
        }
    }

    /// Snaps `value` to the release location for both tap-to-set and
    /// drag-to-set (minimumDistance: 0 means a plain tap drives onChanged
    /// then onEnded too) -- the release location isn't guaranteed to equal
    /// the last `handleChanged` sample (gh#162 W6). Does NOT call
    /// `onCommit` -- see `handleDragActiveChanged`, the single place that
    /// happens, and why. Not `private`: called from a test directly.
    func handleEnded(locationX: CGFloat, trackWidth: CGFloat) {
        let finalValue = nearestValue(for: locationX, trackWidth: trackWidth)
        if finalValue != value {
            withAnimation(.easeInOut(duration: 0.14)) {
                value = finalValue
            }
        }
    }

    /// THE single place `onCommit` fires -- for a normal release, a tap,
    /// AND a cancellation alike (gh#162 W2 round 2).
    ///
    /// Round 2's first attempt had `handleEnded` fire `onCommit` directly
    /// and used a `didCommitAtGestureEnd` flag here to stop the
    /// `isDragActive` reset that follows EVERY end (not just a
    /// cancellation) from firing a second, duplicate commit. That flag was
    /// itself `@State`, mutated inside `handleEnded` and read here in a
    /// SEPARATE callback dispatch -- and a test driving both calls
    /// directly on the same `let` instance caught it going stale between
    /// them (`testNormalReleaseDoesNotDoubleCommitWhenGestureStateResets`
    /// went red: two commits, not one). Whether that specific failure mode
    /// also reproduces inside a real hosted view (where `@State` is keyed
    /// to view identity rather than struct-instance lifetime) is genuinely
    /// unclear -- untested here either way -- but a design that depends on
    /// one callback's state mutation being visible inside a second,
    /// separately-dispatched callback is fragile on its face, and this
    /// board already had a structurally simpler option: don't coordinate
    /// two call sites at all.
    ///
    /// So: `handleEnded` only updates `value` now: never calls `onCommit`.
    /// This is the ONLY call site, so double-commit is structurally
    /// impossible -- there is nothing to coordinate. The remaining
    /// requirement is that `isDragActive`'s `true -> false` reset
    /// reliably fires for a NORMAL end too, not just a cancellation --
    /// which is Apple's documented `@GestureState`/`.updating(_:body:)`
    /// contract ("resets ... when the gesture ends or is cancelled") and
    /// is exactly what `FocusModeView.isFingerDown` already relies on
    /// elsewhere in this codebase. That is OBSERVED/precedented behavior
    /// I'm relying on, not something re-verified on-device for this
    /// specific scrubber.
    ///
    /// For a normal end this also depends on `handleEnded`'s write to
    /// `value` (a `@Binding` -- a plain synchronous closure call into
    /// whoever owns the real storage, not identity-keyed `@State`) landing
    /// before this reads `value`, i.e. that `.onEnded` completes before
    /// the paired `.onChange(of: isDragActive)` fires -- the same ordering
    /// `FocusModeView`'s own comment asserts holds ("Ordinarily onEnded
    /// has already decided..."). If that ordering were ever violated, the
    /// failure mode is a commit of the last LIVE-TRACKED value instead of
    /// the exact release position -- graceful degradation, not a second
    /// write or lost data.
    ///
    /// The real trigger, `.onChange(of: isDragActive)`, needs a live
    /// gesture recognizer to cancel a gesture mid-drag, which a plain
    /// XCTest can't simulate -- so this is exposed (not `private`) as the
    /// pure decision a test drives directly.
    func handleDragActiveChanged(wasActive: Bool, isActive: Bool) {
        guard wasActive, !isActive else { return }
        // `value == nil` only when there was never anything to commit in
        // the first place -- an unset effort that a cancelled,
        // never-even-started drag left untouched (no `.onChanged` ever
        // ran) -- so that case is a deliberate no-op, not a fallback
        // value.
        if let value {
            onCommit?(value)
        }
    }
}

/// 功能： Applies the iOS 26 Liquid Glass effect to a card-shaped container.
/// Renamed-in-place wrapper: prior version stacked `.ultraThinMaterial` + stroke
/// + tint manually, which read flatter than the system `.glassEffect()` used on
/// the page-title pills. Using the real API keeps cards visually consistent
/// with the rest of the Liquid Glass chrome.
struct GlassEffectContainer<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background(Color.black.opacity(0.001), in: shape)
            .glassEffect(.regular, in: shape)
    }
}
