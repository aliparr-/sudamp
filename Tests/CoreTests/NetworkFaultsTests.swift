// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Core

@Suite struct NetworkFaultsTests {
    @Test func grammar() {
        #expect(NetworkFaults.parse("net:offline") == NetworkFaults(offlineFor: 30, offlineAfter: 20))
        #expect(NetworkFaults.parse("youtube:403,net:offline=45") == NetworkFaults(offlineFor: 45, offlineAfter: 20))
        #expect(NetworkFaults.parse("net:offline=30@5") == NetworkFaults(offlineFor: 30, offlineAfter: 5))
        #expect(NetworkFaults.parse("net:offline=-3").offlineFor == 30, "a bad value keeps the default")
        #expect(!NetworkFaults.parse("engine:corrupt").isActive)
        #if !DEBUG
        #expect(NetworkFaults.from(environment: ["SUDAMP_FAULT": "net:offline"]) == .none)
        #endif
    }

    @Test func theWindowReportsOfflineThenHandsBackTheRealPath() async {
        let base = ManualNetworkPath(initial: NetworkPathStatus(isSatisfied: true, interfaces: ["en0/wifi"]))
        let faulty = NetworkFaults(offlineFor: 0.15, offlineAfter: 0.05).observer(base)
        var seen: [Bool] = []
        for await status in faulty.updates() {
            seen.append(status.isSatisfied)
            if seen.count == 1 {
                #expect(status.interfaces == ["en0/wifi"])
            }
            if seen.count == 3 {
                #expect(status.interfaces == ["en0/wifi"], "the real path again")
                break
            }
        }
        #expect(seen == [true, false, true])
    }

    @Test func realChangesInsideTheWindowAreHeldBack() async {
        let base = ManualNetworkPath(initial: NetworkPathStatus(isSatisfied: true, interfaces: ["en0/wifi"]))
        let faulty = OfflineWindowPath(base: base, after: 0.02, duration: 0.6)
        var seen: [NetworkPathStatus] = []
        let task = Task {
            try? await Task.sleep(for: .milliseconds(80))
            base.send(NetworkPathStatus(isSatisfied: true, interfaces: ["en7/ethernet"]))
        }
        for await status in faulty.updates() {
            seen.append(status)
            if seen.count == 3 { break }
        }
        await task.value
        #expect(seen.map(\.isSatisfied) == [true, false, true])
        #expect(seen.last?.interfaces == ["en7/ethernet"], "the latest real path is what comes back")
    }
}
