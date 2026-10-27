import SwiftUI

/// A single, discoverable place to connect, move, replace or forget a gateway.
/// Nothing on this screen opens the microphone or sends a directive.
struct AssistantGatewaySettingsView: View {
    let configuration: AssistantConfiguration
    @EnvironmentObject private var model: AssistantChatModel
    @State private var address = ""
    @State private var setupCode = ""
    @State private var pendingAddress: String?
    @State private var showingAddressConfirmation = false
    @State private var showingPairing = false
    @State private var confirmingForget = false
    @State private var localError: String?
    @State private var showingScanner = false

    private var isBusy: Bool { model.activeRunID != nil }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: status)
                    .accessibilityIdentifier("assistant.gatewayStatus")
                if let endpoint = model.gatewayAddress {
                    LabeledContent("Current gateway") {
                        Text(endpoint).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                }
                if isBusy {
                    Text("Wait for your command to finish or stop it before changing the gateway.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if model.hasSavedGateway {
                Section {
                    TextField("Gateway address", text: $address)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("assistant.gatewayAddress")
                    Button("Save address & reconnect") {
                        do {
                            pendingAddress = try OpenClawSetupCode.gatewayAddress(address).absoluteString
                            localError = nil
                            showingAddressConfirmation = true
                        } catch { show(error) }
                    }
                    .disabled(isBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unchangedAddress)
                    .accessibilityIdentifier("assistant.saveGatewayAddress")
                } header: { Text("Gateway moved?") } footer: {
                    Text("Enter the new hostname, HTTPS or WSS address for the same \(model.assistantName) gateway. Your pairing is kept. For a different gateway, use a new setup code below.")
                }
                .confirmationDialog("Keep your pairing at this new address?", isPresented: $showingAddressConfirmation, titleVisibility: .visible) {
                    Button("Save & Reconnect") {
                        guard let pendingAddress else { return }
                        do {
                            try model.changeGatewayAddress(pendingAddress)
                            address = model.gatewayAddress ?? pendingAddress
                            localError = nil
                        } catch { show(error) }
                        self.pendingAddress = nil
                    }
                } message: {
                    Text("Your existing device credential will be sent to \(pendingAddress ?? "the new address"). Only continue if this is the same trusted gateway at its new address.")
                }
            }

            if !model.hasSavedGateway || model.state == .needsPairing || showingPairing {
                pairingSection
            } else {
                Section {
                    Button("Pair a different gateway") { showingPairing = true; localError = nil }
                        .disabled(isBusy)
                        .accessibilityIdentifier("assistant.replaceGateway")
                }
            }

            if let message = localError ?? model.errorMessage {
                Section {
                    Text(model.displayText(message)).foregroundStyle(.red)
                        .accessibilityIdentifier("assistant.gatewayError")
                }
            }

            if model.hasSavedGateway {
                Section {
                    Button("Reconnect") { localError = nil; model.reconnect() }
                        .disabled(isBusy || model.state == .connecting || model.state == .connected)
                    Button("Forget gateway", role: .destructive) { confirmingForget = true }
                        .disabled(isBusy)
                        .accessibilityIdentifier("assistant.forgetGateway")
                        .confirmationDialog("Forget this gateway?", isPresented: $confirmingForget, titleVisibility: .visible) {
                            Button("Forget gateway", role: .destructive) {
                                model.forget()
                                if !model.hasSavedGateway {
                                    address = ""
                                    setupCode = ""
                                    showingPairing = true
                                    localError = nil
                                }
                            }
                        } message: {
                            Text("Removes this device's local pairing. You can connect a new gateway on this screen immediately. It does not revoke the device on the server.")
                        }
                }
            }

            Section("Details") {
                LabeledContent("Agent", value: configuration.agent)
                if let deviceID = model.deviceID {
                    LabeledContent("Device") { Text(deviceID).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
        }
        .navigationTitle("\(model.assistantName) Gateway")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingScanner) {
            AssistantPairingScanner { code in
                do {
                    _ = try OpenClawSetupCode.parse(code)
                    setupCode = code
                    localError = nil
                } catch { show(error) }
            }
        }
        .task {
            model.refreshGatewayDetails()
            address = model.gatewayAddress ?? ""
            model.activate(configuration: configuration)
        }
        .onDisappear { setupCode = "" }
        .onChange(of: model.hasSavedGateway) { _, saved in
            if saved { address = model.gatewayAddress ?? "" }
        }
        .onChange(of: model.state) { _, state in
            if state == .connected {
                showingPairing = false
                address = model.gatewayAddress ?? ""
            }
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        Section {
            Button { showingScanner = true } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .disabled(isBusy || model.state == .waitingForApproval)
            .accessibilityIdentifier("assistant.scanPairingCode")
            SecureField("Paste setup code", text: $setupCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("assistant.setupCode")
            if let setup = try? OpenClawSetupCode.parse(setupCode) {
                LabeledContent("Connect to") {
                    Text(setup.url.absoluteString).textSelection(.enabled)
                }
                Text("Check that this is your trusted gateway, then tap Connect.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                PasteButton(payloadType: String.self) { setupCode = $0.first ?? "" }
                Spacer()
                Button("Connect gateway") {
                    do {
                        try model.pair(setupCode)
                        setupCode = ""
                        localError = nil
                    } catch { show(error) }
                }
                .disabled(isBusy || model.state == .waitingForApproval || setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("assistant.connectGateway")
            }
            if model.state == .waitingForApproval {
                Label("Waiting for approval on your gateway…", systemImage: "person.badge.key")
                Text("Approve this device on the gateway. This screen will update automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(model.hasSavedGateway ? "Pair a different gateway" : "Connect gateway")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan your gateway's limited pairing QR code or paste its setup code. Both include the address and a short-lived credential.")
            }
        }
        Section {
            DisclosureGroup("How do I get a pairing code?") {
                Text("On your gateway, run:")
                Text("openclaw qr --limited --url wss://YOUR-HOST")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("Scan the QR code displayed in the terminal. To get text for pasting instead, add --setup-code-only.")
                Text("Use a limited setup code, not a shared administrator token. A hostname alone can't authorize a new connection. Your existing pairing is only replaced after the new gateway pairs successfully.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var unchangedAddress: Bool {
        guard let normalized = try? OpenClawSetupCode.gatewayAddress(address) else { return false }
        return normalized.absoluteString == model.gatewayAddress
    }

    private var status: String {
        switch model.state {
        case .needsPairing: return model.hasSavedGateway ? "Pairing required" : "Not connected"
        case .connecting: return "Connecting…"
        case .waitingForApproval: return "Waiting for approval"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private func show(_ error: Error) {
        localError = (error as? OpenClawError)?.localizedDescription ?? "Couldn't save gateway settings. Try again."
    }
}
