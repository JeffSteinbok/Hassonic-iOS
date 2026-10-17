import SwiftUI

struct AssistantView: View {
    let configuration: AssistantConfiguration
    @EnvironmentObject private var model: AssistantChatModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var setupCode = ""
    @State private var pairingError: String?
    @State private var showingConnection = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.state == .needsPairing {
                    pairingView
                } else {
                    statusBar
                    conversation
                }
            }
            .navigationTitle(configuration.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AppMenuButton() }
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
        .onDisappear { model.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activate() }
            else if phase == .background { model.pause() }
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
        case .connected: return model.isLoadingHistory ? "Loading conversation…" : "Connected"
        case .disconnected: return "Reconnecting…"
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.transcript.messages.isEmpty, model.state == .connected, !model.isLoadingHistory {
                        ContentUnavailableView("Ask your assistant", systemImage: configuration.systemIcon,
                                               description: Text("Send a message to start the conversation."))
                    }
                    ForEach(model.transcript.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.isUser ? "You" : configuration.title)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.isUser ? AttributedString(message.text) :
                                 ((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(message.isUser ? Color.accentColor.opacity(0.10) : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 16))
                    }
                    if model.activeRunID != nil {
                        HStack(spacing: 8) { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                            .font(.subheadline)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .frame(maxWidth: 760)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.transcript.messages) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) { composer }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .disabled(model.state != .connected || model.isLoadingHistory)
                .accessibilityIdentifier("assistant.message")
            if model.activeRunID != nil {
                Button { Task { await model.stop() } } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .accessibilityLabel("Stop response")
            } else {
                Button {
                    model.send(draft)
                    draft = ""
                    composerFocused = false
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(model.state != .connected || model.isLoadingHistory || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 16_000)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("assistant.send")
            }
        }
        .padding()
        .background(.bar)
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
