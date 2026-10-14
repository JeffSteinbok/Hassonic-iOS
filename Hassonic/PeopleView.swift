import MapKit
import SwiftUI

/// A dashboard card showing where everyone is: one map with a pin per person
/// (everyone at home shares the house's), and a row per person under it.
/// Tapping a row opens that person's history; tapping their pin centres them.
struct PeopleCardView: View {
    let card: DashboardPeopleCardConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient

    @State private var position: MapCameraPosition = .automatic
    @State private var historyFor: PersonLocation?

    private var people: [PersonLocation] {
        PersonLocationDirectory.people(
            from: haClient.entities,
            matching: card.entities,
            baseURLString: haClient.baseURLString,
            excludingUserId: card.excludeSignedInUser ? haClient.currentUserId : nil
        )
    }

    private var home: CLLocationCoordinate2D? {
        PersonLocationDirectory.homeCoordinate(from: haClient.entities)
    }

    var body: some View {
        let people = people
        let atHome = people.filter(\.isHome)
        let out = people.filter { !$0.isHome }

        VStack(alignment: .leading, spacing: 10) {
            if let title = card.title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal)
            }

            if people.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .rowSurface()
                    .padding(.horizontal)
            } else {
                map(atHome: atHome, out: out)

                VStack(spacing: 10) {
                    ForEach(people) { person in
                        Button { historyFor = person } label: {
                            PersonRow(person: person, home: home, accessToken: haClient.accessToken, baseURLString: haClient.baseURLString)
                                .overlay(alignment: .trailing) {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.trailing, 14)
                                        .accessibilityHidden(true)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows where \(person.givenName) has been")
                    }
                }
                .padding(.horizontal)
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if let id = DemoMode.openHistoryFor { historyFor = people.first { $0.entityId == id } }
        }
        #endif
        .sheet(item: $historyFor) { person in
            PersonHistorySheet(person: person)
                .presentationDetents([.large])
        }
    }

    private func map(atHome: [PersonLocation], out: [PersonLocation]) -> some View {
        Map(position: $position) {
            if let home {
                Annotation("Home", coordinate: home, anchor: .center) {
                    HomePin(people: atHome, accessToken: haClient.accessToken, baseURLString: haClient.baseURLString)
                }
                .annotationTitles(.hidden)
            }
            ForEach(out) { person in
                if let coordinate = person.coordinate {
                    Annotation(person.givenName, coordinate: coordinate, anchor: .top) {
                        PersonPin(person: person, accessToken: haClient.accessToken, baseURLString: haClient.baseURLString)
                            .onTapGesture { focus(on: coordinate) }
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapControls { }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation { position = .automatic }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Show everyone")
            .padding(10)
        }
        .padding(.horizontal)
    }

    private func focus(on coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        withAnimation {
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500))
        }
    }

    private var emptyMessage: String {
        haClient.entities.contains { $0.entityId.hasPrefix("person.") }
            ? "No one has a location to show yet."
            : "No people are configured in Home Assistant."
    }
}

// MARK: - Map pins

/// The house, with the avatars of everyone in it overlapping beneath.
private struct HomePin: View {
    let people: [PersonLocation]
    let accessToken: String?
    let baseURLString: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "house.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(radius: 3, y: 1)
            if !people.isEmpty {
                AvatarStack(people: people, size: 30, accessToken: accessToken, baseURLString: baseURLString)
            }
        }
    }
}

/// An avatar with the person's first name, or the zone they're in.
private struct PersonPin: View {
    let person: PersonLocation
    let accessToken: String?
    let baseURLString: String

