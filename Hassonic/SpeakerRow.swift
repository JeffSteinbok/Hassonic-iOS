import SwiftUI

struct SpeakerRow: View {
    @EnvironmentObject private var haClient: HAWebSocketClient
    let zone: MusicZone
    let entity: HAEntityState

    @State private var localVolume: Double = 0
    @State private var isDraggingVolume = false

    /// Volume/mute/power/input act on the proxy device, if this zone has one.
    private var controlEntityId: String { zone.proxy?.entityId ?? zone.entityId }

    private var proxyEntity: HAEntityState? {
        guard let proxy = zone.proxy else { return nil }
        return haClient.entity(proxy.entityId)
    }

    private var controlEntity: HAEntityState? { zone.proxy != nil ? proxyEntity : entity }

    private var isMuted: Bool {
        if case .bool(let value)? = controlEntity?.attributes["is_volume_muted"] { return value }
        return false
    }

    private var remoteVolume: Double {
        if case .number(let value)? = controlEntity?.attributes["volume_level"] { return value }
        return 0
    }

    /// Defaults to off (not on) when the proxy's state isn't known yet —
    /// safer than assuming "on" for an unconfirmed device.
    private var isProxyOn: Bool {
        guard let proxyEntity else { return false }
        return proxyEntity.state != "off"
    }

    /// nil when we can't tell (proxy off, or it doesn't report a `source` attribute).
    private var isInputCorrect: Bool? {
        guard let proxy = zone.proxy, let currentSource = proxyEntity?.attributeString("source") else { return nil }
        return currentSource == proxy.inputSource
    }

    private var inputStatus: (icon: String, color: Color) {
        switch isInputCorrect {
        case true: return ("checkmark.circle.fill", .green)
        case false: return ("exclamationmark.triangle.fill", .orange)
        case nil: return ("questionmark.circle.fill", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(zone.displayName, systemImage: zone.icon)
                    .font(.subheadline)

                if let proxy = zone.proxy {
                    Button {
                        haClient.selectSource(proxy.entityId, source: proxy.inputSource)
                    } label: {
                        Image(systemName: inputStatus.icon)
                            .foregroundStyle(inputStatus.color)
                    }
                    .buttonStyle(PressFeedbackIconButtonStyle())
                    .accessibilityLabel("Input: \(proxy.inputSource)")

                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isProxyOn },
                        set: { newValue in
                            newValue ? haClient.turnOn(controlEntityId) : haClient.turnOff(controlEntityId)
                        }
                    ))
                    .labelsHidden()
                }
            }

            HStack(spacing: 12) {
                Button {
                    haClient.setMuted(controlEntityId, muted: !isMuted)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(PressFeedbackIconButtonStyle())

                Slider(value: $localVolume, in: 0...1, onEditingChanged: { editing in
                    isDraggingVolume = editing
                    if !editing {
                        haClient.setVolume(controlEntityId, level: localVolume)
                    }
                })
            }
        }
        .onAppear {
            localVolume = remoteVolume
            enforceDefaultVolumeIfNeeded()
        }
        .onChange(of: remoteVolume) { _, newValue in
            if !isDraggingVolume { localVolume = newValue }
        }
    }

    private func enforceDefaultVolumeIfNeeded() {
        guard let defaultVolume = zone.defaultVolume else { return }
        if case .number(let currentOwnVolume)? = entity.attributes["volume_level"], abs(currentOwnVolume - defaultVolume) > 0.02 {
            haClient.setVolume(zone.entityId, level: defaultVolume)
        }
    }
}
