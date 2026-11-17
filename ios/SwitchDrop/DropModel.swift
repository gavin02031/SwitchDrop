import Foundation
import Combine

struct TransferRecord: Identifiable, Codable {
    let id: UUID
    let name: String
    let destination: String
    let size: Int64
    let date: Date
    let direction: String?
}

struct SwitchLogFile: Identifiable {
    let path: String
    let name: String
    let size: UInt64

    var id: String { path }
    var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let prefix = String(path[..<slash])
        return prefix.isEmpty ? "/" : prefix
    }
}

struct SavedDownload: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class DropModel: ObservableObject {
    @Published var link = PairingStore.load()
    @Published var status = "Ready to pair"
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var lastSent: String?
    @Published var canDownload = false
    @Published var canPreview = false
    @Published var currentDirectory = PairingStore.loadDestination()
    @Published var entries: [SwitchEntry] = []
    @Published var nextOffset: Int?
    @Published var isLoadingDirectory = false
    @Published var directoryError: String?
    @Published var isScanningLogs = false
    @Published var logScanNote = "Scan your SD card for homebrew and crash logs."
    @Published var logResults: [SwitchLogFile] = []
    @Published private(set) var savedDownloads: [SavedDownload] = []
    @Published private(set) var recentTransfers: [TransferRecord] = {
        guard let data = UserDefaults.standard.data(forKey: "switchdrop.transferHistory"),
              let history = try? JSONDecoder().decode([TransferRecord].self, from: data)
        else { return [] }
        return Array(history.prefix(30))
    }()

    init() { refreshSavedDownloads() }

    func refreshCapabilities() async {
        guard let link else { return }
        do {
            let health = try await DropTransport.verify(link)
            canDownload = health.download == true
            canPreview = health.preview == true
        } catch {
            canDownload = false
            canPreview = false
            status = "SwitchDrop on your Switch is offline."
        }
    }

    func pair(qr: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let candidate = try DropLink(qr: qr)
            status = "Connecting to Switch..."
            let health = try await DropTransport.verify(candidate)
            PairingStore.save(candidate)
            link = candidate
            canDownload = health.download == true
            canPreview = health.preview == true
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
        canDownload = false
        canPreview = false
        entries = []
        logResults = []
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

    private func record(name: String, destination: String,
                        size: Int64, direction: String) {
        recentTransfers.insert(TransferRecord(id: UUID(), name: name,
                                              destination: destination, size: size,
                                              date: Date(), direction: direction), at: 0)
        if recentTransfers.count > 30 { recentTransfers.removeLast() }
        if let data = try? JSONEncoder().encode(recentTransfers) {
            UserDefaults.standard.set(data, forKey: "switchdrop.transferHistory")
        }
    }

    func refreshSavedDownloads() {
        let manager = FileManager.default
        let folder = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        let urls = (try? manager.contentsOfDirectory(at: folder,
                                                    includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        savedDownloads = urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (a ?? .distantPast) > (b ?? .distantPast)
        }.map { SavedDownload(url: $0) }
    }

    func downloadFile(_ name: String, in directory: String) async -> URL? {
        guard let link else { status = "Scan your Switch's QR code first."; return nil }
        guard canDownload else {
            status = "Update SwitchDrop on your Switch to download files."
            return nil
        }
        isBusy = true
        progress = 0
        status = "Downloading \(name) from Switch..."
        defer { isBusy = false }
        do {
            let tracker = DownloadProgress { fraction in
                Task { @MainActor in self.progress = fraction }
            }
            let saved = try await DropTransport.receive(filename: name, from: directory,
                                                        on: link, delegate: tracker)
            progress = 1
            status = "Saved \(saved.lastPathComponent) to On My iPhone → SwitchDrop → Downloads"
            let bytes = Int64((try? saved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            record(name: saved.lastPathComponent, destination: directory,
                   size: bytes, direction: "received")
            refreshSavedDownloads()
            return saved
        } catch {
            status = "Download failed: \(error.localizedDescription)"
            return nil
        }
    }

    func previewFile(_ name: String, in directory: String) async throws -> (String, Bool) {
        guard let link, canPreview else { throw DropLinkError.incompatibleSwitch }
        let result = try await DropTransport.preview(filename: name, in: directory, on: link)
        return (result.text, result.truncated)
    }

    // A bounded, read-only scan of likely homebrew log locations. This avoids
    // crawling Nintendo game data or the entire SD card in the background.
    func scanLogs() async {
        guard let link, !isScanningLogs else { return }
        isScanningLogs = true
        logResults = []
        logScanNote = "Searching common homebrew folders..."
        defer { isScanningLogs = false }
        let roots = ["/atmosphere/crash_reports", "/atmosphere/fatal_reports",
                     "/atmosphere/error_reports", "/logs", "/switch", "/config"]
        var queue = roots.map { (path: $0, depth: 0) }
        var visited = Set<String>()
        var found: [SwitchLogFile] = []
        var rounds = 0
        while !queue.isEmpty && visited.count < 80 && !Task.isCancelled {
            let current = queue.removeFirst()
            guard visited.insert(current.path).inserted else { continue }
            rounds += 1
            logScanNote = "Checking \(current.path) (\(rounds)/80)..."
            var offset = 0
            for _ in 0..<4 {
                guard !Task.isCancelled else { break }
                guard let listing = try? await DropTransport.browse(current.path, on: link,
                                                                     offset: offset) else { break }
                for entry in listing.items {
                    let fullPath = current.path == "/" ? "/\(entry.name)" : "\(current.path)/\(entry.name)"
                    if entry.isFolder {
                        if current.depth < 3 && queue.count < 200 &&
                            !["contents", "exefs_patches", "kip_patches", "romfs", "mods"]
                                .contains(entry.name.lowercased()) {
                            queue.append((path: fullPath, depth: current.depth + 1))
                        }
                    } else if Self.looksLikeLog(entry.name, in: current.path) {
                        found.append(SwitchLogFile(path: fullPath, name: entry.name,
                                                   size: entry.size))
                        if found.count >= 500 { break }
                    }
                }
                if found.count >= 500 { break }
                guard let next = listing.nextOffset else { break }
                offset = next
            }
            if found.count >= 500 { break }
        }
        logResults = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        logScanNote = Task.isCancelled ? "Log scan cancelled." :
            "Found \(found.count) possible log files in \(visited.count) folders."
    }

    private static func looksLikeLog(_ name: String, in directory: String) -> Bool {
        let lower = name.lowercased()
        let folder = directory.lowercased()
        if [".log", ".crash", ".dmp", ".ips", ".stacktrace", ".err"]
            .contains(where: { lower.hasSuffix($0) }) { return true }
        let marked = ["log", "crash", "error", "fatal", "report", "trace"]
            .contains(where: { lower.contains($0) || folder.contains($0) })
        return marked && [".txt", ".json", ".md", ".trace"]
            .contains(where: { lower.hasSuffix($0) })
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
                let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                record(name: file.lastPathComponent, destination: destination,
                       size: bytes, direction: "sent")
            }
            await refreshDirectory()
            if let lastSent { status = "Sent \(lastSent) to \(destination)!" }
        } catch {
            status = "Transfer failed: \(error.localizedDescription)"
        }
    }
}
