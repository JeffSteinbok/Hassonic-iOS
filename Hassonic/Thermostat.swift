import Foundation

/// The `thermostat` card.
///
///     - type: thermostat
///       entity: climate.my_ecobee
///       title: Thermostat
///       outside: weather.home      # optional: weather.* or sensor.*
///       compact: false             # optional: one row instead of the card
struct DashboardThermostatConfiguration: Decodable, Equatable {
    let entity: String
    let title: String?
    /// Outside temperature: a `weather.*` entity's `temperature` attribute,
    /// or a `sensor.*` entity's state.
    var outside: String?
    /// One row (name, status, − target +) instead of the full card.
    var compact: Bool = false

    private enum CodingKeys: String, CodingKey {
        case entity, title, outside, compact
    }

    init(entity: String, title: String? = nil, outside: String? = nil, compact: Bool = false) {
        self.entity = entity
        self.title = title
        self.outside = outside
        self.compact = compact
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entity = try c.decode(String.self, forKey: .entity)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        outside = try c.decodeIfPresent(String.self, forKey: .outside)
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? false
    }
}

/// What a `climate.*` entity says, in the terms the card draws. Pure, so it
/// can be tested without a view.
struct ThermostatState: Equatable {
    /// The modes the card offers, in button order.
    enum Mode: String, CaseIterable {
        case heat
        case cool
        /// HA's `heat_cool`: both setpoints, a range.
        case auto = "heat_cool"
        case off

        var label: String {
            switch self {
            case .heat: return "Heat"
            case .cool: return "Cool"
            case .auto: return "Auto"
            case .off: return "Off"
            }
        }
    }

    enum Action: Equatable {
        case heating, cooling, idle, fan, off

        var label: String {
            switch self {
            case .heating: return "Heating"
            case .cooling: return "Cooling"
            case .idle: return "Idle"
            case .fan: return "Fan"
            case .off: return "Off"
            }
        }
    }

    var mode: Mode?
    var action: Action
    var current: Double?
    /// The heat or cool setpoint.
    var target: Double?
    /// The heat_cool range.
    var low: Double?
    var high: Double?
    var humidity: Double?
    var minTemp: Double
    var maxTemp: Double
    /// The modes this thermostat supports, in button order.
    var modes: [Mode]
    /// What this thermostat calls Auto: `heat_cool`, or `auto` when that's
    /// the only one it offers.
    var autoModeName = Mode.auto.rawValue

    init(
        mode: Mode?, action: Action, current: Double? = nil, target: Double? = nil,
        low: Double? = nil, high: Double? = nil, humidity: Double? = nil,
        minTemp: Double = 45, maxTemp: Double = 95, modes: [Mode] = Mode.allCases
    ) {
        self.mode = mode
        self.action = action
        self.current = current
        self.target = target
        self.low = low
        self.high = high
        self.humidity = humidity
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.modes = modes
    }

    /// Whether the card shows one setpoint (heat or cool) or a range (auto).
    /// A schedule-driven `auto` with a single setpoint keeps the one.
    var usesRange: Bool { mode == .auto && (low != nil || target == nil) }

    /// One step from `value`: to the next whole degree, within the
    /// thermostat's limits. Ecobee reports tenths (68.4), and stepping to
    /// 69.4 would never land on a round number.
    func stepped(_ value: Double, by direction: Int) -> Double {
        let next = direction > 0 ? (value + 0.5).rounded(.down) + 1 : (value - 0.5).rounded(.up) - 1
        return min(max(next, minTemp), maxTemp)
    }

    /// The range after stepping one end. The other end moves too if they
    /// would come closer than `minimumGap` (heat_cool needs a deadband).
    func steppedRange(low: Double, high: Double, moving end: RangeEnd, by direction: Int, minimumGap: Double = 2) -> (low: Double, high: Double) {
        switch end {
        case .low:
            let newLow = stepped(low, by: direction)
            return (newLow, max(high, min(newLow + minimumGap, maxTemp)))
        case .high:
            let newHigh = stepped(high, by: direction)
            return (min(low, max(newHigh - minimumGap, minTemp)), newHigh)
        }
    }

    enum RangeEnd { case low, high }
}

/// "71°", whole degrees.
func formatDegrees(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded()))°"
}
