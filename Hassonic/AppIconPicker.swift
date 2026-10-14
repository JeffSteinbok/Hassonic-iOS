import SwiftUI
import UIKit

/// One choosable home-screen icon. `alternateName` is nil for the primary
/// icon, which is what `setAlternateIconName` takes to go back to it.
struct AppIconOption: Identifiable, Equatable {
    let alternateName: String?
    let displayName: String
    /// Image asset drawn in the picker; an app icon set can't be loaded as an
    /// image, so each alternate ships a matching `AppIconPreview-*` set.
    let previewAsset: String
    /// The art without its background (`AppIconMark-*`), for drawing on the
    /// theme. Nil for the primary, whose mark is `WelcomeMark`.
    var markAsset: String? = nil
    /// The icon's background and text colors, so a screen can look like the
    /// icon grown to fill it. Nil means the plain launch background.
    var theme: AppIconTheme? = nil

    var id: String { alternateName ?? "default" }

    static let primary = AppIconOption(alternateName: nil, displayName: "Default", previewAsset: "AppMark")
}

/// An icon's colors, from `AppIconThemes.json` (written by
/// scripts/add_app_icon.py).
struct AppIconTheme: Decodable, Equatable {
    enum Text: String, Decodable {
        /// Light text and controls, for a dark background.
        case light
        case dark
    }

    /// Background gradient, top to bottom; the same twice for a flat color.
    let top: String
    let bottom: String
    let text: Text

    /// Text and control color: white on a dark theme, near-black on a light one.
    var ink: Color {
        text == .light ? .white : Palette.ink
    }

    static func load(from bundle: Bundle = .main) -> [String: AppIconTheme] {
        guard let url = bundle.url(forResource: "AppIconThemes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: AppIconTheme].self, from: data)) ?? [:]
    }
}

enum AppIconCatalog {
    static let alternatePrefix = "AppIcon-"
    static let previewPrefix = "AppIconPreview-"
    static let markPrefix = "AppIconMark-"

    /// The primary icon first, then every alternate Xcode listed in the built
    /// Info.plist, alphabetically. Nothing to maintain by hand: adding an
    /// `AppIcon-*` set (scripts/add_app_icon.py) is enough.
    static func options(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        themes: [String: AppIconTheme] = AppIconTheme.load()
    ) -> [AppIconOption] {
        let icons = (infoDictionary["CFBundleIcons"] as? [String: Any])
            ?? (infoDictionary["CFBundleIcons~iphone"] as? [String: Any])
        let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any]) ?? [:]
        let options = alternates.keys
            .filter { $0.hasPrefix(alternatePrefix) }
            .sorted()
            .map { name in
                let slug = String(name.dropFirst(alternatePrefix.count))
                let theme = themes[slug]
                return AppIconOption(
                    alternateName: name,
                    displayName: slug.replacingOccurrences(of: "-", with: " "),
                    previewAsset: previewPrefix + slug,
                    // A mark without a theme would float on the plain
                    // background, so the two come together.
                    markAsset: theme == nil ? nil : markPrefix + slug,
                    theme: theme
                )
            }
        return [.primary] + options
    }
}

extension AppIconCatalog {
    /// The icon on the home screen right now, so in-app branding can match it.
    @MainActor
    static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return options().first { $0.alternateName == name } ?? .primary
    }
}

/// The app's mark as the user chose it, drawn straight on the screen: the
/// original house for the default icon, or a themed icon's art without its
/// background. An icon with no theme falls back to its art as a tile.
struct CurrentAppMark: View {
    let size: CGFloat
    /// Nil for the icon on the home screen now.
    var icon: AppIconOption? = nil

    var body: some View {
        let option = icon ?? AppIconCatalog.current
        Group {
            if option.alternateName == nil {
                Image("WelcomeMark")
                    .resizable()
                    .scaledToFit()
            } else if let mark = option.markAsset {
                Image(mark)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(option.previewAsset)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: size * 0.03, y: size * 0.015)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The chosen icon's background behind a view, with text and controls set
/// light or dark to suit it. The default icon keeps the launch background and
/// the system's appearance. `fillsScreen` runs the background under the safe
/// areas, for a full-screen view (the splash, the connection-failed screen).
private struct AppIconBackdrop: ViewModifier {
    let icon: AppIconOption?
    let fillsScreen: Bool

    func body(content: Content) -> some View {
        let theme = (icon ?? AppIconCatalog.current).theme
        content
            .background {
                Group {
                    if let theme {
                        LinearGradient(colors: [Color(hex: theme.top), Color(hex: theme.bottom)], startPoint: .top, endPoint: .bottom)
                    } else {
                        Color("LaunchBackground")
                    }
                }
                .ignoresSafeArea(edges: fillsScreen ? .all : [])
            }
            .modifier(ThemeColorScheme(text: theme?.text))
    }
}

private struct ThemeColorScheme: ViewModifier {
    let text: AppIconTheme.Text?

    func body(content: Content) -> some View {
        if let text {
            content.environment(\.colorScheme, text == .light ? .dark : .light)
        } else {
            content
        }
    }
}

extension View {
    /// `icon` nil for the icon on the home screen now.
    func appIconBackdrop(_ icon: AppIconOption? = nil, fillsScreen: Bool = true) -> some View {
        modifier(AppIconBackdrop(icon: icon, fillsScreen: fillsScreen))
    }
}


/// Settings → App Icon. iOS confirms each change with its own alert; there's
/// no way to switch silently.
struct AppIconPickerView: View {
    @State private var options = AppIconCatalog.options()
    @State private var selectedName = UIApplication.shared.alternateIconName
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(options) { option in
                    Button {
                        choose(option)
                    } label: {
                        tile(for: option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
                }
            }
            .padding(20)

            if options.count == 1 {
                Text("This build has no other icons yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Just the art: the name is for VoiceOver, not the grid.
    private func tile(for option: AppIconOption) -> some View {
        Image(option.previewAsset)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .padding(4)
            .overlay {
                if isSelected(option) {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 3)
                }
            }
    }

    private func isSelected(_ option: AppIconOption) -> Bool {
        option.alternateName == selectedName
    }

    private func choose(_ option: AppIconOption) {
        guard !isSelected(option) else { return }
        errorMessage = nil
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.alternateName)
                selectedName = option.alternateName
            } catch {
                errorMessage = "Couldn't change the icon: \(error.localizedDescription)"
            }
        }
    }
}
