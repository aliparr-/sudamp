// SPDX-License-Identifier: GPL-3.0-or-later
import SudampAO

/// The linked sudamp pull AO (DESIGN §5.1–5.3), for guards, tools and tests that don't import the C module.
public enum PullAO {
    /// "sudamp pull AO" when the link-time override took effect.
    public static var driverDescription: String { String(cString: sudamp_ao_description()) }
    /// Times mpv initialised the AO (guard: > 0 after the first file).
    public static var initCount: Int64 { Int64(sudamp_ao_init_count()) }
    /// Reads refused because the AO format was not floatp/48000/stereo (guard: stays 0).
    public static var errorCount: Int64 { Int64(sudamp_ao_error_count()) }
    /// mpv has started the AO and is streaming.
    public static var isStreaming: Bool { sudamp_ao_is_streaming() != 0 }
    public static var sampleRate: Int { Int(SUDAMP_AO_SAMPLERATE) }

    /// Pulls planar frames directly (tests and headless tools without AVAudioEngine). Returns frames copied, the
    /// rest zero-filled, or -1 when no AO is active.
    public static func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                            delayNanos: Int64) -> Int {
        Int(sudamp_ao_read(left, right, Int32(frames), delayNanos))
    }
}
