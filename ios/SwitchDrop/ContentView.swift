import SwiftUI
import UniformTypeIdentifiers

private enum Palette {
    static let ink = Color(red: 0.18, green: 0.16, blue: 0.30)
    static let violet = Color(red: 0.65, green: 0.48, blue: 0.94)
    static let lavender = Color(red: 0.91, green: 0.85, blue: 1.00)
    static let mint = Color(red: 0.65, green: 0.97, blue: 0.82)
    static let pale = Color(red: 0.97, green: 0.96, blue: 1.00)
    static let muted = Color(red: 0.48, green: 0.45, blue: 0.56)
    static let blue = Color(red: 0.70, green: 0.86, blue: 1.00)
}

struct ContentView: View {
    @EnvironmentObject private var model: DropModel
    @State private var isScanning = false
    @State private var isImporting = false
    @State private var isShowingHistory = false
    @State private var searchText = ""
    @State private var sortLargestFirst = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.lavender, Palette.pale,
                                    Palette.blue.opacity(0.55), Palette.mint.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Circle().fill(Palette.violet.opacity(0.22))
                .frame(width: 330, height: 330).blur(radius: 66)
                .offset(x: -185, y: -320).accessibilityHidden(true)
            Circle().fill(Palette.mint.opacity(0.48))
                .frame(width: 350, height: 350).blur(radius: 72)
                .offset(x: 175, y: 215).accessibilityHidden(true)
            VStack(spacing: 0) {
                header
                if model.link != nil { connectedBrowser }
                else { pairingWelcome }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.link != nil { sendBar }
        }
        .sheet(isPresented: $isScanning) {
            NavigationStack {
                CameraScanner { result in
                    isScanning = false
                    Task { await model.pair(qr: result) }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Pair your Switch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isScanning = false }
                    }
                }
            }
        }
        .sheet(isPresented: $isImporting) {
            ImportCopyPicker { urls in
                isImporting = false
                Task { await model.send(urls) }
            } onCancel: {
                isImporting = false
            }
        }
        .sheet(isPresented: $isShowingHistory) { transferHistory }
        .task {
            if model.link != nil { await model.refreshDirectory() }
        }
        .onChange(of: model.currentDirectory) { _ in searchText = "" }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.ink)
                .frame(width: 47, height: 47)
                .switchDropGlass(radius: 16, tint: Palette.lavender)
            Text("SwitchDrop")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .tracking(-1.2)
                .foregroundStyle(Palette.ink)
            Spacer()
            if model.link != nil {
                Button { isShowingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .switchDropGlass(radius: 22, interactive: true)
                }
                .accessibilityLabel("Recent transfers")
            }
            Menu {
                if model.link != nil {
                    Button { Task { await model.refreshDirectory() } } label: {
                        Label("Refresh folder", systemImage: "arrow.clockwise")
                    }
                    Button { isScanning = true } label: {
                        Label("Pair another Switch", systemImage: "qrcode.viewfinder")
                    }
                    Button(role: .destructive) { model.forget() } label: {
                        Label("Forget Switch", systemImage: "trash")
                    }
                } else {
                    Button { isScanning = true } label: {
                        Label("Scan Switch QR", systemImage: "qrcode.viewfinder")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .switchDropGlass(radius: 22, interactive: true)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("SwitchDrop options")
        }
        .padding(.horizontal, 22)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    private var connectedBrowser: some View {
        VStack(spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19)).foregroundStyle(Color(red: 0.24, green: 0.57, blue: 0.42))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Switch is connected")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Wireless SD card access")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "wifi")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .switchDropGlass(radius: 22, tint: Palette.mint)
            .padding(.horizontal, 22)

            quickPaths.padding(.horizontal, 22)
            breadcrumb.padding(.horizontal, 22)
            searchAndSort.padding(.horizontal, 22)

            ScrollView {
                LazyVStack(spacing: 5) {
                    if model.currentDirectory != "/" {
                        Button { Task { await model.goUp() } } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 19, weight: .semibold))
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(Palette.violet)
                                Text("Parent folder")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                Spacer()
                            }
                            .folderRowStyle()
                        }
                        .disabled(model.isLoadingDirectory)
                    }
                    ForEach(visibleEntries) { entry in
                        if entry.isFolder {
                            Button { Task { await model.openFolder(entry.name) } } label: {
                                entryRow(entry)
                            }
                            .disabled(model.isLoadingDirectory || model.isBusy)
                        } else {
                            entryRow(entry)
                        }
                    }
                    if model.isLoadingDirectory {
                        ProgressView("Loading SD card...").tint(Palette.violet).padding(26)
                    } else if let error = model.directoryError {
                        VStack(spacing: 11) {
                            Label("Couldn't browse this folder", systemImage: "wifi.exclamationmark")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text(error).font(.caption).multilineTextAlignment(.center)
                            Button("Back to SD Card") {
                                Task { await model.openDirectory("/") }
                            }
                            .buttonStyle(.borderedProminent).tint(Palette.violet)
                        }
                        .foregroundStyle(Palette.ink).padding(25)
                    } else if visibleEntries.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: searchText.isEmpty ? "folder" : "magnifyingglass")
                                .font(.system(size: 45)).foregroundStyle(Palette.violet)
                            Text(searchText.isEmpty ? "Empty folder" : "No matching files")
                                .font(.headline)
                            Text(searchText.isEmpty ? "You can still send files here."
                                 : "Try a different name or clear the search.")
                                .font(.subheadline)
                        }
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity).padding(35)
                    }
                    if model.nextOffset != nil {
                        Button("Load more files") { Task { await model.loadMore() } }
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .padding(17).frame(maxWidth: .infinity)
                            .background(Palette.lavender.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 17))
                            .disabled(model.isLoadingDirectory)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 3)
                .padding(.bottom, 18)
            }
            .refreshable { await model.refreshDirectory() }
        }
    }

    private var visibleEntries: [SwitchEntry] {
        let matching = model.entries.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
        }
        guard sortLargestFirst else { return matching }
        return matching.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            if $0.isFolder { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var quickPaths: some View {
        HStack(spacing: 8) {
            quickPath("SD Card", symbol: "externaldrive.fill", path: "/")
            quickPath("Homebrew", symbol: "gamecontroller.fill", path: "/switch")
            quickPath("Inbox", symbol: "tray.and.arrow.down.fill", path: "/switch/switchdrop/inbox")
        }
    }

    private func quickPath(_ title: String, symbol: String, path: String) -> some View {
        Button { Task { await model.openDirectory(path) } } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 43)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .switchDropGlass(radius: 17, tint: model.currentDirectory == path ? Palette.lavender : .white)
        .disabled(model.isLoadingDirectory || model.isBusy)
    }

    private var searchAndSort: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.violet)
            TextField("Search this folder", text: $searchText)
                .font(.system(size: 14, design: .rounded))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                }
                .accessibilityLabel("Clear search")
            }
            Button { sortLargestFirst.toggle() } label: {
                Image(systemName: sortLargestFirst ? "arrow.down.circle.fill" : "arrow.up.arrow.down")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Palette.ink)
            }
            .accessibilityLabel(sortLargestFirst ? "Sort by name" : "Sort by largest first")
        }
        .padding(.leading, 15).padding(.trailing, 5)
        .frame(height: 47)
        .switchDropGlass(radius: 19)
    }

    private var breadcrumb: some View {
        let parts = model.currentDirectory.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Image(systemName: "house").foregroundStyle(Palette.ink)
                Button("SD Card") { Task { await model.openDirectory("/") } }
                ForEach(parts.indices, id: \.self) { index in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.muted)
                    Button(parts[index]) {
                        let path = "/" + parts.prefix(index + 1).joined(separator: "/")
                        Task { await model.openDirectory(path) }
                    }
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.ink)
            .buttonStyle(.plain)
            .padding(.horizontal, 15).padding(.vertical, 14)
        }
        .switchDropGlass(radius: 18)
    }

    private func entryRow(_ entry: SwitchEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.isFolder ? "folder.fill" : icon(for: entry.name))
                .font(.system(size: entry.isFolder ? 29 : 24))
                .foregroundStyle(entry.isFolder ? Palette.violet.opacity(0.7) : Palette.muted)
                .frame(width: 45, height: 45)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if !entry.isFolder {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)) · \(fileKind(entry.name))")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 4)
            if entry.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.ink)
            }
        }
        .folderRowStyle()
    }

    private func icon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".nro") { return "gamecontroller.fill" }
        if lower.hasSuffix(".nsp") || lower.hasSuffix(".xci") { return "shippingbox.fill" }
        if lower.hasSuffix(".ipa") { return "apps.iphone" }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".7z") { return "doc.zipper" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".png") { return "photo" }
        if lower.hasSuffix(".mp3") || lower.hasSuffix(".wav") { return "music.note" }
        return "doc.text"
    }

    private func fileKind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) file"
    }

    private var sendBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: "folder.fill").foregroundStyle(Palette.violet)
                Text("Destination: \(model.currentDirectory)")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 5)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.violet)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 17).padding(.vertical, 13)
            .switchDropGlass(radius: 18, tint: Palette.lavender)
            Button { isImporting = true } label: {
                Label(model.isBusy ? "Sending..." : "Send a file here",
                      systemImage: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .background(Palette.mint.opacity(0.50),
                        in: RoundedRectangle(cornerRadius: 19))
            .switchDropGlass(radius: 19, tint: Palette.mint, interactive: true)
            .disabled(model.isBusy || model.isLoadingDirectory || model.directoryError != nil)
            if model.isBusy {
                ProgressView(value: model.progress).tint(Palette.violet)
                    .accessibilityLabel("Transfer progress")
                Text("\(Int(model.progress * 100))% transferred")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.muted)
            }
            Text(model.status)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(2).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 13)
        .switchDropGlass(radius: 26)
        .padding(.horizontal, 11).padding(.bottom, 6)
    }

    private var pairingWelcome: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 18)
            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(LinearGradient(colors: [Palette.lavender, Palette.mint],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 17) {
                    Image(systemName: "iphone.gen3")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 25, weight: .semibold))
                    Image(systemName: "gamecontroller.fill")
                }
                .font(.system(size: 63, weight: .ultraLight))
                .foregroundStyle(Palette.ink)
            }
            .frame(height: 205)
            VStack(spacing: 9) {
                Text("Your Switch. Your files. ✨")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                Text("Scan the QR code on your Switch, then browse its SD card and pick exactly where to send files.")
                    .font(.system(size: 15, design: .rounded))
                    .multilineTextAlignment(.center).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            Button { isScanning = true } label: {
                Label("Scan Switch QR code", systemImage: "qrcode.viewfinder")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            .buttonStyle(.plain).foregroundStyle(Palette.ink)
            .background(Palette.mint.opacity(0.40), in: RoundedRectangle(cornerRadius: 19))
            .switchDropGlass(radius: 19, tint: Palette.mint, interactive: true)
            .disabled(model.isBusy)
            Text(model.status).font(.footnote)
                .multilineTextAlignment(.center).foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.horizontal, 22)
    }

    private var transferHistory: some View {
        NavigationStack {
            Group {
                if model.recentTransfers.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 44)).foregroundStyle(Palette.violet)
                        Text("No transfers yet")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Text("Successfully sent files will appear here.")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.recentTransfers) { transfer in
                        HStack(spacing: 13) {
                            Image(systemName: icon(for: transfer.name))
                                .font(.system(size: 21))
                                .foregroundStyle(Palette.violet)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(transfer.name)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                Text("\(transfer.destination) · \(ByteCountFormatter.string(fromByteCount: transfer.size, countStyle: .file))")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(transfer.date, style: .date)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Palette.muted)
                        }
                        .listRowBackground(Palette.pale.opacity(0.85))
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Palette.pale.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .navigationTitle("Recent transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isShowingHistory = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SwitchDropGlass: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.65), lineWidth: 1))
        }
    }
}

private extension View {
    func switchDropGlass(radius: CGFloat, tint: Color? = nil,
                         interactive: Bool = false) -> some View {
        modifier(SwitchDropGlass(radius: radius, tint: tint, interactive: interactive))
    }

    func folderRowStyle() -> some View {
        self
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .switchDropGlass(radius: 17)
            .contentShape(RoundedRectangle(cornerRadius: 17))
    }
}
