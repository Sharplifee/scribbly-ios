import Foundation
import os

/// The learned set of voices, and the logic that decides whether a new
/// embedding is someone known, someone new, or too ambiguous to guess.
///
/// Design choice: a speaker is a CENTROID of many embeddings, not a single
/// enrollment sample. Every confirmed match folds back in, so the profile
/// tightens with use — which is what makes "it gets better after you answer
/// a couple times" actually true rather than a slogan.
public actor SpeakerRegistry {

    public struct Profile: Codable, Identifiable {
        public let id: String
        public var displayName: String
        /// Running mean of every confirmed embedding.
        public var centroid: [Float]
        public var sampleCount: Int
        public var firstSeen: Date
        public var lastSeen: Date
        /// True once a human confirmed the label.
        public var confirmed: Bool
    }

    public enum Match {
        /// Confident hit.
        case known(Profile, similarity: Float)
        /// Between the floors — plausible but needs asking.
        case ambiguous(candidates: [(Profile, Float)])
        /// Nothing close. A new voice.
        case unknown(provisionalID: String)
    }

    /// Above this, accept silently.
    public var acceptThreshold: Float = 0.72
    /// Below this, treat as a brand-new voice. Between the two, ask.
    public var rejectThreshold: Float = 0.55

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "identity")
    private var profiles: [String: Profile] = [:]
    private let storeURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storeURL = base.appendingPathComponent("speakers.json")
        load()
    }

    // MARK: - Matching

    public func match(_ embedding: [Float]) -> Match {
        guard !profiles.isEmpty else {
            return .unknown(provisionalID: "spk-\(UUID().uuidString.prefix(8))")
        }

        let scored = profiles.values
            .map { ($0, SpeakerEmbedder.similarity(embedding, $0.centroid)) }
            .sorted { $0.1 > $1.1 }

        guard let best = scored.first else {
            return .unknown(provisionalID: "spk-\(UUID().uuidString.prefix(8))")
        }

        if best.1 >= acceptThreshold {
            return .known(best.0, similarity: best.1)
        }
        if best.1 >= rejectThreshold {
            return .ambiguous(candidates: Array(scored.prefix(3)))
        }
        return .unknown(provisionalID: "spk-\(UUID().uuidString.prefix(8))")
    }

    // MARK: - Learning

    /// Fold a confirmed embedding into a profile, creating it if new.
    /// This is the call that makes the system improve after you answer.
    public func reinforce(id: String, displayName: String?, embedding: [Float], confirmed: Bool) {
        if var existing = profiles[id] {
            existing.centroid = Self.runningMean(
                current: existing.centroid,
                count: existing.sampleCount,
                new: embedding
            )
            existing.sampleCount += 1
            existing.lastSeen = Date()
            if let displayName { existing.displayName = displayName }
            existing.confirmed = existing.confirmed || confirmed
            profiles[id] = existing
            log.info("reinforced \(id, privacy: .public) n=\(existing.sampleCount, privacy: .public)")
        } else {
            profiles[id] = Profile(
                id: id,
                displayName: displayName ?? "Unknown",
                centroid: embedding,
                sampleCount: 1,
                firstSeen: Date(),
                lastSeen: Date(),
                confirmed: confirmed
            )
            log.info("created profile \(id, privacy: .public)")
        }
        persist()
    }

    /// Merge two profiles discovered to be the same person.
    public func merge(_ sourceID: String, into targetID: String) {
        guard let source = profiles[sourceID], var target = profiles[targetID] else { return }
        let total = source.sampleCount + target.sampleCount
        guard total > 0 else { return }

        var merged = [Float](repeating: 0, count: target.centroid.count)
        for i in 0..<merged.count {
            merged[i] = (target.centroid[i] * Float(target.sampleCount)
                       + source.centroid[i] * Float(source.sampleCount)) / Float(total)
        }
        target.centroid = SpeakerEmbedder.l2Normalize(merged)
        target.sampleCount = total
        target.firstSeen = min(target.firstSeen, source.firstSeen)
        target.lastSeen = max(target.lastSeen, source.lastSeen)
        profiles[targetID] = target
        profiles.removeValue(forKey: sourceID)
        persist()
        log.info("merged \(sourceID, privacy: .public) into \(targetID, privacy: .public)")
    }

    public func rename(_ id: String, to displayName: String) {
        guard var p = profiles[id] else { return }
        p.displayName = displayName
        p.confirmed = true
        profiles[id] = p
        persist()
    }

    public func all() -> [Profile] {
        profiles.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func nameMap() -> [String: String] {
        profiles.mapValues(\.displayName)
    }

    /// Voices seen repeatedly but never named — the queue for "who was that?"
    public func unconfirmed(minSamples: Int = 2) -> [Profile] {
        profiles.values.filter { !$0.confirmed && $0.sampleCount >= minSamples }
            .sorted { $0.sampleCount > $1.sampleCount }
    }

    static func runningMean(current: [Float], count: Int, new: [Float]) -> [Float] {
        guard current.count == new.count, count > 0 else { return new }
        var out = [Float](repeating: 0, count: current.count)
        let n = Float(count)
        for i in 0..<out.count {
            out[i] = (current[i] * n + new[i]) / (n + 1)
        }
        return SpeakerEmbedder.l2Normalize(out)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(profiles.values)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: storeURL),
            let list = try? JSONDecoder().decode([Profile].self, from: data)
        else { return }
        profiles = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        log.info("loaded \(self.profiles.count, privacy: .public) speaker profiles")
    }
}
