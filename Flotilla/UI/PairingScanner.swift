import SwiftUI
import VisionKit

/// The camera, looking for a pairing code. Calls `found` once with the first
/// QR code that holds a pairing link.
struct PairingScanner: UIViewControllerRepresentable {
    let found: (PairingLink) -> Void

    /// False in the simulator and on devices without a capable camera.
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairingLink) -> Void
        private var done = false

        init(found: @escaping (PairingLink) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let text = code.payloadStringValue, let link = PairingLink.parse(text) {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    found(link)
                    return
                }
            }
        }
    }
}

/// The scanner as a sheet: the camera, what to point it at, and Cancel.
struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let found: (PairingLink) -> Void

    var body: some View {
        NavigationStack {
            PairingScanner { link in
                dismiss()
                found(link)
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                Text("Point the camera at the pairing code on your computer: The Hermes → Settings → Devices.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
