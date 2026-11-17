import os

/// One logger per area, all under Brim's subsystem, so Console.app can filter by feature.
/// Personal data (song titles) must be logged with `privacy: .private`.
public enum Log {
    public static let subsystem = "com.theojones.Brim"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let island = Logger(subsystem: subsystem, category: "island")
    public static let nowPlaying = Logger(subsystem: subsystem, category: "nowplaying")
    public static let helper = Logger(subsystem: subsystem, category: "helper")
    /// Bluetooth headphones connecting and disconnecting (never their names).
    public static let devices = Logger(subsystem: subsystem, category: "devices")
}
