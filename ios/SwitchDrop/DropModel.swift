import Foundation
import Combine

@MainActor
final class DropModel: ObservableObject {
    @Published var link = PairingStore.load()
    @Published var status = "Ready to pair"
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var lastSent: String?
    @Published var currentDirectory = PairingStore.loadDestination()
    @Published var entries: [SwitchEntry] = []
    @Published var nextOffset: Int?
    @Published var isLoadingDirectory = false
    @Published var directoryError: String?

    func pair(qr: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let candidate = try DropLink(qr: qr)
            status = "Connecting to Switch..."
            try await DropTransport.verify(candidate)
            PairingStore.save(candidate)
            link = candidate
            currentDirectory = "/"
            PairingStore.saveDestination("/")
            status = "Connected! Browsing SD card."
            await openDirectory("/")
        } catch {
            status = error.localizedDescription
        }
    }

    func forget() {
        PairingStore.clear()
        link = nil
        entries = []
        nextOffset = nil
        currentDirectory = "/"
        directoryError = nil
        status = "Ready to pair"
    }

    func openDirectory(_ path: String) async {
        guard let link else { return }
        isLoadingDirectory = true
        directoryError = nil
        defer { isLoadingDirectory = false }
        do {
            let listing = try await DropTransport.browse(path, on: link)
            currentDirectory = listing.path
            entries = sortEntries(listing.items)
            nextOffset = listing.nextOffset
            PairingStore.saveDestination(currentDirectory)
            status = "Choose a folder, then send your files."
        } catch {
            directoryError = error.localizedDescription
            status = "Couldn't open folder. Is SwitchDrop running?"
        }
    }

    func refreshDirectory() async { await openDirectory(currentDirectory) }

    func loadMore() async {
        guard let link, let offset = nextOffset, !isLoadingDirectory else { return }
        isLoadingDirectory = true
        defer { isLoadingDirectory = false }
        do {
            let listing = try await DropTransport.browse(currentDirectory, on: link,
                                                         offset: offset)
            entries = sortEntries(entries + listing.items)
            nextOffset = listing.nextOffset
            directoryError = nil
        } catch {
            directoryError = error.localizedDescription
        }
    }

    func openFolder(_ name: String) async {
        let separator = currentDirectory == "/" ? "" : currentDirectory
        await openDirectory("\(separator)/\(name)")
    }

    func goUp() async {
        let components = currentDirectory.split(separator: "/")
        let parent = components.dropLast()
        await openDirectory(parent.isEmpty ? "/" : "/" + parent.joined(separator: "/"))
    }

    private func sortEntries(_ items: [SwitchEntry]) -> [SwitchEntry] {
        items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func send(_ files: [URL]) async {
        guard let link else { status = "Scan your Switch's QR code first."; return }
        let destination = currentDirectory
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
                                             to: link, directory: destination, delegate: tracker)
                progress = 1
                status = "Sent \(file.lastPathComponent) to \(destination)!"
            }
            await refreshDirectory()
            if let lastSent { status = "Sent \(lastSent) to \(destination)!" }
        } catch {
            status = "Transfer failed: \(error.localizedDescription)"
        }
    }
}
