import SwiftUI

struct CalendarEventQuickActionMenuView: View {
    let state: CalendarQuickActionMenuState
    let eventTitle: String
    let onLog: () -> Void
    let onRate: () -> Void
    let onChat: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let compactMenuWidth: CGFloat = 220
    private let expandedMenuWidth: CGFloat = 256
    private let itemHeight: CGFloat = 42
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 8
    private let edgeInset: CGFloat = 16
    private let pointerGapX: CGFloat = 18
    private let pointerGapY: CGFloat = 16
    private let compactHeaderHeight: CGFloat = 26
    private let expandedMetaHeight: CGFloat = 86

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let localPoint = CGPoint(
                x: state.touchPointGlobal.x - frame.minX,
                y: state.touchPointGlobal.y - frame.minY
            )
            let avoidRect = CGRect(
                x: state.eventSegmentFrameGlobal.minX - frame.minX,
                y: state.eventSegmentFrameGlobal.minY - frame.minY,
                width: state.eventSegmentFrameGlobal.width,
                height: state.eventSegmentFrameGlobal.height
            )
            let menuSize = resolvedMenuSize
            let menuOrigin = preferredMenuOrigin(
                for: localPoint,
                avoidRect: avoidRect,
                in: geo.size,
                menuSize: menuSize
            )

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }

                menuCard
                    .frame(width: menuSize.width)
                    .position(
                        x: menuOrigin.x + menuSize.width / 2,
                        y: menuOrigin.y + menuSize.height / 2
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity)
                    )
            }
        }
        .zIndex(20)
    }

    private var resolvedMenuSize: CGSize {
        switch state.presentation {
        case .compact:
            return CGSize(
                width: compactMenuWidth,
                height: compactHeaderHeight + verticalPadding * 2 + itemHeight * 4
            )
        case .expanded:
            return CGSize(
                width: expandedMenuWidth,
                height: expandedMetaHeight + verticalPadding * 2 + itemHeight * 4
            )
        }
    }

    private var menuCard: some View {
        GlassEffectContainer(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                switch state.presentation {
                case .compact:
                    compactHeader
                case .expanded:
                    expandedHeader
                }

                actionRow("log", title: "Log", systemImage: "square.and.pencil", action: onLog)
                actionRow("rate", title: "Rate", systemImage: "gauge.with.dots.needle.33percent", action: onRate)
                actionRow("chat", title: "Chat", systemImage: "bubble.left.and.bubble.right", action: onChat)
                actionRow("delete", title: "Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
    }

    private var compactHeader: some View {
        Text(eventTitle)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, horizontalPadding + 4)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private var expandedHeader: some View {
        let summary = state.metaSummary
        VStack(alignment: .leading, spacing: 8) {
            Text(summary?.title ?? eventTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    metaRow(systemImage: "clock", text: summary.occurrenceTimeText)
                    if let locationText = summary.locationText {
                        metaRow(systemImage: "mappin.and.ellipse", text: locationText)
                    }
                    if let recurrenceText = summary.recurrenceText {
                        metaRow(systemImage: "repeat", text: recurrenceText)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding + 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func metaRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionRow(
        _ id: String,
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(role == .destructive ? .red : .primary)
            .frame(height: itemHeight)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .id(id)
    }

    private func preferredMenuOrigin(
        for point: CGPoint,
        avoidRect: CGRect,
        in containerSize: CGSize,
        menuSize: CGSize
    ) -> CGPoint {
        let minX = edgeInset
        let maxX = max(edgeInset, containerSize.width - edgeInset - menuSize.width)
        let minY = edgeInset
        let maxY = max(edgeInset, containerSize.height - edgeInset - menuSize.height)

        let candidates: [CGPoint] = [
            CGPoint(x: point.x + pointerGapX, y: avoidRect.minY - menuSize.height - pointerGapY),
            CGPoint(x: point.x + pointerGapX, y: avoidRect.maxY + pointerGapY),
            CGPoint(x: point.x - menuSize.width - pointerGapX, y: avoidRect.minY - menuSize.height - pointerGapY),
            CGPoint(x: point.x - menuSize.width - pointerGapX, y: avoidRect.maxY + pointerGapY),
            CGPoint(x: avoidRect.maxX + pointerGapX, y: point.y - menuSize.height / 2),
            CGPoint(x: avoidRect.minX - menuSize.width - pointerGapX, y: point.y - menuSize.height / 2)
        ]

        let clampedCandidates = candidates.map { candidate in
            CGPoint(
                x: min(max(candidate.x, minX), maxX),
                y: min(max(candidate.y, minY), maxY)
            )
        }

        let pointAvoidRect = CGRect(
            x: point.x - 14,
            y: point.y - 14,
            width: 28,
            height: 28
        )

        if let nonOverlapping = clampedCandidates.first(where: { candidate in
            let frame = CGRect(origin: candidate, size: menuSize)
            return !frame.intersects(avoidRect) && !frame.intersects(pointAvoidRect)
        }) {
            return nonOverlapping
        }

        return clampedCandidates.min { lhs, rhs in
            let lhsFrame = CGRect(origin: lhs, size: menuSize)
            let rhsFrame = CGRect(origin: rhs, size: menuSize)
            return overlapScore(for: lhsFrame, avoidRect: avoidRect, pointRect: pointAvoidRect)
                < overlapScore(for: rhsFrame, avoidRect: avoidRect, pointRect: pointAvoidRect)
        } ?? CGPoint(x: minX, y: minY)
    }

    private func overlapScore(for frame: CGRect, avoidRect: CGRect, pointRect: CGRect) -> CGFloat {
        let avoidOverlap = frame.intersection(avoidRect)
        let pointOverlap = frame.intersection(pointRect)
        return avoidOverlap.width * avoidOverlap.height + pointOverlap.width * pointOverlap.height * 4
    }
}
