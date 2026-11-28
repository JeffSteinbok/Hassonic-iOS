import AVFoundation
import SwiftUI
import VisionKit

/// Scans locally. The caller previews the endpoint and requires Connect before pairing.
struct AssistantPairingScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraReady = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if cameraReady {
                    PairingQRScanner(onCode: { code in
                        onCode(code)
                        dismiss()
                    }, onFailure: { message = $0; cameraReady = false })
                    .overlay(alignment: .bottom) {
                        Text("Scan the limited pairing QR code shown by your gateway.")
                            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .padding()
                    }
                } else if let message {
                    ContentUnavailableView {
                        Label("Camera unavailable", systemImage: "camera")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Use a setup code instead") { dismiss() }
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Settings", destination: url)
                        }
                    }
                } else { ProgressView("Opening camera…") }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                guard DataScannerViewController.isSupported else {
                    message = "QR scanning isn't supported on this device. You can paste a setup code instead."
                    return
                }
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                guard allowed, DataScannerViewController.isAvailable else {
                    message = "Allow camera access in Settings, or paste a setup code instead."
                    return
                }
                cameraReady = true
            }
        }
    }
}

private struct PairingQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                recognizesMultipleItems: false,
                                                isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        // Defer until SwiftUI has finished creating the controller.
        Task { @MainActor [weak scanner, weak coordinator = context.coordinator] in
            guard let scanner, let coordinator, !coordinator.finished else { return }
            do { try scanner.startScanning() }
            catch { coordinator.fail() }
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        uiViewController.stopScanning()
        uiViewController.delegate = nil
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onFailure: (String) -> Void
        var finished = false

        init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for case .barcode(let barcode) in addedItems {
                guard let code = barcode.payloadStringValue else { continue }
                finished = true
                scanner.stopScanning()
                onCode(code)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            fail()
        }

        func fail() {
            guard !finished else { return }
            finished = true
            onFailure("The camera couldn't start scanning. Try again or paste a setup code instead.")
        }
    }
}
