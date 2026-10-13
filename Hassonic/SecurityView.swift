import SwiftUI

enum AlarmMode: CaseIterable {
    case home, away, night, vacation

    var displayName: String {
        switch self {
        case .home: return "Home"
        case .away: return "Away"
        case .night: return "Night"
        case .vacation: return "Vacation"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .away: return "figure.walk.departure"
        case .night: return "moon.fill"
        case .vacation: return "airplane"
        }
    }

    /// Home Assistant's AlarmControlPanelEntityFeature bit flags.
    var featureBit: Int {
        switch self {
        case .home: return 1
        case .away: return 2
        case .night: return 4
        case .vacation: return 32
        }
    }
}

// MARK: - Pure display helpers (exposed for testing)

func alarmStatusText(for state: String?) -> String {
    switch state {
    case "armed_home": return "Armed – Home"
    case "armed_away": return "Armed – Away"
    case "armed_night": return "Armed – Night"
    case "armed_vacation": return "Armed – Vacation"
    case "disarmed": return "Disarmed"
    case "arming": return "Arming…"
    case "pending": return "Pending"
    case "triggered": return "Triggered!"
    case "disarming": return "Disarming…"
    // Every mapped state above reads as human text, so an unmapped one
    // should too. `.capitalized` alone treats "_" as a word boundary, which
    // turned armed_custom_bypass into "Armed_Custom_Bypass".
    case let s?: return s.humanizedStateName
    case nil: return "Unknown"
    }
}

func alarmStatusColor(for state: String?) -> Color {
    switch state {
    case "disarmed": return .green
    case "triggered": return .red
    case "arming", "pending", "disarming": return .orange
    case nil: return .gray
    default: return .red
    }
}

func alarmStatusIcon(for state: String?) -> String {
    switch state {
    case "disarmed": return "lock.open.fill"
    case "triggered": return "exclamationmark.triangle.fill"
    default: return "lock.fill"
    }
}

func alarmAvailableModes(supportedFeatures: Int) -> [AlarmMode] {
    AlarmMode.allCases.filter { supportedFeatures & $0.featureBit != 0 }
}

// MARK: - Compact alarm panel

struct AlarmPanelView: View {
    let entity: HAEntityState?
    let availableModes: [AlarmMode]
    let onArm: (AlarmMode) -> Void
    let onDisarm: () -> Void

    @State private var showDisarmConfirmation = false

    private var state: String? { entity?.state }
    private var isTransient: Bool {
        ["arming", "pending", "disarming", "triggered"].contains(state)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: alarmStatusIcon(for: state))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(alarmStatusColor(for: state))
                    .accessibilityHidden(true)

                Text(alarmStatusText(for: state))
                    .font(.headline)
                    .foregroundStyle(isTransient ? alarmStatusColor(for: state) : .primary)
                    .accessibilityLabel("Alarm status: \(alarmStatusText(for: state))")

                Spacer()
            }

            if !availableModes.isEmpty || state != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableModes, id: \.self) { mode in
                            Button {
                                onArm(mode)
                            } label: {
                                Label(mode.displayName, systemImage: mode.icon)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Arm \(mode.displayName)")
                        }

                        Button(role: .destructive) {
                            showDisarmConfirmation = true
                        } label: {
                            Label("Disarm", systemImage: "lock.open.fill")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Disarm alarm")
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .confirmationDialog("Disarm the alarm?", isPresented: $showDisarmConfirmation, titleVisibility: .visible) {
            Button("Disarm", role: .destructive) { onDisarm() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension String {
    /// A Home Assistant state rendered for display: underscores become
    /// spaces and only the first letter is capitalized, so
    /// `armed_custom_bypass` reads as "Armed custom bypass".
    var humanizedStateName: String {
        let spaced = replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }
}
