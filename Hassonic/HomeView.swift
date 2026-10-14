import SwiftUI

// MARK: - LightToggleRow

struct LightToggleRow: View {
    let label: String
    let entity: HAEntityState?
    /// Drawn instead of the bulb; it shows on and off by its color alone.
    var icon: String? = nil
    let onToggle: (Bool) -> Void

    private var isOn: Bool { entity?.state == "on" }
    private var isUnavailable: Bool { entity == nil || entity?.isAvailable == false }

    var body: some View {
        HStack {
            Group {
                if let icon {
                    DeviceSymbol(name: icon, size: 17)
                } else {
                    Image(systemName: isOn ? "lightbulb.fill" : "lightbulb")
                }
            }
            .foregroundStyle(isOn ? .yellow : .secondary)
            .frame(width: 28)
            Toggle(label, isOn: Binding(
                get: { isOn },
                set: { onToggle($0) }
            ))
            .disabled(isUnavailable)
        }
        .foregroundStyle(isUnavailable ? .secondary : .primary)
        .overlay(alignment: .trailing) {
            if isUnavailable {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
        }
    }
}

// MARK: - AwningControlRow

struct AwningControlRow: View {
    let label: String
    let entity: HAEntityState?
    let onOpen: () -> Void
    let onClose: () -> Void
    let onStop: () -> Void
    let onSetPosition: (Int) -> Void

    private var currentPosition: Int? {
        if case .number(let v)? = entity?.attributes["current_position"] { return Int(v) }
        return nil
    }

    private var isUnavailable: Bool { entity == nil || entity?.isAvailable == false }

    /// One row: name and position, then open / stop / close. A long-press
    /// offers set positions.
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "blinds.horizontal.closed")
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.body)
                    .lineLimit(1)
                if isUnavailable {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                } else if let pos = currentPosition {
                    Text(pos == 0 ? "Closed" : pos == 100 ? "Open" : "\(pos)% open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Group {
                coverButton("chevron.up", "Open", action: onOpen)
                coverButton("stop.fill", "Stop", action: onStop)
                coverButton("chevron.down", "Close", action: onClose)
            }
            .disabled(isUnavailable)
        }
        .foregroundStyle(isUnavailable ? .secondary : .primary)
        .contextMenu {
            if !isUnavailable {
                ForEach([0, 25, 50, 75, 100], id: \.self) { position in
                    Button("\(position)% open") { onSetPosition(position) }
                }
            }
        }
    }

    private func coverButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(symbol == "stop.fill" ? .orange : nil)
        .accessibilityLabel(label)
    }
}
