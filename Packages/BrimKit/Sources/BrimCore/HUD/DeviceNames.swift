import Foundation

/// Names for sound devices when macOS gives none (P-4). Checked 2026-09-30 on macOS 27: your AirPods' name came
/// back as the single character U+0002 from both IOBluetooth and the sound output list, while another
/// headset's name was fine. Their Apple product ID still says what they are.
public enum DeviceNames {
    /// A name worth showing: not empty and no control characters.
    public static func usable(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return name
    }

    /// Apple's Bluetooth product IDs (vendor 76) for AirPods. Yours report 0x200E: AirPods Pro.
    public static func appleProduct(vendorID: Int, productID: Int) -> String? {
        guard vendorID == 76 else { return nil }
        switch productID {
        case 0x2002, 0x200F, 0x2013: return "AirPods"
        case 0x200E, 0x2014, 0x2024: return "AirPods Pro"
        case 0x200A: return "AirPods Max"
        default: return nil
        }
    }
}
