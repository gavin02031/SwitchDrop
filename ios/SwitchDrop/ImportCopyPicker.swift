import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Import a private copy instead of opening an iCloud/File Provider URL in place.
/// This gives URLSession a readable local file once the Files picker finishes
/// downloading it, including unfamiliar homebrew extensions such as .nro.
struct ImportCopyPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item],
                                                    asCopy: true)
        // Single selection opens immediately when a file is tapped. On some
        // iOS Files versions, the multi-select picker’s blue "Open" confirmation
        // button can fail to complete even for local .nro/.ipa documents.
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
