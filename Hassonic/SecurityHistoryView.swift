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
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let loaded = UIImage(data: data) else { return }
            image = loaded
        }
    }
}

private struct AuthenticatedAsyncImage: View {
    let request: URLRequest?

    @StateObject private var loader = AuthenticatedImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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

// MARK: - Detail view

struct SecurityEventDetailView: View {
    let event: LLMVisionEvent
    let imageRequest: URLRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if imageRequest != nil {
                    AuthenticatedAsyncImage(request: imageRequest)
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let title = event.title {
                        Text(title)
                            .font(.title3.weight(.semibold))
                    }

                    if let date = event.startDate {
                        Text(date, style: .relative)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let camera = event.cameraName {
                        Label(camera, systemImage: "video.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let category = event.category {
                        Label(category.capitalized, systemImage: categoryIcon(category))
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
        .navigationTitle("Event Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryIcon(_ category: String) -> String {
        switch category.lowercased() {
        case "person": return "person.fill"
        case "vehicle", "car": return "car.fill"
        case "animal": return "pawprint.fill"
        case "package": return "shippingbox.fill"
        default: return "tag.fill"
        }
    }
}

// MARK: - History list

struct SecurityHistoryView: View {
    let client: LLMVisionClient?
    let title: String

    @State private var events: [LLMVisionEvent] = []
    @State private var loadState: LoadState = .idle
    @State private var selectedEvent: LLMVisionEvent?

    private enum LoadState {
        case idle, loading, loaded, empty
        case integrationUnavailable
        case authFailed
        case error(String)
    }

    init(client: LLMVisionClient?, title: String = "Security History") {
        self.client = client
        self.title = title
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
                eventList

            case .empty:
                ContentUnavailableView(
                    "No Recent Events",
                    systemImage: "checkmark.shield",
                    description: Text("No security events in the last 24 hours.")
                )

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
        .task(id: client == nil) { await load() }
        .sheet(item: $selectedEvent) { event in
            NavigationStack {
                SecurityEventDetailView(
                    event: event,
                    imageRequest: client?.imageRequest(for: event.keyFrame ?? "")
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { selectedEvent = nil }
                    }
                }
            }
        }
    }

    private var eventList: some View {
        LazyVStack(spacing: 0) {
            ForEach(events) { event in
                Button {
                    selectedEvent = event
                } label: {
                    SecurityEventRow(event: event, imageRequest: client?.imageRequest(for: event.keyFrame ?? ""))
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 76)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
    }

    private func load() async {
        guard let client else { return }
        loadState = .loading
        let result = await client.fetchTimelineEvents()
        switch result {
        case .success(let fetched):
            events = fetched
            loadState = fetched.isEmpty ? .empty : .loaded
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

private struct SecurityEventRow: View {
    let event: LLMVisionEvent
    let imageRequest: URLRequest?

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedAsyncImage(request: imageRequest)
                .frame(width: 56, height: 56)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Event")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if let camera = event.cameraName {
                    Text(camera)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let desc = event.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let date = event.startDate {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let category = event.category {
                    Text(category.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
