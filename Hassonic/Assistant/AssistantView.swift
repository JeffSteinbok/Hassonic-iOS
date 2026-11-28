import SwiftUI

/// Tap the toolbar mic, speak, then watch this one panel become the result.
struct AssistantView: View {
    let configuration: AssistantConfiguration
    var startsRecording = false
    @EnvironmentObject private var model: AssistantChatModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = VoiceCommandListener()
    @State private var captureAttempted = false
    @State private var wantsRecording = false
    @State private var isStarting = false
    @State private var recordingTask: Task<Void, Never>?
    @State private var showingGatewaySettings = false
    @State private var isCancelling = false
    @State private var confirmingNewDirective = false
    @State private var captureError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.state == .needsPairing { pairingView }
                    else if let directive = model.directive { directiveView(directive) }
                    else { captureView }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(model.assistantName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingGatewaySettings) {
                AssistantGatewaySettingsView(configuration: configuration)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.directive == nil ? "Cancel" : "Close") {
                        voice.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(320), .large])
        .presentationDragIndicator(.visible)
        .task(id: configuration) {
            var demo = false
            #if DEBUG && targetEnvironment(simulator)
            demo = DemoMode.directory != nil
            #endif
            wantsRecording = startsRecording
            if startsRecording, model.directive?.status == .completed || model.directive?.status == .cancelled {
                model.clearDirective()
            }
            model.activate(configuration: configuration, demo: demo)
            startIfReady()
        }
        .onChange(of: model.state) { _, _ in startIfReady() }
        .onDisappear {
            recordingTask?.cancel()
            voice.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                recordingTask?.cancel()
                voice.cancel()
                model.pause()
            } else if phase == .active {
                // Don't restart a recording or resend after returning to the app.
                model.activate(configuration: configuration)
                startIfReady()
            }
        }
    }

    private var captureView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if isStarting || model.state == .connecting || model.state == .waitingForApproval {
                    ProgressView()
                } else {
                    Image(systemName: voice.state == .listening ? "waveform" : voice.state == .idle ? "mic.fill" : "mic.slash")
                        .foregroundStyle(.tint).font(.title2)
                }
                Text(captureStatus).font(.title2.bold()).accessibilityIdentifier("assistant.status")
            }
            if voice.state == .listening {
                Text(voice.transcript.isEmpty ? "Say what you'd like done. I'll send it when you finish speaking." : voice.transcript)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant.transcription")
                Button("Finish speaking") { voice.stop() }.buttonStyle(.bordered)
            } else if voice.state == .denied {
                Text("Allow microphone and speech recognition access in Settings.")
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            } else if voice.state == .unavailable {
                Text("Speech recognition isn't available right now. Check microphone access and try again.")
                retryRecording
            } else if !isStarting, captureAttempted, model.state == .connected {
                if captureError == nil {
                    Text("No speech was recognized. Nothing was sent.").foregroundStyle(.secondary)
                }
                retryRecording
            } else if !isStarting, model.state == .connected {
                retryRecording
            }
            if let error = captureError ?? model.errorMessage { Text(model.displayText(error)).foregroundStyle(.red) }
            if model.state == .disconnected {
                Button("Reconnect") { model.reconnect() }.buttonStyle(.borderedProminent)
            }
            if model.state == .waitingForApproval {
                Text("Approve this device on the \(model.assistantName) gateway to continue.").foregroundStyle(.secondary)
            }
        }
    }

    private var captureStatus: String {
        if model.state == .waitingForApproval { return "Device approval needed" }
        if model.state == .connecting { return "Connecting…" }
        if model.state == .disconnected { return "Connection lost" }
        if isStarting { return "Getting microphone ready…" }
        switch voice.state {
        case .listening: return "Listening…"
        case .denied: return "Microphone access needed"
        case .unavailable: return "Couldn't record"
        case .idle: return captureError != nil ? "Not sent" : captureAttempted ? "Didn't hear anything" : "Ready"
        }
    }

    private var retryRecording: some View {
        Button(captureAttempted ? "Try again" : "Speak") {
            wantsRecording = true
            captureAttempted = false
            startIfReady()
        }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("assistant.record")
    }

    private func startIfReady() {
        guard wantsRecording, model.state == .connected, model.directive == nil, !captureAttempted, scenePhase == .active else { return }
        captureAttempted = true
        isStarting = true
        captureError = nil
        voice.reset()
        recordingTask = Task {
            await voice.start { words in
                guard model.state == .connected else {
                    captureError = "Connection lost before sending. Nothing was sent. Reconnect and speak again."
                    return
                }
                guard words.count <= 16_000 else {
                    captureError = "That command was too long. Nothing was sent. Try a shorter command."
                    return
                }
                model.send(words)
            }
            isStarting = false
        }
    }

    private func directiveView(_ directive: AssistantDirective) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if directive.status == .running { ProgressView() }
                else {
                    Image(systemName: directive.status == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(directive.status == .completed ? Color.green : Color.orange)
                        .font(.title2)
                }
                Text(model.displayText(directive.progress)).font(.title2.bold()).accessibilityIdentifier("assistant.status")
            }
            Text(directive.text).foregroundStyle(.secondary)
            if !directive.response.isEmpty {
                Text((try? AttributedString(markdown: directive.response, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(directive.response))
                    .textSelection(.enabled)
            }
            if let error = model.errorMessage { Text(model.displayText(error)).foregroundStyle(.red) }
            if directive.status == .running {
                Button(isCancelling ? "Stopping…" : "Stop", role: .destructive) {
                    isCancelling = true
                    Task { await model.stop(); isCancelling = false }
                }
                .buttonStyle(.bordered).disabled(isCancelling)
            } else if directive.status == .failed {
                Button("Try again") {
                    model.clearDirective()
                    wantsRecording = true
                    captureAttempted = false
                    startIfReady()
                }
                .buttonStyle(.borderedProminent)
            } else if directive.status == .interrupted {
                Button("New command") { confirmingNewDirective = true }
                    .buttonStyle(.bordered)
                    .confirmationDialog("The previous command may still be running.", isPresented: $confirmingNewDirective, titleVisibility: .visible) {
                        Button("Record a different command") {
                            model.clearDirective()
                            wantsRecording = true
                            captureAttempted = false
                            startIfReady()
                        }
                    } message: {
                        Text("It has not been sent again. Starting a new command won't cancel the previous one.")
                    }
            } else {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier("assistant.progress")
    }

    private var pairingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(model.assistantName)").font(.title2.bold())
            Text("Set up or change your \(model.assistantName) gateway in Gateway Settings.").foregroundStyle(.secondary)
            Button("Gateway Settings") {
                wantsRecording = false
                showingGatewaySettings = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("assistant.gatewaySettings")
            if let error = model.errorMessage { Text(model.displayText(error)).foregroundStyle(.red) }
        }
    }
}

struct AssistantSettingsSection: View {
    let configuration: AssistantConfiguration
    @EnvironmentObject private var model: AssistantChatModel

    var body: some View {
        Section(model.assistantName) {
            NavigationLink {
                AssistantGatewaySettingsView(configuration: configuration)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.assistantName) Gateway")
                    Text(model.gatewayHost ?? "Connect \(model.assistantName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("assistant.gatewaySettings")
        }
        .task { model.refreshGatewayDetails() }
    }
}
