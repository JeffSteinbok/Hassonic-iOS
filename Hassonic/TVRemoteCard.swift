import SwiftUI

// MARK: - TVRemoteCardView

/// A TV and the box plugged into it, each with its own panel, both always on
/// screen. Drawn as dark remotes in light and dark mode alike.
///
///     SAMSUNG TV                ⏻
///     VOL    ( round pad )      ⌂
///      🔇                        ↩  ⏯  123
///
///     XFINITY
///     PG   A ◇ B   CH
///          C ◇ D
///     ↩  Exit  Guide  i  Xfinity
///     ⏪  ⏯  ⏩  ⏺  123
struct TVRemoteCardView: View {
    let configuration: DashboardTVRemoteConfiguration
    /// The app the TV is in, if it certainly is one: shown on the TV panel,
    /// and the box panel is greyed out, since the box isn't on screen.
    var tvApp: String? = nil
    /// The TV is off: every key but its power is greyed out, the box's too,
    /// since nothing they send would show.
    var tvIsOff = false
    let isAvailable: Bool
    let perform: ([TVRemoteAction]) -> Void

    @State private var presses = 0
    @State private var keypad: TVRemoteSide?

    var body: some View {
        VStack(spacing: 12) {
            if let tv = configuration.tv {
                TVPanel(name: tv.displayName, app: tvApp, isOff: tvIsOff, press: { press($0, on: .tv) }, showKeypad: { keypad = .tv })
            }
            if let box = configuration.box {
                BoxPanel(name: box.displayName, menuLabel: box.kind.displayName, press: { press($0, on: .box) }, showKeypad: { keypad = .box })
                    .disabled(boxIsIdle)
                    // Dimmed darker rather than faded, which would wash a
                    // dark panel out to grey on a light background.
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.black.opacity(boxIsIdle ? 0.55 : 0))
                            .allowsHitTesting(false)
                    }
                    .animation(.easeInOut(duration: 0.2), value: boxIsIdle)
                    .accessibilityHint(tvIsOff ? "Unavailable while the TV is off" : tvApp.map { "Unavailable while the TV is in \($0)" } ?? "")
            }
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        .sheet(item: $keypad) { side in
            NumberPadSheet(title: configuration.device(side)?.displayName ?? "") { entry in
                presses += 1
                switch entry {
                case .digit(let digit): perform(configuration.digitActions(digit, on: side))
                case .key(let key): perform(configuration.actions(for: key, on: side))
                }
            }
            .presentationDetents([.medium])
        }
    }

    /// The box isn't on screen: the TV is off, or showing one of its own apps.
    private var boxIsIdle: Bool { tvIsOff || tvApp != nil }

    private func press(_ key: TVRemoteKey, on side: TVRemoteSide) {
        presses += 1
        perform(configuration.actions(for: key, on: side))
    }
}

extension TVRemoteSide: Identifiable {
    var id: String { rawValue }
}

// MARK: - Colors

/// Fixed, not semantic: the panels are drawn as dark remotes.
private enum RemoteColors {
    static let tvPanel = Color(hex: "#121214")
    static let tvKey = Color(hex: "#1E1F23")
    static let tvKeyPressed = Color(hex: "#2C2D32")
    static let tvCenter = Color(hex: "#2A2B2F")
    static let boxPanel = Color(hex: "#2A2C31")
    static let boxKey = Color(hex: "#3A3D43")
    static let boxKeyPressed = Color(hex: "#4A4E55")
    static let boxPad = Color(hex: "#4A4D54")
    static let label = Color(hex: "#E9EAEE")
    static let caption = Color(hex: "#A3A6AD")
    static let power = Color(hex: "#F0503F")
}

// MARK: - Samsung panel

