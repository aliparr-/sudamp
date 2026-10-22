/// Build-wide constants shared by every module.
public enum BuildInfo {
    /// Marketing version; Support/Info.plist.in and `make app` take theirs from the Makefile's VERSION.
    public static let version = "0.1.0-dev"
    /// Unified logging subsystem (DESIGN §9 agent hooks: `log show --predicate 'subsystem == "app.sudamp"'`).
    public static let logSubsystem = "app.sudamp"
}
