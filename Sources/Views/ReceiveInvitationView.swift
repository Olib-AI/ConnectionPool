// ReceiveInvitationView.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Friend-side flow: tap "Open invite card from Files" to pick a `.stcard`
/// the host shared via iMessage / AirDrop / Mail. The viewmodel handles the
/// rest of the join flow.
public struct ReceiveInvitationView: View {

    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var openError: String?
    @State private var isPickingFile = false
    @State private var isScanningQR = false

    public init(viewModel: ConnectionPoolViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Receive an Invitation")
                            .font(.headline)
                        Text("Open the invite card your friend sent you. The file ends in .stcard and arrives via Messages, AirDrop, Mail, or Files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    #if canImport(UIKit)
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Open invite card from Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        isScanningQR = true
                    } label: {
                        Label("Scan invite QR code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Text("Tip: in Messages, tap and hold the file → Share → StealthOS. Or have the host show the QR.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif

                    if let openError {
                        Label(openError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Receive Invitation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $isPickingFile) {
            CardDocumentPicker { url in
                isPickingFile = false
                Task { await openCardFile(at: url) }
            } onCancel: {
                isPickingFile = false
            }
        }
        .sheet(isPresented: $isScanningQR) {
            QRInviteScanSheet(
                onText: { text in
                    isScanningQR = false
                    if let bytes = SealedInviteCard.decodeFromQRText(text) {
                        Task { await openCardBytes(bytes) }
                    } else {
                        openError = "That QR code isn't a StealthOS invite card."
                    }
                },
                onBytes: { bytes in
                    isScanningQR = false
                    Task { await openCardBytes(bytes) }
                },
                onCancel: { isScanningQR = false }
            )
        }
        #endif
    }

    @MainActor
    private func openCardBytes(_ bytes: Data) async {
        do {
            try await viewModel.handleIncomingInviteCard(bytes: bytes)
            openError = nil
            dismiss()
        } catch {
            openError = error.localizedDescription
        }
    }

    @MainActor
    private func openCardFile(at url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try await viewModel.handleIncomingInviteCard(bytes: data)
            openError = nil
            dismiss()
        } catch {
            openError = error.localizedDescription
        }
    }
}

#if canImport(UIKit)
private struct QRInviteScanSheet: View {
    let onText: (String) -> Void
    let onBytes: (Data) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(
                    onCodeScanned: { text in onText(text) },
                    onBytesScanned: { bytes in onBytes(bytes) }
                )
                .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Point at the host's invite QR")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Scan Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct CardDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let utType = UTType(SealedInviteCard.utiIdentifier) ?? UTType.data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [utType])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: CardDocumentPicker
        init(_ parent: CardDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) } else { parent.onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
#endif
