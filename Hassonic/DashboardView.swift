import SwiftUI

struct DashboardPageView: View {
    let page: DashboardPageConfiguration
    /// Pages past the tab bar's fifth slot live under More, which already
    /// has a navigation bar, so they mustn't bring their own.
    var isInMoreTab = false
    /// The room pages, shown as tiles at the top of the first page.
    var rooms: [DashboardPageConfiguration] = []
    /// Pushed from a room tile: the page above supplies the navigation bar.
    var isPushed = false

    @EnvironmentObject private var configurationLoader: AppConfigurationLoader
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if isInMoreTab || isPushed {
            content
        } else if !rooms.isEmpty {
            // The router owns the path, so a link can open a room.
            NavigationStack(path: $router.roomPath) { content }
        } else {
            NavigationStack { content }
        }
    }

    @ViewBuilder private var cards: some View {
        if let errorMessage = configurationLoader.errorMessage {
            DashboardConfigurationErrorBanner(message: errorMessage)
        }

        if !rooms.isEmpty {
            RoomsStrip(rooms: rooms)
        }

        ForEach(Array(page.sections.enumerated()), id: \.offset) { _, section in
            DashboardSectionView(section: section)
        }
    }

    /// A page of nothing but remotes is a remote: it fits the screen, shrunk
    /// as needed on a smaller phone, rather than scrolling.
    private var fitsScreen: Bool {
        let cards = page.sections.flatMap(\.cards)
        return rooms.isEmpty && !cards.isEmpty && cards.allSatisfy {
            if case .tvRemote = $0 { return true } else { return false }
        }
    }

    private var content: some View {
        ScrollView {
            if fitsScreen {
                // Still in a scroll view, for pull-to-refresh; it never has
                // anything to scroll.
                ShrinkToFit {
                    VStack(alignment: .leading, spacing: 16) { cards }
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                }
                .containerRelativeFrame(.vertical)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    cards
                }
                .padding(.top, 4)
                .padding(.bottom)
            }
        }
        .reloadsConfigurationOnPull()
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(page.isRoom ? .large : .inline)
        .toolbar {
            // Under More, or pushed from a room tile, the leading spot is the back button.
            ToolbarItem(placement: isInMoreTab || isPushed ? .topBarTrailing : .topBarLeading) {
                AppMenuButton(page: AppPage(id: page.id, title: page.title, systemIcon: page.systemIcon))
            }
        }
        .navigationDestination(for: String.self) { roomID in
            if let room = rooms.first(where: { $0.id == roomID }) {
                DashboardPageView(page: room, isPushed: true)
            }
        }
    }
}

/// Lays its content out at its natural height and scales the whole thing
/// down, evenly, when that's taller than the space it has. Full width either
/// way: it's laid out wider by the same factor it's shrunk by.
private struct ShrinkToFit<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let scale = naturalHeight > proxy.size.height && naturalHeight > 0
                ? proxy.size.height / naturalHeight
                : 1
            content
                .frame(width: proxy.size.width / scale)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                .scaleEffect(scale, anchor: .top)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

private struct DashboardSectionView: View {
    let section: DashboardSectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = section.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal)
            }

            ForEach(Array(section.cards.enumerated()), id: \.offset) { _, card in
                DashboardCardView(configuration: card)
            }
        }
    }
}

private struct DashboardCardView: View {
    let configuration: DashboardCardConfiguration

    @EnvironmentObject private var haClient: HAWebSocketClient

