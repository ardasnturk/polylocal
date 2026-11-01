import os

/// Unified logging. Read with: log stream --predicate 'subsystem == "dev.translater.app"'
/// Messages carry metadata only (app, capture path); translated text is never logged.
enum Log {
    static let capture = Logger(subsystem: "dev.translater.app", category: "capture")
}
