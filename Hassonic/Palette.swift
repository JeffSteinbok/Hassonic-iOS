import SwiftUI

/// Colors shared across screens. Remotes keep their own fixed set
/// (`RemoteColors`), since they're drawn as physical objects.
enum Palette {
    /// Heating: the thermostat's heat setpoint, mode and status.
    static let heat = Color(hex: "#C2410C")
    /// Cooling.
    static let cool = Color(hex: "#1D6FD1")
    /// Neutral fill for a selected control with no hue of its own.
    static let neutral = Color(hex: "#5B6371")
    /// Dark ink for text on a light icon theme.
    static let ink = Color(hex: "#1B1F28")
}

extension Color {
    /// `#RRGGBB`; anything else is clear.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .clear
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
