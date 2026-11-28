import SwiftUI

/// Something to start playing: a favorite, a recent, or a Browse pick.
struct MusicStartRequest: Equatable {
    let contentType: String
    let contentId: String
    /// Spoken to the voice assistant when a speaker has to be claimed first.
    let displayName: String
    /// What lands in Recents once it starts.
    var recent: RecentMusicItem?

    init(contentType: String, contentId: String, displayName: String, recent: RecentMusicItem? = nil) {
        self.contentType = contentType
        self.contentId = contentId
        self.displayName = displayName
        self.recent = recent
    }

    init(favorite: MusicFavorite) {
        self.init(contentType: favorite.contentType, contentId: favorite.contentId,
                  displayName: favorite.displayName, recent: RecentMusic.item(from: favorite))
    }

    init(recent: RecentMusicItem) {
        self.init(contentType: recent.contentType, contentId: recent.contentId, displayName: recent.title, recent: recent)
    }

    /// Nil for a folder or anything else that can't be played.
    init?(node: HABrowseMediaNode) {
        guard node.isPlayable, let contentType = node.mediaContentType, let contentId = node.mediaContentId else { return nil }
        self.init(contentType: contentType, contentId: contentId, displayName: node.displayTitle,
                  recent: RecentMusic.item(from: node))
    }
}

/// The account it plays on, and where.
struct MusicStartContext {
    let accountEntityId: String
    let accountDisplayName: String
    let speakerClaim: SpeakerClaimConfig?
    let zones: [MusicZone]
    /// Something is playing or paused on the account right now.
    let hasMedia: Bool
    /// Play on this speaker (a room's). Nil: wherever the account is
    /// playing, or ask.
    var target: MusicZone? = nil
}

/// The rules for starting music, kept apart from the views so they can be
/// tested.
enum MusicStart {
    enum Route: Equatable {
        /// Already playing where it should: just send the content.
        case playHere
        /// Move the account to this zone first, without asking.
        case switchTo(zoneId: String)
        /// Nothing to go on: the Play On sheet asks where.
        case ask
    }

    /// `currentSource` is the account's `source` now; `rememberedSource` the
    /// zone last picked, for when Home Assistant leaves `source` out.
    static func route(target: MusicZone?, hasMedia: Bool, currentSource: String?, rememberedSource: String?) -> Route {
        let source = currentSource ?? rememberedSource
        if let target, let targetSource = target.sourceName {
            let playingThere = hasMedia && source?.normalizedZoneSourceName == targetSource.normalizedZoneSourceName
            return playingThere ? .playHere : .switchTo(zoneId: target.id)
        }
        return hasMedia && source != nil ? .playHere : .ask
    }

    enum Outcome: Equatable {
        case started
        /// The provider had nowhere to play it (Spotify with no active device).
        case noSpeaker
        case failed(String)
    }

    /// A failed `play_media` call, read: "no active device" is a speaker
    /// problem the Play On sheet can solve; anything else is just an error.
    static func outcome(ofFailure error: HAResultError?) -> Outcome {
        let message = error?.message ?? ""
        let lowered = message.lowercased()
        let speakerless = ["no active device", "active device", "no device", "device not found",
                           "no active playback", "player command failed"]
        if speakerless.contains(where: lowered.contains) { return .noSpeaker }
        return .failed(message.isEmpty ? "Home Assistant couldn't start it." : message)
    }

    /// Whether playback has started since `play_media` was sent. A player
    /// that was already playing has a speaker, so the call landing is
    /// enough; an idle one has to go to `playing`.
    static func hasStarted(before: HAEntityState?, now: HAEntityState?) -> Bool {
        if before?.state == "playing" { return true }
        return now?.state == "playing"
    }

    static func noSpeakerNotice(for name: String) -> String {
        "Nothing's playing, so there's no speaker to start \(name) on. Pick one."
    }
}

