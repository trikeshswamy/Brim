import Foundation
import BrimCore

/// Runs Apple's `/usr/bin/perl` with the MediaRemoteAdapter helper bundled inside Brim.app.
///
/// Why Perl: since macOS 15.4 only Apple-signed programs may read Now Playing. `/usr/bin/perl` is
/// Apple-signed and can load native add-on code, so it loads our helper, which asks for the data.
///
/// Two kinds of runs:
/// - one long-lived `stream` process that prints a JSON line whenever something changes;
/// - short one-shot runs for commands (`send`, `seek`), about 20 ms each.
final class AdapterHelper {
    struct Files {
        let script: URL
        let framework: URL
    }

    enum StreamEvent: Sendable {
        case started(pid: Int32)
        case update(AdapterStreamParser.Result)
        case exited(status: Int32)
    }

    let files: Files
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    /// Finds the helper inside the app bundle. `nil` if the files are missing.
    init?(bundle: Bundle) {
        guard let framework = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              let script = Bundle(url: framework)?.url(forResource: "mediaremote-adapter", withExtension: "pl")
        else { return nil }
        files = Files(script: script, framework: framework)
    }

    /// Starts `stream`. Lines are parsed off the main thread; `onEvent` may be called from any thread.
    func startStream(onEvent: @escaping @Sendable (StreamEvent) -> Void) throws -> Process {
        let process = Process()
        process.executableURL = Self.perl
        // --micros: exact timestamps (otherwise rounded to whole seconds, and lyrics would drift).
        // --debounce=100: merge bursts of changes into one line.
        process.arguments = [files.script.path, files.framework.path, "stream", "--micros", "--debounce=100"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            onEvent(.exited(status: finished.terminationStatus))
        }
        try process.run()
        onEvent(.started(pid: process.processIdentifier))

        let handle = output.fileHandleForReading
        Task.detached(priority: .utility) {
            // The parser lives only inside this task, so it never crosses threads.
            let parser = AdapterStreamParser()
            do {
                for try await line in handle.bytes.lines {
                    let result = parser.consume(line: line)
                    if result != .ignored { onEvent(.update(result)) }
                }
            } catch {
                Log.helper.error("Reading the stream failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return process
    }

    /// Runs a one-shot command such as `["send", "2"]` and waits until it finishes.
    func run(_ arguments: [String]) async -> Int32 {
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [files.script.path, files.framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// Stops helpers left running by an earlier Brim that crashed; otherwise they'd linger until the next song change.
    func killOrphans() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", files.framework.path + " stream"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        do {
            try pkill.run()
            pkill.waitUntilExit()
            if pkill.terminationStatus == 0 { Log.helper.notice("Stopped an orphaned helper from a previous run") }
        } catch {
            Log.helper.error("Orphan cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
