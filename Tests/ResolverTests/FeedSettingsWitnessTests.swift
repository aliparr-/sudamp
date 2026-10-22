// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Testing
@testable import Resolver

@Test func resolverServiceIsTheSetSettingsWitness() async {
    let root = FileManager.default.temporaryDirectory.appending(path: "witness-\(UUID().uuidString)")
    let service = ResolverService(layout: EngineLayout(paths: .profile(root)), engine: nil)
    var bad = ResolverSettings.standard
    bad.formats[.youtube] = "-o/tmp/x"
    let backend: any ResolveBackend = service
    let rejected = await backend.setSettings(bad)
    #expect(!rejected.isEmpty, "the protocol-extension default ([]) must not be the witness")
}
