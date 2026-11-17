import SwiftUI
import UniformTypeIdentifiers

private enum Palette {
    static let ink = Color(red: 0.18, green: 0.16, blue: 0.30)
    static let violet = Color(red: 0.65, green: 0.48, blue: 0.94)
    static let lavender = Color(red: 0.91, green: 0.85, blue: 1.00)
    static let mint = Color(red: 0.65, green: 0.97, blue: 0.82)
    static let pale = Color(red: 0.97, green: 0.96, blue: 1.00)
    static let muted = Color(red: 0.48, green: 0.45, blue: 0.56)
}

struct ContentView: View {
    @EnvironmentObject private var model: DropModel
    @State private var isScanning = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.lavender.opacity(0.80), Palette.pale,
                                    Color(red: 0.89, green: 0.99, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
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
        .task {
            if model.link != nil { await model.refreshDirectory() }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 47, height: 47)
                .background(LinearGradient(colors: [Palette.violet, Palette.lavender],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14))
            Text("SwitchDrop")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .tracking(-1.2)
                .foregroundStyle(Palette.ink)
            Spacer()
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
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("SwitchDrop options")
        }
        .padding(.horizontal, 22)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    private var connectedBrowser: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Circle().fill(Color.green).frame(width: 10, height: 10)
                Text("Connected to your Switch")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "wifi")
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Palette.mint, in: Capsule())
            .padding(.horizontal, 22)

            breadcrumb.padding(.horizontal, 22)

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
                    ForEach(model.entries) { entry in
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
                    } else if model.entries.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "folder")
                                .font(.system(size: 45)).foregroundStyle(Palette.violet)
                            Text("Empty folder").font(.headline)
                            Text("You can still send files here.").font(.subheadline)
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
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
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
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size),
                                                   countStyle: .file))
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
        if lower.hasSuffix(".zip") || lower.hasSuffix(".7z") { return "doc.zipper" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".png") { return "photo" }
        if lower.hasSuffix(".mp3") || lower.hasSuffix(".wav") { return "music.note" }
        return "doc.text"
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
            .background(Palette.lavender.opacity(0.65),
                        in: RoundedRectangle(cornerRadius: 18))
            Button { isImporting = true } label: {
                Label(model.isBusy ? "Sending..." : "Send a file here",
                      systemImage: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .background(Palette.mint, in: RoundedRectangle(cornerRadius: 19))
            .disabled(model.isBusy || model.isLoadingDirectory || model.directoryError != nil)
            if model.isBusy { ProgressView(value: model.progress).tint(Palette.violet) }
            Text(model.status)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(2).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .background(.regularMaterial)
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
            .background(Palette.mint, in: RoundedRectangle(cornerRadius: 19))
            .disabled(model.isBusy)
            Text(model.status).font(.footnote)
                .multilineTextAlignment(.center).foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.horizontal, 22)
    }
}

private extension View {
    func folderRowStyle() -> some View {
        self
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.86),
                        in: RoundedRectangle(cornerRadius: 17))
            .contentShape(RoundedRectangle(cornerRadius: 17))
    }
}
