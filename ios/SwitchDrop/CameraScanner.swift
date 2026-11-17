import AVFoundation
import SwiftUI
import UIKit

struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private var hasScanned = false
    private let hint = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        hint.text = "Point your camera at the Switch QR code"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hint.layer.cornerRadius = 14
        hint.clipsToBounds = true
        view.addSubview(hint)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { self.setup() }
                    else { self.hint.text = "Enable camera access in Settings" } }
            }
        default: hint.text = "Enable camera access in Settings"
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
        hint.frame = CGRect(x: 24, y: view.bounds.height - 155,
                            width: view.bounds.width - 48, height: 62)
    }

    private func setup() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { hint.text = "Camera unavailable"; return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasScanned,
              let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = first.stringValue else { return }
        hasScanned = true
        onCode?(value)
    }
}
