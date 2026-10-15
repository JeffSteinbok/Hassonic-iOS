import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A page pinned to the Lock Screen. Its keys press without opening the app;
/// a tap anywhere else opens the page.
struct PinnedPageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PinnedPageActivityAttributes.self) { context in
            PinnedPageLockScreenView(context: context)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 10) {
                        AppMark(name: context.state.appMark, size: 28)
                        Text(context.attributes.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.attributes.systemIcon)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(.trailing, 8)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    KeyRow(context: context, size: 40)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                AppMark(name: context.state.appMark, size: 22)
                    .padding(.leading, 2)
            } compactTrailing: {
                Image(systemName: context.attributes.systemIcon)
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.attributes.systemIcon)
                    .foregroundStyle(.white)
            }
            .widgetURL(context.attributes.url)
        }
    }
}

private struct PinnedPageLockScreenView: View {
    let context: ActivityViewContext<PinnedPageActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                AppMark(name: context.state.appMark, size: 26)
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: context.attributes.systemIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open \(context.attributes.title)")
            KeyRow(context: context, size: 44)
        }
        .foregroundStyle(.white)
    }
}

/// The page's keys as round buttons, evenly across, captioned when the
/// config chose them.
private struct KeyRow: View {
    let context: ActivityViewContext<PinnedPageActivityAttributes>
    let size: CGFloat

    var body: some View {
        if !context.attributes.keys.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                ForEach(context.attributes.keys) { key in
                    Group {
                        if key.opensPage, let url = context.attributes.url {
                            Link(destination: url) { face(key) }
                        } else {
                            Button(intent: PressPinnedPageKeyIntent(activityId: context.activityID, keyId: key.id)) {
                                face(key)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key.label)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func face(_ key: PinnedPageActivityAttributes.Key) -> some View {
        VStack(spacing: 3) {
            Image(systemName: key.systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(key.systemImage == "power" ? Color.red : .white)
                .frame(width: size, height: size)
                .background(.white.opacity(0.18), in: Circle())
            if let caption = key.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

#Preview("Lock screen", as: .content, using: PinnedPageActivityAttributes.preview) {
    PinnedPageLiveActivity()
} contentStates: {
    PinnedPageActivityAttributes.ContentState()
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: PinnedPageActivityAttributes.preview) {
    PinnedPageLiveActivity()
} contentStates: {
    PinnedPageActivityAttributes.ContentState()
}

private extension PinnedPageActivityAttributes {
    static let preview = PinnedPageActivityAttributes(
        pageID: "remote",
        title: "Remote",
        systemIcon: "appletvremote.gen4.fill",
        keys: [
            Key(id: "open", label: "Open Remote", systemImage: "appletvremote.gen4.fill", actions: [], caption: "Open"),
            Key(id: "tv.playPause", label: "Samsung TV Play/Pause", systemImage: "playpause.fill",
                actions: [Action(kind: .mediaPlayPause, entityId: "media_player.tv")], caption: "Samsung TV"),
            Key(id: "box.playPause", label: "Xfinity Play/Pause", systemImage: "playpause.fill",
                actions: [Action(kind: .send, entityId: "remote.xfinity", command: "play_pause")], caption: "Xfinity"),
        ]
    )
}
