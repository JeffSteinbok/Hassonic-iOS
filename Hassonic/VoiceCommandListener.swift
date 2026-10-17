import AVFoundation
import Speech

/// Listens for one spoken command, like the voice button on a cable box's
/// remote: start, and it hands back what was said once you stop talking (or
/// tap again). Recognition stays on the iPhone when the language allows it.
@MainActor
final class VoiceCommandListener: ObservableObject {
    enum Mode { case phrase, hold }
    enum State: Equatable {
        case idle
        case listening
        /// Microphone or speech recognition is turned off for the app.
        case denied
        /// No recognizer for this language right now (offline, unsupported).
        case unavailable
    }

    @Published private(set) var state: State = .idle
    /// What's been heard so far, while listening.
    @Published private(set) var transcript = ""
    @Published private(set) var isFinishing = false

    /// How long a pause ends the command, once something's been said.
    private static let pauseThatEnds: Duration = .seconds(1.2)
    /// How long to wait for anything at all before giving up.
    private static let waitForSpeech: Duration = .seconds(6)

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var onCommand: ((String) -> Void)?
    /// Set while asking for permission, before `state` says listening, so a
    /// second tap can't start a second microphone tap (which traps).
    private var isStarting = false
    private var startGeneration = UUID()
    private var mode: Mode = .phrase
    private var tapInstalled = false
    private let authorization: () async -> Bool

    init(authorize: (() async -> Bool)? = nil) {
        authorization = authorize ?? { await Self.authorize() }
    }

    /// Starts listening; `onCommand` gets the words once they're finished.
    /// Nothing is handed back if nothing was said.
    func start(mode: Mode = .phrase, onCommand: @escaping (String) -> Void) async {
        guard state != .listening, !isStarting, !Task.isCancelled else { return }
        isStarting = true
        let generation = UUID()
        startGeneration = generation
        let authorized = await authorization()
        // cancel() while asking: the view's gone, so don't open the mic.
        guard isStarting, startGeneration == generation else { return }
        isStarting = false
        guard !Task.isCancelled else { return }
        guard authorized else {
            state = .denied
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [request] buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            Log.homeAssistant.error("voice command: couldn't start the microphone: \(error.localizedDescription)")
            tearDown()
            state = .unavailable
            return
        }

        self.request = request
        self.mode = mode
        self.onCommand = onCommand
        transcript = ""
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                // A cancelled session still reports in; it mustn't end the next one.
                guard let self, self.request === request else { return }
                if let words { self.heard(words) }
                if isFinal || error != nil {
                    let failedWithoutSpeech = error != nil && self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    self.finish()
                    if failedWithoutSpeech { self.state = .unavailable }
                }
            }
        }
        // Hold mode records through pauses; a safety cap prevents an indefinitely open mic.
        endAfter(mode == .hold ? .seconds(60) : Self.waitForSpeech)
    }

    /// Ends listening now and hands back whatever was heard.
    func stop() {
        isStarting = false
        startGeneration = UUID()
        if state == .listening, mode == .hold {
            guard !isFinishing else { return }
            isFinishing = true
            if audioEngine.isRunning { audioEngine.stop() }
            if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            request?.endAudio()
            // Allow the recognizer's final words to arrive after release.
            endAfter(.milliseconds(500))
            return
        }
        finish()
    }

    /// Ends listening and drops what was heard.
    func cancel() {
        isStarting = false
        startGeneration = UUID()
        onCommand = nil
        finish()
    }

    /// Clears a denied or unavailable state once it's been shown.
    func reset() {
        if state != .listening { state = .idle }
    }

    private func heard(_ words: String) {
        guard state == .listening else { return }
        transcript = words
        if mode == .phrase { endAfter(Self.pauseThatEnds) }
    }

    private func endAfter(_ delay: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard state == .listening else { return }
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = onCommand
        tearDown()
        state = .idle
        transcript = ""
        if !command.isEmpty { handler?(command) }
    }

    private func tearDown() {
        isFinishing = false
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        onCommand = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
