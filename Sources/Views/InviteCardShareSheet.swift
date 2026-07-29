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
    @ObservedObject private var design = PoolDesign.shared
    let invitation: RemoteInvitation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var fileURL: URL?
    @State private var qrImage: CGImage?
    @State private var error: String?

    public init(viewModel: ConnectionPoolViewModel, invitation: RemoteInvitation) {
        self.viewModel = viewModel
        self.invitation = invitation
    }

    public var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            ScrollView {
                VStack(spacing: theme.spacingL) {
                    if let cg = qrImage {
                        #if canImport(CoreImage)
                        // QR code renders on a white plate for reliable scanning
                        // regardless of theme (functional, not chrome).
                        Image(decorative: cg, scale: 1.0)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(theme.spacingM)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        #endif
                    }

                    PoolText("connectionpool.invite.cardTitle", fallback: "Invite Card")
                        .font(theme.fontHeading)
                        .foregroundColor(theme.textPrimary)

                    if let url = fileURL {
                        ShareLink(
                            item: url,
                            subject: Text(poolString("connectionpool.invite.shareSubject", fallback: "StealthOS Invite Card")),
                            message: Text(poolString("connectionpool.invite.shareMessage", fallback: "Open this in StealthOS to join my pool."))
                        ) {
                            HStack(spacing: theme.spacingS) {
                                PoolIcon("arrow-up-from-bracket", size: 16, systemFallback: "square.and.arrow.up")
                                PoolText("connectionpool.invite.sendCard", fallback: "Send invite card")
                            }
                            .font(theme.fontBody)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, theme.spacingM)
                            .background(theme.accent)
                            .foregroundColor(theme.textOnAccent)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                        }
                    }

                    if !invitation.isExpired {
                        Text(poolString("connectionpool.invite.expires", fallback: "Expires") + " ")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.textSecondary)
                        + Text(invitation.expiresAt, style: .relative)
                            .font(theme.fontCaption)
                            .foregroundColor(theme.textSecondary)
                    } else {
                        PoolText("connectionpool.invite.expired", fallback: "Expired")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.danger)
                    }

                    DisclosureGroup(poolString("connectionpool.invite.helpTitle", fallback: "Help your friend open it")) {
                        VStack(alignment: .leading, spacing: theme.spacingXS + 2) {
                            PoolText("connectionpool.invite.help1", fallback: "In Messages they tap and hold the file → Share → StealthOS.")
                            PoolText("connectionpool.invite.help2", fallback: "Or save it to Files and open it from inside StealthOS.")
                            PoolText("connectionpool.invite.help3", fallback: "Or scan the QR code from inside StealthOS.")
                        }
                        .font(theme.fontBody)
                        .foregroundColor(theme.textSecondary)
                        .padding(.vertical, theme.spacingXS + 2)
                    }
                    .font(theme.fontBody)
                    .tint(theme.accent)
                    .foregroundColor(theme.textPrimary)

                    if let error {
                        HStack(spacing: theme.spacingS) {
                            PoolIcon("triangle-exclamation", size: 14, systemFallback: "exclamationmark.triangle.fill")
                            Text(error)
                        }
                        .font(theme.fontBody)
                        .foregroundColor(theme.danger)
                    }
                }
                .padding(theme.spacingL)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(poolString("connectionpool.invite.navTitle", fallback: "Invite a Friend"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.done", fallback: "Done")) { dismiss() }
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