private struct TVPanel: View {
    let name: String
    /// What the TV is showing, if it's an app.
    let app: String?
    /// Every key but power is greyed out.
    let isOff: Bool
    let press: (TVRemoteKey) -> Void
    let showKeypad: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Room for the caption, which spans the panel's top.
                Color.clear.frame(width: 52, height: 44)
                Spacer(minLength: 8)
                Rocker(caption: "VOL", upImage: "plus", downImage: "minus",
                       upLabel: TVRemoteKey.volumeUp.label, downLabel: TVRemoteKey.volumeDown.label,
                       width: 52, height: 148, radius: 26, fill: RemoteColors.tvKey,
                       onUp: { press(.volumeUp) }, onDown: { press(.volumeDown) })
                    .greyedOut(isOff)
                Spacer(minLength: 8)
                roundKey(.mute, systemImage: "speaker.slash.fill")
                    .greyedOut(isOff)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            RoundPad(onDirection: { press(TVRemoteKey($0)) })
                .greyedOut(isOff)
                .padding(.top, 52)
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                roundKey(.power, systemImage: "power", tint: RemoteColors.power)
                Group {
                    roundKey(.home, systemImage: "house")
                    roundKey(.back, systemImage: "arrow.uturn.backward")
                    roundKey(.playPause, systemImage: "playpause.fill")
                    Button(action: showKeypad) {
                        Text("123")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(KeyStyle(shape: Circle(), fill: RemoteColors.tvKey, pressed: RemoteColors.tvKeyPressed))
                    .accessibilityLabel("\(name) number keys")
                }
                .greyedOut(isOff)
            }
        }
        .overlay(alignment: .topLeading) {
            // Same place as the box panel's caption: the panel's top-left.
            VStack(alignment: .leading, spacing: 3) {
                PanelCaption(name)
                if let app {
                    Text(app)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RemoteColors.label)
                        .lineLimit(1)
                        .accessibilityLabel("Showing \(app)")
                }
            }
            .padding(.trailing, 60)
        }
        .foregroundStyle(RemoteColors.label)
        .padding(16)
        .background(RemoteColors.tvPanel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func roundKey(_ key: TVRemoteKey, systemImage: String, tint: Color? = nil) -> some View {
        Button {
            press(key)
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint ?? RemoteColors.label)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(KeyStyle(shape: Circle(), fill: RemoteColors.tvKey, pressed: RemoteColors.tvKeyPressed))
        .accessibilityLabel("\(name) \(key.label)")
    }
}

private extension View {
    /// A key that does nothing while the TV is off: faded and untappable.
    func greyedOut(_ greyed: Bool) -> some View {
        disabled(greyed)
            .opacity(greyed ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.2), value: greyed)
    }
}

/// The Samsung pad: a ring of arrows around a round select key.
private struct RoundPad: View {
    let onDirection: (RemoteDirection) -> Void
    private let size: CGFloat = 180

