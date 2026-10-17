import SwiftUI

struct AssistantView: View {
    let configuration: AssistantConfiguration
    @EnvironmentObject private var model: AssistantChatModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = VoiceCommandListener()
    @GestureState private var isHolding = false
    @State private var draft = ""
    @State private var setupCode = ""
    @State private var pairingError: String?
    @State private var showingConnection = false
    @State private var showingReview = false
    @State private var confirmingNewDirective = false
    @State private var isCancelling = false
    @State private var recordingTask: Task<Void, Never>?
    @FocusState private var reviewFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.state == .needsPairing {
                    pairingView
                } else {
                    statusBar
                    if let directive = model.directive {
                        directiveScreen(directive)
                    } else {
                        captureScreen
                    }
                }
            }
            .navigationTitle(configuration.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingConnection = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Assistant connection")
                }
            }
            .sheet(isPresented: $showingConnection) {
                NavigationStack {
                    Form { AssistantSettingsSection(configuration: configuration) }
                        .navigationTitle("Assistant")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingConnection = false } } }
                }
            }
        }
        .task(id: configuration) { activate() }
        .onDisappear {
            recordingTask?.cancel()
            voice.cancel()
            if model.directive?.status != .running { model.pause() }
        }
        .onChange(of: isHolding) { _, holding in
            if holding { beginRecording() }
            else { finishRecording() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activate() }
            else if phase == .background { recordingTask?.cancel(); voice.cancel(); model.pause() }
        }
    }

    private func activate() {
        var demo = false
        #if DEBUG && targetEnvironment(simulator)
        demo = DemoMode.directory != nil
        #endif
        model.activate(configuration: configuration, demo: demo)
    }

    private var pairingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Connect your assistant")
                    .font(.title2.bold())
                Text("Get a limited setup code from the person who manages your OpenClaw gateway, then paste it here.")
                    .foregroundStyle(.secondary)
                SecureField("Setup code", text: $setupCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .accessibilityIdentifier("assistant.setupCode")
                HStack {
                    PasteButton(payloadType: String.self) { strings in setupCode = strings.first ?? "" }
                    Spacer()
                    Button("Connect") {
                        do {
                            try model.pair(setupCode)
                            setupCode = ""
                            pairingError = nil
                        } catch { pairingError = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = pairingError ?? model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.state == .connecting || model.state == .waitingForApproval { ProgressView().controlSize(.small) }
                else { Image(systemName: model.state == .connected ? "checkmark.circle.fill" : "wifi.slash") }
                Text(statusText).font(.subheadline)
                Spacer()
                if model.state == .disconnected {
                    Button("Reconnect") { model.reconnect() }.font(.subheadline)
                }
            }
            if model.state == .waitingForApproval {
                Text("Ask the gateway owner to approve this device, then keep this screen open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch model.state {
        case .needsPairing: return "Not connected"
        case .connecting: return "Connecting…"
        case .waitingForApproval: return "Waiting for approval…"
        case .connected: return "Connected"
        case .disconnected: return "Reconnecting…"
        }
    }

    private var captureScreen: some View {
        ScrollView {
            VStack(spacing: 26) {
                if !showingReview {
                    VStack(spacing: 10) {
                        Text("What would you like done?").font(.title.bold())
                        Text("Hold to record a directive, then review and send it.")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)

                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 180, height: 180)
                        Circle().fill(isHolding ? Color.red.gradient : Color.accentColor.gradient)
                            .frame(width: 140, height: 140)
                        Image(systemName: voice.state == .listening ? "waveform" : "mic.fill")
                            .font(.system(size: 48, weight: .medium)).foregroundStyle(.white)
                    }
                    .scaleEffect(isHolding ? 1.06 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isHolding)
                    .contentShape(Circle())
                    .allowsHitTesting(!voice.isFinishing)
                    .gesture(DragGesture(minimumDistance: 0).updating($isHolding) { _, holding, _ in holding = true })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(voice.state == .listening ? "Stop recording directive" : "Record directive")
                    .accessibilityHint("Touch and hold to record. With VoiceOver, double tap to start or stop. Recording never sends automatically.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if voice.state == .listening { finishRecording() }
                        else { beginRecording() }
                    }
                    .accessibilityIdentifier("assistant.record")

                    VStack(spacing: 8) {
                        Text(voice.isFinishing ? "Preparing your directive…" : isHolding ? "Release when you're done" : "Hold to record")
                            .font(.headline)
                        if voice.state == .listening {
                            Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                        Text("Nothing is sent until you tap Send directive.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                voiceFeedback
                } else {
                    Text("Review your directive")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)
                }

                if showingReview || !draft.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Your directive").font(.headline)
                            Spacer()
                            Button("Record again") {
                                draft = ""
                                showingReview = false
                                reviewFocused = false
                            }
                            .font(.subheadline)
                        }
                        TextField("Review or edit your directive", text: $draft, axis: .vertical)
                            .lineLimit(3...8).focused($reviewFocused)
                            .accessibilityIdentifier("assistant.directive")
                        HStack {
                            Button("Discard", role: .destructive) {
                                voice.cancel()
                                draft = ""
                                showingReview = false
                                reviewFocused = false
                            }
                            Spacer()
                            Text("Review before sending").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    Button {
                        voice.cancel()
                        model.send(draft)
                        if model.directive != nil {
                            draft = ""
                            showingReview = false
                            reviewFocused = false
                        }
                    } label: {
                        Label("Send directive", systemImage: "arrow.up.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.state != .connected || voice.state == .listening || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 16_000)
                    .accessibilityIdentifier("assistant.send")
                } else {
                    Button("Type a directive instead") { showingReview = true; reviewFocused = true }
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: 600)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var voiceFeedback: some View {
        if voice.state == .denied {
            VStack(spacing: 8) {
                Text("Allow microphone and speech recognition access to record a directive.")
                    .font(.callout).multilineTextAlignment(.center)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
        } else if voice.state == .unavailable {
            Text("Voice recording is unavailable right now. You can type your directive instead.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func beginRecording() {
        reviewFocused = false
        voice.reset()
        recordingTask?.cancel()
        recordingTask = Task {
            await voice.start(mode: .hold) { words in
                draft = words
                showingReview = true
            }
        }
    }

    private func finishRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voice.stop()
    }

    private func directiveScreen(_ directive: AssistantDirective) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 14) {
                    if directive.status == .running {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: directive.status == .completed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 52))
                            .foregroundStyle(directive.status == .completed ? Color.green : Color.secondary)
                    }
                    Text(directive.progress).font(.title2.bold()).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Directive").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(directive.text).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                if !directive.response.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(directive.status == .running ? "Progress" : "Result").font(.headline)
                        Text((try? AttributedString(markdown: directive.response, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(directive.response))
                            .textSelection(.enabled)
                    }
                }
                if directive.status == .running {
                    Button(isCancelling ? "Stopping…" : "Stop directive", role: .destructive) {
                        isCancelling = true
                        Task { await model.stop(); isCancelling = false }
                    }
                    .buttonStyle(.bordered).disabled(isCancelling)
                } else {
                    Button {
                        if directive.status == .interrupted { confirmingNewDirective = true }
                        else { model.clearDirective() }
                    } label: {
                        Text("New directive").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .confirmationDialog("Start another directive?", isPresented: $confirmingNewDirective, titleVisibility: .visible) {
                        Button("New directive") { model.clearDirective() }
                    } message: { Text("The previous directive may still be running on OpenClaw. Starting another will not cancel or resend it.") }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("assistant.progress")
    }
}

struct AssistantSettingsSection: View {
    let configuration: AssistantConfiguration
    @EnvironmentObject private var model: AssistantChatModel
    @State private var confirmingForget = false

    var body: some View {
        Section("Assistant") {
            LabeledContent("Agent", value: configuration.agent)
            if let host = model.gatewayHost { LabeledContent("Gateway", value: host) }
            if let deviceID = model.deviceID {
                LabeledContent("Device") { Text(deviceID).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Button("Forget gateway", role: .destructive) { confirmingForget = true }
                .confirmationDialog("Forget this gateway?", isPresented: $confirmingForget, titleVisibility: .visible) {
                    Button("Forget gateway", role: .destructive) { model.forget() }
                } message: {
                    Text("This removes the connection and device key from this app. The gateway owner can also revoke the device on the server.")
                }
        }
    }
}
