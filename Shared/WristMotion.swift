//
//  WristMotion.swift
//  Shared (Done + DoneWatch)
//
//  The phone's timeline motions — a block being created, deleted, or
//  changing length — as the watch plays them. The phone decides whether
//  each one plays at all (its 观察站 switches, sent in the snapshot as
//  `WristMotionSettings`) and which style; the watch decides, from two
//  snapshots of its own page, which blocks they apply to, by the phone's
//  rules (`WristMotionPlan`).
//

import Foundation

/// The phone's motion switches. Each is the raw value of the style the
/// phone plays (`EventCreationMotionVariant`, `EventDeletionMotionVariant`,
/// `EventResizeTweenVariant`), nil when that motion is off. Missing from a
/// phone before the field: all off, the page as it always was.
nonisolated struct WristMotionSettings: Codable, Equatable, Sendable {
    var create: WristCreateStyle?
    var delete: WristDeleteStyle?
    var resize: WristResizePace?

    static let off = WristMotionSettings()

    init(create: WristCreateStyle? = nil, delete: WristDeleteStyle? = nil, resize: WristResizePace? = nil) {
        self.create = create
        self.delete = delete
        self.resize = resize
    }

    private enum CodingKeys: String, CodingKey { case create, delete, resize }

    /// A style this watch does not know reads as off for that motion only.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        create = (try? c.decodeIfPresent(String.self, forKey: .create)).flatMap { $0 }.flatMap(WristCreateStyle.init)
        delete = (try? c.decodeIfPresent(String.self, forKey: .delete)).flatMap { $0 }.flatMap(WristDeleteStyle.init)
        resize = (try? c.decodeIfPresent(String.self, forKey: .resize)).flatMap { $0 }.flatMap(WristResizePace.init)
    }
}

nonisolated enum WristCreateStyle: String, Codable, CaseIterable, Sendable {
    case assemble, inkFill, pinDrop, crtOn
}

nonisolated enum WristDeleteStyle: String, Codable, CaseIterable, Sendable {
    case dissolve, shatter, crtOff, fall, pop
}

nonisolated enum WristResizePace: String, Codable, CaseIterable, Sendable {
    case brisk, standard, soft

    /// The phone's `editDuration`: a length changed without a finger.
    var duration: Double {
        switch self {
        case .brisk: return 0.2
        case .standard: return 0.28
        case .soft: return 0.36
        }
    }
}

