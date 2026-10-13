import CarPlay
import Combine
import CoreLocation
import MapKit
import UIKit

/// Drives the CarPlay screen.
///
/// The root is a `CPListTemplate` — one full-width row per person, showing
/// their Home Assistant profile picture, their name, and the zone they're in.
/// Selecting someone pushes a `CPPointOfInterestTemplate` holding just them,
/// which is CarPlay's only map surface available outside the navigation
/// category.
///
/// ## Why a list and not a map up front
///
/// `CPPointOfInterest` carries no image and CarPlay fixes its row layout, so
/// a map-first screen couldn't show profile pictures and couldn't fit four
/// people without scrolling. `CPListItem` does take an image and uses normal
/// list metrics, so the list leads and the map is one tap in.
///
/// Drawing the screen by hand instead — the only way to control type or row
/// height at all — needs the navigation entitlement and a `CPMapTemplate`
/// root so CarPlay hands over a `CPWindow`. That path crash-loops the
/// iOS 26.5 simulator's CarPlay host on a missing selector inside Apple's own
/// CarPlaySupport:
///
///     -[CPSTemplateInstance vehicleSupportsDestinationSharing]:
///         unrecognized selector sent to instance
///       -[CPSMapTemplateViewController _updateShareButtonVisibility]
///
/// It fires from `viewDidLoad` on a stock, unconfigured `CPMapTemplate`, so
/// nothing on our side avoids it. See docs/carplay.md.
///
/// ## Scene lifetime
///
/// The CarPlay scene can be the first — or only — scene the system creates,
/// so this doesn't assume the phone UI has already connected to Home
/// Assistant; it kicks off its own connection attempt and then just follows
/// `HAWebSocketClient.shared`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var cancellables: Set<AnyCancellable> = []
    private let avatars = PersonAvatarStore()
    /// The person whose map page is on screen, so an address arriving late
    /// only redraws that page — and only while it's still the one showing.
    private weak var mapTemplate: CPPointOfInterestTemplate?
    private var mappedPerson: PersonLocation?
    /// What the screen is currently showing, so a state change only rebuilds
    /// the template when something the driver can see actually changed.
    private var renderedPeople: [PersonLocation]?
    private var renderedStatus: String?
    /// The car screen's pixel density, for rendering avatars at native scale.
    private var imageScale: CGFloat = 1

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        imageScale = interfaceController.carTraitCollection.displayScale
        let client = HAWebSocketClient.shared
        Log.carPlay.note("connected, car trait scale \(imageScale)")

        // A picture arriving after the fact only changes the artwork, so
        // redraw from whatever the client holds now.
        avatars.onAvatarLoaded = { [weak self] in
            guard let self else { return }
            renderedPeople = nil
            render(entities: client.entities, connectionState: client.connectionState, animated: false)
        }

        render(entities: client.entities, connectionState: client.connectionState, animated: false)

        client.objectWillChange
            // objectWillChange fires before the property is updated, so read
            // the client back on the next runloop turn.
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.render(
                    entities: client.entities,
                    connectionState: client.connectionState,
                    animated: true
                )
            }
            .store(in: &cancellables)

        Task { await HAConnectionBootstrapper.connectUsingSavedCredentials(client: client) }
    }

    /// Selector pinned explicitly: Swift's importer shortens this to
    /// `didDisconnect:`, which collides with the optional `didSelect:`
    /// requirement and silently matches neither — leaving the subscription
    /// alive across a CarPlay disconnect.
    @objc(templateApplicationScene:didDisconnectInterfaceController:)
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        cancellables.removeAll()
        self.interfaceController = nil
        listTemplate = nil
        mapTemplate = nil
        mappedPerson = nil
        renderedPeople = nil
        renderedStatus = nil
    }

    // MARK: - Rendering

    private func render(entities: [HAEntityState], connectionState: HAConnectionState, animated: Bool) {
        guard let interfaceController else { return }
        let client = HAWebSocketClient.shared
        let people = PersonLocationDirectory.mappablePeople(
            from: entities,
            baseURLString: client.baseURLString,
            excludingUserId: client.currentUserId
        )

        guard !people.isEmpty else {
            // Nothing to show yet — say why rather than show an empty list.
            let status = Self.statusMessage(
                for: connectionState,
                hasPeopleEntities: entities.contains { $0.entityId.hasPrefix("person.") }
            )
            guard status != renderedStatus else { return }
            renderedStatus = status
            renderedPeople = nil
            listTemplate = nil
            interfaceController.setRootTemplate(Self.statusTemplate(message: status), animated: animated, completion: nil)
            return
        }

        renderedStatus = nil
        guard people != renderedPeople else { return }
        renderedPeople = people

        for person in people {
            guard let pictureURL = person.pictureURL else { continue }
            avatars.loadIfNeeded(url: pictureURL, accessToken: client.accessToken)
        }
        // Someone moving while their map page is open should move on it.
        if let mappedPerson, let updated = people.first(where: { $0.entityId == mappedPerson.entityId }) {
            self.mappedPerson = updated
            refreshMap(for: updated)
        }

        let section = CPListSection(items: sectionItems(for: people))

        if let listTemplate {
            listTemplate.updateSections([section])
        } else {
            let template = CPListTemplate(title: "People", sections: [section])
            listTemplate = template
            interfaceController.setRootTemplate(template, animated: animated, completion: nil)
        }
    }

    /// CarPlay's condensed image row: a wrapping grid of circular avatars
    /// with a name and zone under each, several across rather than one
    /// person per full-width row. Six people fit without scrolling.
    /// One full-width row per person.
    ///
    /// CarPlay's condensed image rows would tile these two-across, but a
    /// household is only ever a handful of people — vertical space is the
    /// surplus here and width is what's scarce. Two columns halve the text
    /// width and truncate exactly the two things the screen is for
    /// ("Avery Sterl…", "Victoria - Pa…"), to save room we don't need.
    private func sectionItems(for people: [PersonLocation]) -> [any CPListTemplateItem] {
        people.map(listItem)
    }

    /// One person's row: profile picture, name, and the zone they're in.
    private func listItem(for person: PersonLocation) -> CPListItem {
        let item = CPListItem(
            text: person.name,
            detailText: person.locationLabel,
            image: PersonPinRenderer.pin(
                avatar: person.pictureURL.flatMap(avatars.avatar),
                name: person.name,
                size: CPListItem.maximumImageSize,
                scale: imageScale
            )
        )
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.showMap(for: person)
            completion()
        }
        return item
    }

    /// A map of one person, pushed on selection. A single point of interest
    /// means CarPlay frames the map on them rather than on the household's
    /// bounding box.
    private func showMap(for person: PersonLocation) {
        guard let interfaceController, let pointOfInterest = pointOfInterest(for: person) else { return }
        mappedPerson = person

        // NSNotFound leaves the point of interest unselected, so CarPlay
        // draws the pane as a single collapsed row instead of an expanded
        // detail card — less panel, more map.
        let template = CPPointOfInterestTemplate(
            title: person.name,
            pointsOfInterest: [pointOfInterest],
            selectedIndex: NSNotFound
        )
        template.pointOfInterestDelegate = self
        mapTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// Moves the pin and re-labels the pane without rebuilding the page.
    private func refreshMap(for person: PersonLocation) {
        guard let mapTemplate, let pointOfInterest = pointOfInterest(for: person) else { return }
        mapTemplate.setPointsOfInterest([pointOfInterest], selectedIndex: NSNotFound)
    }

    private func pointOfInterest(for person: PersonLocation) -> CPPointOfInterest? {
        guard let coordinate = person.coordinate else { return nil }
        let mapItem = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        mapItem.name = person.name

        // Nil until the picture has been fetched — the pin falls back to the
        // person's initials in the meantime and swaps in once it arrives.
        let avatar = person.pictureURL.flatMap(avatars.avatar)
        // The collapsed row stacks its three slots tightly, so it can narrow
        // from zone to street to town across them.
        //
        // The expanded card lays out differently: title and subtitle sit
        // together at the top while summary is pushed to the bottom of the
        // panel, just above the buttons. Splitting an address across that gap
        // reads as two unrelated facts, so the card gets the address whole
        // and leaves the bottom slot empty.
        //
        // The bottom slot says how long they've been there — the one thing
        // a map of a moving person can't show. Empty string, not nil, when
        // HA didn't say: a nil detail variant falls back to its plain
        // counterpart, which would strand the town down there again.
        let poi = CPPointOfInterest(
            location: mapItem,
            title: person.locationLabel,
            subtitle: person.street,
            summary: person.locality,
            detailTitle: person.locationLabel,
            detailSubtitle: person.streetAndLocality,
            detailSummary: person.arrivalDescription ?? "",
            pinImage: PersonPinRenderer.pin(
                avatar: avatar,
                name: person.name,
                size: CPPointOfInterest.pinImageSize,
                scale: imageScale
            ),
            selectedPinImage: PersonPinRenderer.pin(
                avatar: avatar,
                name: person.name,
                size: CPPointOfInterest.selectedPinImageSize,
                scale: imageScale
            )
        )
        poi.primaryButton = CPTextButton(title: "Directions", textStyle: .confirm) { [weak self] _ in
            self?.openInMaps(mapItem)
        }
        return poi
    }

    /// Hands the destination to Maps.
    ///
    /// Deliberately the synchronous overload rather than
    /// `openInMaps(launchOptions:from:completionHandler:)`. That one takes a
    /// scene, and handing it this scene segfaults inside MapKit —
    /// `-[MKSystemController openURL:fromScene:completionHandler:]_block_invoke`
    /// null-derefs on the LaunchServices reply. `CPTemplateApplicationScene`
    /// is a `UIScene` but not a `UIWindowScene`, which looks to be the
    /// assumption it breaks. Checking whether Maps is installed doesn't help:
    /// it is, and the crash happens anyway.
    ///
    /// This overload reports failure by returning false instead, so a refusal
    /// is something we can tell the driver about rather than a dead button.
    private func openInMaps(_ mapItem: MKMapItem) {
        let opened = mapItem.openInMaps(
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
        if !opened {
            presentDirectionsUnavailable()
        }
    }

    private func presentDirectionsUnavailable() {
        guard let interfaceController else { return }
        let alert = CPAlertTemplate(
            titleVariants: [
                "Maps isn't available on this screen.",
                "Maps isn't available.",
                "No Maps"
            ],
            actions: [
                CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                }
            ]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    static func statusMessage(for connectionState: HAConnectionState, hasPeopleEntities: Bool) -> String {
        switch connectionState {
        case .connected where hasPeopleEntities:
            return "No one has a location to show yet."
        case .connected:
            return "No people are configured in Home Assistant."
        case .connecting, .authenticating:
            return "Connecting to Home Assistant…"
        case .disconnected:
            return "Open \(AppIdentity.name) on your iPhone to connect."
        case .failed(let message):
            return message
        }
    }

    private static func statusTemplate(message: String) -> CPInformationTemplate {
        CPInformationTemplate(
            title: "People",
            layout: .leading,
            items: [CPInformationItem(title: nil, detail: message)],
            actions: []
        )
    }
}

extension CarPlaySceneDelegate: CPPointOfInterestTemplateDelegate {
    /// The pushed map shows one specific person, not a search of the visible
    /// area, so panning doesn't change what's on it.
    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate, didChangeMapRegion region: MKCoordinateRegion) {}
}
