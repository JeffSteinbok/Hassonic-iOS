import ActivityKit
import Foundation
import UIKit

/// Pins a page to the Lock Screen as a Live Activity and unpins it, and
/// carries out its key presses (which iOS delivers to this process, even
/// launching it in the background to do so). One page at a time: pinning
/// another replaces it. Swiping it away unpins it too.
@MainActor
final class PinnedPageActivityController: ObservableObject {
    static let shared = PinnedPageActivityController()

    private typealias PinnedActivity = Activity<PinnedPageActivityAttributes>

    @Published private(set) var pinnedPageID: String?

    private var observedIds: Set<String> = []
    private let client: HAWebSocketClient = .shared

    private init() {
        // One from before a relaunch is still pinned.
        if let current = Self.liveActivities.first {
            pinnedPageID = current.attributes.pageID
            observe(current)
        }
    }

    private static var liveActivities: [PinnedActivity] {
        PinnedActivity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isPinned(_ pageID: String) -> Bool { pinnedPageID == pageID }

    func toggle(_ page: DashboardPageConfiguration) {
        if isPinned(page.id) {
            unpin()
        } else {
            pin(page)
        }
    }

    func pin(_ page: DashboardPageConfiguration) {
        unpin()
        let pageID = page.id
        let attributes = PinnedPageActivityAttributes(
            pageID: pageID,
            title: page.title,
            systemIcon: page.systemIcon,
            keys: PinnedPageKeys.keys(for: page)
        )
        let state = PinnedPageActivityAttributes.ContentState(
            appMark: ZonesActivityAttributes.appMark(forAlternateIcon: UIApplication.shared.alternateIconName)
        )
        do {
            let activity = try PinnedActivity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            pinnedPageID = pageID
            observe(activity)
        } catch {
            Log.liveActivity.note("pin failed — \(error.localizedDescription)")
        }
    }

    func unpin() {
        pinnedPageID = nil
        for activity in PinnedActivity.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func press(_ keyId: String, activityId: String) async {
        guard let activity = PinnedActivity.activities.first(where: { $0.id == activityId }),
              let key = activity.attributes.keys.first(where: { $0.id == keyId }),
              let first = key.actions.first else { return }
        guard await HAConnectionBootstrapper.connectAndWait(client: client, for: first.entityId) else {
            Log.liveActivity.note("\(key.label) — couldn't reach Home Assistant")
            return
        }
        DashboardCardActionRouter.perform(key.actions.compactMap(PinnedPageKeys.remoteAction), client: client)
    }

    /// Clears the pin when it's swiped away, or when iOS ends it after its
    /// eight hours.
    private func observe(_ activity: PinnedActivity) {
        guard observedIds.insert(activity.id).inserted else { return }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                guard let self else { return }
                self.observedIds.remove(activity.id)
                if self.pinnedPageID == activity.attributes.pageID,
                   !Self.liveActivities.contains(where: { $0.id != activity.id }) {
                    self.pinnedPageID = nil
                }
                return
            }
        }
    }
}
