import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct ZonesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZonesActivityAttributes.self) { context in
            ZonesLockScreenView(context: context)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(musicURL)
        } dynamicIsland: { context in
            DynamicIsland {
                // Below the camera, so the icon and the zone share one row
                // instead of the icon sitting beside the camera and the title
                // under it.
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    HStack(spacing: 10) {
                        AppMark(name: context.state.appMark, size: 28)
                        ActiveZoneLabel(state: context.state)
                    }
                    .padding(.leading, 8)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayPauseButton(context: context, size: 36)
                        .padding(.trailing, 8)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ZoneButtons(context: context, style: .tiles)
                        VolumeBar(context: context, trackHeight: 6)
                        if let message = context.state.message {
                            MessageText(message)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                AppMark(name: context.state.appMark, size: 22)
                    .padding(.leading, 2)
            } compactTrailing: {
                Text(context.state.activeZone?.name ?? "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            } minimal: {
                AppMark(name: context.state.appMark, size: 22)
            }
            .widgetURL(musicURL)
        }
    }

    private var musicURL: URL? { URL(string: "hassonic://music") }
}

/// iOS gives the Lock Screen presentation about 160pt and clips anything
/// taller, so the zone name shares the header row and the buttons are compact.
private struct ZonesLockScreenView: View {
    let context: ActivityViewContext<ZonesActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppMark(name: context.state.appMark, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.state.activeZone?.name ?? "No speaker")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    subtitle
                }
                Spacer(minLength: 0)
                PlayPauseButton(context: context, size: 34)
            }
            ZoneButtons(context: context, style: .circles)
            VolumeBar(context: context, trackHeight: 8)
        }
        .foregroundStyle(.white)
    }

    /// A problem takes the status line rather than adding a row, which
    /// would push the activity past its height.
    @ViewBuilder private var subtitle: some View {
        if let problem = context.state.message
            ?? (context.isStale ? "May be out of date. Open the app to refresh." : nil) {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            Text("\(appName) · \(playbackText)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hassonic"
    }

    private var playbackText: String {
        guard context.state.activeZone != nil else { return "Not on a known zone" }
        return context.state.isPlaying ? "Playing" : "Paused"
    }
}

/// Plays or pauses the account, wherever it's playing. Hidden when it isn't
/// on a speaker the app knows, where there's nothing sensible to resume.
private struct PlayPauseButton: View {
    let context: ActivityViewContext<ZonesActivityAttributes>
    let size: CGFloat

    var body: some View {
        if context.state.activeZone != nil {
            Button(intent: TogglePlaybackIntent(activityId: context.activityID)) {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.18), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(context.state.isPlaying ? "Pause" : "Play")
        }
    }
}

/// The app's icon as the user picked it, so the activity reads as this app at
/// a glance. Falls back to the default mark if this build lacks the asset.
private struct AppMark: View {
    let name: String?
    let size: CGFloat

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }

    private var assetName: String {
        guard let name, UIImage(named: name) != nil else { return ZonesActivityAttributes.defaultAppMark }
        return name
    }
}

private struct ActiveZoneLabel: View {
    let state: ZonesActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(state.activeZone?.name ?? "No speaker")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caption: String {
        guard state.activeZone != nil else { return "Not playing on a known zone" }
        return state.isPlaying ? "Playing on" : "Paused on"
    }
}

/// Looks like a volume slider: one track filled to the current level. A Live
/// Activity can't host a real slider, so the track is covered by invisible
/// buttons, one per tenth — tapping anywhere along it sets roughly that level.
/// Hidden when nothing in the zone is adjustable.
private struct VolumeBar: View {
    let context: ActivityViewContext<ZonesActivityAttributes>
    let trackHeight: CGFloat

    private var levels: Int { ZonesActivityAttributes.volumeLevels }

    var body: some View {
        if let volume = context.state.volume, context.state.activeZone != nil {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.22))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(trackHeight, geometry.size.width * min(max(volume, 0), 1)))
                    }
                    .frame(height: trackHeight)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach(1...levels, id: \.self) { step in
                                Button(intent: SetZoneVolumeIntent(
                                    activityId: context.activityID,
                                    level: Double(step) / Double(levels)
                                )) {
                                    Color.clear
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Volume \(step * 100 / levels)%")
                            }
                        }
                    }
                }
                .frame(height: trackHeight + 14)
                // The level reads as part of the control, not a stray number.
                Text(volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
    }
}

