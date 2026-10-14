import MapKit
import SwiftUI

/// What tapping a person on the People card opens: a day of where they were.
/// A map with their path and a pin at each stop, and the stays under it,
/// newest first. Pick another day along the top; tap a stay to find it on
/// the map.
struct PersonHistorySheet: View {
    let person: PersonLocation

    @EnvironmentObject private var haClient: HAWebSocketClient
    @Environment(\.dismiss) private var dismiss

    /// Home Assistant keeps ten days of history unless told otherwise.
    private static let dayCount = 10

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var history: PersonHistory?
    @State private var failed = false
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedStay: PersonHistory.Stay.ID?

    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<Self.dayCount).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DayStrip(days: days, selection: $day)
                    content
                }
                .padding(.vertical)
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: day) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let history {
            if history.stays.isEmpty {
                ContentUnavailableView("Nothing recorded", systemImage: "clock",
                                       description: Text("Home Assistant has no history for \(person.givenName) on this day."))
            } else {
                map(history)
                VStack(spacing: 8) {
                    ForEach(history.stays) { stay in
                        Button { focus(on: stay) } label: {
                            StayRow(stay: stay, isSelected: selectedStay == stay.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(stay.coordinate == nil)
                    }
                }
                .padding(.horizontal)
            }
        } else if failed {
            ContentUnavailableView("Couldn't load history", systemImage: "exclamationmark.triangle",
                                   description: Text("Check the connection to Home Assistant and try again."))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func map(_ history: PersonHistory) -> some View {
        Map(position: $position) {
            if history.path.count > 1 {
                MapPolyline(coordinates: history.path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(history.stays.filter { $0.coordinate != nil }) { stay in
                Marker(stay.place, systemImage: stay.place == "Home" ? "house.fill" : "mappin",
                       coordinate: stay.coordinate!)
                    .tint(stay.place == "Home" ? .green : stay.place == "Away" ? .indigo : .teal)
            }
        }
        .mapControls { }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
    }

    private func focus(on stay: PersonHistory.Stay) {
        guard let coordinate = stay.coordinate else { return }
        selectedStay = stay.id
        withAnimation {
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
        }
    }

    private func load() async {
        history = nil
        failed = false
        selectedStay = nil
        position = .automatic
        do {
            history = try await PersonHistoryLoader.load(
                entityId: person.entityId,
                day: day,
                baseURLString: haClient.baseURLString,
                accessToken: haClient.accessToken
            )
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}

/// "Today", "Yesterday", then "Sat 10" back as far as history goes.
private struct DayStrip: View {
    let days: [Date]
    @Binding var selection: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let isSelected = day == selection
                    Button { selection = day } label: {
                        Text(label(for: day))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }

    private func label(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// One stay: the place, when, and for how long.
private struct StayRow: View {
    let stay: PersonHistory.Stay
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(stay.place)
                    .font(.headline)
                    .lineLimit(1)
                Text(times)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(PersonHistory.duration(from: stay.start, to: stay.end ?? .now))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? tint : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var times: String {
        let start = stay.start.formatted(date: .omitted, time: .shortened)
        guard let end = stay.end else { return "Since \(start)" }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var symbol: String {
        switch stay.place {
        case "Home": return "house.fill"
        case "Away": return "figure.walk"
        default: return "mappin.circle.fill"
        }
    }

    private var tint: Color {
        switch stay.place {
        case "Home": return .green
        case "Away": return .indigo
        default: return .teal
        }
    }
}
