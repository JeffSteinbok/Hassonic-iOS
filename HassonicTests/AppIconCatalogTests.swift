import XCTest
@testable import Hassonic

final class AppIconCatalogTests: XCTestCase {
    func testOnlyThePrimaryWhenNoAlternatesShip() {
        XCTAssertEqual(AppIconCatalog.options(infoDictionary: [:]), [.primary])
    }

    func testAlternatesFromTheBuiltInfoPlistFollowThePrimary() {
        let info: [String: Any] = [
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"],
                "CFBundleAlternateIcons": [
                    "AppIcon-Waveform-House": ["CFBundleIconName": "AppIcon-Waveform-House"],
                    "AppIcon-Echo-Roof": ["CFBundleIconName": "AppIcon-Echo-Roof"],
                    "SomethingElse": [:],
                ],
            ],
        ]

        let options = AppIconCatalog.options(infoDictionary: info)

        XCTAssertEqual(options.map(\.displayName), ["Default", "Echo Roof", "Waveform House"])
        XCTAssertEqual(options.map(\.alternateName), [nil, "AppIcon-Echo-Roof", "AppIcon-Waveform-House"])
        XCTAssertEqual(options[1].previewAsset, "AppIconPreview-Echo-Roof")
    }

    func testAThemedIconGetsItsMarkAndTheme() {
        let info: [String: Any] = [
            "CFBundleIcons": [
                "CFBundleAlternateIcons": [
                    "AppIcon-Clay-Sky": [:],
                    "AppIcon-Plain": [:],
                ],
            ],
        ]
        let sky = AppIconTheme(top: "#E4F4FE", bottom: "#A9DCF7", text: .dark)

        let options = AppIconCatalog.options(infoDictionary: info, themes: ["Clay-Sky": sky])

        XCTAssertEqual(options[1].markAsset, "AppIconMark-Clay-Sky")
        XCTAssertEqual(options[1].theme, sky)
        // No theme: no bare mark either, so it falls back to the tile.
        XCTAssertNil(options[2].markAsset)
        XCTAssertNil(options[2].theme)
        XCTAssertNil(AppIconOption.primary.theme)
    }

    /// Every shipped alternate has a mark, a theme, and valid colors.
    func testEveryShippedIconIsThemed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appendingPathComponent("Hassonic/Assets.xcassets")
        let data = try Data(contentsOf: root.appendingPathComponent("Hassonic/AppIconThemes.json"))
        let themes = try JSONDecoder().decode([String: AppIconTheme].self, from: data)
        let slugs = try FileManager.default.contentsOfDirectory(atPath: assets.path)
            .filter { $0.hasPrefix("AppIcon-") && $0.hasSuffix(".appiconset") }
            .map { String($0.dropFirst("AppIcon-".count).dropLast(".appiconset".count)) }
        XCTAssertFalse(slugs.isEmpty)
        for slug in slugs {
            let theme = try XCTUnwrap(themes[slug], "\(slug) has no theme")
            for hex in [theme.top, theme.bottom] {
                XCTAssertNotNil(hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression), "\(slug): \(hex)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("AppIconMark-\(slug).imageset/mark.png").path), slug)
        }
    }
}
