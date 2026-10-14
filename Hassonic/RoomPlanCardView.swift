import SwiftUI

/// The `room` card: status chips, the room's picture with a button on each
/// device (tap toggles, long-press opens its controls; an appliance or sensor
/// opens them on a tap, and shows its reading on the picture), lights glowing
/// on the floor where they're on, quick actions, and what's playing.
struct RoomPlanCardView: View {
    let card: DashboardRoomCardConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient

    @State private var image: UIImage?
    @State private var failed = false
    @State private var controlling: DashboardRoomCardConfiguration.Hotspot?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoomStatusChips(card: card)

            Group {
                if let image {
                    plan(image)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if failed {
                                Label("Couldn't load \(card.image)", systemImage: "photo")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                        }
                }
            }
            .padding(.horizontal)

            if let actions = card.actions, !actions.isEmpty {
                RoomActions(actions: actions)
                    .padding(.horizontal)
            }

            RoomNowPlaying(card: card)
                .padding(.horizontal)
        }
        .task(id: card.image) {
            image = await RoomImageStore.shared.image(card.image, client: haClient)
            failed = image == nil
        }
        .sheet(item: $controlling) { hotspot in
            DeviceControlSheet(
                entityId: hotspot.entity,
                title: name(of: hotspot),
                symbol: hotspot.symbol
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func plan(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        // The room dims a little, and each light that's on
                        // throws a warm pool around itself.
                        Color.black.opacity(0.3)
                        ForEach(litLights) { hotspot in
                            RadialGradient(
                                colors: [Color(red: 1, green: 0.78, blue: 0.4).opacity(0.7),
                                         Color(red: 1, green: 0.66, blue: 0.24).opacity(0.18),
                                         .clear],
                                center: UnitPoint(x: hotspot.x, y: hotspot.y),
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.32
                            )
                            .blendMode(.screen)
                        }
                        ForEach(card.hotspots) { hotspot in
                            HotspotButton(
                                hotspot: hotspot,
                                entity: haClient.entity(hotspot.entity),
                                toggle: { haClient.toggle(hotspot.entity) },
                                name: name(of: hotspot),
                                showControls: { controlling = hotspot }
                            )
                            .position(
                                x: hotspot.x * geometry.size.width,
                                y: hotspot.y * geometry.size.height
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: litLights.map(\.id))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var litLights: [DashboardRoomCardConfiguration.Hotspot] {
        card.hotspots.filter { $0.domain == "light" && haClient.entity($0.entity)?.state == "on" }
    }

    private func name(of hotspot: DashboardRoomCardConfiguration.Hotspot) -> String {
        hotspot.label ?? haClient.entity(hotspot.entity)?.name(in: card.title) ?? hotspot.entity
    }
}

private struct HotspotButton: View {
    let hotspot: DashboardRoomCardConfiguration.Hotspot
    let entity: HAEntityState?
    let toggle: () -> Void
    let name: String
    let showControls: () -> Void

    /// Appliances and sensors always have a sheet: their controls or readings.
    private var hasControls: Bool { !hotspot.isToggleable || (entity?.hasControlsBeyondPower ?? false) }

    @State private var longPresses = 0

    private var isOn: Bool {
        guard let entity else { return false }
        if hotspot.domain == "water_heater" { return entity.isApplianceRunning }
        return ["on", "playing", "open"].contains(entity.state)
    }

    private func tap() {
        guard isAvailable else { return }
        if hotspot.isToggleable { toggle() } else { showControls() }
    }

    private var isAvailable: Bool {
        guard let state = entity?.state else { return false }
        return state != "unavailable"
    }

    private var diameter: CGFloat { hotspot.size == .large ? 60 : 46 }

    var body: some View {
        // Not a Button: a Button swallows the long-press.
        DeviceSymbol(name: hotspot.symbol, size: diameter * 0.42)
            .foregroundStyle(isOn ? Color.black : Color.secondary)
            .frame(width: diameter, height: diameter)
            .background(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial), in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: isOn ? .yellow.opacity(0.6) : .black.opacity(0.3), radius: isOn ? 12 : 3, y: isOn ? 0 : 1)
            .overlay(alignment: .bottom) {
                // Below the button without moving it off the device.
                if let reading = entity?.hotspotReading {
                    Text(reading)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial), in: Capsule())
                        .foregroundStyle(isOn ? Color.black : Color.primary)
                        .offset(y: 22)
                        .accessibilityHidden(true)
                }
            }
            .opacity(isAvailable ? 1 : 0.45)
            .contentShape(Circle())
            .onTapGesture { tap() }
            .onLongPressGesture(minimumDuration: 0.4) {
                guard hasControls else { return }
                longPresses += 1
                showControls()
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: longPresses)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .accessibilityAction(named: "Controls") { if hasControls { showControls() } }
            .accessibilityLabel(name)
            .accessibilityValue(hotspot.isToggleable ? (isOn ? "On" : "Off") : (entity?.readableState ?? ""))
            .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// An SF Symbol by name, or one of the app's own drawn in the same style
/// (`torchiere`: iOS has no uplight floor lamp).
struct DeviceSymbol: View {
    let name: String
    let size: CGFloat

    var body: some View {
        if UIImage(systemName: name) != nil {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
        } else {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.15, height: size * 1.15)
        }
    }
}
