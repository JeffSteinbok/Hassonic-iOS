import SwiftUI

/// What a long-press on a room hotspot opens: the controls that fit the
/// device. A light gets brightness (when it dims), a fan its speed, presets
/// and oscillation, a speaker transport and volume, a switch or cover on/off,
/// an oven or fridge its mode and temperature, a select its options. A
/// sensor gets its reading.
struct DeviceControlSheet: View {
    let entityId: String
    let title: String
    /// The hotspot's symbol, so the sheet shows the same device you pressed.
    let symbol: String

    @EnvironmentObject private var haClient: HAWebSocketClient

    private var entity: HAEntityState? { haClient.entity(entityId) }
    private var domain: String { String(entityId.split(separator: ".").first ?? "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let entity {
                        switch domain {
                        case "light": LightControls(entity: entity, symbol: symbol)
                        case "fan": FanControls(entity: entity, symbol: symbol)
                        case "media_player": SpeakerControls(entity: entity)
                        case "water_heater": ApplianceControls(entity: entity, symbol: symbol)
                        case "select": OptionControls(entity: entity, symbol: symbol)
                        case let domain where DashboardRoomCardConfiguration.Hotspot.toggleableDomains.contains(domain):
                            PowerToggle(entity: entity, symbol: symbol)
                        default: ReadOnlyStatus(entity: entity, symbol: symbol)
                        }
                    } else {
                        ContentUnavailableView("Not in Home Assistant", systemImage: "questionmark.circle", description: Text(entityId))
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Shared

extension HAEntityState {
    /// Whether a long-press has anything to offer beyond the tap's on/off:
    /// a light that dims, a fan, a speaker. A plain on/off light has not.
    var hasControlsBeyondPower: Bool {
        switch entityId.split(separator: ".").first {
        case "light": return attributeStrings("supported_color_modes").contains { $0 != "onoff" }
        case "fan", "media_player": return true
        default: return false
        }
    }

    /// An oven heating. Only a `water_heater` that can be off counts, so a
    /// fridge compartment, always "Normal", never reads as running.
    var isApplianceRunning: Bool {
        guard attributeStringArray("operation_list")?.contains("off") == true else { return false }
        return !["off", "unavailable", "unknown"].contains(state)
    }

    /// The state in words: "Open" for a door, "Dry" for a leak sensor,
    /// "Bake" for an oven, "37°" for a temperature.
    var readableState: String {
        switch state {
        case "unavailable": return "Unavailable"
        case "unknown": return "Unknown"
        default: break
        }
        if entityId.hasPrefix("binary_sensor.") {
            let on = state == "on"
            switch attributeString("device_class") {
            case "door", "garage_door", "opening", "window": return on ? "Open" : "Closed"
            case "moisture": return on ? "Wet" : "Dry"
            default: return on ? "On" : "Off"
            }
        }
        if let number = Double(state) {
            let unit = attributeString("unit_of_measurement") ?? ""
            return unit.hasPrefix("°") ? "\(Int(number.rounded()))°" : "\(Int(number.rounded())) \(unit)".trimmingCharacters(in: .whitespaces)
        }
        let words = state.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// What a hotspot shows on the picture under the device: an oven's
    /// "Off", "342°", or "212° → 350°" while it heats; a fridge's setpoint;
    /// a sensor's reading.
    var hotspotReading: String? {
        guard !["unavailable", "unknown"].contains(state) else { return nil }
        if entityId.hasPrefix("sensor.") { return readableState }
        guard entityId.hasPrefix("water_heater.") else { return nil }

        let target = attributeDouble("temperature").flatMap { $0 > 0 ? Int($0.rounded()) : nil }
        guard attributeStringArray("operation_list")?.contains("off") == true else {
            return target.map { "\($0)°" }
        }
        guard isApplianceRunning else { return "Off" }
        guard let current = attributeDouble("current_temperature").map({ Int($0.rounded()) }) else {
            return target.map { "\($0)°" } ?? readableState
        }
        if let target, current < target - 5 { return "\(current)° → \(target)°" }
        return "\(current)°"
    }

    /// An appliance's readings under its state: "Set to 350°", "Now 342°",
    /// "Door closed". A fridge reports no current temperature, an oven
    /// that's off a meaningless one, so those are left out.
    var applianceDetails: [String] {
        guard entityId.hasPrefix("water_heater.") else { return [] }
        var details: [String] = []
        if let target = attributeDouble("temperature"), target > 0 {
            details.append("Set to \(Int(target.rounded()))°")
        }
        if isApplianceRunning, let current = attributeDouble("current_temperature") {
            details.append("Now \(Int(current.rounded()))°")
        }
        if let door = attributeString("door_status") {
            details.append("Door \(door.lowercased())")
        }
        return details
    }

    /// The friendly name without the room in front: "Main Bedroom Bedside
    /// Torches" in the Main Bedroom is "Bedside Torches".
    func name(in room: String?) -> String {
        guard let room, friendlyName.count > room.count,
              friendlyName.lowercased().hasPrefix(room.lowercased() + " ") else { return friendlyName }
        return String(friendlyName.dropFirst(room.count + 1))
    }
}

private extension HAEntityState {
    var isOn: Bool { ["on", "playing"].contains(state) }

    func attributeStrings(_ key: String) -> [String] {
        guard case .array(let values)? = attributes[key] else { return [] }
        return values.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
    }

    func attributeBool(_ key: String) -> Bool? {
        if case .bool(let value)? = attributes[key] { return value }
        return nil
    }
}

/// The big round power button every sheet starts with.
private struct PowerToggle: View {
    let entity: HAEntityState
    var symbol = "power"

    @EnvironmentObject private var haClient: HAWebSocketClient

    var body: some View {
        VStack(spacing: 8) {
            Button { haClient.toggle(entity.entityId) } label: {
                DeviceSymbol(name: symbol, size: 34)
                    .foregroundStyle(entity.isOn ? Color.black : Color.secondary)
                    .frame(width: 88, height: 88)
                    .background(entity.isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial), in: Circle())
                    .shadow(color: entity.isOn ? .yellow.opacity(0.5) : .clear, radius: 14)
            }
            .buttonStyle(.plain)
            .disabled(!entity.isAvailable)
            .sensoryFeedback(.selection, trigger: entity.isOn)
            .accessibilityLabel("Power")
            .accessibilityValue(entity.isOn ? "On" : "Off")

            Text(entity.isAvailable ? (entity.isOn ? "On" : "Off") : "Unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A device's state and readings, without a power button: a sensor's whole
/// sheet, and the top of an appliance's.
private struct ReadOnlyStatus: View {
    let entity: HAEntityState
    let symbol: String

    private var isActive: Bool {
        entity.entityId.hasPrefix("water_heater.") ? entity.isApplianceRunning : entity.state == "on"
    }

    var body: some View {
        VStack(spacing: 8) {
            DeviceSymbol(name: symbol, size: 34)
                .foregroundStyle(isActive ? Color.black : Color.secondary)
                .frame(width: 88, height: 88)
                .background(isActive ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial), in: Circle())
                .shadow(color: isActive ? .yellow.opacity(0.5) : .clear, radius: 14)
                .accessibilityHidden(true)

            Text(entity.readableState)
                .font(.headline)
            ForEach(entity.applianceDetails, id: \.self) { detail in
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A slider that only calls Home Assistant when the finger lifts, and
/// follows the entity otherwise.
private struct CommitSlider: View {
    let label: String
    let symbol: String
    let value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0.rounded()))%" }
    let commit: (Double) -> Void

    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: symbol)
                Spacer()
                Text(format(draft ?? value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(
                value: Binding(get: { draft ?? value }, set: { draft = $0 }),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    if !editing, let draft {
                        commit(draft)
                        self.draft = nil
                    }
                }
            )
        }
    }
}

// MARK: - Appliance

/// An oven or fridge compartment, which Home Assistant models as a
/// `water_heater`: the mode, which is how an oven turns on and off, and the
/// temperature it's set to.
private struct ApplianceControls: View {
    let entity: HAEntityState
    let symbol: String

    @EnvironmentObject private var haClient: HAWebSocketClient

    private var modes: [String] { entity.attributeStrings("operation_list") }
    private var mode: String { entity.attributeString("operation_mode") ?? entity.state }

    private var range: ClosedRange<Double>? {
        guard let low = entity.attributeDouble("min_temp"), let high = entity.attributeDouble("max_temp"), low < high else { return nil }
        return low...high
    }

    /// An oven that's off has no temperature to set: picking a mode starts it.
    private var canSetTemperature: Bool { range != nil && (entity.isApplianceRunning || !modes.contains("off")) }

    var body: some View {
        ReadOnlyStatus(entity: entity, symbol: symbol)

        if !modes.isEmpty {
            LabeledContent("Mode") {
                Picker("Mode", selection: Binding(
                    get: { mode },
                    set: { haClient.callService(domain: "water_heater", service: "set_operation_mode", entityId: entity.entityId,
                                                data: ["operation_mode": .string($0)]) }
                )) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.prefix(1).uppercased() + mode.dropFirst()).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
            .font(.subheadline)
            .disabled(!entity.isAvailable)
        }

        if canSetTemperature, let range {
            CommitSlider(
                label: "Set to",
                symbol: "thermometer.medium",
                value: min(max(entity.attributeDouble("temperature") ?? range.lowerBound, range.lowerBound), range.upperBound),
                range: range,
                // An oven's 170–550° in fives; a fridge's few degrees in ones.
                step: range.upperBound - range.lowerBound > 50 ? 5 : 1,
                format: { "\(Int($0.rounded()))°" }
            ) { temperature in
                haClient.callService(domain: "water_heater", service: "set_temperature", entityId: entity.entityId,
                                     data: ["temperature": .number(temperature)])
            }
            .disabled(!entity.isAvailable)
        }
    }
}

/// A `select`, like an oven light's Off and High: one button per option.
private struct OptionControls: View {
    let entity: HAEntityState
    let symbol: String

    @EnvironmentObject private var haClient: HAWebSocketClient

    var body: some View {
        ReadOnlyStatus(entity: entity, symbol: symbol)

        Picker("Option", selection: Binding(
            get: { entity.state },
            set: { haClient.callService(domain: "select", service: "select_option", entityId: entity.entityId,
                                        data: ["option": .string($0)]) }
        )) {
            ForEach(entity.attributeStrings("options"), id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(!entity.isAvailable)
    }
}

// MARK: - Light

private struct LightControls: View {
    let entity: HAEntityState
    let symbol: String

    @EnvironmentObject private var haClient: HAWebSocketClient

    private var dims: Bool {
        entity.attributeStrings("supported_color_modes").contains { $0 != "onoff" }
    }

    private var brightnessPercent: Double {
        guard entity.isOn, let brightness = entity.attributeDouble("brightness") else { return 0 }
        return brightness / 255 * 100
    }

    var body: some View {
        PowerToggle(entity: entity, symbol: symbol)
        if dims {
            CommitSlider(label: "Brightness", symbol: "sun.max", value: brightnessPercent, range: 1...100) { percent in
                haClient.callService(domain: "light", service: "turn_on", entityId: entity.entityId,
                                     data: ["brightness_pct": .number(percent.rounded())])
            }
            .disabled(!entity.isAvailable)
        }
    }
}

// MARK: - Fan

private struct FanControls: View {
    let entity: HAEntityState
    let symbol: String

    @EnvironmentObject private var haClient: HAWebSocketClient

    /// The fan's speeds as percentages: 25/50/75/100 for a four-speed fan.
    private var speeds: [Double] {
        guard let step = entity.attributeDouble("percentage_step"), step > 0, step < 100 else { return [] }
        let count = Int((100 / step).rounded())
        return (1...count).map { (Double($0) * step).rounded() }
    }

    private var currentSpeed: Double? {
        guard entity.isOn, let percentage = entity.attributeDouble("percentage"), percentage > 0 else { return nil }
        return speeds.min { abs($0 - percentage) < abs($1 - percentage) }
    }

    private var presets: [String] { entity.attributeStrings("preset_modes") }

    var body: some View {
        PowerToggle(entity: entity, symbol: symbol)

        if !speeds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Speed", systemImage: "gauge.with.dots.needle.33percent").font(.subheadline)
                HStack(spacing: 8) {
                    ForEach(Array(speeds.enumerated()), id: \.offset) { index, speed in
                        ChoiceButton(title: "\(index + 1)", isSelected: currentSpeed == speed) {
                            haClient.callService(domain: "fan", service: "set_percentage", entityId: entity.entityId,
                                                 data: ["percentage": .number(speed)])
                        }
                    }
                }
            }
        }

        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Mode", systemImage: "slider.horizontal.3").font(.subheadline)
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        ChoiceButton(title: preset.capitalized, isSelected: entity.isOn && entity.attributeString("preset_mode") == preset) {
                            haClient.callService(domain: "fan", service: "set_preset_mode", entityId: entity.entityId,
                                                 data: ["preset_mode": .string(preset)])
                        }
                    }
                }
            }
        }

        if let oscillating = entity.attributeBool("oscillating") {
            Toggle(isOn: Binding(
                get: { oscillating },
                set: { haClient.callService(domain: "fan", service: "oscillate", entityId: entity.entityId, data: ["oscillating": .bool($0)]) }
            )) {
                Label("Oscillate", systemImage: "arrow.left.and.right")
            }
            .font(.subheadline)
        }
    }
}

private struct ChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .background(isSelected ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Speaker

private struct SpeakerControls: View {
    let entity: HAEntityState

    @EnvironmentObject private var haClient: HAWebSocketClient

    private var isPlaying: Bool { entity.state == "playing" }
    private var isOff: Bool { ["off", "standby", "unavailable"].contains(entity.state) }

    var body: some View {
        VStack(spacing: 4) {
            Text(entity.attributeString("media_title") ?? (isOff ? "Off" : "Nothing playing"))
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let artist = entity.attributeString("media_artist") {
                Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)

        HStack(spacing: 36) {
            Button { haClient.mediaPreviousTrack(entity.entityId) } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .accessibilityLabel("Previous")
            Button { haClient.mediaPlayPause(entity.entityId) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(Color.yellow, in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button { haClient.mediaNextTrack(entity.entityId) } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .disabled(isOff)

        HStack(spacing: 12) {
            Button { haClient.setMuted(entity.entityId, muted: !(entity.attributeBool("is_volume_muted") ?? false)) } label: {
                Image(systemName: entity.attributeBool("is_volume_muted") == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mute")
            CommitSlider(label: "Volume", symbol: "speaker.wave.1", value: (entity.attributeDouble("volume_level") ?? 0) * 100) { percent in
                haClient.setVolume(entity.entityId, level: percent / 100)
            }
        }
        .disabled(isOff)

        Button(isOff ? "Turn On" : "Turn Off", systemImage: "power") {
            isOff ? haClient.turnOn(entity.entityId) : haClient.turnOff(entity.entityId)
        }
        .buttonStyle(.bordered)
    }
}
