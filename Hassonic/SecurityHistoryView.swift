import SwiftUI

// MARK: - Authenticated image loader

@MainActor
final class AuthenticatedImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private var task: Task<Void, Never>?

    func load(request: URLRequest?) {
        guard let request else { return }
        task?.cancel()
        isLoading = true
        task = Task {
            defer { isLoading = false }
            // Only an HTTP response has a status; a demo file has none.
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let loaded = UIImage(data: data) else { return }
            image = loaded
        }
    }
}

private struct AuthenticatedAsyncImage: View {
    let request: URLRequest?
    /// Fit shows the whole frame, letterboxed; fill crops it to the frame.
    var contentMode: ContentMode = .fill

    @StateObject private var loader = AuthenticatedImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loader.isLoading {
                ProgressView()
            } else {
                Image(systemName: "camera.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: request?.url) {
            loader.load(request: request)
        }
    }
}

// MARK: - Detail

/// The events of the selected day, one page each: swipe left for the next
/// (older) one, right for the one before.
struct SecurityEventPager: View {
    let events: [LLMVisionEvent]
    let cameraName: (LLMVisionEvent) -> String?
    let imageRequest: (LLMVisionEvent) -> URLRequest?

    @State var selection: LLMVisionEvent.ID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(events) { event in
                    SecurityEventDetailView(
                        event: event,
                        cameraName: cameraName(event),
                        imageRequest: imageRequest(event)
                    )
                    .tag(event.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// "3 of 7": where this one sits in the day.
    private var title: String {
        guard events.count > 1, let index = events.firstIndex(where: { $0.id == selection }) else { return "Event" }
        return "\(index + 1) of \(events.count)"
    }
}

struct SecurityEventDetailView: View {
    let event: LLMVisionEvent
    let cameraName: String?
    let imageRequest: URLRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if imageRequest != nil {
                    // The whole frame, letterboxed: what the camera saw at
                    // the edges matters.
                    AuthenticatedAsyncImage(request: imageRequest, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(event.title ?? "Event")
                        .font(.title3.weight(.semibold))

                    if let date = event.startDate {
                        Label(SecurityTimeline.eventTime(date), systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let cameraName {
                        Label(cameraName, systemImage: "video.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let category = event.category {
                        Label(category.capitalized, systemImage: SecurityEventRow.icon(for: category))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let description = event.description, !description.isEmpty {
                    Divider()
                    Text(description)
                        .font(.body)
                }
            }
            .padding()
        }
    }
}

// MARK: - Timeline

/// The LLM Vision timeline, a day at a time like a person's history: the
/// strip of days along the top, that day's events under it, newest first.
/// Tap one for its detail, then swipe through the rest of the day.
struct SecurityHistoryView: View {
    let client: LLMVisionClient?
    let title: String

    @EnvironmentObject private var haClient: HAWebSocketClient

    @State private var events: [LLMVisionEvent] = []
    @State private var loadState: LoadState = .idle
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var opened: LLMVisionEvent?

    private enum LoadState {
        case idle, loading, loaded
        case integrationUnavailable
        case authFailed
        case error(String)
    }

    init(client: LLMVisionClient?, title: String = "Security History") {
        self.client = client
        self.title = title
    }

    private var dayEvents: [LLMVisionEvent] {
        SecurityTimeline.events(events, on: day)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.horizontal)

            switch loadState {
            case .idle, .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding()

            case .loaded:
                DayStrip(days: DayStrip.recentDays(SecurityTimeline.dayCount), selection: $day)
                eventList

            case .integrationUnavailable:
                ContentUnavailableView(
                    "LLM Vision Not Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Install and configure the LLM Vision integration in Home Assistant to see history here.")
                )

            case .authFailed:
                ContentUnavailableView(
                    "Authentication Error",
                    systemImage: "lock.slash",
                    description: Text("Check your Home Assistant access token in Settings.")
                )

            case .error(let message):
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Could Not Load History",
                        systemImage: "wifi.slash",
                        description: Text(message)
                    )
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        // Again once connected: there's no client before then.
        .task(id: client == nil) {
            await load()
            #if DEBUG && targetEnvironment(simulator)
            if let uid = DemoMode.openEvent { opened = events.first { $0.uid == uid } }
            #endif
        }
        .sheet(item: $opened) { event in
            // The day as it was when tapped, so a refresh can't shift pages.
            SecurityEventPager(
                events: SecurityTimeline.events(events, on: day).nonEmpty ?? [event],
                cameraName: cameraName(for:),
                imageRequest: imageRequest(for:),
                selection: event.id
            )
        }
    }

    @ViewBuilder
    private var eventList: some View {
        let dayEvents = dayEvents
        if dayEvents.isEmpty {
            ContentUnavailableView(
                "Nothing seen",
                systemImage: "checkmark.shield",
                description: Text("The cameras recorded no events on this day.")
            )
        } else {
            VStack(spacing: 8) {
                ForEach(dayEvents) { event in
                    Button { opened = event } label: {
                        SecurityEventRow(event: event, cameraName: cameraName(for: event), imageRequest: imageRequest(for: event))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func cameraName(for event: LLMVisionEvent) -> String? {
        SecurityTimeline.cameraName(event.cameraName) { id in
            haClient.entity(id)?.attributeString("friendly_name")
        }
    }

    private func imageRequest(for event: LLMVisionEvent) -> URLRequest? {
        #if DEBUG && targetEnvironment(simulator)
        if DemoMode.directory != nil, let frame = event.keyFrame, let url = URL(string: frame), url.isFileURL {
            return URLRequest(url: url)
        }
        #endif
        return client?.imageRequest(for: event.keyFrame ?? "")
    }

    private func load() async {
        #if DEBUG && targetEnvironment(simulator)
        if let demo = DemoMode.timeline() {
            events = demo
            loadState = .loaded
            return
        }
        #endif
        guard let client else { return }
        loadState = .loading
        let result = await client.fetchTimelineEvents(limit: 500, hours: SecurityTimeline.dayCount * 24)
        switch result {
        case .success(let fetched):
            events = fetched
            loadState = .loaded
        case .failure(let error):
            events = []
            switch error {
            case .integrationUnavailable: loadState = .integrationUnavailable
            case .authenticationFailed: loadState = .authFailed
            case .networkError(let msg): loadState = .error(msg)
            case .decodingError: loadState = .error("Unexpected response from LLM Vision.")
            }
        }
    }
}

/// One event, styled like a stay in a person's history: the key frame, what
/// happened, and when and where.
private struct SecurityEventRow: View {
    let event: LLMVisionEvent
    let cameraName: String?
    let imageRequest: URLRequest?

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedAsyncImage(request: imageRequest)
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Event")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let category = event.category {
                Image(systemName: Self.icon(for: category))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(category.capitalized)
            }
        }
        .historyRow()
        .accessibilityElement(children: .combine)
    }

    /// "5:42 PM · Backyard Left"
    private var subtitle: String {
        [event.startDate.map { SecurityTimeline.rowTime($0) }, cameraName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func icon(for category: String) -> String {
        switch category.lowercased() {
        case "person": return "person.fill"
        case "vehicle", "car": return "car.fill"
        case "animal": return "pawprint.fill"
        case "package": return "shippingbox.fill"
        default: return "tag.fill"
        }
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
