// SPDX-License-Identifier: GPL-3.0-or-later

/// Feeds: the bundled snapshot (M1) and the signed remote feed (M7): fetch with ETag, Ed25519 verification,
/// anti-rollback, expiry, the `<profile>/feed/` cache and the 12 h refresh (DESIGN §4, §7.2).
public enum FeedsModule {
    public static let name = "Feeds"
}
