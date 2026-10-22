/// Deterministic, seedable generator (SplitMix64) so shuffle-bag tests are reproducible (PLAN M1).
/// Production uses `SystemRandomNumberGenerator`; anything random takes `inout some RandomNumberGenerator`.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1).
    public mutating func unitInterval() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}
