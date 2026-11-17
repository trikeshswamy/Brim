#if DEBUG
import AppKit
import ApplicationServices
import BrimSystem

/// Debug only: `--safari-scan-bench <file>` times Brim's Safari fallback scan 30 times (the scan that repeats every
/// second while nothing plays), writes the numbers as JSON and quits, before Brim's island starts. No page text,
/// titles or URLs are written.
enum SafariScanBench {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--safari-scan-bench"), flag + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[flag + 1])
        let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
        let result = SafariScanTimings.measure(runs: 10)
        let sorted = result.milliseconds.sorted()
        let report: [String: Any] = [
            "accessibilityAllowed": AXIsProcessTrusted(),
            "safariRunning": safari != nil,
            "foundVideo": result.found,
            "runs": sorted.count,
            "medianMs": sorted[sorted.count / 2],
            "maxMs": sorted.last ?? 0,
            "minMs": sorted.first ?? 0,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out)
        }
        NSApp.terminate(nil)
        return true
    }
}
#endif
