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

    private let menuWidth: CGFloat = 220
    private let itemHeight: CGFloat = 42
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let localPoint = CGPoint(
                x: state.touchPointGlobal.x - frame.minX,
                y: state.touchPointGlobal.y - frame.minY
            )
            let menuHeight = itemHeight * 4 + verticalPadding * 2 + 26
            let menuX = clamp(localPoint.x + 116, 16 + menuWidth / 2, geo.size.width - 16 - menuWidth / 2)
            let menuY = clamp(localPoint.y + 14, 16 + menuHeight / 2, geo.size.height - 16 - menuHeight / 2)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }

                menuCard
                    .frame(width: menuWidth)
                    .position(x: menuX, y: menuY)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity)
                    )
            }
        }
        .zIndex(20)
    }

    private var menuCard: some View {
        GlassEffectContainer(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eventTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalPadding + 4)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

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
}

