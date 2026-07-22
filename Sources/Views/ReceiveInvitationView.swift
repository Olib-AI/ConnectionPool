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
    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var openError: String?
    @State private var isPickingFile = false
    @State private var isScanningQR = false

    public init(viewModel: ConnectionPoolViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacingL) {
                    VStack(alignment: .leading, spacing: theme.spacingXS + 2) {
                        PoolText("connectionpool.receive.title", fallback: "Receive an Invitation")
                            .font(theme.fontHeading)
                            .foregroundColor(theme.textPrimary)
                        PoolText("connectionpool.receive.subtitle", fallback: "Open the invite card your friend sent you. The file ends in .stcard and arrives via Messages, AirDrop, Mail, or Files.")
                            .font(theme.fontBody)
                            .foregroundColor(theme.textSecondary)
                    }

                    #if canImport(UIKit)
                    Button {
                        isPickingFile = true
                    } label: {
                        HStack(spacing: theme.spacingS) {
                            PoolIcon("folder-open", size: 16, systemFallback: "folder")
                            PoolText("connectionpool.receive.openFromFiles", fallback: "Open invite card from Files")
                        }
                        .font(theme.fontBody)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, theme.spacingM)
                        .background(theme.accent)
                        .foregroundColor(theme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                    }

                    Button {
                        isScanningQR = true
                    } label: {
                        HStack(spacing: theme.spacingS) {
                            PoolIcon("qrcode", size: 16, systemFallback: "qrcode.viewfinder")
                            PoolText("connectionpool.receive.scanQR", fallback: "Scan invite QR code")
                        }
                        .font(theme.fontBody)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, theme.spacingM)
                        .foregroundColor(theme.accent)
                        .background(theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                                .strokeBorder(theme.border, lineWidth: 1)
                        )
                    }

                    PoolText("connectionpool.receive.tip", fallback: "Tip: in Messages, tap and hold the file → Share → StealthOS. Or have the host show the QR.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.textSecondary)
                    #endif

                    if let openError {
                        HStack(spacing: theme.spacingS) {
                            PoolIcon("triangle-exclamation", size: 14, systemFallback: "exclamationmark.triangle.fill")
                            Text(openError)
                        }
                        .font(theme.fontBody)
                        .foregroundColor(theme.danger)
                    }
                }
                .padding(theme.spacingL)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(poolString("connectionpool.receive.navTitle", fallback: "Receive Invitation"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.done", fallback: "Done")) { dismiss() }
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
                        openError = poolString("connectionpool.receive.badQR", fallback: "That QR code isn't a StealthOS invite card.")
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
                    // White-on-scrim over the live camera (functional overlay).
                    PoolText("connectionpool.qr.pointAtHost", fallback: "Point at the host's invite QR")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle(poolString("connectionpool.qr.scanInvite", fallback: "Scan Invite"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.cancel", fallback: "Cancel"), action: onCancel)
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
