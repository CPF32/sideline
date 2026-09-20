import AVFoundation
import SwiftUI
import VisionKit

/// Scans a QR/barcode or on-screen text into an API key field.
struct APIKeyCameraScanner: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [
                    .barcode(symbologies: [.qr, .aztec, .pdf417, .dataMatrix]),
                    .text()
                ],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            scanner.title = "Scan API key"
            context.coordinator.dataScanner = scanner
            context.coordinator.attachChrome(to: scanner)
            return scanner
        }

        let fallback = APIKeyQRFallbackController()
        fallback.onScan = { context.coordinator.handleRaw($0) }
        fallback.onCancel = onCancel
        return fallback
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        if let scanner = uiViewController as? DataScannerViewController, scanner.isScanning {
            try? scanner.stopScanning()
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let onCancel: () -> Void
        weak var dataScanner: DataScannerViewController?
        private var didEmit = false

        init(onScan: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func attachChrome(to scanner: DataScannerViewController) {
            let cancel = UIButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            cancel.tintColor = .white
            cancel.translatesAutoresizingMaskIntoConstraints = false
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            scanner.view.addSubview(cancel)
            NSLayoutConstraint.activate([
                cancel.topAnchor.constraint(equalTo: scanner.view.safeAreaLayoutGuide.topAnchor, constant: 12),
                cancel.trailingAnchor.constraint(equalTo: scanner.view.trailingAnchor, constant: -20)
            ])

            let hint = UILabel()
            hint.text = "Point at a QR code or the API key text"
            hint.textColor = .white
            hint.font = .systemFont(ofSize: 14, weight: .medium)
            hint.textAlignment = .center
            hint.translatesAutoresizingMaskIntoConstraints = false
            scanner.view.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.leadingAnchor.constraint(equalTo: scanner.view.leadingAnchor, constant: 24),
                hint.trailingAnchor.constraint(equalTo: scanner.view.trailingAnchor, constant: -24),
                hint.bottomAnchor.constraint(equalTo: scanner.view.safeAreaLayoutGuide.bottomAnchor, constant: -28)
            ])

            DispatchQueue.main.async {
                try? scanner.startScanning()
            }
        }

        @objc private func cancelTapped() {
            try? dataScanner?.stopScanning()
            onCancel()
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            switch item {
            case .barcode(let barcode):
                if let value = barcode.payloadStringValue {
                    handleRaw(value)
                }
            case .text(let text):
                handleRaw(text.transcript)
            @unknown default:
                break
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didEmit else { return }
            for item in addedItems {
                switch item {
                case .barcode(let barcode):
                    if let value = barcode.payloadStringValue {
                        handleRaw(value)
                        return
                    }
                case .text(let text):
                    let cleaned = Self.sanitize(text.transcript)
                    // Prefer barcode auto-accept; for text wait for a key-like string.
                    if Self.looksLikeAPIKey(cleaned) {
                        handleRaw(cleaned)
                        return
                    }
                @unknown default:
                    break
                }
            }
        }

        func handleRaw(_ raw: String) {
            guard !didEmit else { return }
            let cleaned = Self.sanitize(raw)
            guard !cleaned.isEmpty else { return }
            didEmit = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? dataScanner?.stopScanning()
            onScan(cleaned)
        }

        static func sanitize(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\u{00a0}", with: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        }

        static func looksLikeAPIKey(_ value: String) -> Bool {
            guard value.count >= 16 else { return false }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.=+/"))
            return value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

// MARK: - QR fallback (devices without DataScanner)

private final class APIKeyQRFallbackController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addCancelButton()
        requestCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func addCancelButton() {
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.tintColor = .white
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setupSession() }
                    else { self?.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    private func setupSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showDenied()
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            showDenied()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr, .aztec, .pdf417, .dataMatrix]
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func showDenied() {
        let label = UILabel()
        label.text = "Camera access is required to scan an API key. Enable it in Settings."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty else { return }
        didScan = true
        session.stopRunning()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(APIKeyCameraScanner.Coordinator.sanitize(value))
    }
}