    var body: some View {
        ZStack {
            Circle()
                .fill(RemoteColors.tvKey)
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            VStack(spacing: 0) {
                arrow(.up)
                HStack(spacing: 0) {
                    arrow(.left)
                    Button {
                        onDirection(.ok)
                    } label: {
                        Circle()
                            .fill(RemoteColors.tvCenter)
                            .frame(width: 84, height: 84)
                            .overlay(Circle().strokeBorder(RemoteColors.tvPanel, lineWidth: 4))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel("Select")
                    arrow(.right)
                }
                arrow(.down)
            }
        }
        .frame(width: size, height: size)
    }

    private func arrow(_ direction: RemoteDirection) -> some View {
        Button {
            onDirection(direction)
        } label: {
            Image(systemName: direction.systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(RemoteColors.caption)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(direction.label)
    }
}

// MARK: - Xfinity panel

private struct BoxPanel: View {
    let name: String
    /// The main-menu key's wordmark.
    let menuLabel: String
    let press: (TVRemoteKey) -> Void
    let showKeypad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCaption(name)
            HStack(spacing: 0) {
                Rocker(caption: "PG", upImage: "chevron.up", downImage: "chevron.down",
                       upLabel: TVRemoteKey.pageUp.label, downLabel: TVRemoteKey.pageDown.label,
                       width: 66, height: 174, radius: 14, fill: RemoteColors.boxKey,
                       onUp: { press(.pageUp) }, onDown: { press(.pageDown) })
                Spacer(minLength: 4)
                DiamondPad(onDirection: { press(TVRemoteKey($0)) }, onColorKey: press)
                Spacer(minLength: 4)
                Rocker(caption: "CH", upImage: "chevron.up", downImage: "chevron.down",
                       upLabel: TVRemoteKey.channelUp.label, downLabel: TVRemoteKey.channelDown.label,
                       width: 66, height: 174, radius: 14, fill: RemoteColors.boxKey,
                       onUp: { press(.channelUp) }, onDown: { press(.channelDown) })
            }
            HStack(spacing: 8) {
                key(.back) { Image(systemName: "arrow.uturn.backward") }
                key(.exit) { Text("Exit") }
                key(.guide) { Text("Guide") }
                key(.info) { Image(systemName: "info") }
                key(.menu, label: "\(menuLabel) menu") {
                    Text(menuLabel)
                        .font(.system(.subheadline, design: .rounded, weight: .heavy))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                key(.rewind) { Image(systemName: "backward.fill") }
                key(.playPause) { Image(systemName: "playpause.fill") }
                key(.fastForward) { Image(systemName: "forward.fill") }
                key(.record) { Image(systemName: "circle.fill").foregroundStyle(RemoteColors.power) }
                Button(action: showKeypad) {
                    Text("123")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(KeyStyle(shape: RoundedRectangle(cornerRadius: 12, style: .continuous), fill: RemoteColors.boxKey, pressed: RemoteColors.boxKeyPressed))
                .accessibilityLabel("\(name) number keys")
            }
        }
        .foregroundStyle(RemoteColors.label)
        .padding(16)
        .background(RemoteColors.boxPanel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func key(_ key: TVRemoteKey, label: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        Button {
            press(key)
        } label: {
            content()
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
                .padding(.horizontal, 2)
        }
        .buttonStyle(KeyStyle(shape: RoundedRectangle(cornerRadius: 12, style: .continuous), fill: RemoteColors.boxKey, pressed: RemoteColors.boxKeyPressed))
        .accessibilityLabel(label ?? key.label)
    }
}

/// X1's pad: a diamond with an OK ring, and the A–D keys in its corners.
private struct DiamondPad: View {
    let onDirection: (RemoteDirection) -> Void
    let onColorKey: (TVRemoteKey) -> Void
    private let size: CGFloat = 170

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RemoteColors.boxPad)
                .frame(width: 110, height: 110)
                .rotationEffect(.degrees(45))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
            VStack(spacing: 0) {
                arrow(.up)
                HStack(spacing: 0) {
                    arrow(.left)
                    Button {
                        onDirection(.ok)
                    } label: {
                        Circle()
                            .strokeBorder(RemoteColors.label, lineWidth: 2)
                            .frame(width: 64, height: 64)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel("OK")
                    arrow(.right)
                }
                arrow(.down)
            }
            colorKey(.keyA, shape: AnyShape(Triangle()), x: -1, y: -1)
            colorKey(.keyB, shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)), x: 1, y: -1)
            colorKey(.keyC, shape: AnyShape(Circle()), x: -1, y: 1)
            colorKey(.keyD, shape: AnyShape(Diamond()), x: 1, y: 1)
        }
        .frame(width: size, height: size)
    }

    private func arrow(_ direction: RemoteDirection) -> some View {
        Button {
            onDirection(direction)
        } label: {
            Image(systemName: direction.systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(RemoteColors.caption)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(direction.label)
    }

    private func colorKey(_ key: TVRemoteKey, shape: AnyShape, x: CGFloat, y: CGFloat) -> some View {
        Button {
            onColorKey(key)
        } label: {
            Text(key.label)
                .font(.footnote.weight(.bold))
                .foregroundStyle(RemoteColors.label)
                .offset(y: key == .keyA ? 3 : 0)
                .frame(width: 34, height: 34)
                .background(shape.fill(RemoteColors.boxKey))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(key.label)
        .offset(x: x * 66, y: y * 66)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

// MARK: - Shared parts

private struct PanelCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(RemoteColors.caption)
            .lineLimit(1)
    }
}

/// Up and down halves around a small caption.
private struct Rocker: View {
    let caption: String
    let upImage: String
    let downImage: String
    let upLabel: String
    let downLabel: String
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let fill: Color
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            half(upImage, accessibility: upLabel, action: onUp)
            Text(caption)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(RemoteColors.caption)
                .accessibilityHidden(true)
            half(downImage, accessibility: downLabel, action: onDown)
        }
        .frame(width: width, height: height)
        .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func half(_ systemImage: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(accessibility)
    }
}

private struct KeyStyle<S: Shape>: ButtonStyle {
    let shape: S
    let fill: Color
    let pressed: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(configuration.isPressed ? pressed : fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - NumberPadSheet

/// Number keys for one device, sent as they're tapped, like the physical
/// remote, with Last (previous channel) and Enter.
struct NumberPadSheet: View {
    enum Entry {
        case digit(Int)
        case key(TVRemoteKey)
    }

    let title: String
    let onEntry: (Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(1...9, id: \.self) { digitKey($0) }
                textKey("Last", accessibility: TVRemoteKey.lastChannel.label) { onEntry(.key(.lastChannel)) }
                digitKey(0)
                textKey("Enter", accessibility: TVRemoteKey.enter.label) { onEntry(.key(.enter)) }
            }
        }
        .padding(24)
    }

    private func digitKey(_ digit: Int) -> some View {
        Button {
            onEntry(.digit(digit))
        } label: {
            Text("\(digit)")
                .font(.title2.monospacedDigit().weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(RemoteKeyButtonStyle())
    }

    private func textKey(_ title: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(RemoteKeyButtonStyle())
        .accessibilityLabel(accessibility)
    }
}

#Preview {
    ScrollView {
        TVRemoteCardView(
            configuration: DashboardTVRemoteConfiguration(
                title: "Family Room",
                tv: .init(kind: .samsung, remote: "remote.tv", mediaPlayer: "media_player.tv"),
                box: .init(kind: .xfinity, remote: "remote.xfinity")
            ),
            isAvailable: true,
            perform: { _ in }
        )
        .padding()
    }
}
