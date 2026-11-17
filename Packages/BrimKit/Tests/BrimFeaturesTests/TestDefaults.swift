import Foundation

/// A settings suite for one test, kept as a file in the temp folder instead of ~/Library/Preferences: before
/// 2026-11-17 each test run left its suites there, 8,165 files (32 MB) in two months. A suite name that's a full path
/// is stored at that path (checked: nothing reaches Preferences); macOS empties the temp folder by itself.
func testSuiteName(_ prefix: String) -> String {
    NSTemporaryDirectory() + prefix + "." + UUID().uuidString
}
