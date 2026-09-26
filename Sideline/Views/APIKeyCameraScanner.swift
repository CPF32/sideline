import AVFoundation
import SwiftUI
import VisionKit

/// Scans a QR/barcode or on-screen text into a secret field (API keys, ESPN cookies, etc.).
struct APIKeyCameraScanner: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onCancel: () -> Void
    var title: String = "Scan API key"
    var hint: String = "Point at a QR code or the API key text"
    /// When true, OCR auto-accepts only key-shaped strings; barcodes always accept.
    /// Set false for longer cookie values (espn_s2 / SWID).
    var requireAPIKeyShape: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScan: onScan,
            onCancel: onCancel,
            hint: hint,
            requireAPIKeyShape: requireAPIKeyShape
        )
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
            scanner.title = title
            context.coordinator.dataScanner = scanner
            context.coordinator.attachChrome(to: scanner)
            return scanner
        }

        let fallback = APIKeyQRFallbackController()
        fallback.onScan = { context.coordinator.handleRaw($0) }
        fallback.onCancel = onCancel
        fallback.deniedMessage = "Camera access is required to scan. Enable it in Settings."
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
        let hint: String
        let requireAPIKeyShape: Bool
        weak var dataScanner: DataScannerViewController?
        private var didEmit = false

        init(
            onScan: @escaping (String) -> Void,
            onCancel: @escaping () -> Void,
            hint: String,
            requireAPIKeyShape: Bool
        ) {
            self.onScan = onScan
            self.onCancel = onCancel
            self.hint = hint
            self.requireAPIKeyShape = requireAPIKeyShape
        }

        private var confirmContainer: UIView?
        private var confirmValueLabel: UILabel?
        private var pendingValue: String?

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

            let hintLabel = UILabel()
            hintLabel.text = hint
            hintLabel.textColor = .white
            hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
            hintLabel.textAlignment = .center
            hintLabel.numberOfLines = 2
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            scanner.view.addSubview(hintLabel)
            NSLayoutConstraint.activate([
                hintLabel.leadingAnchor.constraint(equalTo: scanner.view.leadingAnchor, constant: 24),
                hintLabel.trailingAnchor.constraint(equalTo: scanner.view.trailingAnchor, constant: -24),
                hintLabel.bottomAnchor.constraint(equalTo: scanner.view.safeAreaLayoutGuide.bottomAnchor, constant: -28)
            ])

            setUpConfirmChrome(in: scanner.view)

            DispatchQueue.main.async {
                try? scanner.startScanning()
            }
        }

        private func setUpConfirmChrome(in parent: UIView) {
            let container = UIView()
            container.backgroundColor = UIColor.black.withAlphaComponent(0.85)
            container.layer.cornerRadius = 14
            container.isHidden = true
            container.translatesAutoresizingMaskIntoConstraints = false

            let promptLabel = UILabel()
            promptLabel.text = "Use this value?"
            promptLabel.textColor = .white
            promptLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            promptLabel.translatesAutoresizingMaskIntoConstraints = false

            let valueLabel = UILabel()
            valueLabel.textColor = .white
            valueLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            valueLabel.numberOfLines = 2
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            confirmValueLabel = valueLabel

            let useButton = UIButton(type: .system)
            useButton.setTitle("Use", for: .normal)
            useButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
            useButton.tintColor = .systemGreen
            useButton.addTarget(self, action: #selector(confirmUseTapped), for: .touchUpInside)
            useButton.translatesAutoresizingMaskIntoConstraints = false

            let rescanButton = UIButton(type: .system)
            rescanButton.setTitle("Keep Scanning", for: .normal)
            rescanButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            rescanButton.tintColor = .white
            rescanButton.addTarget(self, action: #selector(confirmRescanTapped), for: .touchUpInside)
            rescanButton.translatesAutoresizingMaskIntoConstraints = false

            let buttonRow = UIStackView(arrangedSubviews: [rescanButton, useButton])
            buttonRow.axis = .horizontal
            buttonRow.spacing = 16
            buttonRow.distribution = .equalSpacing
            buttonRow.translatesAutoresizingMaskIntoConstraints = false

            let stack = UIStackView(arrangedSubviews: [promptLabel, valueLabel, buttonRow])
            stack.axis = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
            ])

            parent.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 24),
                container.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -24),
                container.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            ])
            confirmContainer = container
        }

        @objc private func cancelTapped() {
            try? dataScanner?.stopScanning()
            onCancel()
        }

        @objc private func confirmUseTapped() {
            guard let value = pendingValue else { return }
            didEmit = true
            confirmContainer?.isHidden = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? dataScanner?.stopScanning()
            onScan(value)
        }

        @objc private func confirmRescanTapped() {
            pendingValue = nil
            confirmContainer?.isHidden = true
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            switch item {
            case .barcode(let barcode):
                if let value = barcode.payloadStringValue {
                    presentCandidate(value)
                }
            case .text(let text):
                presentCandidate(text.transcript)
            @unknown default:
                break
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didEmit, pendingValue == nil else { return }
            for item in addedItems {
                switch item {
                case .barcode(let barcode):
                    if let value = barcode.payloadStringValue {
                        presentCandidate(value)
                        return
                    }
                case .text(let text):
                    let cleaned = Self.sanitize(text.transcript)
                    // Surface a key/cookie-shaped candidate for the user to confirm, rather
                    // than committing it immediately — live OCR fires many times a second and
                    // can otherwise lock onto the wrong on-screen text.
                    if shouldAutoAccept(cleaned) {
                        presentCandidate(cleaned)
                        return
                    }
                @unknown default:
                    break
                }
            }
        }

        /// Surfaces a detected value for explicit user confirmation instead of accepting it outright.
        private func presentCandidate(_ raw: String) {
            guard !didEmit else { return }
            let cleaned = Self.sanitize(raw)
            guard !cleaned.isEmpty else { return }
            pendingValue = cleaned
            confirmValueLabel?.text = cleaned
            confirmContainer?.isHidden = false
            UISelectionFeedbackGenerator().selectionChanged()
        }

        /// Used by the QR fallback path (no live highlighting UI), where tap-to-confirm isn't
        /// available, so the scanned value is accepted directly.
        func handleRaw(_ raw: String) {
            guard !didEmit else { return }
            let cleaned = Self.sanitize(raw)
            guard !cleaned.isEmpty else { return }
            didEmit = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? dataScanner?.stopScanning()
            onScan(cleaned)
        }

        private func shouldAutoAccept(_ value: String) -> Bool {
            if requireAPIKeyShape {
                return Self.looksLikeAPIKey(value)
            }
            return Self.looksLikeCookieOrSecret(value)
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

        /// ESPN cookies / pasted cookie headers — longer, may include `%`, `{}`, `;`, `=`.
        static func looksLikeCookieOrSecret(_ value: String) -> Bool {
            guard value.count >= 8 else { return false }
            if value.localizedCaseInsensitiveContains("espn_s2")
                || value.localizedCaseInsensitiveContains("SWID") {
                return true
            }
            // Braced UUID (SWID) or long opaque cookie token.
            if value.hasPrefix("{"), value.hasSuffix("}"), value.count >= 36 { return true }
            guard value.count >= 20 else { return false }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.=+/%{};:"))
            return value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

// MARK: - QR fallback (devices without DataScanner)

private final class APIKeyQRFallbackController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var deniedMessage = "Camera access is required to scan an API key. Enable it in Settings."

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
        label.text = deniedMessage
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
