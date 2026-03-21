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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Scan Server Claim QR")
                    .font(.headline)

                Text("Point your camera at the QR code shown in your server's Docker logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                #if os(iOS)
                QRScannerView { code in
                    scannedCode = code
                    isPresented = false
                    onScanned()
                }
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
                #else
                Spacer()
                Image(systemName: "camera.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Camera scanning is only available on iOS")
                    .foregroundStyle(.secondary)
                Spacer()
                #endif
            }
            .navigationTitle("Scan QR Code")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
