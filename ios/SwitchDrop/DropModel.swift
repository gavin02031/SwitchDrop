import Foundation

@MainActor
final class DropModel: ObservableObject {
    @Published var link = PairingStore.load()
    @Published var status = "Ready to pair"
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var lastSent: String?

    func pair(qr: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let candidate = try DropLink(qr: qr)
            status = "Connecting to Switch..."
            try await DropTransport.verify(candidate)
            PairingStore.save(candidate)
            link = candidate
            status = "Connected! Ready to drop."
        } catch {
            status = error.localizedDescription
        }
    }

    func forget() {
        PairingStore.clear()
        link = nil
        status = "Ready to pair"
    }

    func send(_ files: [URL]) async {
        guard let link else { status = "Scan your Switch's QR code first."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await DropTransport.verify(link)
            for file in files {
                let allowed = file.startAccessingSecurityScopedResource()
                defer { if allowed { file.stopAccessingSecurityScopedResource() } }
                lastSent = file.lastPathComponent
                progress = 0
                status = "Sending \(file.lastPathComponent)..."
                let tracker = UploadProgress { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
                try await DropTransport.send(file, filename: file.lastPathComponent,
                                             to: link, delegate: tracker)
                progress = 1
                status = "Sent \(file.lastPathComponent)!"
            }
        } catch {
            status = "Transfer failed: \(error.localizedDescription)"
        }
    }
}
