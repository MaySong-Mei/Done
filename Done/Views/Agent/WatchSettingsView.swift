//
//  WatchSettingsView.swift
//  Done
//
//  Settings → Apple Watch: what the watch's stats page counts, how it
//  credits overlapping events, and which period it opens on. Stored on the
//  phone (`AppSettingsKeys.watchStatsSettings`) and sent in every
//  `WristSnapshot`; the watch has no settings of its own.
//

import SwiftUI

extension WristStatsSettings {
    /// The stored settings; `.standard` when nothing is stored or it does
    /// not decode.
    static func load(from defaults: UserDefaults) -> WristStatsSettings {
        decode(defaults.string(forKey: AppSettingsKeys.watchStatsSettings))
    }

    static func decode(_ raw: String?) -> WristStatsSettings {
        guard let data = raw?.data(using: .utf8),
              let settings = try? JSONDecoder().decode(WristStatsSettings.self, from: data) else { return .standard }
        return settings
    }

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension UserDefaults {
    /// Settings → Apple Watch, observable: key-value observing of a defaults
    /// key goes by this property's name, which is therefore the key's
    /// (`AppSettingsKeys.watchStatsSettings`).
    @objc dynamic var watchStatsSettings: String? {
        string(forKey: AppSettingsKeys.watchStatsSettings)
    }
}

struct WatchSettingsView: View {
    @EnvironmentObject private var store: EventStore
    @AppStorage(AppSettingsKeys.watchStatsSettings) private var raw = ""
    @AppStorage(AppSettingsKeys.meBackgroundTypes) private var backgroundRaw = AppSettingsKeys.meBackgroundTypesDefault
    /// The categories the stats know, read once on appear.
    @State private var knownTypes: [String] = []

    private var settings: WristStatsSettings { WristStatsSettings.decode(raw) }

    private func update(_ change: (inout WristStatsSettings) -> Void) {
        var copy = settings
        change(&copy)
        raw = copy.encoded
    }

    var body: some View {
        settingsPage(L(.watchSettings)) {
            settingsCard(L(.watchStatsPage)) {
                settingsPickerRow(
                    L(.watchStatsOpensOn),
                    selection: Binding(get: { settings.defaultPeriod }, set: { value in update { $0.defaultPeriod = value } }),
                    options: WristStatsPeriod.allCases.map { ($0, Self.title(of: $0)) }
                )
                settingsPickerRow(
                    L(.watchStatsOverlap),
                    selection: Binding(get: { settings.overlap }, set: { value in update { $0.overlap = value } }),
                    options: WristOverlapRule.allCases.map { ($0, Self.title(of: $0)) }
                )
                settingsHintText(Self.hint(of: settings.overlap))
            }

            settingsCard(L(.watchStatsTypes)) {
                Toggle(L(.watchStatsLeaveOutBackground), isOn: Binding(
                    get: { settings.excludesBackground },
                    set: { value in update { $0.excludesBackground = value } }
                ))
                settingsHintText(L(.hintWatchStatsBackground))
                Divider()
                if knownTypes.isEmpty {
                    settingsHintText(L(.watchStatsNoTypesYet))
                } else {
                    ForEach(knownTypes, id: \.self) { name in
                        typeRow(name)
                    }
                }
                settingsHintText(L(.hintWatchStatsTypes))
            }
        }
        .onAppear { knownTypes = Self.types(in: store.latestCategoryStats, keeping: settings.excludedTypes) }
    }

    /// One type: on when the watch counts it. A background type is shown
    /// off while background types are left out, and cannot be turned on
    /// from here.
    private func typeRow(_ name: String) -> some View {
        let background = settings.excludesBackground
            && MeBackgroundTypes.contains(name, in: MeBackgroundTypes.parse(backgroundRaw))
        let picked = settings.excludedTypes.contains { $0.lowercased() == name.lowercased() }
        return Toggle(isOn: Binding(
            get: { !picked && !background },
            set: { counted in
                update { settings in
                    settings.excludedTypes.removeAll { $0.lowercased() == name.lowercased() }
                    if !counted { settings.excludedTypes.append(name) }
                    settings.excludedTypes.sort()
                }
            }
        )) {
            HStack(spacing: 8) {
                Circle()
                    .fill(EventTypeTemplateStore.color(for: name))
                    .frame(width: 10, height: 10)
                Text(name)
            }
        }
        .disabled(background)
    }

    /// The stats payload's categories — every type with time in it — plus any
    /// left-out name it no longer holds (so it can be turned back on).
    static func types(in payload: CategoryStatsPayload?, keeping excluded: [String]) -> [String] {
        var names = (payload?.categories ?? []).compactMap(\.name)
        for name in excluded where !names.contains(where: { $0.lowercased() == name.lowercased() }) {
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func title(of period: WristStatsPeriod) -> String {
        switch period {
        case .today: return L(.watchStatsPeriodToday)
        case .threeDays: return L(.watchStatsPeriodThreeDays)
        case .sevenDays: return L(.watchStatsPeriodSevenDays)
        case .thirtyDays: return L(.watchStatsPeriodThirtyDays)
        }
    }

    static func title(of rule: WristOverlapRule) -> String {
        switch rule {
        case .split: return L(.watchOverlapSplit)
        case .full: return L(.watchOverlapFull)
        case .latestStart: return L(.watchOverlapLatestStart)
        }
    }

    static func hint(of rule: WristOverlapRule) -> String {
        switch rule {
        case .split: return L(.hintWatchOverlapSplit)
        case .full: return L(.hintWatchOverlapFull)
        case .latestStart: return L(.hintWatchOverlapLatestStart)
        }
    }
}
