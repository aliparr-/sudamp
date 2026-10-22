// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Feeds
import Foundation
import Synchronization
import Testing
@testable import Playback
@testable import Resolver

/// Records the install policy each first install gets.
final class RecordingEngines: EngineProviding {
    let policies = Mutex<[EngineInstallPolicy]>([])

    func readiness() async -> EngineReadiness { .missing }

    func install(policy: EngineInstallPolicy, progress: @escaping @Sendable (EngineInstallPhase) -> Void) async throws
        -> EngineReadiness {
        policies.withLock { $0.append(policy) }
        return .ready(version: policy.pin?.version ?? "2026.10.21", executable: URL(filePath: "/nonexistent/yt-dlp_macos"))
    }
}

private func remoteFeed(_ streams: [StreamRef], revision: Int, engine: EngineConfig = .defaults) -> LoadedFeed {
    let doc = FeedDocument(revision: revision, generatedAt: fakeT0, expiresAt: nil,
                           catalog: FeedCatalog(genres: [Genre(id: deepHouse, name: "Deep House", order: 1),
                                                         Genre(id: techno, name: "Techno", order: 2)], streams: streams),
                           engine: engine)
    return LoadedFeed(document: doc, origin: .fetched, url: URL(filePath: "/dev/null"))
}

@MainActor @Test func firstEngineChoiceWaitsForTheLaunchFeed() async {
    let engines = RecordingEngines()
    let streams = [stream(.radio, 1), stream(.radio, 2), stream(.soundcloud, 1)]
    let h = Harness(streams, engines: engines) { $0.engineMode = .install }
    var remote = EngineConfig.defaults
    remote.pin = EnginePin(version: "2026.08.19", sha256: String(repeating: "a", count: 64))
    remote.block = ["2026.10.21"]
    let fetched = remoteFeed(streams, revision: 4, engine: remote)
    let gateCalls = Mutex(0)
    h.controller.feedBeforeEngineChoice = {
        gateCalls.withLock { $0 += 1 }
        try? await Task.sleep(for: .milliseconds(50))   // the launch fetch takes a moment
        return fetched
    }
    await h.controller.prepare()
    await h.until("install") { !engines.policies.withLock { $0 }.isEmpty }
    #expect(engines.policies.withLock { $0 } == [EngineInstallPolicy(pin: .init(version: "2026.08.19",
                                                                             sha256: String(repeating: "a", count: 64)),
                                                                   block: ["2026.10.21"])])
    #expect(h.controller.feed.document.revision == 4)
    #expect(gateCalls.withLock { $0 } == 1)
    #expect(h.controller.feedBeforeEngineChoice == nil, "used once")
}

@MainActor @Test func applyFeedSwapsTheCatalogAndKeepsPlaying() async {
    let h = Harness([stream(.radio, 1), stream(.radio, 2), stream(.soundcloud, 1)])
    let playing = await h.startPlaying()
    let next = remoteFeed([stream(.radio, 1), stream(.radio, 3), stream(.soundcloud, 1), stream(.soundcloud, 2)],
                          revision: 4)
    h.controller.applyFeed(next)
    #expect(h.controller.feed.document.revision == 4)
    #expect(h.controller.catalog.streams.map(\.id) == next.document.catalog.streams.map(\.id))
    #expect(h.controller.phase == .playing && h.controller.currentStream?.id == playing?.id)
    #expect(h.metricsEvents("feed.applied").first?["to"] as? Int == 4)
    h.controller.applyFeed(next)
    #expect(h.metricsEvents("feed.applied").count == 1, "the same document again is a no-op")
}
