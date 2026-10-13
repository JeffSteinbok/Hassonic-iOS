import SwiftUI

/// What the thermostat card asks of its owner.
struct ThermostatActions {
    var setTemperature: (Double) -> Void
    var setRange: (_ low: Double, _ high: Double) -> Void
    var setMode: (ThermostatState.Mode) -> Void
}

extension ThermostatState {
    init?(_ entity: HAEntityState?) {
        guard let entity, entity.isAvailable else { return nil }
        // `auto` (schedule-driven) is shown as Auto too; most thermostats
        // offer one or the other.
        mode = entity.state == "auto" ? .auto : Mode(rawValue: entity.state)
        switch entity.attributeString("hvac_action") {
        case "heating", "preheating", "defrosting": action = .heating
        case "cooling", "drying": action = .cooling
        case "fan": action = .fan
        case "off": action = .off
        default: action = entity.state == "off" ? .off : .idle
        }
        current = entity.attributeDouble("current_temperature")
        target = entity.attributeDouble("temperature")
        low = entity.attributeDouble("target_temp_low")
        high = entity.attributeDouble("target_temp_high")
        humidity = entity.attributeDouble("current_humidity")
        minTemp = entity.attributeDouble("min_temp") ?? 45
        maxTemp = entity.attributeDouble("max_temp") ?? 95
        let offered = Set((entity.attributeStringArray("hvac_modes") ?? []).map { $0 == "auto" ? "heat_cool" : $0 })
        modes = Mode.allCases.filter { offered.contains($0.rawValue) }
    }

}

// MARK: - ThermostatCardView

/// The mocked thermostat: humidity and outside temperature, a status pill,
/// the inside temperature, and the setpoint (or the heat_cool range) with −
/// and +. The modes hide in the status pill's menu. `compact` draws it as
/// one row instead.
///
/// Taps change the shown setpoint at once and are sent after a short pause,
/// so tapping + five times makes one call, not five.
struct ThermostatCardView: View {
    let title: String
    let state: ThermostatState?
    var outside: Double? = nil
    var compact = false
    let actions: ThermostatActions

    @State private var pendingTarget: Double?
    @State private var pendingRange: (low: Double, high: Double)?
    @State private var pendingMode: ThermostatState.Mode?
    @State private var sendTask: Task<Void, Never>?
    @State private var presses = 0

    /// How long taps settle before the setpoint is sent.
    static let sendDelay: Duration = .milliseconds(800)

