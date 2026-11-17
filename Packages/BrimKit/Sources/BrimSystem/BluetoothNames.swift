import Foundation
import IOBluetooth
import BrimCore

/// A paired Bluetooth device's product name ("AirPods Pro"), for when macOS gives no usable name (P-4).
enum BluetoothNames {
    /// `address` in any spelling: "70-F9-4A-…" (sound output IDs) or "70:f9:4a:…".
    static func productName(address: String) -> String? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { hex($0.addressString) == hex(address) }.flatMap(productName(of:))
    }

    static func productName(of device: IOBluetoothDevice) -> String? {
        func number(_ key: String) -> Int {
            guard device.responds(to: NSSelectorFromString(key)) else { return 0 }
            return (device.value(forKey: key) as? NSNumber)?.intValue ?? 0
        }
        return DeviceNames.appleProduct(vendorID: number("vendorID"), productID: number("productID"))
    }

    /// "70-F9-4A-…" or "70:f9:4a:…" → "70f94a…", so both spellings compare equal.
    static func hex(_ address: String?) -> String {
        String((address ?? "").lowercased().filter(\.isHexDigit))
    }
}
