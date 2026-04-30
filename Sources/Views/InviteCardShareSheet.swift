// InviteCardShareSheet.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// Host-side share sheet: shows a QR + "Send invite card" button. Tapping
/// the button surfaces iOS's native share sheet with a `.stcard` file
/// attachment for iMessage / AirDrop / Mail.
public struct InviteCardShareSheet: View {

    @ObservedObject var viewModel: ConnectionPoolViewModel
    let invitation: RemoteInvitation

    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var qrImage: CGImage?
    @State private var error: String?

    public init(viewModel: ConnectionPoolViewModel, invitation: RemoteInvitation) {
        self.viewModel = viewModel
        self.invitation = invitation
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let cg = qrImage {
                        #if canImport(CoreImage)
                        Image(decorative: cg, scale: 1.0)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        #endif
                    }

                    Text("Invite Card")
                        .font(.headline)

                    if let url = fileURL {
                        ShareLink(
                            item: url,
                            subject: Text("StealthOS Invite Card"),
                            message: Text("Open this in StealthOS to join my pool.")
                        ) {
                            Label("Send invite card", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.purple)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    if !invitation.isExpired {
                        Text("Expires \(invitation.expiresAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Expired").font(.caption).foregroundStyle(.red)
                    }

                    DisclosureGroup("Help your friend open it") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("In Messages they tap and hold the file → Share → StealthOS.")
                            Text("Or save it to Files and open it from inside StealthOS.")
                            Text("Or scan the QR code from inside StealthOS.")
                        }
                        .font(.callout)
                        .padding(.vertical, 6)
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Invite a Friend")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { build() }
        }
    }

    @MainActor
    private func build() {
        do {
            fileURL = try viewModel.remotePoolService.packageInvitationCard(invitation: invitation)
            #if canImport(CoreImage)
            let bytes = try viewModel.remotePoolService.packageInvitationCardBytes(invitation: invitation)
            qrImage = Self.qrCode(from: bytes, size: 240)
            #endif
            error = nil
        } catch let err as RemotePoolService.CardPackagingError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    #if canImport(CoreImage)
    private static func qrCode(from bytes: Data, size: CGFloat) -> CGImage? {
        // Encode as text-mode QR using a base64 wrapper. Text-mode QRs
        // round-trip reliably through AVFoundation's `stringValue`, which
        // is far more dependable across iOS versions than parsing the raw
        // byte-mode codeword stream from `CIQRCodeDescriptor`.
        let payload = SealedInviteCard.encodeForQRText(bytes)
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(
            scaleX: size / out.extent.size.width,
            y: size / out.extent.size.height
        ))
        return context.createCGImage(scaled, from: scaled.extent)
    }
    #endif
}
