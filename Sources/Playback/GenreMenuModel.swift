// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Picker

/// Whether a genre can play right now (the menu disables one with no playable streams, DESIGN §3).
nonisolated public struct GenreAvailability: Sendable, Equatable {
    public var eligible: Int
    public var total: Int
    /// Why nothing is eligible (when `eligible == 0` and the genre has streams).
    public var reason: Ineligibility?

    public init(eligible: Int, total: Int, reason: Ineligibility? = nil) {
        self.eligible = eligible
        self.total = total
        self.reason = reason
    }

    public var isPlayable: Bool { eligible > 0 }

    /// The menu's explanation for a disabled genre.
    public var unavailableText: String? {
        guard !isPlayable else { return nil }
        guard total > 0 else { return "No streams yet" }
        switch reason {
        case .banned?: return "Every stream is hidden"
        case .backingOff?: return "Streams unavailable - retrying soon"
        case .sourceDisabled?: return "Its sources are switched off"
        case .breakerOpen?: return "Sources unreachable - retrying soon"
        case .engineNotReady?: return "Waiting for the stream engine"
        case .noYouTubeTokens?: return "YouTube is resting - try again in a minute"
        case nil: return "No playable streams right now"
        }
    }
}

/// One row of the genre menu. The same rows feed the plain window's dropdown, the menu-bar Genre menu, the status
/// item and the Dock menu (DESIGN §3 "One NSMenu builder").
nonisolated public struct GenreMenuItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case genre(GenreID)
        case surpriseMe
        case separator
    }

    public var kind: Kind
    public var title: String
    /// Shown under a disabled genre.
    public var subtitle: String?
    public var isEnabled: Bool
    /// The current genre is ticked.
    public var isChecked: Bool
    /// `"1"`…`"9"` for the first nine genres and `"0"` for Surprise Me (with ⌘), when shortcuts are wanted.
    public var keyEquivalent: String?

    public init(kind: Kind, title: String, subtitle: String? = nil, isEnabled: Bool = true, isChecked: Bool = false,
                keyEquivalent: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.keyEquivalent = keyEquivalent
    }

    public var genre: GenreID? { if case .genre(let g) = kind { g } else { nil } }
}

nonisolated public enum GenreMenuModel {
    public static let surpriseTitle = "Surprise Me"

    /// Genres in menu order, then a separator and Surprise Me (enabled when any genre can play). A genre missing from
    /// `availability` (not computed yet) is shown enabled.
    public static func items(genres: [Genre], availability: [GenreID: GenreAvailability], current: GenreID?,
                             shortcuts: Bool) -> [GenreMenuItem] {
        let ordered = genres.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        var out: [GenreMenuItem] = []
        for (i, g) in ordered.enumerated() {
            let a = availability[g.id]
            out.append(GenreMenuItem(kind: .genre(g.id), title: g.name, subtitle: a?.unavailableText,
                                     isEnabled: a?.isPlayable ?? true, isChecked: g.id == current,
                                     keyEquivalent: shortcuts && i < 9 ? String(i + 1) : nil))
        }
        let anyPlayable = ordered.contains { availability[$0.id]?.isPlayable ?? true }
        if !ordered.isEmpty { out.append(GenreMenuItem(kind: .separator, title: "")) }
        out.append(GenreMenuItem(kind: .surpriseMe, title: surpriseTitle,
                                 subtitle: anyPlayable ? nil : "Nothing can play right now", isEnabled: anyPlayable,
                                 keyEquivalent: shortcuts ? "0" : nil))
        return out
    }
}
