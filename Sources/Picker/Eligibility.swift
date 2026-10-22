// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// Everything outside the Picker that decides whether a stream may be picked right now (DESIGN §7.3). It is plain
/// data, gathered by the PlaybackController from the library, Resolver (token bucket, cache), breakers and engine.
public struct PickContext: Sendable {
    public var now: Date
    /// "Never play again" (library.json).
    public var banned: Set<StreamID>
    /// Kill switches and fast-start order come from the active feed's engine section.
    public var engine: EngineConfig
    /// Platforms whose breaker is open (half-open breakers allow their probe, so they are not listed).
    public var openBreakers: Set<SourceKind>
    /// yt-dlp installed and verified; without it only radio is eligible.
    public var engineReady: Bool
    /// Whole tokens left in the shared YouTube bucket (DESIGN §6.3).
    public var youtubeTokens: Int
    /// Streams with an unexpired cached resolution (they need no token and start fast).
    public var cachedResolutions: Set<StreamID>
    /// The active feed's revision (hidden streams return with a newer one).
    public var feedRevision: Int

    public init(now: Date, banned: Set<StreamID> = [], engine: EngineConfig = .defaults, openBreakers: Set<SourceKind> = [],
                engineReady: Bool = true, youtubeTokens: Int = 3, cachedResolutions: Set<StreamID> = [], feedRevision: Int = 0) {
        self.now = now
        self.banned = banned
        self.engine = engine
        self.openBreakers = openBreakers
        self.engineReady = engineReady
        self.youtubeTokens = youtubeTokens
        self.cachedResolutions = cachedResolutions
        self.feedRevision = feedRevision
    }
}

/// Why a stream can't be picked now (also used to explain a disabled genre in the menu).
public enum Ineligibility: String, Sendable, Equatable, CaseIterable {
    case banned
    case backingOff
    case sourceDisabled
    case breakerOpen
    case engineNotReady
    case noYouTubeTokens
}

public enum Eligibility {
    /// `eligible(s)` from DESIGN §7.3:
    /// ¬banned ∧ now ≥ nextEligibleAt ∧ source enabled ∧ breaker ≠ open ∧ (radio ∨ engineReady)
    /// ∧ (source ≠ youtube ∨ tokens ≥ 1 ∨ resolution cached). `youtube-live` counts as YouTube throughout.
    public static func reason(_ s: StreamRef, health: StreamHealth?, context c: PickContext) -> Ineligibility? {
        if c.banned.contains(s.id) { return .banned }
        if let h = health, !h.isEligible(now: c.now, revision: c.feedRevision) { return .backingOff }
        if !c.engine.isSourceEnabled(s.source) { return .sourceDisabled }
        if c.openBreakers.contains(s.source) || c.openBreakers.contains(s.source.platform) { return .breakerOpen }
        if !s.isRadio && !c.engineReady { return .engineNotReady }
        if s.source.platform == .youtube && c.youtubeTokens < 1 && !c.cachedResolutions.contains(s.id) {
            return .noYouTubeTokens
        }
        return nil
    }

    public static func isEligible(_ s: StreamRef, health: StreamHealth?, context: PickContext) -> Bool {
        reason(s, health: health, context: context) == nil
    }

    /// Ready to play at once: radio, or a stream with an unexpired cached resolution (fast-start preference).
    public static func isReady(_ s: StreamRef, context: PickContext) -> Bool {
        s.isRadio || context.cachedResolutions.contains(s.id)
    }
}