/// What to play when the page goes from `old` to `new` blocks.
nonisolated struct WristMotionPlan: Equatable, Sendable {
    enum Arrival: Hashable, Sendable {
        /// Drawn on this watch: the draft becomes the block.
        case fromDraft
        /// Arrived from the phone: the phone's create style.
        case style(WristCreateStyle)
        /// Past the first few of one burst: a plain fade.
        case fade
    }

    enum Departure: Equatable, Sendable {
        case style(WristDeleteStyle)
        case fade
    }

    /// By motion key.
    var arrivals: [String: Arrival] = [:]
    /// The blocks that were deleted, as they were last drawn.
    var departures: [(block: WristDayBlock, motion: Departure)] = []
    /// A block's length changed: every block glides to its new place.
    var tween: WristResizePace?

    var isEmpty: Bool { arrivals.isEmpty && departures.isEmpty && tween == nil }

    static func == (lhs: WristMotionPlan, rhs: WristMotionPlan) -> Bool {
        lhs.arrivals == rhs.arrivals && lhs.tween == rhs.tween
            && lhs.departures.map(\.block) == rhs.departures.map(\.block)
            && lhs.departures.map(\.motion) == rhs.departures.map(\.motion)
    }

    /// The phone's `EventCreationMotionRegistry.maxRemoteArrivals`: more new
    /// events than this at once is an import, not someone creating.
    static let maxRemoteArrivals = 8
    /// The phone's `fullMotionGhostsPerBurst`: past this many in one change,
    /// the rest fade.
    static let fullMotionsPerBurst = 3
    /// The phone tweens a length change of at least this many seconds.
    static let minimumLengthChange: TimeInterval = 60

    /// - `oldAll`/`newAll`: every occurrence in the two snapshots, not only
    ///   this page's — a block that left the page for another day, or was
    ///   replaced by an edit, is not a deletion.
    /// - `localCreates`: events this watch created whose start is still in
    ///   flight; their block plays from the draft.
    /// - `sameDay`: false across midnight (or a first page), when the page
    ///   changes wholesale and nothing plays.
    /// - `drawing`: a draft is being drawn; the page reflows around it
    ///   without tweening, as the phone's does under a finger.
    static func make(
        old: [WristDayBlock], new: [WristDayBlock],
        oldAll: [WristOccurrence], newAll: [WristOccurrence],
        localCreates: Set<UUID>, settings: WristMotionSettings,
        sameDay: Bool, drawing: Bool = false, reduceMotion: Bool = false
    ) -> WristMotionPlan {
        var plan = WristMotionPlan()
        guard sameDay, !old.isEmpty || !new.isEmpty else { return plan }
        let oldKeys = Set(old.map(\.motionKey))
        let newKeys = Set(new.map(\.motionKey))

        // Created: the event had no block on this page before, and either
        // this watch made it or it is new to the snapshot altogether — not
        // an exception instance an edit of a series minted.
        if let style = settings.create {
            let oldEvents = Set(old.map(\.occurrence.eventID))
            let knownEvents = Set(oldAll.map(\.eventID))
            let candidates = new.filter { !oldKeys.contains($0.motionKey) && !oldEvents.contains($0.occurrence.eventID) }
            let local = candidates.filter { localCreates.contains($0.occurrence.eventID) }
            let remote = candidates.filter {
                !localCreates.contains($0.occurrence.eventID)
                    && !knownEvents.contains($0.occurrence.eventID)
                    && $0.occurrence.seriesID == nil
            }
            let remoteEvents = Set(newAll.filter { !knownEvents.contains($0.eventID) && $0.seriesID == nil }.map(\.eventID))
                .subtracting(localCreates)
            var full = 0
            for block in local {
                plan.arrivals[block.motionKey] = reduceMotion ? .fade : .fromDraft
                full += 1
            }
            if remoteEvents.count <= maxRemoteArrivals {
                for block in remote {
                    let fullMotion = !reduceMotion && full < fullMotionsPerBurst
                    plan.arrivals[block.motionKey] = fullMotion ? .style(style) : .fade
                    if fullMotion { full += 1 }
                }
            }
        }

        // Deleted: the block left the page, its occurrence is nowhere in the
        // new snapshot, and nothing new took its event's place (an edit
        // changes the occurrence id; an exception instance replaces a
        // series occurrence).
        if let style = settings.delete {
            let newIDs = Set(newAll.map(\.id))
            let oldIDs = Set(oldAll.map(\.id))
            let fresh = newAll.filter { !oldIDs.contains($0.id) }
            let freshEvents = Set(fresh.map(\.eventID))
            let freshAnchors = Set(fresh.map(\.anchorID))
            var full = 0
            for block in old where !newKeys.contains(block.motionKey) {
                let occurrence = block.occurrence
                guard !newIDs.contains(occurrence.id),
                      !freshEvents.contains(occurrence.eventID),
                      !freshAnchors.contains(occurrence.anchorID) else { continue }
                let fullMotion = !reduceMotion && full < fullMotionsPerBurst
                plan.departures.append((block, fullMotion ? .style(style) : .fade))
                if fullMotion { full += 1 }
            }
        }

        // Length changed: some block on both pages is a minute longer or
        // shorter. A block that only moved keeps its length and jumps.
        if let pace = settings.resize, !drawing, !reduceMotion {
            let before = Dictionary(old.map { ($0.motionKey, $0.end.timeIntervalSince($0.start)) },
                                    uniquingKeysWith: { a, _ in a })
            let resized = new.contains { block in
                guard let length = before[block.motionKey] else { return false }
                return abs(block.end.timeIntervalSince(block.start) - length) >= minimumLengthChange
            }
            if resized { plan.tween = pace }
        }
        return plan
    }
}