    var body: some View {
        VStack(spacing: 4) {
            PersonAvatar(person: person, size: 40, accessToken: accessToken, baseURLString: baseURLString)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(radius: 3, y: 1)
                .overlay(alignment: .bottomTrailing) {
                    if person.isDriving {
                        Image(systemName: "car.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.orange, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 4, y: 4)
                            .accessibilityLabel("Driving")
                    }
                }
            Text(person.isInNamedZone ? person.locationLabel : person.givenName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

private struct AvatarStack: View {
    let people: [PersonLocation]
    let size: CGFloat
    let accessToken: String?
    let baseURLString: String

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(people) { person in
                PersonAvatar(person: person, size: size, accessToken: accessToken, baseURLString: baseURLString)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            }
        }
    }
}

// MARK: - Rows

/// One person: where, how far from home, and since when.
private struct PersonRow: View {
    let person: PersonLocation
    let home: CLLocationCoordinate2D?
    let accessToken: String?
    let baseURLString: String

    var body: some View {
        HStack(spacing: 12) {
            PersonAvatar(person: person, size: 46, accessToken: accessToken, baseURLString: baseURLString)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The name keeps its room; a long zone in the badge
                    // trails off instead of wrapping.
                    Text(person.name)
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                    PlaceBadge(person: person)
                }
                // Always three lines, so every name sits at the same height.
                Text(person.streetAndLocality ?? person.locationLabel)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(detail ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .rowSurface()
    }

    private var detail: String? {
        let parts = [
            PeopleFormatting.distanceFromHome(of: person, home: home).map { "\($0) from home" },
            person.zoneEnteredAt.map { PeopleFormatting.since($0) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct PlaceBadge: View {
    let person: PersonLocation

    var body: some View {
        if person.isHome {
            Badge(text: "Home", style: .home)
        } else if person.isDriving {
            Badge(text: "Driving", style: .driving, systemImage: "car.fill")
        } else {
            switch person.locationLabel {
            case "Away": Badge(text: "Away", style: .away)
            case "Unknown": Badge(text: "Unknown", style: .unknown)
            default: Badge(text: person.locationLabel, style: .zone)
            }
        }
    }
}

private struct Badge: View {
    enum Style { case home, zone, away, driving, unknown }

    let text: String
    let style: Style
    var systemImage: String?

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
            .labelStyle(BadgeLabelStyle())
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }

    private var tint: Color {
        switch style {
        case .home: return .green
        case .zone: return .teal
        case .away: return .indigo
        case .driving: return .orange
        case .unknown: return .secondary
        }
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private extension View {
    func rowSurface() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}

// MARK: - Formatting

enum PeopleFormatting {
    /// "3.4 mi" or "5.5 km" by the user's locale; nil for someone at home or
    /// with no coordinate, or when there's no home zone to measure from.
    static func distanceFromHome(
        of person: PersonLocation,
        home: CLLocationCoordinate2D?,
        locale: Locale = .current
    ) -> String? {
        guard !person.isHome, let home, let coordinate = person.coordinate else { return nil }
        let meters = CLLocation(latitude: home.latitude, longitude: home.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 1
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let usesMiles = locale.measurementSystem != .metric
        return formatter.string(from: measurement.converted(to: usesMiles ? .miles : .kilometers))
    }

    /// "since 3:15 PM" today, "since yesterday", "since Mon" this week, then
    /// "since Oct 3".
    static func since(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "since " + date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "since yesterday" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = days < 7 ? style.weekday(.abbreviated) : style.month(.abbreviated).day()
        return "since " + date.formatted(style)
    }
}

// MARK: - Avatar

/// The profile picture, falling back to initials on a tinted disc while it
/// loads or when Home Assistant has none.
///
/// Takes the token and address rather than reading `@EnvironmentObject`: this is a leaf
/// used inside a `Map` annotation, and SwiftUI does not carry environment
/// objects into that closure — reading one there traps at runtime.
struct PersonAvatar: View {
    let person: PersonLocation
    let size: CGFloat
    let accessToken: String?
    let baseURLString: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Color.accentColor.opacity(0.18)
                    Text(PersonLocationDirectory.initials(for: person.name))
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: person.pictureURL) {
            await load()
        }
    }

    private func load() async {
        guard let url = person.pictureURL else {
            image = nil
            return
        }
        let request = homeAssistantRequest(for: url, baseURLString: baseURLString, accessToken: accessToken)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let loaded = UIImage(data: data) else { return }
        image = loaded
    }
}