private struct ZoneButtons: View {
    enum Style {
        /// Round buttons with names under them, like Control Center. Lock screen.
        case circles
        /// Icon-only tiles; the expanded island is too short for names, so
        /// they're left to VoiceOver.
        case tiles
    }

    let context: ActivityViewContext<ZonesActivityAttributes>
    let style: Style

    var body: some View {
        HStack(spacing: style == .circles ? 4 : 6) {
            ForEach(context.attributes.quickZones) { zone in
                Button(intent: SelectZoneIntent(activityId: context.activityID, zoneId: zone.id)) {
                    switch style {
                    case .circles: circle(for: zone)
                    case .tiles: tile(for: zone)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Play on \(zone.name)")
                .accessibilityAddTraits(isActive(zone) ? .isSelected : [])
            }
        }
    }

    private func circle(for zone: ZonesActivityAttributes.Zone) -> some View {
        VStack(spacing: 3) {
            icon(for: zone)
                .font(.body)
                .foregroundStyle(isActive(zone) ? Color.black : .white)
                .frame(width: 38, height: 38)
                .background(isActive(zone) ? Color.white : background(for: zone), in: Circle())
            Text(zone.name)
                .font(.caption2.weight(isActive(zone) ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isActive(zone) ? 1 : 0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(for zone: ZonesActivityAttributes.Zone) -> some View {
        icon(for: zone)
            .font(.callout)
            .frame(height: 18)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isActive(zone) ? Color.blue.opacity(0.85) : background(for: zone),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }

    private func icon(for zone: ZonesActivityAttributes.Zone) -> Image {
        Image(systemName: context.state.pendingZoneId == zone.id ? "ellipsis" : zone.icon)
    }

    private func isActive(_ zone: ZonesActivityAttributes.Zone) -> Bool {
        context.state.activeZone?.id == zone.id && context.state.pendingZoneId == nil
    }

    private func background(for zone: ZonesActivityAttributes.Zone) -> Color {
        context.state.pendingZoneId == zone.id ? .white.opacity(0.3) : .white.opacity(0.16)
    }
}

private struct MessageText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(2)
    }
}

#Preview("Lock screen", as: .content, using: ZonesActivityAttributes.preview) {
    ZonesLiveActivity()
} contentStates: {
    ZonesActivityAttributes.ContentState.playingKitchen
    ZonesActivityAttributes.ContentState.switching
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: ZonesActivityAttributes.preview) {
    ZonesLiveActivity()
} contentStates: {
    ZonesActivityAttributes.ContentState.playingKitchen
}

private extension ZonesActivityAttributes {
    static let kitchen = Zone(id: "media_player.kitchen", name: "Kitchen", icon: "hifispeaker.fill", sourceName: "Kitchen", volumeEntityIds: ["media_player.kitchen"])

    static let preview = ZonesActivityAttributes(
        accountEntityId: "media_player.spotify",
        accountName: "Jamie",
        quickZones: [
            Zone(id: "media_player.everywhere", name: "Everywhere", icon: "house.fill", sourceName: "Everywhere", volumeEntityIds: []),
            Zone(id: "media_player.downstairs", name: "Downstairs", icon: "stairs", sourceName: "Downstairs", volumeEntityIds: []),
            kitchen,
            Zone(id: "media_player.living_room", name: "Living Room", icon: "sofa.fill", sourceName: "Living Room", volumeEntityIds: []),
        ]
    )
}

private extension ZonesActivityAttributes.ContentState {
    static let playingKitchen = Self(activeZone: ZonesActivityAttributes.kitchen, volume: 0.45, isPlaying: true, pendingZoneId: nil, message: nil)
    static let switching = Self(activeZone: ZonesActivityAttributes.kitchen, volume: 0.45, isPlaying: true, pendingZoneId: "media_player.downstairs", message: nil)
}
