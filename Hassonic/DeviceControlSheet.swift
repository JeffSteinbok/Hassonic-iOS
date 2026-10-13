import SwiftUI

/// What a long-press on a room hotspot opens: the controls that fit the
/// device. A light gets brightness (when it dims), a fan its speed, presets
/// and oscillation, a speaker transport and volume; anything else on/off.
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
                        default: PowerToggle(entity: entity, symbol: symbol)
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
