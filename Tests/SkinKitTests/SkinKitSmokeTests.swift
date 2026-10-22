// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SkinKit

@Test func moduleLinks() {
    #expect(SkinKitModule.name == "SkinKit")
    #expect(SkinKitModule.webampCommit.hasPrefix("7734cd3"))
}