/// Starts music from anywhere in the app: plays straight away when it's
/// clear where, otherwise brings up the Play On sheet (see `musicStartFlow`),
/// then checks that playback really started and says so when it didn't.
@MainActor
final class MusicStarter: ObservableObject {
    /// The Play On sheet, while it's up.
    struct PlayOn: Identifiable {
        let id = UUID()
        let request: MusicStartRequest
        let context: MusicStartContext
        /// Switch to this one straight away (a room's speaker).
        let autoZone: MusicZone?
        /// Why it's asking, when playing directly didn't start.
        let notice: String?
    }

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Offer the Play On sheet: there's no fixed speaker to retry on.
        let retry: (request: MusicStartRequest, context: MusicStartContext)?
    }

    @Published var playOn: PlayOn?
    @Published var failure: Failure?

    /// How long an idle player gets to start playing.
    var startTimeout: Duration = .seconds(12)

    private let defaults: UserDefaults
    private let recents: RecentMusicStore
    /// The sheet that's up; `playOn` is already nil by the time it's dismissed.
    private var asking: PlayOn?
    private var onStarted: () -> Void = {}
    private var startTask: Task<Void, Never>?
    /// Resends after an account switch; a newer tap cancels them so they
    /// can't switch back to the old content.
    private var resendTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, recents: RecentMusicStore? = nil) {
        self.defaults = defaults
        self.recents = recents ?? .shared
    }

    /// `onStarted` runs once it's playing (a sheet that started it closes).
    func start(_ request: MusicStartRequest, context: MusicStartContext, client: any HAClientProtocol,
               onStarted: @escaping () -> Void = {}) {
        // A second tap while the sheet's up would swap what it's about to play.
        guard playOn == nil, asking == nil else { return }
        startTask?.cancel()
        resendTask?.cancel()
        self.onStarted = onStarted
        let route = MusicStart.route(
            target: context.target, hasMedia: context.hasMedia,
            currentSource: client.entity(context.accountEntityId)?.attributeString("source"),
            rememberedSource: rememberedSource(for: context))
        switch route {
        case .playHere:
            startTask = Task { await play(request, context: context, client: client, canAsk: true) }
        case .switchTo(let zoneId):
            present(PlayOn(request: request, context: context, autoZone: context.zones.first { $0.id == zoneId }, notice: nil))
        case .ask:
            present(PlayOn(request: request, context: context, autoZone: nil, notice: nil))
        }
    }

    /// The Play On sheet closed. `picked`: a speaker was chosen and is ready;
    /// `switched`: it had to be claimed for the account first.
    func sheetDismissed(picked: Bool, switched: Bool, client: any HAClientProtocol) {
        guard let asked = asking else { return }
        asking = nil
        playOn = nil
        guard picked else { return }
        let request = asked.request
        let account = asked.context.accountEntityId
        guard switched else {
            startTask = Task { await play(request, context: asked.context, client: client, canAsk: false) }
            return
        }
        // Claiming the speaker already asked the voice assistant for this
        // content by name. These resend the exact request over a longer
        // window in case its interpretation differs or the still-settling
        // handoff drops a call; harmless once one lands (it restarts the
        // same content).
        remember(request, account: account, client: client)
        onStarted()
        resendTask = Task {
            for delay in [0.0, 5.0, 7.0, 13.0, 20.0, 25.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                client.playMedia(account, contentType: request.contentType, contentId: request.contentId)
            }
        }
    }

    /// The alert's "Choose Speaker".
    func chooseSpeaker(for failure: Failure) {
        self.failure = nil
        guard let retry = failure.retry else { return }
        present(PlayOn(request: retry.request, context: retry.context, autoZone: nil, notice: nil))
    }

    #if DEBUG && targetEnvironment(simulator)
    /// For screenshots: the sheet as it comes up when playing directly
    /// found no speaker.
    func showDemoFallback(_ request: MusicStartRequest, context: MusicStartContext) {
        present(PlayOn(request: request, context: context, autoZone: nil,
                       notice: MusicStart.noSpeakerNotice(for: request.displayName)))
    }
    #endif

    private func present(_ playOn: PlayOn) {
        asking = playOn
        self.playOn = playOn
    }

    private func play(_ request: MusicStartRequest, context: MusicStartContext, client: any HAClientProtocol, canAsk: Bool) async {
        let account = context.accountEntityId
        let before = client.entity(account)
        let result = await client.playMediaChecked(account, contentType: request.contentType, contentId: request.contentId)
        guard !Task.isCancelled else { return }

        var outcome = result.success ? MusicStart.Outcome.started : MusicStart.outcome(ofFailure: result.error)
        if result.success, !MusicStart.hasStarted(before: before, now: client.entity(account)) {
            outcome = await waitForPlayback(account: account, before: before, client: client) ? .started : .noSpeaker
            guard !Task.isCancelled else { return }
        }
        Log.music.note("MusicStarter: \(request.contentId) on \(account) → \(String(describing: outcome))")

        let canPickSpeaker = context.target == nil
        switch outcome {
        case .started:
            remember(request, account: account, client: client)
            onStarted()
        case .noSpeaker where canAsk && canPickSpeaker:
            // The account lost its speaker since it last played: ask where.
            present(PlayOn(request: request, context: context, autoZone: nil,
                           notice: MusicStart.noSpeakerNotice(for: request.displayName)))
        case .noSpeaker:
            failure = Failure(title: "Couldn't Play \(request.displayName)",
                              message: "It didn't start on \(context.target?.displayName ?? "the speaker"). Try again, or pick another speaker.",
                              retry: canPickSpeaker ? (request, context) : nil)
        case .failed(let message):
            failure = Failure(title: "Couldn't Play \(request.displayName)", message: message,
                              retry: canPickSpeaker ? (request, context) : nil)
        }
    }

    private func waitForPlayback(account: String, before: HAEntityState?, client: any HAClientProtocol) async -> Bool {
        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
            if MusicStart.hasStarted(before: before, now: client.entity(account)) { return true }
        }
        return false
    }

    private func rememberedSource(for context: MusicStartContext) -> String? {
        let value = defaults.string(forKey: StorageKeys.lastPlayOnSource(account: context.accountEntityId)) ?? ""
        return value.isEmpty ? nil : value
    }

    private func remember(_ request: MusicStartRequest, account: String, client: any HAClientProtocol) {
        guard var item = request.recent else { return }
        item.playedAt = Date()
        recents.record(item, account: account)
        guard item.thumbnail == nil else { return }
        let recents = recents
        Task {
            await recents.fillArtwork(for: item.id, account: account) { type, id in
                await client.browseMedia(entityId: account, mediaContentType: type, mediaContentId: id)
            }
        }
    }
}

