import SwiftUI

/// Room pictures, fetched once and shared by the room page and its tile.
@MainActor
final class RoomImageStore {
    static let shared = RoomImageStore()

    private var images: [String: UIImage] = [:]

    func image(_ path: String, client: HAWebSocketClient) async -> UIImage? {
        if let cached = images[path] { return cached }
        guard let url = resolveHAImageURL(path: path, baseURLString: client.baseURLString) else { return nil }
        let request = homeAssistantRequest(for: url, baseURLString: client.baseURLString, accessToken: client.accessToken)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              // A file URL (the screenshot demo's) has no status to check.
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? url.isFileURL,
              let image = UIImage(data: data) else { return nil }
        images[path] = image
        return image
    }
}

@MainActor
extension DashboardRoomCardConfiguration {
    /// "71°", "Air excellent" or "Sink dry": a status entity as a chip reads.
    func statusText(_ status: Status, client: HAWebSocketClient) -> String? {
        guard let entity = client.entity(status.entity),
              !["unavailable", "unknown"].contains(entity.state) else { return nil }
        let reading = entity.readableState
        guard let label = status.label else { return reading }
        return "\(label) \(reading.prefix(1).lowercased() + reading.dropFirst())"
    }
}

// MARK: - On the room page

/// The chips above the picture: the room's sensors ("71°", "Air excellent").
struct RoomStatusChips: View {
    let card: DashboardRoomCardConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient

    var body: some View {
        // Keyed by place in the list: two sensors can read the same "71°".
        let readings = Array((card.status ?? []).compactMap { card.statusText($0, client: haClient) }.enumerated())
        if !readings.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(readings, id: \.offset) { _, reading in
                        Text(reading)
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// "Lights Off", "Bedtime": each sets several devices at once.
struct RoomActions: View {
    let actions: [DashboardRoomCardConfiguration.Action]

    @EnvironmentObject private var haClient: HAWebSocketClient
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.name) { action in
                Button {
                    run(action)
                } label: {
                    Label {
                        Text(action.name).lineLimit(1).minimumScaleFactor(0.8)
                    } icon: {
                        if let icon = action.icon { DeviceSymbol(name: icon, size: 14) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private func run(_ action: DashboardRoomCardConfiguration.Action) {
        taps += 1
        for entity in action.on ?? [] { call(entity, "turn_on") }
        for entity in action.off ?? [] { call(entity, "turn_off") }
        if let script = action.script { haClient.runScript(script) }
    }

    private func call(_ entity: String, _ service: String) {
        guard let domain = entity.split(separator: ".").first else { return }
        haClient.callService(domain: String(domain), service: service, entityId: entity)
    }
}

/// What the room's speaker is playing, with play/pause.
struct RoomNowPlaying: View {
    let card: DashboardRoomCardConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient

    private var speaker: HAEntityState? {
        card.entities.filter { $0.hasPrefix("media_player.") }
            .compactMap { haClient.entity($0) }
            .first { ["playing", "paused"].contains($0.state) && $0.attributeString("media_title") != nil }
    }

    var body: some View {
        if let speaker {
            let isPlaying = speaker.state == "playing"
            HStack(spacing: 12) {
                AsyncImage(url: resolveHAImageURL(path: speaker.attributeString("entity_picture"), baseURLString: haClient.baseURLString)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.attributeString("media_title") ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text([speaker.attributeString("media_artist"), speaker.attributeString("media_album_name")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { haClient.mediaPlayPause(speaker.entityId) } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - On the first page

/// A tile per room at the top of the first page: its picture and name.
/// Tapping one opens it.
struct RoomsStrip: View {
    let rooms: [DashboardPageConfiguration]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(rooms) { room in
                        NavigationLink(value: room.id) {
                            RoomTile(room: room)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct RoomTile: View {
    let room: DashboardPageConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient
    @State private var image: UIImage?

    var body: some View {
        let card = room.roomCard

        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // The head of the room (bed, lamps, art) is at the top.
                        .frame(width: 200, height: 96, alignment: .top)
                } else {
                    Image(systemName: room.systemIcon)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 96)
            .clipped()

            Text(room.title)
                .font(.headline)
                .lineLimit(1)
                    .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 200)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: card?.image) {
            if let path = card?.image {
                image = await RoomImageStore.shared.image(path, client: haClient)
            }
        }
    }
}
