import SwiftUI
import UniformTypeIdentifiers

private enum DropStyle {
    static let ink = Color(red: 0.18, green: 0.19, blue: 0.32)
    static let violet = Color(red: 0.68, green: 0.63, blue: 0.94)
    static let mint = Color(red: 0.73, green: 0.91, blue: 0.83)
    static let cream = Color(red: 0.97, green: 0.96, blue: 0.99)
}

struct ContentView: View {
    @EnvironmentObject private var model: DropModel
    @State private var isScanning = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            DropStyle.cream.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    title
                    previewCard
                    if let link = model.link {
                        connectedCard(host: link.host)
                    } else {
                        unpairedCard
                    }
                    VStack(spacing: 12) {
                        Button {
                            if model.link == nil { isScanning = true }
                            else { isImporting = true }
                        } label: {
                            Label(model.link == nil ? "Scan Switch QR code" : "Send files to Switch",
                                  systemImage: model.link == nil ? "qrcode.viewfinder" : "square.and.arrow.up")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 19)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DropStyle.ink)
                        .background(DropStyle.mint, in: RoundedRectangle(cornerRadius: 20))
                        .disabled(model.isBusy)

                        if model.link != nil {
                            Button("Pair a different Switch") { isScanning = true }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DropStyle.ink.opacity(0.7))
                                .padding(.top, 7)
                        }
                    }
                    statusCard
                    if model.link != nil {
                        Button("Forget this Switch", role: .destructive) { model.forget() }
                            .font(.footnote)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 30)
                .padding(.bottom, 60)
            }
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
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.send(urls) }
            case .failure(let error): model.status = error.localizedDescription
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.up.right.and.arrow.down.left")
                    .font(.title3.bold())
                    .frame(width: 49, height: 49)
                    .background(DropStyle.violet.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                Text("SwitchDrop")
                    .font(.system(size: 35, weight: .heavy, design: .rounded))
                    .tracking(-1.2)
            }
            Text("Your stuff, straight to your Switch.")
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(DropStyle.ink.opacity(0.68))
        }
        .foregroundStyle(DropStyle.ink)
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(LinearGradient(colors: [Color(red: 0.84, green: 0.79, blue: 0.99),
                                             Color(red: 0.82, green: 0.94, blue: 0.89)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 19) {
                HStack(spacing: 18) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 73, weight: .ultraLight))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 28, weight: .medium))
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 67, weight: .regular))
                }
                Text("DROP IT. PLAY IT. KEEP IT.")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(2)
            }
            .foregroundStyle(DropStyle.ink)
        }
        .frame(height: 235)
    }

    private var unpairedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let's connect ✨")
                .font(.system(size: 23, weight: .bold, design: .rounded))
            Text("1. Open SwitchDrop from the Homebrew Menu.\n2. Connect your iPhone and Switch to the same Wi-Fi.\n3. Scan the QR code on your Switch.")
                .font(.system(size: 15, design: .rounded))
                .lineSpacing(6)
                .foregroundStyle(DropStyle.ink.opacity(0.72))
        }
        .foregroundStyle(DropStyle.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectedCard(host: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 29))
                .foregroundStyle(Color(red: 0.24, green: 0.58, blue: 0.43))
            VStack(alignment: .leading, spacing: 4) {
                Text("Paired Switch")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("\(host)  ·  Local Wi-Fi")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(DropStyle.ink.opacity(0.58))
            }
            Spacer()
        }
        .foregroundStyle(DropStyle.ink)
        .padding(19)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STATUS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(DropStyle.ink.opacity(0.45))
            Text(model.status)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DropStyle.ink)
            if model.isBusy {
                ProgressView(value: model.progress)
                    .tint(DropStyle.violet)
            }
            if model.link != nil {
                Label("Shared files go to /switch/switchdrop/inbox", systemImage: "folder")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(DropStyle.ink.opacity(0.56))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
    }
}
