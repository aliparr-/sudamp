// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Core

@Suite struct NetworkPathTests {
    let wifi = NetworkPathStatus(isSatisfied: true, interfaces: ["en1/wifi"], gateways: ["192.168.1.1:0"])
    let wired = NetworkPathStatus(isSatisfied: true, interfaces: ["en0/ethernet"], gateways: ["192.168.1.1:0"])
    let down = NetworkPathStatus(isSatisfied: false)

    @Test func classification() {
        #expect(NetworkPathChange.between(nil, wifi) == .initial)
        #expect(NetworkPathChange.between(wifi, wifi) == .unchanged)
        #expect(NetworkPathChange.between(wifi, down) == .lost)
        #expect(NetworkPathChange.between(down, down) == .unchanged)
        #expect(NetworkPathChange.between(down, wifi) == .restored)
        #expect(NetworkPathChange.between(wifi, wired) == .changed)
        var newGateway = wifi
        newGateway.gateways = ["10.0.0.1:0"]
        #expect(NetworkPathChange.between(wifi, newGateway) == .changed, "another Wi-Fi network")
        var cheaper = wifi
        cheaper.isExpensive = true
        #expect(NetworkPathChange.between(wifi, cheaper) == .unchanged, "same route, different cost: same address")
    }

    @Test func manualPathDeliversCurrentThenUpdates() async {
        let source = ManualNetworkPath(initial: wifi)
        var iterator = source.updates().makeAsyncIterator()
        #expect(await iterator.next() == wifi)
        source.send(down)
        #expect(await iterator.next() == down)
        source.send(wired)
        #expect(await iterator.next() == wired)
    }

    @Test func systemMonitorReportsAPath() async {
        // The real NWPathMonitor answers at once with the current path (satisfied or not).
        var iterator = SystemNetworkPathMonitor().updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
    }
}
