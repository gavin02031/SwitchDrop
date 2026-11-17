import UIKit
import UniformTypeIdentifiers

/// Native Share Sheet target. The full app writes the QR pairing to an App Group.
final class ShareViewController: UIViewController {
    private let heading = UILabel()
    private let details = UILabel()
    private let button = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .default)
    private var sending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.97, green: 0.96, blue: 0.99, alpha: 1)
        heading.text = "SwitchDrop ✨"
        heading.font = .systemFont(ofSize: 28, weight: .heavy, design: .rounded)
        heading.textColor = UIColor(red: 0.18, green: 0.19, blue: 0.32, alpha: 1)
        details.text = PairingStore.load(sharedOnly: true) == nil
            ? "Open SwitchDrop and scan your Switch QR code first."
            : "Your files will go straight to your paired Switch."
        details.font = .systemFont(ofSize: 15, weight: .medium, design: .rounded)
        details.numberOfLines = 0
        details.textColor = UIColor(red: 0.35, green: 0.36, blue: 0.45, alpha: 1)
        button.setTitle("Send to Switch", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold, design: .rounded)
        button.backgroundColor = UIColor(red: 0.73, green: 0.91, blue: 0.83, alpha: 1)
        button.setTitleColor(UIColor(red: 0.18, green: 0.19, blue: 0.32, alpha: 1), for: .normal)
        button.layer.cornerRadius = 16
        button.isEnabled = PairingStore.load(sharedOnly: true) != nil
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        progress.progressTintColor = UIColor(red: 0.68, green: 0.63, blue: 0.94, alpha: 1)

        let stack = UIStackView(arrangedSubviews: [heading, details, progress, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 25),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -25),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    @objc private func sendTapped() {
        guard !sending, let link = PairingStore.load(sharedOnly: true) else { return }
        sending = true
        button.isEnabled = false
        details.text = "Preparing files..."
        Task {
            do {
                try await DropTransport.verify(link)
                let files = try await attachments()
                guard !files.isEmpty else {
                    throw NSError(domain: "SwitchDrop", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "No supported files were shared."])
                }
                defer { for file in files { try? FileManager.default.removeItem(at: file.url) } }
                for (index, file) in files.enumerated() {
                    details.text = "Sending \(file.name) (\(index + 1) of \(files.count))"
                    progress.progress = 0
                    let tracker = UploadProgress { [weak self] fraction in
                        DispatchQueue.main.async { self?.progress.progress = Float(fraction) }
                    }
                    try await DropTransport.send(file.url, filename: file.name,
                                                 to: link, delegate: tracker)
                }
                details.text = "Sent successfully!"
                progress.progress = 1
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                details.text = "Transfer failed: \(error.localizedDescription)"
                sending = false
                button.isEnabled = true
            }
        }
    }

    private struct SharedFile { let url: URL; let name: String }

    private func attachments() async throws -> [SharedFile] {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        var result: [SharedFile] = []
        for provider in providers.prefix(10) {
            guard let id = provider.registeredTypeIdentifiers.first(where: {
                guard let type = UTType($0) else { return false }
                return type.conforms(to: .data) || type.conforms(to: .content)
            }) else { continue }
            let local = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SharedFile, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: id) { url, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let url else {
                        continuation.resume(throwing: DropLinkError.invalidResponse)
                        return
                    }
                    let fileType = UTType(id)
                    let originalName = (provider.suggestedName ?? url.lastPathComponent)
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "\\", with: "_")
                    let ext = fileType?.preferredFilenameExtension ?? "bin"
                    let name = originalName.contains(".") ? originalName : "\(originalName).\(ext)"
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "-" + name)
                    do {
                        try FileManager.default.copyItem(at: url, to: copy)
                        continuation.resume(returning: SharedFile(url: copy, name: name))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            result.append(local)
        }
        return result
    }
}
