import os

/// Unified logging. Read with: log stream --predicate 'subsystem == "dev.polylocal.app"'
/// Messages carry metadata only (app, capture path); translated text is never logged.
enum Log {
    static let capture = Logger(subsystem: "dev.polylocal.app", category: "capture")
}