extension View {
    /// The Play On sheet and the "couldn't play" alert for `starter`.
    /// Attach it in the view that's on screen when music is started, so the
    /// sheet comes up over it (over Browse, say, rather than behind it).
    func musicStartFlow(_ starter: MusicStarter) -> some View {
        modifier(MusicStartFlow(starter: starter))
    }
}

private struct MusicStartFlow: ViewModifier {
    @ObservedObject var starter: MusicStarter
    @EnvironmentObject private var haClient: HAWebSocketClient
    @State private var picked = false
    @State private var switched = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $starter.playOn, onDismiss: {
                starter.sheetDismissed(picked: picked, switched: switched, client: haClient)
                picked = false
                switched = false
            }) { playOn in
                let context = playOn.context
                let key = StorageKeys.lastPlayOnSource(account: context.accountEntityId)
                let remembered = Binding(
                    get: { UserDefaults.standard.string(forKey: key) ?? "" },
                    set: { UserDefaults.standard.set($0, forKey: key) })
                PlayOnSheet(
                    mediaEntityId: context.accountEntityId,
                    accountDisplayName: context.accountDisplayName,
                    speakerClaim: context.speakerClaim,
                    zones: context.zones,
                    activeSource: remembered.wrappedValue.isEmpty ? nil : remembered.wrappedValue,
                    lastPlayOnSourceName: remembered,
                    zonePicked: $picked,
                    zoneSwitchedAccount: $switched,
                    desiredContentName: playOn.request.displayName,
                    autoStartZone: playOn.autoZone,
                    notice: playOn.notice
                )
            }
            .alert(starter.failure?.title ?? "", isPresented: Binding(
                get: { starter.failure != nil },
                set: { if !$0 { starter.failure = nil } }
            ), presenting: starter.failure) { failure in
                if failure.retry != nil {
                    Button("Choose Speaker") { starter.chooseSpeaker(for: failure) }
                }
                Button("OK", role: .cancel) { starter.failure = nil }
            } message: { failure in
                Text(failure.message)
            }
    }
}
