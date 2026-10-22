// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SkinUI

@MainActor @Test func moduleLinks() {
    #expect(SkinUIModule.name == "SkinUI")
}
