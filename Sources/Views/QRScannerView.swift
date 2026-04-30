// QRScannerView.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

#if os(iOS)
import SwiftUI
@preconcurrency import AVFoundation

/// A SwiftUI view that uses the device camera to scan QR codes.
///
/// `onCodeScanned` fires with the textual interpretation when present (used
/// for legacy claim codes / invitation URLs), and `onBytesScanned` fires with
/// the raw error-corrected payload bytes from the QR descriptor (required for
/// binary `.stcard` invitation QRs whose bytes are not valid UTF-8).
public struct QRScannerView: UIViewRepresentable {

    public let onCodeScanned: @MainActor (String) -> Void
    public let onBytesScanned: (@MainActor (Data) -> Void)?

    public init(
        onCodeScanned: @escaping @MainActor (String) -> Void,
        onBytesScanned: (@MainActor (Data) -> Void)? = nil
    ) {
        self.onCodeScanned = onCodeScanned
        self.onBytesScanned = onBytesScanned
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onBytesScanned: onBytesScanned)
    }

    public func makeUIView(context: Context) -> QRScannerUIView {
        let view = QRScannerUIView(coordinator: context.coordinator)
        return view
    }

    public func updateUIView(_ uiView: QRScannerUIView, context: Context) {
        // No dynamic updates needed
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCodeScanned: @MainActor (String) -> Void
        private let onBytesScanned: (@MainActor (Data) -> Void)?
        private var hasScanned = false

        init(
            onCodeScanned: @escaping @MainActor (String) -> Void,
            onBytesScanned: (@MainActor (Data) -> Void)?
        ) {
            self.onCodeScanned = onCodeScanned
            self.onBytesScanned = onBytesScanned
            super.init()
        }

        nonisolated public func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject else {
                return
            }
            let stringValue = readableObject.stringValue
            // Binary QR content (`.stcard` cards) doesn't survive
            // `stringValue` UTF-8 decoding, so we walk the QR codewords
            // directly. Try multiple strategies and accept whichever
            // produces bytes that look like an invite card.
            var bytes: Data?
            if let qr = readableObject.descriptor as? CIQRCodeDescriptor {
                bytes = Self.decodeQRByteMode(qr.errorCorrectedPayload, symbolVersion: qr.symbolVersion)
            }
            if bytes == nil, let s = stringValue {
                // AVFoundation occasionally falls back to ISO Latin-1 for
                // byte-mode QRs (each byte → one Unicode scalar in 0x00–0xFF).
                // Re-encoding as Latin-1 reverses that lossy view.
                bytes = s.data(using: .isoLatin1)
            }

            Task { @MainActor [weak self] in
                guard let self, !self.hasScanned else { return }
                self.hasScanned = true
                // Prefer the string interpretation when AVFoundation provides
                // it — covers our text-mode invite QRs (`stcard1:base64…`)
                // and legacy URL/claim-code QRs. Only fall back to raw bytes
                // when there is no usable string (true binary QR).
                if let stringValue, !stringValue.isEmpty {
                    self.onCodeScanned(stringValue)
                    return
                }
                if let bytes, let onBytes = self.onBytesScanned {
                    onBytes(bytes)
                }
            }
        }

        func resetScanning() {
            hasScanned = false
        }

        /// Decode a QR error-corrected codeword stream as a single byte-mode
        /// segment (possibly preceded by an ECI segment). Returns the raw
        /// payload bytes for the first byte-mode segment.
        ///
        /// ISO/IEC 18004 mode chain:
        /// - 0x7 (ECI): 4-bit mode + variable-length ECI designator (most
        ///   often 8 bits).
        /// - 0x4 (Byte): 4-bit mode + 8-bit (versions 1–9) or 16-bit
        ///   (versions 10–40) character count + data bytes.
        nonisolated static func decodeQRByteMode(_ codewords: Data, symbolVersion: Int) -> Data? {
            let bits = BitReader(data: codewords)
            // Walk through up to 4 leading segments looking for byte mode —
            // covers ECI, structured-append headers, and chained segments.
            for _ in 0..<4 {
                guard let mode = bits.read(4) else { return nil }
                if mode == 0x4 { break }
                if mode == 0x7 {
                    // ECI designator: 1, 2, or 3 byte form indicated by leading 1 bits.
                    guard let first = bits.read(8) else { return nil }
                    if first & 0x80 == 0 {
                        // single-byte ECI, value is the 7 lower bits — we just
                        // skipped the right amount, continue reading next mode.
                        continue
                    } else if first & 0xC0 == 0x80 {
                        // 2-byte ECI: 14 trailing bits of value. We read 8 already, read 6 more.
                        guard bits.read(6) != nil else { return nil }
                        continue
                    } else {
                        // 3-byte ECI: 21 trailing bits, we read 8, read 13 more.
                        guard bits.read(13) != nil else { return nil }
                        continue
                    }
                }
                if mode == 0x3 {
                    // Structured-append header: 4 bits + 4 bits + 8 bits parity.
                    guard bits.read(16) != nil else { return nil }
                    continue
                }
                // Unknown / unsupported leading mode — abort.
                return nil
            }
            let lengthBits = symbolVersion < 10 ? 8 : 16
            guard let length = bits.read(lengthBits), length > 0 else { return nil }
            var out = Data(capacity: length)
            for _ in 0..<length {
                guard let byte = bits.read(8) else { return nil }
                out.append(UInt8(byte))
            }
            return out
        }
    }

    // MARK: - Bit Reader

    private final class BitReader {
        private let data: Data
        private var bitOffset = 0

        init(data: Data) { self.data = data }

        /// Read up to 24 bits MSB-first as an unsigned integer.
        func read(_ n: Int) -> Int? {
            guard n > 0 && n <= 24 else { return nil }
            if bitOffset + n > data.count * 8 { return nil }
            var v = 0
            for _ in 0..<n {
                let byte = data[data.startIndex + bitOffset / 8]
                let bit = (Int(byte) >> (7 - bitOffset % 8)) & 1
                v = (v << 1) | bit
                bitOffset += 1
            }
            return v
        }
    }

    // MARK: - UIView

    public final class QRScannerUIView: UIView {
        private var captureSession: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private let coordinator: Coordinator

        private let overlayColor = UIColor.black.withAlphaComponent(0.4)

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            backgroundColor = .black
            checkPermissionsAndSetup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Not implemented")
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
            updateOverlay()
        }

        // MARK: - Camera Setup

        private func checkPermissionsAndSetup() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                setupCaptureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    if granted {
                        DispatchQueue.main.async {
                            self?.setupCaptureSession()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self?.showPermissionDeniedMessage()
                        }
                    }
                }
            case .denied, .restricted:
                showPermissionDeniedMessage()
            @unknown default:
                showPermissionDeniedMessage()
            }
        }

        private func setupCaptureSession() {
            let session = AVCaptureSession()
            session.sessionPreset = .high

            guard let videoCaptureDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                showUnavailableMessage()
                return
            }

            let videoInput: AVCaptureDeviceInput
            do {
                videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            } catch {
                showUnavailableMessage()
                return
            }

            guard session.canAddInput(videoInput) else {
                showUnavailableMessage()
                return
            }
            session.addInput(videoInput)

            let metadataOutput = AVCaptureMetadataOutput()
            guard session.canAddOutput(metadataOutput) else {
                showUnavailableMessage()
                return
            }
            session.addOutput(metadataOutput)

            metadataOutput.setMetadataObjectsDelegate(coordinator, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = bounds
            layer.insertSublayer(preview, at: 0)
            previewLayer = preview

            captureSession = session

            // Start on a background queue to avoid blocking main thread
            DispatchQueue.global(qos: .userInitiated).async { [weak session] in
                session?.startRunning()
            }

            addScanOverlay()
        }

        // MARK: - Overlay

        private var overlayLayer: CAShapeLayer?
        private var borderLayer: CAShapeLayer?

        private func addScanOverlay() {
            let overlay = CAShapeLayer()
            overlay.fillColor = overlayColor.cgColor
            overlay.fillRule = .evenOdd
            layer.addSublayer(overlay)
            overlayLayer = overlay

            let border = CAShapeLayer()
            border.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            border.fillColor = UIColor.clear.cgColor
            border.lineWidth = 2
            border.lineDashPattern = [10, 6]
            layer.addSublayer(border)
            borderLayer = border

            updateOverlay()
        }

        private func updateOverlay() {
            guard bounds.width > 0, bounds.height > 0 else { return }

            let side = min(bounds.width, bounds.height) * 0.7
            let scanRect = CGRect(
                x: (bounds.width - side) / 2,
                y: (bounds.height - side) / 2,
                width: side,
                height: side
            )

            let fullPath = UIBezierPath(rect: bounds)
            let cutoutPath = UIBezierPath(roundedRect: scanRect, cornerRadius: 12)
            fullPath.append(cutoutPath)

            overlayLayer?.path = fullPath.cgPath
            borderLayer?.path = cutoutPath.cgPath
        }

        // MARK: - Fallback Messages

        private func showPermissionDeniedMessage() {
            showFallbackLabel(
                "Camera access denied.\nGo to Settings > Privacy > Camera\nto enable access."
            )
        }

        private func showUnavailableMessage() {
            showFallbackLabel("Camera is not available on this device.")
        }

        private func showFallbackLabel(_ text: String) {
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            ])
        }

        // MARK: - Cleanup

        deinit {
            let session = captureSession
            DispatchQueue.global(qos: .background).async {
                session?.stopRunning()
            }
        }
    }
}
#endif