    var body: some View {
        switch configuration {
        case .light(let card):
            let entity = haClient.entity(card.entity)
            LightToggleRow(
                label: card.title ?? entity?.friendlyName ?? card.entity,
                entity: entity,
                icon: card.icon,
                onToggle: { isOn in
                    DashboardCardActionRouter.setLight(isOn, entityID: card.entity, client: haClient)
                }
            )
            .dashboardCardSurface()

        case .cover(let card):
            let entity = haClient.entity(card.entity)
            CoverControlRow(
                label: card.title ?? entity?.friendlyName ?? card.entity,
                entity: entity,
                onOpen: {
                    DashboardCardActionRouter.performCoverAction(.open, entityID: card.entity, client: haClient)
                },
                onClose: {
                    DashboardCardActionRouter.performCoverAction(.close, entityID: card.entity, client: haClient)
                },
                onStop: {
                    DashboardCardActionRouter.performCoverAction(.stop, entityID: card.entity, client: haClient)
                },
                onSetPosition: {
                    DashboardCardActionRouter.performCoverAction(
                        .setPosition($0),
                        entityID: card.entity,
                        client: haClient
                    )
                }
            )
            .dashboardCardSurface()

        case .alarm(let card):
            alarmCard(card)

        case .llmVisionTimeline(let card):
            SecurityHistoryView(
                client: llmVisionClient,
                title: card.title ?? "Security History"
            )
            .padding(.bottom)

        case .people(let card):
            PeopleCardView(card: card)

        case .room(let card):
            RoomPlanCardView(card: card)

        case .tvRemote(let card):
            TVRemoteCardView(
                configuration: card,
                tvApp: tvApp(card),
                tvIsOff: card.tvIsOff(mediaPlayerState: card.tv?.mediaPlayer.flatMap { haClient.entity($0)?.state }),
                refreshTV: {
                    guard let player = card.tv?.mediaPlayer else { return }
                    haClient.callService(domain: "homeassistant", service: "update_entity", entityId: player)
                },
                isAvailable: haClient.connectionState == .connected,
                perform: { DashboardCardActionRouter.perform($0, client: haClient) }
            )
            .padding(.horizontal)

        case .thermostat(let card):
            let entity = haClient.entity(card.entity)
            let state = ThermostatState(entity)
            ThermostatCardView(
                title: card.title ?? entity?.friendlyName ?? card.entity,
                state: state,
                outside: card.outside.flatMap { DashboardCardActionRouter.outsideTemperature(haClient.entity($0)) },
                compact: card.compact,
                actions: ThermostatActions(
                    setTemperature: { DashboardCardActionRouter.setThermostat($0, entityID: card.entity, client: haClient) },
                    setRange: { DashboardCardActionRouter.setThermostatRange(low: $0, high: $1, entityID: card.entity, client: haClient) },
                    setMode: {
                        DashboardCardActionRouter.setThermostatMode($0, autoModeName: state?.autoModeName ?? ThermostatState.Mode.auto.rawValue,
                                                                    entityID: card.entity, client: haClient)
                    }
                )
            )
            .dashboardCardSurface()

        case .unsupported(let card):
            ContentUnavailableView(
                card.title ?? "Unsupported Card",
                systemImage: "questionmark.app.dashed",
                description: Text("This version of \(AppIdentity.name) does not support '\(card.type)' cards.")
            )
            .dashboardCardSurface()
        }
    }

    private func tvApp(_ card: DashboardTVRemoteConfiguration) -> String? {
        let player = card.tv?.mediaPlayer.flatMap { haClient.entity($0) }
        return card.runningApp(
            source: player?.attributeString("source"),
            sourceList: player?.attributeStringArray("source_list") ?? []
        )
    }

    private func alarmCard(_ card: DashboardEntityCardConfiguration) -> some View {
        let entity = haClient.entity(card.entity)
        let supportedFeatures: Int
        if case .number(let value)? = entity?.attributes["supported_features"] {
            supportedFeatures = Int(value)
        } else {
            supportedFeatures = 0
        }

        return VStack(alignment: .leading, spacing: 8) {
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }

            if haClient.connectionState == .connected || entity != nil {
                AlarmPanelView(
                    entity: entity,
                    availableModes: alarmAvailableModes(supportedFeatures: supportedFeatures),
                    onArm: {
                        DashboardCardActionRouter.setAlarmMode($0, entityID: card.entity, client: haClient)
                    },
                    onDisarm: {
                        DashboardCardActionRouter.disarm(entityID: card.entity, client: haClient)
                    }
                )
            } else {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "shield.slash",
                    description: Text("Connect on the Connection tab to control the alarm.")
                )
            }
        }
        .padding(.horizontal)
    }

    private var llmVisionClient: LLMVisionClient? {
        guard haClient.connectionState == .connected,
              let baseURL = URL(string: haClient.baseURLString),
              let token = haClient.accessToken else {
            return nil
        }
        return LLMVisionClient(baseURL: baseURL, accessToken: token)
    }

}

private struct DashboardConfigurationErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .accessibilityLabel("Dashboard configuration warning: \(message)")
    }
}

private extension View {
    func dashboardCardSurface() -> some View {
        padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
    }
}
