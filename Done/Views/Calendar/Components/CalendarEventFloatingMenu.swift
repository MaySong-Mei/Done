import SwiftUI

struct CalendarEventFloatingMenu: View {
    let anchorPoint: CGPoint
    let onViewDetails: () -> Void
    let onInterrupt: (() -> Void)?
    let onLogEvent: () -> Void
    let onEdit: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let rowCount = 5 + (onInterrupt == nil ? 0 : 1)
            let menuSize = CGSize(width: 210, height: CGFloat(rowCount * 44 + (rowCount - 1)))
            let position = menuPosition(
                anchor: anchorPoint,
                menuSize: menuSize,
                containerSize: proxy.size
            )

            ZStack(alignment: .topLeading) {
                // Tap-outside dismiss layer
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                VStack(spacing: 0) {
                    menuRow(icon: "info.circle", title: "View Details") {
                        onDismiss()
                        onViewDetails()
                    }
                    if let onInterrupt {
                        Divider().padding(.leading, 40)
                        menuRow(icon: "bolt.fill", title: "Interrupt") {
                            onDismiss()
                            onInterrupt()
                        }
                    }
                    Divider().padding(.leading, 40)
                    menuRow(icon: "square.and.pencil", title: "Log Event") {
                        onDismiss()
                        onLogEvent()
                    }
                    Divider().padding(.leading, 40)
                    menuRow(icon: "pencil", title: "Edit") {
                        onDismiss()
                        onEdit()
                    }
                    Divider().padding(.leading, 40)
                    menuRow(icon: "square.and.arrow.up", title: "Share") {
                        onDismiss()
                        onShare()
                    }
                    Divider().padding(.leading, 40)
                    menuRow(icon: "trash", title: "Delete", role: .destructive) {
                        onDelete()
                        onDismiss()
                    }
                }
                .frame(width: menuSize.width)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
                .offset(x: position.x, y: position.y)
                .scaleEffect(appeared ? 1 : 0.7, anchor: .top)
                .opacity(appeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                appeared = true
            }
        }
    }

    private func menuRow(
        icon: String,
        title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : .primary)
    }

    private func menuPosition(
        anchor: CGPoint,
        menuSize: CGSize,
        containerSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 12
        let bottomSafeMargin: CGFloat = 90 // tab bar + safe area
        // Prefer placing menu below and centered on the anchor
        var x = anchor.x - menuSize.width / 2
        var y = anchor.y + 12

        // Clamp horizontal
        x = max(margin, min(x, containerSize.width - menuSize.width - margin))
        // If menu would overflow bottom (accounting for tab bar), place above
        if y + menuSize.height > containerSize.height - bottomSafeMargin {
            y = anchor.y - menuSize.height - 12
        }
        // Clamp vertical
        y = max(margin, min(y, containerSize.height - menuSize.height - bottomSafeMargin))

        return CGPoint(x: x, y: y)
    }
}
