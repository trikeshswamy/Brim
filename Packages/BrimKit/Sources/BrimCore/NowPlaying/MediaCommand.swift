/// Playback commands. The raw values are the numbers the helper's `send` command expects
/// (MediaRemote's `MRCommand` IDs), so a command is sent as `send <rawValue>`.
public enum MediaCommand: Int, Sendable, CaseIterable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
    case toggleShuffle = 6
    case toggleRepeat = 7
    case skipBackward15 = 12
    case skipForward15 = 13
}
