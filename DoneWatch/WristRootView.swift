//
//  WristRootView.swift
//  DoneWatch
//
//  Three screens, chosen by `WristStateReducer.display`: nothing from the
//  phone yet; the start grid; the running session. The minute schedule
//  re-resolves the state at event boundaries; the elapsed counter ticks on
//  its own through `Text(_:style: .timer)`.
//

import SwiftUI

struct WristRootView: View {
    @EnvironmentObject private var client: WristSessionClient
    private let housekeeping = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
        }
        .onReceive(housekeeping) { now in
            client.tick(now: now)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let strings = WristStrings(code: client.snapshot?.language)
        switch client.display(now: now) {
        case .noPhoneData:
            WristEmptyView(strings: strings)
        case .idle(let types, let since):
            WristIdleView(
                types: types,
                sinceLastRecord: since,
                snapshotAge: client.snapshot.map { now.timeIntervalSince($0.generatedAt) },
                strings: strings,
                onStart: { client.start($0) }
            )
        case .active(let occurrence, let pending):
            WristActiveView(
                occurrence: occurrence,
                pending: pending,
                strings: strings,
                onExtend: { client.extend(occurrence) },
                onFinish: { client.finish(occurrence) }
            )
        }
    }
}

struct WristEmptyView: View {
    let strings: WristStrings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(strings.noPhoneData)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle(strings.appTitle)
    }
}

struct WristIdleView: View {
    let types: [WristType]
    let sinceLastRecord: TimeInterval?
    let snapshotAge: TimeInterval?
    let strings: WristStrings
    let onStart: (WristType) -> Void

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let since = sinceLastRecord, since < 12 * 3600 {
                    Text(strings.sinceLastRecord(since))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if types.isEmpty {
                    Text(strings.noTypes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(types) { type in
                        Button {
                            onStart(type)
                        } label: {
                            Text(type.title)
                                .font(.system(.callout, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .background(
                            WristColor.color(type.colorHex),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(WristColor.foreground(on: type.colorHex))
                    }
                }
                if let age = snapshotAge, age > 24 * 3600 {
                    Text(strings.stale(age))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(strings.appTitle)
    }
}

struct WristActiveView: View {
    let occurrence: WristOccurrence
    let pending: Bool
    let strings: WristStrings
    let onExtend: () -> Void
    let onFinish: () -> Void

    private var color: Color { WristColor.color(occurrence.colorHex) }

    var body: some View {
        VStack(spacing: 4) {
            if occurrence.type != occurrence.title, !occurrence.type.isEmpty {
                Text(occurrence.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(occurrence.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(occurrence.start, style: .timer)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if !occurrence.isOpenEnded {
                Text(strings.endsAt(occurrence.end))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if occurrence.quickActionsEnabled {
                HStack(spacing: 8) {
                    Button(strings.extend, action: onExtend)
                    Button(strings.finish, action: onFinish)
                        .tint(color)
                        .handGestureShortcut(.primaryAction)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            } else {
                Text(strings.editOnPhone)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if pending {
                Text(strings.sending)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .navigationTitle(strings.appTitle)
        .containerBackground(color.opacity(0.45).gradient, for: .navigation)
    }
}

enum WristColor {
    static func color(_ hex: String) -> Color {
        guard let rgb = components(hex) else { return .gray }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Black on light fills, white on dark ones.
    static func foreground(on hex: String) -> Color {
        guard let rgb = components(hex) else { return .white }
        let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
        return luminance > 0.6 ? .black : .white
    }

    private static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 8, let value = UInt64(sanitized, radix: 16) else {
            return nil
        }
        let shift: UInt64 = sanitized.count == 8 ? 8 : 0
        return (
            Double((value >> (16 + shift)) & 0xFF) / 255,
            Double((value >> (8 + shift)) & 0xFF) / 255,
            Double((value >> shift) & 0xFF) / 255
        )
    }
}
