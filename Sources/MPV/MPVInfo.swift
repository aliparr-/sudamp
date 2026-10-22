import Libmpv

/// libmpv facts used by guards and `--selftest` (DESIGN §5.3).
public enum MPVInfo {
    /// mpv client API version (MPVKit 1.0.0 reports 2.5 = 131077).
    public static var clientAPIVersion: UInt { UInt(mpv_client_api_version()) }
}
