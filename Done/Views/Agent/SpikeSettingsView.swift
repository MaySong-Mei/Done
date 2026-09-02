//
//  SpikeSettingsView.swift
//  Done
//
//  gh#197 SPIKE — Settings → Experimental → Spikes → spike detail.
//
//  Deliberately English-only and undiscoverable rather than DEBUG-gated,
//  mirroring `DeveloperSettingsView`'s own stated audience ("whoever is
//  building the app, not end users") and gh#165's spike toggle, which
//  shipped the same way: reachable in every build, off by default, no
//  extra entitlement gate. See the harness report's decision points for
//  the build-gating tradeoff this deliberately did not resolve.
//

import Combine
import SwiftUI

struct SpikeListView: View {
    @EnvironmentObject private var spikeSession: SpikeSessionCoordinator

    var body: some View {
        settingsPage("Spikes") {
            settingsHintCard("Developer-only probes for investigation issues (gh#197). Nothing here runs unless a spike's instrumentation is enabled AND a scenario is started — both default off.")

            // The management surface for parallel arming: every armed run
            // across every spike, stoppable individually, without having
            // to visit each spike's own detail page.
            if !spikeSession.activeRuns.isEmpty {
                settingsCard("Active Runs") {
                    ForEach(Array(spikeSession.activeRuns.enumerated()), id: \.element.id) { index, run in
                        activeRunRow(run)
                        if index != spikeSession.activeRuns.count - 1 {
                            Divider()
                        }
                    }
                    // Only earns its place once there is more than one
                    // run to manage — with a single run it duplicates
                    // that run's own Stop.
                    if spikeSession.activeRuns.count > 1 {
                        Divider()
                        Button("Stop All") {
                            spikeSession.stopAll()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            settingsCard("Registered Spikes") {
                ForEach(Array(SpikeRegistry.all.enumerated()), id: \.element.id) { index, definition in
                    NavigationLink {
                        SpikeDetailView(definition: definition)
                    } label: {
                        spikeRow(definition)
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    if index != SpikeRegistry.all.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activeRunRow(_ run: SpikeSessionCoordinator.ActiveRun) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SpikeRegistry.definition(for: run.spikeID)?.title ?? run.spikeID)
                    .font(.subheadline.weight(.semibold))
                Text(activeRunScenarioTitle(run))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Started \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Stop") {
                spikeSession.stop(runID: run.id)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }

    private func activeRunScenarioTitle(_ run: SpikeSessionCoordinator.ActiveRun) -> String {
        SpikeRegistry.definition(for: run.spikeID)?
            .scenarios.first { $0.id == run.scenarioID }?.title ?? run.scenarioID
    }

    private func spikeRow(_ definition: SpikeDefinition) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(definition.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    lifecycleBadge(definition.lifecycle)
                    // Only feature spikes get a kind badge, so measurement
                    // rows render exactly as before.
                    if definition.kind == .featureToggle {
                        Text("feature")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.16), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                if let issueNumber = definition.issueNumber {
                    Text("gh#\(issueNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct SpikeDetailView: View {
    let definition: SpikeDefinition

    @EnvironmentObject private var store: EventStore
    /// This view is a REMOTE CONTROL: the coordinator (and through it,
    /// every runner) is owned at the app level, so a run armed here keeps
    /// running when this sheet-presented screen is dismissed. v1's
    /// `@StateObject`-owned runner died with the sheet mid-run — the
    /// gh#197 v2 blocker.
    @EnvironmentObject private var spikeSession: SpikeSessionCoordinator
    @AppStorage private var enabled: Bool
    /// Only rendered (and only meaningful) when the definition declares
    /// variants; persists as a plain string so gate sites can read it with
    /// the same @AppStorage idiom as the enabled flag.
    @AppStorage private var selectedVariantID: String
    @State private var runs: [SpikeRun] = []
    /// Polled, never pushed. The gh#201 runner deliberately does NOT
    /// publish per gesture: its whole measurement lives on the effort
    /// scrubber's hot path, and a Combine send per phase would be the
    /// instrument changing what it measures. This screen is not even on
    /// screen while the user taps, so a one-second poll while armed is
    /// enough to prove the rig is seeing gestures.
    @State private var liveGestureCount = 0
    /// Run-level signal totals (gh#201 round 3 / R8). A zero and a dead
    /// wire read identically hours later in the file; here they are a
    /// glance apart. Navigating into the detail page alone drives the page
    /// total up (`.navigationDestination(item:)` hangs off
    /// `CalendarPageView.body`), and the scenario asks for one calendar
    /// scroll, which drives the day-layer totals.
    @State private var livePageBodyCount = 0
    @State private var liveDayLayerCount = 0
    @State private var liveDayLayerAppliedCount = 0
    private let liveCountTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var noteDrafts: [UUID: String] = [:]

    private var runner195: Spike195Runner { spikeSession.runner195 }
    private var runner201: Spike201Runner { spikeSession.runner201 }

    /// Whether THIS spike has a run armed right now (gh#201 round 3 / R5).
    /// Not "is anything armed": another spike's run must not lock this
    /// spike's controls.
    private var hasArmedRun: Bool {
        spikeSession.activeRuns.contains { $0.spikeID == definition.id }
    }

    init(definition: SpikeDefinition) {
        self.definition = definition
        _enabled = AppStorage(wrappedValue: false, SpikeFeatureFlag.enabledKey(definition.id))
        _selectedVariantID = AppStorage(
            wrappedValue: definition.variants.first?.id ?? "",
            SpikeFeatureFlag.variantKey(definition.id)
        )
    }

    var body: some View {
        settingsPage(definition.title) {
            settingsCard("Purpose") {
                Text(definition.purpose)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsCard("Status") {
                // For a feature spike the toggle IS the feature flag, so it
                // must not be labeled as instrumentation.
                Toggle(definition.kind == .featureToggle ? "Feature enabled" : "Instrumentation enabled", isOn: $enabled)
                    .disabled(hasArmedRun)
                // Gated on "has variants", NOT on `.featureToggle`: gh#201
                // round 2 is a MEASUREMENT spike whose variants each remove
                // one publish from the commit path so the cost can be
                // attributed. A measurement spike may have variants too.
                if !definition.variants.isEmpty {
                    Picker("Variant", selection: $selectedVariantID) {
                        ForEach(definition.variants) { variant in
                            Text(variant.title).tag(variant.id)
                        }
                    }
                    .disabled(hasArmedRun)
                }
                settingsLabeledRow("Lifecycle", value: definition.lifecycle.rawValue)
                if let issueNumber = definition.issueNumber {
                    settingsLabeledRow("Issue", value: "gh#\(issueNumber)")
                }
                if definition.kind == .featureToggle {
                    settingsHintText("Turns the candidate feature on in the app itself. Off means stock behavior. Feature flags are independent — any set of features can be enabled at once.")
                } else {
                    settingsHintText("Enabling arms nothing by itself — it only allows a scenario's Start/Run button below to attach instrumentation. Both must be on for anything to run.")
                    if !definition.variants.isEmpty {
                        // Corrected in gh#201 round 3. The old wording
                        // ("it only takes effect while this spike is
                        // enabled") let a reader believe the variant was a
                        // measurement setting. A non-stock variant REMOVES
                        // A PUBLISH FROM PRODUCTION for as long as the run
                        // is armed.
                        settingsHintText("A non-stock variant changes what the app actually does — it removes one publish from the effort-commit path — for as long as a run is armed. It is snapshotted when Start is tapped, so these two controls lock while the run is armed and unlock when it stops.")
                    }
                }
                if hasArmedRun {
                    settingsHintText("Locked: a run of this spike is armed. Stop it to change these.")
                }
            }

            if !definition.scenarios.isEmpty {
                settingsCard("Scenarios") {
                    ForEach(Array(definition.scenarios.enumerated()), id: \.element.id) { index, scenario in
                        scenarioRow(scenario)
                        if index != definition.scenarios.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            if !runs.isEmpty {
                settingsCard("Latest Runs") {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        runRow(run)
                        if index != runs.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: runner195.lastCompletedRun) { _, _ in refresh() }
        .onChange(of: runner201.lastCompletedRun) { _, _ in refresh() }
        .onReceive(liveCountTicker) { _ in
            let armed = runner201.isArmed
            liveGestureCount = armed ? runner201.recordedGestureCount : 0
            livePageBodyCount = armed ? runner201.recordedCalendarPageBodyTotal : 0
            liveDayLayerCount = armed ? runner201.recordedCalendarDayLayerTotal : 0
            liveDayLayerAppliedCount = armed ? runner201.recordedCalendarDayLayerAppliedTotal : 0
        }
    }

    private func refresh() {
        // Runs armed by THIS process are excluded: this screen can appear
        // while a run is live (that is the point of app-level ownership),
        // and reconciling an armed run's write-ahead record would close it
        // as interrupted mid-measurement.
        SpikeRunStore.reconcileInterruptedRuns(
            spikeIDs: [definition.id],
            excludingRunIDs: spikeSession.armedRunIDs
        )
        runs = SpikeRunStore.latestRuns(spikeID: definition.id, limit: 20)
    }

    @ViewBuilder
    private func scenarioRow(_ scenario: SpikeScenario) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(scenario.title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                scenarioActionButton(scenario)
            }
            Text(scenario.instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// Wired scenarios get a real Start/Stop; everything else shows an
    /// honest placeholder rather than a button that does nothing.
    @ViewBuilder
    private func scenarioActionButton(_ scenario: SpikeScenario) -> some View {
        if definition.id == Spike201Runner.spikeID, scenario.id == Spike201Runner.scenarioID {
            if runner201.isArmed {
                VStack(alignment: .trailing, spacing: 4) {
                    // Live count: twenty taps into a run that never saw a
                    // single one would otherwise look identical to twenty
                    // taps that worked, until the file is read hours later.
                    Text("\(liveGestureCount) gestures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    // Same one-second poll, three more numbers: a live 0
                    // here is a dead wire, and non-zero totals beside
                    // all-zero per-gesture counts is a real finding.
                    Text("page \(livePageBodyCount) · layer \(liveDayLayerCount)/\(liveDayLayerAppliedCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Stop") {
                        runner201.cancel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                Button("Start") {
                    runner201.start(store: store)
                }
                .buttonStyle(.bordered)
                .disabled(!enabled)
            }
        } else if definition.id == Spike195Runner.spikeID, scenario.id == Spike195Runner.scenarioID {
            if runner195.isArmed {
                Button("Stop") {
                    runner195.cancel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button(scenario.kind == .automated ? "Run" : "Start") {
                    runner195.start(store: store)
                }
                .buttonStyle(.bordered)
                .disabled(!enabled)
            }
        } else {
            Text("Not wired in this build")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func runRow(_ run: SpikeRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.weight(.semibold))
                Spacer()
                outcomeBadge(run)
            }
            if !run.metrics.isEmpty {
                Text(metricsSummary(run))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top) {
                TextField("Note", text: noteBinding(for: run), axis: .vertical)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    saveNote(for: run)
                }
                .font(.caption)
                .disabled(noteDraftMatchesSaved(run))
            }
        }
        .padding(.vertical, 4)
    }

    private func noteBinding(for run: SpikeRun) -> Binding<String> {
        Binding(
            get: { noteDrafts[run.id] ?? run.note ?? "" },
            set: { noteDrafts[run.id] = $0 }
        )
    }

    private func noteDraftMatchesSaved(_ run: SpikeRun) -> Bool {
        (noteDrafts[run.id] ?? run.note ?? "") == (run.note ?? "")
    }

    private func saveNote(for run: SpikeRun) {
        guard let draft = noteDrafts[run.id] else { return }
        SpikeRunStore.setNote(draft, forRunID: run.id, spikeID: definition.id)
        refresh()
    }

    private func outcomeBadge(_ run: SpikeRun) -> some View {
        let (label, color): (String, Color) = {
            switch run.outcome {
            case .completed: return ("completed", .green)
            case .aborted: return ("aborted", .orange)
            case .interrupted: return ("interrupted", .red)
            case nil: return ("in progress", .blue)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func metricsSummary(_ run: SpikeRun) -> String {
        run.metrics.keys.sorted().map { key in
            "\(key)=\(metricValueDescription(run.metrics[key]!))"
        }.joined(separator: "  ")
    }

    private func metricValueDescription(_ value: SpikeMetricValue) -> String {
        switch value {
        case .number(let v):
            return v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v)
        case .string(let v): return v
        case .bool(let v): return v ? "true" : "false"
        }
    }
}

private func lifecycleBadge(_ lifecycle: SpikeLifecycle) -> some View {
    Text(lifecycle.rawValue)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(lifecycleColor(lifecycle).opacity(0.16), in: Capsule())
        .foregroundStyle(lifecycleColor(lifecycle))
}

private func lifecycleColor(_ lifecycle: SpikeLifecycle) -> Color {
    switch lifecycle {
    case .active: return .green
    case .concluded: return .gray
    case .removed: return .red
    }
}
