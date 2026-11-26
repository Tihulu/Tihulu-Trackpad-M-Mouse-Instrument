#if os(iOS)
import SwiftUI
import VisionKit

/// The scanner returns text to the address field. Only the pairing button opens a connection.
@MainActor struct MobileAddressScanner: UIViewControllerRepresentable {
    let onResult: (String?) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(onResult: onResult) }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    final class Controller: UIViewController, DataScannerViewControllerDelegate {
        private var onResult: ((String?) -> Void)?
        private var scanner: DataScannerViewController?

        init(onResult: @escaping (String?) -> Void) {
            self.onResult = onResult
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(onResult:)") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard scanner == nil, onResult != nil else { return }
            guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
                finish(nil)
                return
            }
            let child = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false)
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(child.view)
            child.didMove(toParent: self)
            child.delegate = self
            scanner = child
            do { try child.startScanning() } catch { finish(nil) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard dataScanner === scanner else { return }
            for case .barcode(let code) in addedItems {
                if let text = code.payloadStringValue { finish(text); return }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            if dataScanner === scanner { finish(nil) }
        }

        private func finish(_ value: String?) {
            let result = onResult
            stop()
            result?(value)
        }

        func stop() {
            onResult = nil
            scanner?.delegate = nil
            scanner?.stopScanning()
        }
    }
}
#endif
