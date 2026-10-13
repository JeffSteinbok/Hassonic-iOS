import ActivityKit
import AppIntents
import Foundation

// LiveActivityIntents always run in the app's process, launching it in the
// background if needed. The widget extension only needs the types so its
// buttons can name them, which is why perform() is a stub there.

struct SelectZoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play on Zone"
    static let isDiscoverable = false

    @Parameter(title: "Activity") var activityId: String
    @Parameter(title: "Zone") var zoneId: String

    init() {}

    init(activityId: String, zoneId: String) {
        self.activityId = activityId
        self.zoneId = zoneId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
#if !WIDGET_EXTENSION
        await ZonesLiveActivityController.shared.selectZone(zoneId, activityId: activityId)
#endif
        return .result()
    }
}

struct SetZoneVolumeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Zone Volume"
    static let isDiscoverable = false

    @Parameter(title: "Activity") var activityId: String
    /// 0–1, one of the volume bar's segments.
    @Parameter(title: "Level") var level: Double

    init() {}

    init(activityId: String, level: Double) {
        self.activityId = activityId
        self.level = level
    }

    @MainActor
    func perform() async throws -> some IntentResult {
#if !WIDGET_EXTENSION
        await ZonesLiveActivityController.shared.setVolume(to: level, activityId: activityId)
#endif
        return .result()
    }
}
