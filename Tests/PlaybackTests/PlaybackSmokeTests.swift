import Testing
@testable import Playback

@MainActor @Test func moduleLinks() {
    #expect(PlaybackModule.name == "Playback")
}
