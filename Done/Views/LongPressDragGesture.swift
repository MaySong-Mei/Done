//
//  LongPressDragGesture.swift
//  Done
//

import SwiftUI

enum LongPressDragPhase: Equatable {
    case inactive
    case pressing
    case dragging(translation: CGSize, location: CGPoint, startLocation: CGPoint)
}

extension LongPressDragPhase {
    var isActive: Bool {
        switch self {
        case .inactive:
            return false
        case .pressing, .dragging:
            return true
        }
    }

    var translation: CGSize {
        if case .dragging(let translation, _, _) = self {
            return translation
        }
        return .zero
    }

    var location: CGPoint {
        if case .dragging(_, let location, _) = self {
            return location
        }
        return .zero
    }

    var startLocation: CGPoint {
        if case .dragging(_, _, let startLocation) = self {
            return startLocation
        }
        return .zero
    }
}

struct LongPressDragGestureModifier: ViewModifier {
    let minimumDuration: TimeInterval
    let maximumDistance: CGFloat
    @Binding var phase: LongPressDragPhase
    let onEnded: (CGSize) -> Void

    @GestureState private var internalPhase: LongPressDragPhase = .inactive

    func body(content: Content) -> some View {
        content
            .gesture(gesture)
            .onChange(of: internalPhase) { _, newValue in
                phase = newValue
            }
            .onAppear {
                phase = .inactive
            }
    }

    private var gesture: some Gesture {
        LongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($internalPhase) { value, state, _ in
                switch value {
                case .first(true):
                    state = .pressing
                case .second(true, .none):
                    state = .pressing
                case .second(true, let drag?):
                    state = .dragging(
                        translation: drag.translation,
                        location: drag.location,
                        startLocation: drag.startLocation
                    )
                default:
                    state = .inactive
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    onEnded(drag.translation)
                }
            }
    }
}

extension View {
    func longPressDragGesture(
        minimumDuration: TimeInterval = 0.2,
        maximumDistance: CGFloat = 8,
        phase: Binding<LongPressDragPhase>,
        onEnded: @escaping (CGSize) -> Void
    ) -> some View {
        modifier(
            LongPressDragGestureModifier(
                minimumDuration: minimumDuration,
                maximumDistance: maximumDistance,
                phase: phase,
                onEnded: onEnded
            )
        )
    }
}
