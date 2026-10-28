//
//  WristMotionViews.swift
//  DoneWatch
//
//  The phone's timeline motions, made for the wrist (`WristMotionPlan`
//  decides which play). The phone breaks a block into hundreds of layers;
//  here each motion moves the one block view — offset, scale, rotation,
//  blur, opacity — so it costs a few frames of one view and nothing at
//  rest. Nothing runs on a timer: each motion starts when its view appears
//  and ends with it.
//

import SwiftUI

/// A block that just arrived. From a draft drawn here, it is the draft
/// becoming the block: it waits in the draft's place and look while the
/// type picker is still up (`holding`), then glides to its own place, its
/// colour flooding in as the draft's grey and outline fade, with a slight
/// settle — the phone's draft morph. From the phone, the phone's create
/// style, played on the block.
struct WristArrivalEffect: ViewModifier {
    let arrival: WristMotionPlan.Arrival?
    /// The block's own frame, and the draft's when it came from one.
    let frame: CGRect
    let draftFrame: CGRect?
    let holding: Bool

    /// Captured on appear: the arrival the block was inserted with, which
    /// the next plan no longer names.
    @State private var playing: WristMotionPlan.Arrival?
    @State private var landed = false

    func body(content: Content) -> some View {
        let morphing = playing == .fromDraft && draftFrame != nil && !landed
        let shown = morphing ? draftFrame! : frame
        content
            .overlay {
                if playing == .fromDraft {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(white: 0.3))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                        }
                        .opacity(landed ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: shown.width, height: shown.height)
            .modifier(WristCreateStyleEffect(look: look, progress: playing == nil || landed ? 1 : 0))
            .offset(x: shown.minX, y: shown.minY)
            .onAppear {
                guard playing == nil, let arrival else { return }
                playing = arrival
                if !(arrival == .fromDraft && holding) { land() }
            }
            .onChange(of: holding) { _, isHolding in
                if !isHolding, playing != nil, !landed { land() }
            }
    }

    private var look: WristCreateStyleEffect.Look {
        switch playing {
        case .style(let style): return .style(style)
        case .fade: return .fade
        case .fromDraft, nil: return .none
        }
    }

    private func land() {
        switch playing {
        case .fromDraft:
            // Settles a few percent past its place and back.
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) { landed = true }
        case .style(let style):
            withAnimation(Self.animation(for: style)) { landed = true }
        case .fade:
            withAnimation(.easeOut(duration: 0.2)) { landed = true }
        case nil:
            break
        }
    }

    static func animation(for style: WristCreateStyle) -> Animation {
        switch style {
        case .assemble: return .easeOut(duration: 0.45)
        case .inkFill: return .timingCurve(0.3, 0, 0.2, 1, duration: 0.42)
        case .pinDrop: return .spring(response: 0.42, dampingFraction: 0.62)
        case .crtOn: return .easeOut(duration: 0.38)
        }
    }
}

/// The phone's create styles on one view, `progress` 0 (not yet there) to 1
/// (in place).
struct WristCreateStyleEffect: ViewModifier, Animatable {
    enum Look: Equatable {
        case none, fade
        case style(WristCreateStyle)
    }

    let look: Look
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress, q = 1 - progress
        switch look {
        case .none:
            content
        case .fade:
            content.opacity(p)
        case .style(.assemble):
            // 聚沙成形: drifts in from the upper left, out of a haze.
            content
                .blur(radius: 3 * q)
                .scaleEffect(0.9 + 0.1 * p)
                .offset(x: -14 * q, y: -8 * q)
                .opacity(p)
        case .style(.inkFill):
            // 预览转实: fills from the top down.
            content
                .mask(alignment: .top) {
                    Rectangle().scaleEffect(x: 1, y: max(0.001, p), anchor: .top)
                }
        case .style(.pinDrop):
            // 落钉: drops in from just above, the spring pins it.
            content
                .offset(y: -12 * q)
                .opacity(min(1, p * 2.5))
        case .style(.crtOn):
            // 开电视: a bright line across, then open to full height.
            let across = min(1, p / 0.45)
            let open = max(0, (p - 0.45) / 0.55)
            content
                .brightness(0.5 * (1 - open))
                .scaleEffect(x: 0.02 + 0.98 * across, y: 0.04 + 0.96 * open)
                .opacity(min(1, p * 4))
        }
    }
}

/// A deleted block's last frame, played out and gone — the phone's delete
/// style on one view, or a fade past the first few of a burst.
struct WristDepartureView: View {
    let block: WristDayBlock
    let motion: WristMotionPlan.Departure
    let frame: CGRect
    let content: AnyView

    @State private var gone = false

    var body: some View {
        content
            .frame(width: frame.width, height: frame.height)
            .modifier(WristDeleteStyleEffect(style: style, progress: gone ? 1 : 0, height: frame.height))
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(Self.animation(for: motion)) { gone = true }
            }
    }

    private var style: WristDeleteStyle? {
        if case .style(let style) = motion { return style }
        return nil
    }

    static func duration(of motion: WristMotionPlan.Departure) -> Double {
        switch motion {
        case .fade: return 0.2
        case .style(.dissolve): return 0.45
        case .style(.shatter): return 0.5
        case .style(.crtOff): return 0.42
        case .style(.fall): return 0.6
        case .style(.pop): return 0.36
        }
    }

    static func animation(for motion: WristMotionPlan.Departure) -> Animation {
        switch motion {
        case .fade: return .easeOut(duration: duration(of: motion))
        case .style(.crtOff), .style(.pop): return .linear(duration: duration(of: motion))
        case .style: return .easeIn(duration: duration(of: motion))
        }
    }
}

private struct WristDeleteStyleEffect: ViewModifier, Animatable {
    let style: WristDeleteStyle?
    var progress: Double
    let height: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        switch style {
        case .dissolve:
            // 沙化: blows off to the right into a haze.
            content
                .blur(radius: 5 * p)
                .scaleEffect(1 - 0.12 * p)
                .offset(x: 22 * p, y: -6 * p)
                .opacity(1 - p)
        case .shatter:
            // 碎裂: knocked loose, it tips and falls.
            content
                .rotationEffect(.degrees(14 * p), anchor: .bottomLeading)
                .offset(y: 48 * p * p)
                .opacity(1 - p * p)
        case .crtOff:
            // 关电视: squashed to a bright line, then to a dot.
            let squash = min(1, p / 0.55)
            let shrink = max(0, (p - 0.55) / 0.45)
            content
                .brightness(0.6 * squash)
                .scaleEffect(x: 1 - 0.97 * shrink, y: max(0.02, 1 - 0.98 * squash))
                .opacity(1 - shrink)
        case .fall:
            // 掉落: the right-hand nail lets go — it swings on the left one,
            // then drops.
            let swing = min(1, p / 0.55)
            let drop = max(0, (p - 0.55) / 0.45)
            content
                .rotationEffect(.degrees(22 * swing), anchor: .topLeading)
                .offset(y: (height + 30) * drop * drop)
                .opacity(1 - drop)
        case .pop:
            // 膨胀破裂: swells under pressure, then pops.
            let swell = min(1, p / 0.75)
            let burst = max(0, (p - 0.75) / 0.25)
            content
                .brightness(0.35 * swell)
                .scaleEffect(1 + 0.12 * swell + 0.25 * burst)
                .opacity(1 - burst)
        case nil:
            content.opacity(1 - p)
        }
    }
}
