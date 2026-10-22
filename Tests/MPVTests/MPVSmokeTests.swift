// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import SudampAO
@testable import MPV

@Test func libmpvLinksAtExpectedAPI() {
    // MPVKit 1.0.0 = mpv v0.41.0, client API 2.5.
    #expect(MPVInfo.clientAPIVersion == 131077)
}

@Test func pullAODescriptionIsLinked() {
    #expect(String(cString: sudamp_ao_description()) == "sudamp pull AO")
    #expect(PullAO.driverDescription == "sudamp pull AO")
}
