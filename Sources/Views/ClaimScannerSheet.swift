// ClaimScannerSheet.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import SwiftUI

/// Sheet presented when the user taps "Scan QR Code" during server claiming.
/// Shows the camera viewfinder with instructions, or a fallback message on macOS.
struct ClaimScannerSheet: View {
    @Binding var scannedCode: String
    @Binding var isPresented: Bool
    let onScanned: () -> Void

    @ObservedObject private var design = PoolDesign.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = design.snapshot(dark: scheme == .dark)
        NavigationStack {
            VStack(spacing: theme.spacingL) {
                PoolText("connectionpool.claim.title", fallback: "Scan Server Claim QR")
                    .font(theme.fontHeading)
                    .foregroundColor(theme.textPrimary)

                PoolText("connectionpool.claim.subtitle", fallback: "Point your camera at the QR code shown in your server's Docker logs.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, theme.spacingL)

                #if os(iOS)
                QRScannerView { code in
                    scannedCode = code
                    isPresented = false
                    onScanned()
                }
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                .padding(theme.spacingL)
                #else
                Spacer()
                PoolIcon("camera", size: 40, systemFallback: "camera.fill")
                    .foregroundColor(theme.textSecondary)
                PoolText("connectionpool.claim.iosOnly", fallback: "Camera scanning is only available on iOS")
                    .foregroundColor(theme.textSecondary)
                Spacer()
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(poolString("connectionpool.claim.navTitle", fallback: "Scan QR Code"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(poolString("common.cancel", fallback: "Cancel")) { isPresented = false }
                }
            }
        }
    }
}
