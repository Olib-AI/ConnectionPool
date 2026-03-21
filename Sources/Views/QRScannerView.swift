// QRScannerView.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

#if os(iOS)
import SwiftUI
@preconcurrency import AVFoundation

/// A SwiftUI view that uses the device camera to scan QR codes.
/// Returns the decoded string via the `onCodeScanned` callback.
public struct QRScannerView: UIViewRepresentable {

    public let onCodeScanned: @MainActor (String) -> Void

    public init(onCodeScanned: @escaping @MainActor (String) -> Void) {
        self.onCodeScanned = onCodeScanned
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
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
        private var hasScanned = false

        init(onCodeScanned: @escaping @MainActor (String) -> Void) {
            self.onCodeScanned = onCodeScanned
            super.init()
        }

        nonisolated public func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = readableObject.stringValue else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self, !self.hasScanned else { return }
                self.hasScanned = true
                self.onCodeScanned(stringValue)
            }
        }

        func resetScanning() {
            hasScanned = false
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
