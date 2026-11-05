import AppKit

/// The smallest app the tests can archive. It is built, never launched.
@main
struct SampleApplication {
    static func main() {
        _ = NSApplication.shared
    }
}