    var body: some View {
        Group {
            if let state {
                if compact { row(state) } else { card(state) }
            } else {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        // HA caught up: drop the optimistic values.
        .onChange(of: state) { _, _ in
            if sendTask == nil {
                pendingTarget = nil
                pendingRange = nil
            }
            if pendingMode == state?.mode { pendingMode = nil }
        }
    }

    // MARK: Card

    private func card(_ state: ThermostatState) -> some View {
        let mode = pendingMode ?? state.mode
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle = subtitle(state) {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                modeMenu(state, mode: mode)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("INSIDE")
                        .font(.caption.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(formatDegrees(state.current))
                        .font(.system(size: 52, weight: .heavy))
                        .tracking(-1.5)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                setpoints(state, mode: mode)
            }
        }
    }

    @ViewBuilder
    private func setpoints(_ state: ThermostatState, mode: ThermostatState.Mode?) -> some View {
        switch mode {
        case .heat?, .cool?:
            let value = pendingTarget ?? state.target
            Stepper3(
                caption: mode == .heat ? "HEAT TO" : "COOL TO",
                value: value,
                color: mode == .heat ? Palette.heat : Palette.cool,
                large: true,
                onStep: { direction in
                    guard let value else { return }
                    stepTarget(from: value, by: direction, in: state)
                }
            )
        case .auto?:
            let range = pendingRange ?? (state.low ?? state.target ?? 68, state.high ?? state.target ?? 74)
            VStack(alignment: .trailing, spacing: 8) {
                Stepper3(caption: "HEAT TO", value: range.low, color: Palette.heat, large: false) { direction in
                    stepRange(range, end: .low, by: direction, in: state)
                }
                Stepper3(caption: "COOL TO", value: range.high, color: Palette.cool, large: false) { direction in
                    stepRange(range, end: .high, by: direction, in: state)
                }
            }
        case .off?, nil:
            Text("Off")
                .font(.title2.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    /// The status pill doubles as the mode button: modes change seldom, so
    /// they wait in its menu rather than taking a row of the card.
    @ViewBuilder
    private func modeMenu(_ state: ThermostatState, mode: ThermostatState.Mode?) -> some View {
        if state.modes.count > 1 {
            Menu {
                Picker("Mode", selection: Binding(
                    get: { mode },
                    set: { newMode in
                        guard let newMode, newMode != mode else { return }
                        presses += 1
                        pendingMode = newMode
                        pendingTarget = nil
                        pendingRange = nil
                        actions.setMode(newMode)
                    }
                )) {
                    ForEach(state.modes, id: \.self) { option in
                        Text(option.label).tag(Optional(option))
                    }
                }
            } label: {
                StatusPill(action: state.action, mode: mode, showsChevron: true)
            }
            .accessibilityLabel("Mode")
            .accessibilityValue(mode?.label ?? "")
        } else {
            StatusPill(action: state.action)
        }
    }

    private func color(for mode: ThermostatState.Mode) -> Color {
        switch mode {
        case .heat: return Palette.heat
        case .cool: return Palette.cool
        case .auto, .off: return Palette.neutral
        }
    }

    // MARK: Compact row

    private func row(_ state: ThermostatState) -> some View {
        let mode = pendingMode ?? state.mode
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                Label {
                    Text(rowStatus(state, mode: mode))
                } icon: {
                    StatusIcon(action: state.action)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(statusColor(state.action))
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            if mode == .heat || mode == .cool {
                let value = pendingTarget ?? state.target
                HStack(spacing: 8) {
                    RoundStepButton(symbol: "minus", label: "Lower \(title) target") {
                        if let value { stepTarget(from: value, by: -1, in: state) }
                    }
                    Text(formatDegrees(value))
                        .font(.title3.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(mode == .heat ? Palette.heat : Palette.cool)
                        .frame(width: 44)
                    RoundStepButton(symbol: "plus", label: "Raise \(title) target") {
                        if let value { stepTarget(from: value, by: 1, in: state) }
                    }
                }
            }
        }
    }

    private func rowStatus(_ state: ThermostatState, mode: ThermostatState.Mode?) -> String {
        let inside = formatDegrees(state.current)
        switch mode {
        case .heat?: return "\(inside) · \(state.action == .heating ? "Heating" : "Heat") to \(formatDegrees(pendingTarget ?? state.target))"
        case .cool?: return "\(inside) · \(state.action == .cooling ? "Cooling" : "Cool") to \(formatDegrees(pendingTarget ?? state.target))"
        case .auto?:
            let range = pendingRange ?? (state.low ?? 0, state.high ?? 0)
            return "\(inside) · \(state.action.label) · \(formatDegrees(range.low))–\(formatDegrees(range.high))"
        case .off?, nil: return "\(inside) · Off"
        }
    }

    // MARK: Helpers

    private func subtitle(_ state: ThermostatState) -> String? {
        var parts: [String] = []
        if let humidity = state.humidity { parts.append("Humidity \(Int(humidity.rounded()))%") }
        if let outside { parts.append("Outside \(formatDegrees(outside))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func stepTarget(from value: Double, by direction: Int, in state: ThermostatState) {
        presses += 1
        let next = state.stepped(value, by: direction)
        pendingTarget = next
        schedule { actions.setTemperature(next) }
    }

    private func stepRange(_ range: (low: Double, high: Double), end: ThermostatState.RangeEnd, by direction: Int, in state: ThermostatState) {
        presses += 1
        let next = state.steppedRange(low: range.low, high: range.high, moving: end, by: direction)
        pendingRange = next
        schedule { actions.setRange(next.low, next.high) }
    }

    private func schedule(_ send: @escaping () -> Void) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: Self.sendDelay)
            guard !Task.isCancelled else { return }
            send()
            sendTask = nil
        }
    }
}

func statusColor(_ action: ThermostatState.Action) -> Color {
    switch action {
    case .heating: return Palette.heat
    case .cooling: return Palette.cool
    case .idle, .fan, .off: return .secondary
    }
}

// MARK: - Parts

private struct StatusPill: View {
    let action: ThermostatState.Action
    var mode: ThermostatState.Mode? = nil
    var showsChevron = false

    /// "Heat · Idle", or just "Heating" when the action already says it.
    private var text: String {
        guard let mode, !action.label.localizedCaseInsensitiveContains(mode.label) else { return action.label }
        return "\(mode.label) · \(action.label)"
    }

    var body: some View {
        HStack(spacing: 5) {
            StatusIcon(action: action)
            Text(text)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(statusColor(action))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(statusColor(action).opacity(0.12), in: Capsule())
    }
}

private struct StatusIcon: View {
    let action: ThermostatState.Action

    var body: some View {
        Image(systemName: symbol)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch action {
        case .heating: return "flame.fill"
        case .cooling: return "snowflake"
        case .fan: return "fan.fill"
        case .idle: return "pause.circle"
        case .off: return "power"
        }
    }
}

/// − value +, with a caption over the value.
private struct Stepper3: View {
    let caption: String
    let value: Double?
    let color: Color
    let large: Bool
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: large ? 12 : 8) {
            RoundStepButton(symbol: "minus", label: "Lower \(caption.lowercased())", size: large ? 44 : 38) { onStep(-1) }
            VStack(spacing: 0) {
                Text(caption)
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                Text(formatDegrees(value))
                    .font(.system(size: large ? 30 : 22, weight: .heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(color)
            .frame(width: large ? 70 : 64)
            .accessibilityElement(children: .combine)
            RoundStepButton(symbol: "plus", label: "Raise \(caption.lowercased())", size: large ? 44 : 38) { onStep(1) }
        }
    }
}

private struct RoundStepButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

#Preview {
    VStack(spacing: 16) {
        ThermostatCardView(
            title: "Thermostat",
            state: ThermostatState(mode: .heat, action: .heating, current: 71, target: 72, humidity: 41),
            outside: 54,
            actions: ThermostatActions(setTemperature: { _ in }, setRange: { _, _ in }, setMode: { _ in })
        )
        ThermostatCardView(
            title: "Upstairs Thermostat",
            state: ThermostatState(mode: .cool, action: .cooling, current: 76, target: 74),
            compact: true,
            actions: ThermostatActions(setTemperature: { _ in }, setRange: { _, _ in }, setMode: { _ in })
        )
    }
    .padding()
}
