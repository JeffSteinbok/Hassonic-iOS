import SwiftUI
import UIKit

enum AppIdentity {
    /// The home-screen name, so a rename only has to happen in Info.plist.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Hassonic"
    }

    static let sourceURL = URL(string: "https://github.com/JeffSteinbok/Hassonic-iOS")!
}

/// Shown while a saved connection comes up: the mark, name and spinner
/// centered as one group on the chosen icon's background, with the sign-off
/// at the bottom.
struct SplashView: View {
    /// Nil for the icon on the home screen now.
    var icon: AppIconOption? = nil

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 24) {
                CurrentAppMark(size: 160, icon: icon)
                VStack(spacing: 14) {
                    Text(AppIdentity.name)
                        .font(.system(size: 28, weight: .black))
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting to Home Assistant…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .safeAreaInset(edge: .bottom) {
            MadeWithLoveFooter()
                .padding(.bottom, 12)
        }
        .appIconBackdrop(icon)
    }
}

struct MadeWithLoveFooter: View {
    var body: some View {
        Text("Made with ♥ by Jeff Steinbok")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct ConnectionFailedView: View {
    let message: String
    let onRetry: () -> Void
    let onSettings: () -> Void
    /// Nil for the icon on the home screen now.
    var icon: AppIconOption? = nil

    var body: some View {
        let theme = (icon ?? AppIconCatalog.current).theme
        ZStack {
            Color.clear
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                CurrentAppMark(size: 72, icon: icon)
                Text("Connection failed")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    // Red and the system blue vanish on some icons' colors,
                    // so a themed screen uses its own ink.
                    .foregroundStyle(theme.map { AnyShapeStyle($0.ink.opacity(0.75)) } ?? AnyShapeStyle(.red))
                Text("Can't reach your home")
                    .font(.system(size: 34, weight: .black))
                Text("\(AppIdentity.name) couldn't connect to Home Assistant. Check that you're online and that the server is running, or review your connection in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.map { AnyShapeStyle($0.ink.opacity(0.1)) } ?? AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .textSelection(.enabled)
                Spacer()
                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.headline)
                            .foregroundStyle(theme.map { AnyShapeStyle(Color(hex: $0.top)) } ?? AnyShapeStyle(.white))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onSettings) {
                        Text("Settings")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .tint(theme?.ink)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .appIconBackdrop(icon)
    }
}

/// Replaces the old gear button: Settings and About. Reloading the
/// configuration is pull-to-refresh on the pages themselves.
struct AppMenuButton: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Menu {
            Button {
                router.presentedSheet = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button {
                router.presentedSheet = .about
            } label: {
                Label("About \(AppIdentity.name)", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .accessibilityLabel("Menu")
    }
}

/// Pull down to reload the app configuration from Home Assistant.
private struct ReloadsConfigurationOnPull: ViewModifier {
    @EnvironmentObject private var haClient: HAWebSocketClient
    @EnvironmentObject private var configurationLoader: AppConfigurationLoader

    func body(content: Content) -> some View {
        content.refreshable {
            await configurationLoader.refresh(
                baseURLString: haClient.baseURLString,
                accessToken: haClient.accessToken
            )
        }
    }
}

extension View {
    func reloadsConfigurationOnPull() -> some View {
        modifier(ReloadsConfigurationOnPull())
    }
}

/// Modeled on RuleBook's About: a big title and tagline, a few facts, a
/// privacy note, and a sign-off.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var haClient: HAWebSocketClient
    @State private var copiedVersion = false
    private let build = BuildInformation.current

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AboutHeader()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                Section {
                    LabeledContent("Version", value: copiedVersion ? "Copied" : build.versionAndBuild)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            UIPasteboard.general.string = "\(build.versionAndBuild) \(build.revision)"
                            copiedVersion = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copiedVersion = false
                            }
                        }
                        .accessibilityHint("Long-press to copy")
                    LabeledContent("Build", value: "\(build.revision) · \(buildDate)")
                    LabeledContent("Home Assistant") {
                        Text(serverText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Link(destination: AppIdentity.sourceURL) {
                        LabeledContent("Source", value: "GitHub")
                    }
                }

                Section {
                    Text("\(AppIdentity.name) talks only to your Home Assistant. Your sign-in stays on this device, and nothing about your home is sent anywhere else.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) {
                MadeWithLoveFooter()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.bar)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var buildDate: String {
        guard let date = try? Date(build.timestamp, strategy: .iso8601) else { return build.timestamp }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var serverText: String {
        let host = URL(string: haClient.baseURLString)?.host() ?? "Not set"
        return haClient.connectionState == .connected ? "\(host) · Connected" : host
    }
}

/// About's header: the chosen icon's colors and bare mark, like the splash,
/// so About carries the same branding.
struct AboutHeader: View {
    /// Nil for the icon on the home screen now.
    var icon: AppIconOption? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CurrentAppMark(size: 88, icon: icon)
            Text(AppIdentity.name)
                .font(.system(size: 40, weight: .black))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            // Stronger than .secondary, which fades out on the lighter
            // half of a gradient.
            Text("A focused, native way to control your Home Assistant home.")
                .font(.body)
                .opacity(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .appIconBackdrop(icon, fillsScreen: false)
    }
}

#Preview("Splash") { SplashView() }

#Preview("Failed") {
    ConnectionFailedView(message: "The request timed out.", onRetry: {}, onSettings: {})
}
