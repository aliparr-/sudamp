import os

/// Unified logging (subsystem `app.sudamp`, DESIGN §9): `log show --predicate 'subsystem == "app.sudamp"'`.
public enum Log {
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: BuildInfo.logSubsystem, category: category)
    }
}
