// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import MPV

/// Questions asked of the render-callback probe log (methodology of spikes/engine-pull-ao spikepull).
struct ProbeAnalysis {
    let records: [ProbeRecord]
    static let sampleRate = 48_000.0

    /// Index of the first record at or after `nanos`.
    func index(atOrAfter nanos: UInt64) -> Int {
        var lo = 0, hi = records.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if records[mid].nanos < nanos { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func first(after nanos: UInt64, where predicate: (ProbeRecord) -> Bool) -> ProbeRecord? {
        var i = index(atOrAfter: nanos)
        while i < records.count {
            if predicate(records[i]) { return records[i] }
            i += 1
        }
        return nil
    }

    func last(before nanos: UInt64, where predicate: (ProbeRecord) -> Bool) -> ProbeRecord? {
        var i = index(atOrAfter: nanos) - 1
        while i >= 0 {
            if predicate(records[i]) { return records[i] }
            i -= 1
        }
        return nil
    }

    func records(from start: UInt64, to end: UInt64) -> ArraySlice<ProbeRecord> {
        records[index(atOrAfter: start)..<index(atOrAfter: end)]
    }

    static func audible(_ r: ProbeRecord) -> Bool { r.got > 0 && r.peak > 0 }

    static func position(_ sample: Float) -> Double { RampFixture.position(fromRight: sample) }

    /// When the output went silent after `nanos`, sample-accurately: the first callback that read nothing, or read
    /// less than it rendered (the host-pause ramp reads only the 240 frames it fades), ends its audio at
    /// `start + got/48000`.
    func silenceOnset(after nanos: UInt64) -> UInt64? {
        guard let r = first(after: nanos, where: { $0.got <= 0 || $0.peak == 0 || $0.got < $0.frames }) else { return nil }
        let audioFrames = r.peak == 0 ? 0 : max(Int(r.got), 0)
        return r.nanos + UInt64(Double(audioFrames) / Self.sampleRate * 1e9)
    }

    /// New audio near `target` seconds after `nanos`, and how many audible callbacks of old audio came first.
    func arrival(after nanos: UInt64, nearPosition target: Double, tolerance: Double = 0.25)
        -> (record: ProbeRecord, staleQuanta: Int)? {
        guard let hit = first(after: nanos, where: { Self.audible($0) && abs(Self.position($0.firstR) - target) < tolerance })
        else { return nil }
        let stale = records(from: nanos, to: hit.nanos).filter(Self.audible).count
        return (hit, stale)
    }
}
